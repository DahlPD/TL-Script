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
function Throw-HttpError([string]$Code) {
    $errorRecord = [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('HTTP error'), 'HttpFailure', [Management.Automation.ErrorCategory]::InvalidOperation, $null)
    $errorRecord.ErrorDetails = [Management.Automation.ErrorDetails]::new((@{ error = $Code } | ConvertTo-Json))
    throw $errorRecord
}
$settings = [pscustomobject]@{
    TenantId = '11111111-1111-1111-1111-111111111111'; ClientId = '22222222-2222-2222-2222-222222222222'
    ApiAppId = '33333333-3333-3333-3333-333333333333'; ApiBasUrl = 'https://transportlogg.azurewebsites.net'
}
Assert-TransportClientSettings $settings
foreach ($bad in @('http://transportlogg.azurewebsites.net','https://transportlogg.azurewebsites.net/?code=secret','https://user@transportlogg.azurewebsites.net','https://transportlogg.azurewebsites.net/api/transportlogg')) {
    $copy = $settings | Select-Object *; $copy.ApiBasUrl = $bad
    Assert-Throws { Assert-TransportClientSettings $copy } 'Ogiltig API-basadress nekas'
}
$copy = $settings | Select-Object *; $copy.ClientId = ''
Assert-Throws { Assert-TransportClientSettings $copy } 'Tom klientkonfiguration nekas'
$session = Start-TransportDeviceLogin -Settings $settings -Request {
    param($Url,$Body)
    Assert ($Url -like 'https://login.microsoftonline.com/111*/oauth2/v2.0/devicecode*') 'Tenantbunden inloggning'
    Assert ($Body.scope -eq "api://$($settings.ApiAppId)/Transportlogg.Access") 'Klienten begär API-behörighet, inte Graph-behörighet'
    Assert (-not $Body.ContainsKey('client_secret')) 'Ingen klienthemlighet skickas'
    [pscustomobject]@{ device_code = 'device-code'; user_code = 'ABCDE123'; expires_in = 900; interval = 5 }
}
Assert ($session.UserCode -eq 'ABCDE123' -and $session.IntervalSeconds -eq 5) 'Engångskod och pollningsintervall läses'
$pending = Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request { Throw-HttpError 'authorization_pending' }
Assert ($null -eq $pending) 'Pågående inloggning är inget fel'
$null = Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request { Throw-HttpError 'slow_down' }
Assert ($session.IntervalSeconds -eq 10) 'slow_down förlänger intervallet'
Assert-Throws { Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request { Throw-HttpError 'authorization_declined' } } 'Avböjd inloggning avbryts'
$auth = Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request {
    param($Url,$Body)
    Assert ($Body.grant_type -eq 'urn:ietf:params:oauth:grant-type:device_code' -and $Body.device_code -eq 'device-code') 'Koden byts mot token med rätt flöde'
    [pscustomobject]@{ access_token = 'user-api-token'; expires_in = 3600 }
}
Assert ($auth.AccessToken -eq 'user-api-token') 'Användartoken hålls i minnet'
$state = @{ Calls = 0 }
$response = Invoke-TransportApi -Settings $settings -Authentication $auth -Body @{ action = 'session' } -Request {
    param($Url,$Headers,$Json)
    $state.Calls++
    Assert ($Url -eq 'https://transportlogg.azurewebsites.net/api/transportlogg') 'Klienten anropar bara sin tjänst'
    Assert ($Headers.Authorization -eq 'Bearer user-api-token') 'Användartoken skickas till tjänsten'
    Assert (($Json | ConvertFrom-Json).action -eq 'session') 'Begäran skickas som JSON'
    [pscustomobject]@{ schemaVersion = 1; userName = 'handlaggare@kommun.example' }
}
Assert ($response.userName -eq 'handlaggare@kommun.example') 'Användarnamn kommer från verifierad tjänstesession'
$auth.ExpiresUtc = [datetime]::UtcNow.AddSeconds(-1)
Assert-Throws { Invoke-TransportApi -Settings $settings -Authentication $auth -Body @{ action = 'session' } -Request { $state.Calls++ } } 'Utgången inloggning kräver ny inloggning'
Assert ($state.Calls -eq 1) 'Utgången token skickas inte'
$session.ExpiresUtc = [datetime]::UtcNow.AddSeconds(-1)
Assert-Throws { Get-TransportDeviceLoginResult -Settings $settings -Session $session -Request { throw 'Ska ej köras' } } 'Utgången engångskod avvisas'
Write-Output "Godkänt: $script:checks klientkontroller (utan inloggning eller nätverksanrop)."
