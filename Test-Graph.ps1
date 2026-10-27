#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Handläggare/Transportlogg.Client.ps1')
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "TEST MISSLYCKADES: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    Assert $thrown $Message
}
$from = [datetime]::UtcNow.AddDays(-3)
$to = $from.AddDays(1)
$parameters = @{ StartDate = $from; EndDate = $to; SenderAddress = "o'hara@example.net"; RecipientAddress = 'registrator@kommun.example' }
$item = [pscustomobject]@{
    id = 'trace-1'; receivedDateTime = $from.AddHours(1).ToString('o')
    senderAddress = "o'hara@example.net"; recipientAddress = 'registrator@kommun.example'
    status = 'delivered'; subject = 'Test'
}
$state = @{ Calls = 0; Urls = [Collections.Generic.List[string]]::new() }
$next = 'https://graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces?$skiptoken=opaque%2Btoken'
$request = {
    param($Url,$Headers)
    $state.Calls++
    $state.Urls.Add($Url)
    Assert ($Headers.Authorization -eq 'Bearer test-token') 'Token skickas i Authorization'
    if ($state.Calls -eq 1) { [pscustomobject]@{ value = @($item); '@odata.nextLink' = $next } }
    else { [pscustomobject]@{ value = @($item) } }
}
$rows = @(Get-GraphTraceBatch -Parameters $parameters -AccessTokenProvider { 'test-token' } -Request $request)
Assert ($rows.Count -eq 2 -and $state.Calls -eq 2) 'Alla sidor hämtas'
Assert ($state.Urls[1] -ceq $next) 'nextLink används oförändrad'
$decoded = [uri]::UnescapeDataString($state.Urls[0])
Assert ($decoded.Contains("senderAddress eq 'o''hara@example.net'")) 'Apostrof i adress OData-kodas'
Assert ($decoded.Contains("recipientAddress eq 'registrator@kommun.example'")) 'Verksamhetsadress begränsar anropet'
Assert ($rows[0].Received.Kind -eq [DateTimeKind]::Utc) 'Graph-tider konverteras till UTC'
Assert ($rows[0].MessageTraceId -eq 'trace-1') 'Graph-fält mappas till befintlig exportmodell'

foreach ($bad in @('https://example.net/v1.0/admin/exchange/tracing/messageTraces',
    'http://graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces',
    'https://graph.microsoft.com/v1.0/users',
    'https://graph.microsoft.com:444/v1.0/admin/exchange/tracing/messageTraces',
    'https://user@graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces')) {
    Assert-Throws { Assert-TraceGraphUri $bad } 'Ovän­tad Graph-URL avvisas'
}
$state.Calls = 0
Assert-Throws {
    Get-GraphTraceBatch -Parameters $parameters -AccessTokenProvider { 'test-token' } -Request {
        param($Url,$Headers) $state.Calls++
        [pscustomobject]@{ value = @($item); '@odata.nextLink' = 'https://example.net/steal-token' }
    }
} 'Främmande nextLink avvisas före anrop'
Assert ($state.Calls -eq 1) 'Ingen token skickas till en annan värd'
Assert-Throws {
    Get-GraphTraceBatch -Parameters $parameters -AccessTokenProvider { 'test-token' } -Request {
        param($Url,$Headers) [pscustomobject]@{ value = @($item); '@odata.nextLink' = $next }
    }
} 'Upprepade sidlänkar avvisas'
Assert-Throws {
    Get-GraphTraceBatch -Parameters $parameters -MaximumItems 1 -AccessTokenProvider { 'test-token' } -Request {
        param($Url,$Headers) [pscustomobject]@{ value = @($item,$item) }
    }
} 'För stort resultat avvisas'
Assert-Throws {
    Get-GraphTraceBatch -Parameters $parameters -AccessTokenProvider { '' } -Request { throw 'Ska inte anropas' }
} 'Tom token avvisas'
Assert-Throws {
    Get-GraphTraceBatch -Parameters $parameters -AccessTokenProvider { 'test-token' } -Request { [pscustomobject]@{ error = 'Fel' } }
} 'Svar utan value avvisas'

$rows = @(Invoke-GraphTransportSearch -Address "o'hara@example.net" -AllowedDomains @('kommun.example') `
    -Direction 'Till verksamheten' -StartUtc $from -EndUtc $to -AccessTokenProvider { 'test-token' } -Request {
        param($Url,$Headers) [pscustomobject]@{ value = @($item,$item) }
    })
Assert ($rows.Count -eq 1 -and $rows[0].TekniskStatus -eq 'delivered') 'Graph-sökning deduplicerar och behåller ursprunglig status'
Assert ($rows[0].Status -eq 'Levererat enligt Exchange') 'Graph-status med gemener översätts'

$state.Calls = 0
$rows = @(Invoke-GraphTransportSearch -Address "o'hara@example.net" -AllowedDomains @('kommun.example') `
    -Direction 'Till verksamheten' -StartUtc $from -EndUtc $to -AccessTokenProvider { 'test-token' } -Request {
        param($Url,$Headers) $state.Calls++
        [pscustomobject]@{ value = @(for ($i=0; $i -lt 5000; $i++) { $item }) }
    })
Assert ($state.Calls -eq 1 -and $rows.Count -eq 1) 'Komplett Graph-resultat på 5000 rader delas inte i onödan'
Write-Output "Godkänt: $script:checks Graph-kontroller (utan nätverksanrop)."
