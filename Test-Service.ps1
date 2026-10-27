#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Transportlogg.Graph.ps1')
. (Join-Path $PSScriptRoot 'azure/function/shared/Transportlogg.Service.ps1')
$script:checks = 0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "TEST MISSLYCKADES: $Message" }
    $script:checks++
}
$tenant = '11111111-1111-1111-1111-111111111111'
$client = '22222222-2222-2222-2222-222222222222'
$user = '33333333-3333-3333-3333-333333333333'
function New-Principal($TenantValue = $tenant,$ClientValue = $client,$Role = 'Trace.Reader',$Scope = 'Transportlogg.Access') {
    $json = @{ auth_typ = 'aad'; claims = @(
        @{ typ = 'tid'; val = $TenantValue }, @{ typ = 'azp'; val = $ClientValue }, @{ typ = 'oid'; val = $user }
        @{ typ = 'roles'; val = $Role }, @{ typ = 'scp'; val = $Scope }, @{ typ = 'preferred_username'; val = 'handlaggare@kommun.example' }
    ) } | ConvertTo-Json -Depth 5
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}
$state = @{ Calls = 0; Arguments = $null }
$row = [pscustomobject]@{
    TidSverige = '2026-01-01 12:00:00'; TidUTC = '2026-01-01T11:00:00Z'; Riktning = 'Till verksamheten'
    Avsandare = 'invanare@example.net'; Mottagare = 'registrator@kommun.example'; Status = 'Levererat enligt Exchange'
    TekniskStatus = 'delivered'; SparningsId = 'trace-1'; Amne = 'Känsligt ämne'; ExtraInternalField = 'Hämta inte detta'
}
$search = { param($Arguments) $state.Calls++; $state.Arguments = $Arguments; $row }
$base = @{ PrincipalHeader = (New-Principal); TenantId = $tenant; ClientId = $client; AllowedDomains = @('kommun.example'); Search = $search }
$result = Invoke-TransportService @base -Body ([pscustomobject]@{ action = 'session' })
Assert ($result.StatusCode -eq 200 -and $result.Body.userName -eq 'handlaggare@kommun.example') 'Tilldelad användare kan öppna session'
Assert ($state.Calls -eq 0) 'Session anropar inte Graph'
Assert ($result.Body.allowedDomains[0] -eq 'kommun.example') 'Domäner kommer från servern'
foreach ($principal in @('', 'not-base64', (New-Principal -TenantValue $client), (New-Principal -ClientValue $tenant), (New-Principal -Role 'Other'), (New-Principal -Scope 'Other'))) {
    $argsForCall = $base.Clone(); $argsForCall.PrincipalHeader = $principal
    $result = Invoke-TransportService @argsForCall -Body ([pscustomobject]@{ action = 'session' })
    Assert ($result.StatusCode -eq 403) 'Saknad eller felaktig identitet/roll/scope nekas'
}
$now = [datetime]::UtcNow
$body = [pscustomobject]@{
    action = 'search'; address = 'invanare@example.net'; organizationAddress = ''; direction = 'Till verksamheten'
    startUtc = $now.AddDays(-3).ToString('o'); endUtc = $now.AddDays(-1).ToString('o'); includeSubject = $false
    AllowedDomains = @('annan.example'); MaximumRows = 999999; Query = 'farlig kod'
}
$result = Invoke-TransportService @base -Body $body
Assert ($result.StatusCode -eq 200 -and @($result.Body.rows).Count -eq 1) 'Giltig sökning returnerar träff'
Assert ($state.Arguments.AllowedDomains[0] -eq 'kommun.example' -and $state.Arguments.MaximumRows -eq 10000) 'Klienten kan inte utöka servergränserna'
Assert (-not $state.Arguments.ContainsKey('Query')) 'Klientens kommandon vidarebefordras inte'
Assert ($result.Body.rows[0].Amne -eq '') 'Ämne skickas inte till klienten som standard'
Assert ('ExtraInternalField' -notin $result.Body.rows[0].PSObject.Properties.Name) 'Endast kända svarsfält returneras'
$body.includeSubject = $true
$result = Invoke-TransportService @base -Body $body
Assert ($result.Body.rows[0].Amne -eq 'Känsligt ämne') 'Ämne kan begäras uttryckligen'
$body.organizationAddress = 'x@annan.example'
$result = Invoke-TransportService @base -Body $body
Assert ($result.StatusCode -eq 400) 'Verksamhetsadress utanför serverns domäner nekas'
$body.organizationAddress = ''; $body.includeSubject = 'false'
$result = Invoke-TransportService @base -Body $body
Assert ($result.StatusCode -eq 400) 'Ämnesval måste vara en JSON-boolean'
$body.includeSubject = $false; $body.startUtc = $now.AddDays(-91).ToString('o')
$result = Invoke-TransportService @base -Body $body
Assert ($result.StatusCode -eq 400) 'För gammal period nekas på servern'
$body.startUtc = $now.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ss')
$result = Invoke-TransportService @base -Body $body
Assert ($result.StatusCode -eq 400) 'Tidszon måste anges som UTC'
$body.startUtc = $now.AddDays(-3).ToString('o')
$errorArgs = $base.Clone(); $errorArgs.Search = { param($Arguments) throw 'TOKEN eller intern teknisk information' }
$result = Invoke-TransportService @errorArgs -Body $body
Assert ($result.StatusCode -eq 503 -and $result.Body.message -notmatch 'TOKEN') 'Interna fel och hemligheter lämnar inte servern'
Assert ($result.Body.Contains('requestId') -and -not $result.Body.Contains('rows')) 'Felsvar har referens men inga partiella träffar'
$result = Invoke-TransportService @base -Body ([pscustomobject]@{ action = 'other' })
Assert ($result.StatusCode -eq 400) 'Okänd åtgärd nekas'
$cached = @{ Token = 'cached-token'; TokenExpiresUtc = [datetime]::UtcNow.AddHours(1) }
Assert ((Get-TransportManagedIdentityToken -State $cached) -eq 'cached-token') 'Managed identity-token återanvänds i samma sökning'

# Integration: Graph response -> server authorization/filter -> client-compatible result.
$integrated = $base.Clone()
$graphItem = [pscustomobject]@{
    id = 'graph-id'; senderAddress = $body.address; recipientAddress = 'registrator@kommun.example'
    receivedDateTime = $now.AddDays(-2).ToString('o'); status = 'delivered'; subject = 'Integrerat test'
}
$integrated.Search = {
    param($Arguments)
    Invoke-GraphTransportSearch @Arguments -AccessTokenProvider { 'simulated-token' } -Request {
        param($Url,$Headers) [pscustomobject]@{ value = @($graphItem) }
    }
}
$result = Invoke-TransportService @integrated -Body $body
Assert ($result.StatusCode -eq 200 -and $result.Body.rows[0].SparningsId -eq 'graph-id') 'Graph-adaptern fungerar bakom tjänstens åtkomstkontroll'

function Throw-TestThrottle([int]$RetrySeconds) {
    $exception = [InvalidOperationException]::new('Throttled')
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{
        StatusCode = 429; Headers = [pscustomobject]@{ RetryAfter = [pscustomobject]@{ Delta = [timespan]::FromSeconds($RetrySeconds); Date = $null } }
    })
    throw $exception
}
$httpState = @{ Calls = 0; Waits = [Collections.Generic.List[int]]::new() }
$budget = @{ DeadlineUtc = [datetime]::UtcNow.AddSeconds(100) }
$httpResponse = Invoke-TransportGraphHttp -Url 'https://graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces' -Headers @{} -State $budget -Wait {
    param($Seconds) $httpState.Waits.Add([int]$Seconds)
} -Request {
    param($Address,$RequestHeaders,$Timeout) $httpState.Calls++
    if ($httpState.Calls -eq 1) { Throw-TestThrottle 7 }
    [pscustomobject]@{ value = @() }
}
Assert ($httpState.Calls -eq 2 -and 7 -in $httpState.Waits) '429 följer Retry-After och försöker igen'
$denied = $false
try {
    Invoke-TransportGraphHttp -Url 'https://graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces' -Headers @{} -State @{ DeadlineUtc = [datetime]::UtcNow.AddSeconds(10) } -Wait {
        param($Seconds) throw 'Ska inte vänta'
    } -Request { Throw-TestThrottle 120 } | Out-Null
} catch { $denied = $_.Exception.Message -like '*time budget*' }
Assert $denied 'Retry-After utanför tidsbudgeten avbryter i stället för att försöka för tidigt'
Write-Output "Godkänt: $script:checks tjänstekontroller (utan Azure/Graph-anslutning)."
