#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Handläggare/Transportlogg.Client.ps1')
$script:checks = 0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "TEST MISSLYCKADES: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action,[string]$Message) {
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    Assert $thrown $Message
}
function Throw-HttpError([string]$Code,[int]$Status = 400,[int]$RetrySeconds = 0) {
    $exception = [InvalidOperationException]::new('HTTP error')
    $responseHeaders = [Collections.Specialized.NameValueCollection]::new()
    if ($RetrySeconds) { $responseHeaders.Add('Retry-After',[string]$RetrySeconds) }
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status; Headers = $responseHeaders })
    $errorRecord = [Management.Automation.ErrorRecord]::new($exception,'HttpFailure',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
    $errorRecord.ErrorDetails = [Management.Automation.ErrorDetails]::new((@{ error = $Code } | ConvertTo-Json))
    throw $errorRecord
}
$settings = [pscustomobject]@{
    TenantId = '11111111-1111-1111-1111-111111111111'; ClientId = '22222222-2222-2222-2222-222222222222'
    VerksamhetensDomaner = @('kommun.example')
}
Assert-TransportClientSettings $settings
$copy = $settings | Select-Object *; $copy.ClientId = ''
Assert-Throws { Assert-TransportClientSettings $copy } 'Tomt klient-ID nekas'
$copy = $settings | Select-Object *; $copy.TenantId = 'common'
Assert-Throws { Assert-TransportClientSettings $copy } 'Inloggningen måste vara tenantbunden'
foreach ($bad in @(@(), @(''), @('*.example'), @('kommun.example',''))) {
    $copy = $settings | Select-Object *; $copy.VerksamhetensDomaner = $bad
    Assert-Throws { Assert-TransportClientSettings $copy } 'Ofullständig eller ogiltig domänlista nekas'
}
$session = Start-TransportDeviceLogin -Settings $settings -Request {
    param($Url,$Body)
    Assert ($Url -like 'https://login.microsoftonline.com/111*/oauth2/v2.0/devicecode*') 'Tenantbunden inloggning'
    Assert ($Body.scope -eq 'https://graph.microsoft.com/ExchangeMessageTrace.Read.All openid profile') 'Endast delegerad Graph-spårning och inloggningsscopes begärs'
    Assert (-not $Body.ContainsKey('client_secret')) 'Ingen klienthemlighet skickas'
    [pscustomobject]@{ device_code = 'device-code'; user_code = 'ABCDE123'; expires_in = 900; interval = 5 }
}
Assert ($session.UserCode -eq 'ABCDE123' -and $session.IntervalSeconds -eq 5) 'Kod och intervall läses'
$pending = Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request { Throw-HttpError 'authorization_pending' }
Assert ($null -eq $pending) 'Pågående inloggning är inget fel'
$null = Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request { Throw-HttpError 'slow_down' }
Assert ($session.IntervalSeconds -eq 10) 'slow_down respekteras'
Assert-Throws { Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request { Throw-HttpError 'authorization_declined' } } 'Avböjd inloggning avbryts'
$idPayload = @{ aud = $settings.ClientId; preferred_username = 'handlaggare@kommun.example' } | ConvertTo-Json -Compress
$idPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($idPayload)).TrimEnd('=').Replace('+','-').Replace('/','_')
$auth = Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request {
    param($Url,$Body)
    Assert ($Body.grant_type -eq 'urn:ietf:params:oauth:grant-type:device_code' -and $Body.device_code -eq 'device-code') 'Rätt tokenflöde'
    # The Graph access token is deliberately opaque. It must not be decoded as JWT.
    [pscustomobject]@{ access_token = 'opaque-graph-user-token'; expires_in = 3600; id_token = "header.$idPayload.signature" }
}
Assert ($auth.AccountLabel -eq 'handlaggare@kommun.example') 'ID-token för egen klient ger bara visningsnamnet'
Assert ((Get-TransportAccessToken $auth) -eq 'opaque-graph-user-token') 'Graph-token behandlas som en ogenomskinlig sträng'
$testState = @{ Calls = 0 }
Test-TransportGraphAccess -Authentication $auth -Request {
    param($Url,$Headers) $testState.Calls++
    Assert ($Url -like 'https://graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces?*') 'Åtkomstkontrollen anropar Graph direkt'
    Assert ($Headers.Authorization -eq 'Bearer opaque-graph-user-token') 'Användartoken används direkt'
    Assert ([uri]::UnescapeDataString($Url).Contains('transportlogg-behorighetskontroll@invalid.example')) 'Inloggningen gör en avgränsad behörighetskontroll'
    [pscustomobject]@{ value = @() }
}
Assert ($testState.Calls -eq 1) 'Åtkomstkontroll utan egen server'
$auth.ExpiresUtc = [datetime]::UtcNow.AddSeconds(-1)
Assert-Throws { Test-TransportGraphAccess -Authentication $auth -Request { $testState.Calls++ } } 'Utgången inloggning kräver ny inloggning'
Assert ($testState.Calls -eq 1) 'Utgången token skickas inte'
$session.ExpiresUtc = [datetime]::UtcNow.AddSeconds(-1)
Assert-Throws { Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request { throw 'Ska ej köras' } } 'Utgången engångskod avvisas'

$uri = 'https://graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces?$top=1'
$testState = @{ Calls = 0; Waits = [Collections.Generic.List[int]]::new() }
$null = Invoke-TransportGraphRequest -Url $uri -Headers @{} -Wait { param($Seconds) $testState.Waits.Add([int]$Seconds) } -Request {
    param($Url,$Headers) $testState.Calls++
    if ($testState.Calls -eq 1) { Throw-HttpError 'TooManyRequests' 429 7 }
    [pscustomobject]@{ value = @() }
}
Assert ($testState.Calls -eq 2 -and 7 -in $testState.Waits) '429 följer Retry-After'
$testState.Calls = 0
Assert-Throws {
    Invoke-TransportGraphRequest -Url $uri -Headers @{} -Wait { throw 'Ska ej vänta' } -Request {
        param($Url,$Headers) $testState.Calls++; Throw-HttpError 'TooManyRequests' 429 120
    }
} 'Lång Retry-After avbryter utan att försöka för tidigt'
Assert ($testState.Calls -eq 1) 'Ingen för tidig omsökning vid lång väntan'
$testState.Calls = 0
Assert-Throws {
    Invoke-TransportGraphRequest -Url $uri -Headers @{} -Request { $testState.Calls++; Throw-HttpError 'Forbidden' 403 }
} 'Nekad Graph-behörighet blir ett tydligt fel'
Assert ($testState.Calls -eq 1) '403 återförsöks inte'
Assert-Throws { Invoke-TransportGraphRequest -Url 'https://example.net/steal' -Headers @{ Authorization = 'Bearer test' } -Request { throw 'Ska ej anropas' } } 'Token skickas aldrig till främmande värd'

# Regression: the normal Graph search path must use the module-free HTTP transport.
$httpCalls = @{ Count = 0; Mode = 'success' }
function Invoke-RestMethod {
    param($Uri,$Headers,$Method,$TimeoutSec,$ErrorAction)
    $httpCalls.Count++
    if ($httpCalls.Mode -eq 'forbidden') { Throw-HttpError 'Forbidden' 403 }
    [pscustomobject]@{ value = @([pscustomobject]@{
        id = 'integrated-id'; receivedDateTime = [datetime]::UtcNow.AddDays(-2).ToString('o')
        senderAddress = 'invanare@example.net'; recipientAddress = 'registrator@kommun.example'; status = 'delivered'; subject = 'Test'
    }) }
}
$rows = @(Invoke-GraphTransportSearch -Address 'invanare@example.net' -AllowedDomains @('kommun.example') -Direction 'Till verksamheten' `
    -StartUtc ([datetime]::UtcNow.AddDays(-3)) -EndUtc ([datetime]::UtcNow.AddDays(-1)) -AccessTokenProvider { 'opaque-token' })
Assert ($rows.Count -eq 1 -and $httpCalls.Count -eq 1) 'Sökning går genom HTTP-transporten utan server eller moduler'
$httpCalls.Count = 0; $httpCalls.Mode = 'forbidden'
Assert-Throws {
    Invoke-GraphTransportSearch -Address 'invanare@example.net' -AllowedDomains @('kommun.example') -Direction 'Till verksamheten' `
        -StartUtc ([datetime]::UtcNow.AddDays(-3)) -EndUtc ([datetime]::UtcNow.AddDays(-1)) -AccessTokenProvider { 'opaque-token' }
} 'Nekad sökning ger inget partiellt sökresultat'
Assert ($httpCalls.Count -eq 1) 'Sökmotorn återförsöker inte ett avslaget Graph-anrop'
Write-Output "Godkänt: $script:checks klientkontroller (utan inloggning eller nätverksanrop)."
