using namespace System.Net
param($Request, $TriggerMetadata)
$ErrorActionPreference = 'Stop'
$shared = Join-Path (Split-Path $PSScriptRoot -Parent) 'shared'
. (Join-Path $shared 'Transportlogg.Core.ps1')
. (Join-Path $shared 'Transportlogg.Graph.ps1')
. (Join-Path $shared 'Transportlogg.Service.ps1')

# Anonymous here means no shared function key. Easy Auth is mandatory at the app boundary.
$state = @{ DeadlineUtc = [datetime]::UtcNow.AddSeconds(100) }
try {
    $domains = @($env:TL_ALLOWED_DOMAINS | ConvertFrom-Json -ErrorAction Stop)
    $body = $Request.Body
    if ($body -is [string]) {
        if ($body.Length -gt 8192) { throw 'Request is too large' }
        $body = $body | ConvertFrom-Json -ErrorAction Stop
    }
    # Re-serialize because PowerShell Functions may supply Body as a hashtable.
    $body = $body | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $result = Invoke-TransportService -PrincipalHeader ([string]$Request.Headers['x-ms-client-principal']) `
        -Body $body -TenantId $env:TL_TENANT_ID -ClientId $env:TL_CLIENT_ID -AllowedDomains $domains -Search {
            param($Arguments)
            Invoke-GraphTransportSearch @Arguments -AccessTokenProvider { Get-TransportManagedIdentityToken -State $state } `
                -Request { param($Url,$Headers) Invoke-TransportGraphHttp -Url $Url -Headers $Headers -State $state }
        }
} catch {
    $reference = [guid]::NewGuid().ToString()
    Write-Warning "Transportlogg configuration/request error. Reference: $reference"
    $result = @{ StatusCode = 400; Body = @{ schemaVersion = 1; error = 'invalid_request'; message = 'Begäran eller tjänstens konfiguration är ogiltig. Kontakta IT.'; requestId = $reference } }
}
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $result.StatusCode
    Headers = @{ 'Content-Type' = 'application/json; charset=utf-8'; 'Cache-Control' = 'no-store'; 'X-Content-Type-Options' = 'nosniff' }
    Body = ($result.Body | ConvertTo-Json -Depth 8 -Compress)
})
