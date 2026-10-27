#requires -Version 5.1
# Only built-in Windows PowerShell/.NET APIs are used on the client.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Transportlogg.Core.ps1')

function Assert-TransportClientSettings {
    param([Parameter(Mandatory)]$Settings)
    foreach ($name in @('TenantId','ClientId')) {
        $parsed = [guid]::Empty
        if ($null -eq $Settings.PSObject.Properties[$name] -or
            -not [guid]::TryParse([string]$Settings.$name, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw "IT måste konfigurera $name i Installningar.json."
        }
    }
    if ($null -eq $Settings.PSObject.Properties['VerksamhetensDomaner'] -or
        $Settings.VerksamhetensDomaner -is [string] -or @($Settings.VerksamhetensDomaner).Count -eq 0) {
        throw 'IT måste konfigurera VerksamhetensDomaner som en lista i Installningar.json.'
    }
    foreach ($domain in $Settings.VerksamhetensDomaner) {
        if ([string]::IsNullOrWhiteSpace([string]$domain)) { throw 'Verksamhetens domänlista innehåller ett tomt värde.' }
        Assert-TraceAddress "kontroll@$domain"
    }
}

function Get-TransportHttpError {
    param([Parameter(Mandatory)]$Record)
    $code = ''; $requestId = ''; $status = 0
    if ($null -ne $Record.Exception.PSObject.Properties['Response'] -and $null -ne $Record.Exception.Response) {
        $status = [int]$Record.Exception.Response.StatusCode
    }
    if ($null -ne $Record.ErrorDetails -and $Record.ErrorDetails.Message) {
        try {
            $body = $Record.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $body.PSObject.Properties['error']) {
                if ($body.error -is [string]) { $code = $body.error }
                elseif ($null -ne $body.error.PSObject.Properties['code']) {
                    $code = [string]$body.error.code
                    if ($null -ne $body.error.PSObject.Properties['innerError'] -and $null -ne $body.error.innerError.PSObject.Properties['request-id']) {
                        $requestId = [string]$body.error.innerError.'request-id'
                    }
                }
            }
        } catch { }
    }
    [pscustomobject]@{ Code = $code; StatusCode = $status; RequestId = $requestId }
}

function Start-TransportDeviceLogin {
    param([Parameter(Mandatory)]$Settings, [scriptblock]$Request = {
        param($Url,$Body) Invoke-RestMethod -Uri $Url -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 -ErrorAction Stop
    })
    Assert-TransportClientSettings $Settings
    # Delegated user access only: no secret, certificate or application permission.
    $response = & $Request "https://login.microsoftonline.com/$($Settings.TenantId)/oauth2/v2.0/devicecode?mkt=sv-SE" @{
        client_id = $Settings.ClientId; scope = 'https://graph.microsoft.com/ExchangeMessageTrace.Read.All openid profile'
    }
    foreach ($name in @('device_code','user_code','expires_in','interval')) {
        if ($null -eq $response -or $null -eq $response.PSObject.Properties[$name]) { throw 'Microsoft returnerade ett oväntat inloggningssvar.' }
    }
    if ([int]$response.expires_in -le 0 -or [int]$response.interval -lt 1) { throw 'Microsoft returnerade ogiltig giltighetstid för inloggningen.' }
    [pscustomobject]@{
        DeviceCode = [string]$response.device_code; UserCode = [string]$response.user_code
        ExpiresUtc = [datetime]::UtcNow.AddSeconds([int]$response.expires_in)
        IntervalSeconds = [int]$response.interval
    }
}

function Get-TransportDeviceLoginResult {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Session, [scriptblock]$Request = {
        param($Url,$Body) Invoke-RestMethod -Uri $Url -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 20 -ErrorAction Stop
    })
    if ([datetime]::UtcNow -ge $Session.ExpiresUtc) { throw 'Inloggningstiden har gått ut. Tryck på Logga in igen.' }
    try {
        $response = & $Request "https://login.microsoftonline.com/$($Settings.TenantId)/oauth2/v2.0/token" @{
            client_id = $Settings.ClientId; device_code = $Session.DeviceCode
            grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
        }
    } catch {
        $failure = Get-TransportHttpError $_
        switch ($failure.Code) {
            'authorization_pending' { return $null }
            'slow_down' { $Session.IntervalSeconds += 5; return $null }
            'authorization_declined' { throw 'Inloggningen avböjdes.' }
            'expired_token' { throw 'Inloggningstiden har gått ut. Tryck på Logga in igen.' }
            default { throw 'Microsoft kunde inte slutföra inloggningen. Kontakta IT om felet kvarstår.' }
        }
    }
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['access_token'] -or
        $null -eq $response.PSObject.Properties['expires_in'] -or [string]::IsNullOrWhiteSpace([string]$response.access_token) -or
        [int]$response.expires_in -le 60) { throw 'Microsoft returnerade ingen användbar åtkomsttoken.' }
    $accountLabel = 'Microsoftinloggning'
    # ID-token is for our own client. Read only a display label; it is not used for authorization.
    # Never decode the Microsoft Graph access token.
    if ($null -ne $response.PSObject.Properties['id_token']) {
        try {
            $parts = ([string]$response.id_token).Split('.')
            if ($parts.Count -eq 3 -and $parts[1].Length -lt 16384) {
                $payload = $parts[1].Replace('-','+').Replace('_','/')
                $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
                $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
                if ($claims.aud -eq $Settings.ClientId -and $null -ne $claims.PSObject.Properties['preferred_username']) {
                    $accountLabel = [string]$claims.preferred_username
                }
            }
        } catch { $accountLabel = 'Microsoftinloggning' }
    }
    [pscustomobject]@{ AccessToken = [string]$response.access_token; ExpiresUtc = [datetime]::UtcNow.AddSeconds([int]$response.expires_in - 60); AccountLabel = $accountLabel }
}

function Get-TransportAccessToken {
    param(
        [Parameter(Mandatory)]$Authentication
    )
    if ([datetime]::UtcNow -ge $Authentication.ExpiresUtc) { throw 'Din inloggning har gått ut. Logga in igen.' }
    if ([string]::IsNullOrWhiteSpace($Authentication.AccessToken) -or $Authentication.AccessToken -match '[\r\n]') { throw 'Logga in igen.' }
    [string]$Authentication.AccessToken
}

function Invoke-TransportGraphRequest {
    param(
        [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][hashtable]$Headers,
        [hashtable]$State = @{},
        [scriptblock]$Request = { param($Address,$RequestHeaders) Invoke-RestMethod -Uri $Address -Headers $RequestHeaders -Method Get -TimeoutSec 120 -ErrorAction Stop },
        [scriptblock]$Wait = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )
    Assert-TraceGraphUri $Url
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ($State.ContainsKey('NextRequestUtc') -and $State.NextRequestUtc -gt [datetime]::UtcNow) {
            & $Wait ([int][math]::Ceiling(($State.NextRequestUtc - [datetime]::UtcNow).TotalSeconds))
        }
        $State.NextRequestUtc = [datetime]::UtcNow.AddSeconds(4)
        try { return & $Request $Url $Headers }
        catch {
            $failure = Get-TransportHttpError $_
            $reference = if ($failure.RequestId) { " Referens: $($failure.RequestId)" } else { '' }
            if ($failure.StatusCode -eq 401) { throw "Microsoft nekade inloggningen. Logga in igen.$reference" }
            if ($failure.StatusCode -eq 403) { throw "Microsoft nekade åtkomst till transportloggar. Be IT kontrollera delegerad ExchangeMessageTrace.Read.All, administratörsgodkännande och testkontots åtkomst.$reference" }
            if ($failure.StatusCode -notin @(429,503,504) -or $attempt -eq 2) {
                throw "Graph-anropet kunde inte slutföras. Försök igen senare eller kontakta IT.$reference"
            }
            $seconds = 5 * ($attempt + 1)
            try {
                $values = @($_.Exception.Response.Headers.GetValues('Retry-After'))
                if ($values.Count) {
                    $parsedSeconds = 0; $retryDate = [DateTimeOffset]::MinValue
                    if ([int]::TryParse([string]$values[0],[ref]$parsedSeconds)) { $seconds = [math]::Max($seconds,$parsedSeconds) }
                    elseif ([DateTimeOffset]::TryParse([string]$values[0],[ref]$retryDate)) { $seconds = [math]::Max($seconds,[math]::Ceiling(($retryDate.UtcDateTime - [datetime]::UtcNow).TotalSeconds)) }
                }
            } catch { }
            if ($seconds -gt 60) { throw "Microsoft begär längre väntan. Försök igen senare.$reference" }
            & $Wait $seconds
        }
    }
}

function Test-TransportGraphAccess {
    param([Parameter(Mandatory)]$Authentication, [scriptblock]$Request = {
        param($Url,$Headers) Invoke-TransportGraphRequest -Url $Url -Headers $Headers
    })
    $to = [datetime]::UtcNow
    $filter = "receivedDateTime ge $($to.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')) and receivedDateTime le $($to.ToString('yyyy-MM-ddTHH:mm:ssZ')) and senderAddress eq 'transportlogg-behorighetskontroll@invalid.example'"
    $url = 'https://graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces?$top=1&$filter=' + [uri]::EscapeDataString($filter)
    $response = & $Request $url @{ Authorization = 'Bearer ' + (Get-TransportAccessToken $Authentication); Accept = 'application/json' }
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['value'] -or $null -eq $response.value) { throw 'Graph returnerade ett oväntat svar vid åtkomstkontrollen.' }
}

function Show-TransportSignIn {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Owner)
    $session = Start-TransportDeviceLogin $Settings
    $window = [Windows.Forms.Form]::new()
    $window.Text = 'Logga in med Microsoft'; $window.Size = [Drawing.Size]::new(530,310)
    $window.StartPosition = 'CenterParent'; $window.FormBorderStyle = 'FixedDialog'; $window.MaximizeBox = $false
    $window.Font = [Drawing.Font]::new('Segoe UI',11)
    $instructions = [Windows.Forms.Label]::new()
    $instructions.Text = 'Öppna Microsofts inloggningssida, ange koden nedan och logga in med ditt arbetskonto. Återvänd sedan hit.'
    $instructions.SetBounds(20,20,470,65); $window.Controls.Add($instructions)
    $code = [Windows.Forms.TextBox]::new(); $code.ReadOnly = $true; $code.Text = $session.UserCode
    $code.Font = [Drawing.Font]::new('Consolas',20); $code.SetBounds(20,95,470,45); $window.Controls.Add($code)
    $open = [Windows.Forms.Button]::new(); $open.Text = 'Öppna inloggning'; $open.SetBounds(20,155,230,38)
    $open.Add_Click({ Start-Process -FilePath 'https://microsoft.com/devicelogin' }); $window.Controls.Add($open)
    $cancel = [Windows.Forms.Button]::new(); $cancel.Text = 'Avbryt'; $cancel.DialogResult = 'Cancel'; $cancel.SetBounds(270,155,220,38)
    $window.CancelButton = $cancel; $window.Controls.Add($cancel)
    $hint = [Windows.Forms.Label]::new(); $hint.Text = 'Väntar på att du loggar in ...'; $hint.SetBounds(20,210,470,45); $window.Controls.Add($hint)
    $state = @{ Result = $null; Error = '' }
    $timer = [Windows.Forms.Timer]::new(); $timer.Interval = $session.IntervalSeconds * 1000
    $timer.Add_Tick({
        $timer.Stop()
        try {
            $result = Get-TransportDeviceLoginResult -Settings $Settings -Session $session
            if ($null -ne $result) { $state.Result = $result; $window.DialogResult = 'OK'; $window.Close() }
            else { $timer.Interval = $session.IntervalSeconds * 1000; $timer.Start() }
        } catch { $state.Error = $_.Exception.Message; $window.DialogResult = 'Abort'; $window.Close() }
    })
    try {
        $timer.Start(); [void]$window.ShowDialog($Owner)
        if ($state.Error) { throw $state.Error }
        if ($null -eq $state.Result) { throw 'Inloggningen avbröts.' }
        $state.Result
    } finally { $timer.Stop(); $timer.Dispose(); $window.Dispose() }
}

function Assert-TraceGraphUri {
    param([Parameter(Mandatory)][string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'graph.microsoft.com' -or
        $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or
        $uri.AbsolutePath -cne '/v1.0/admin/exchange/tracing/messageTraces') {
        throw 'Graph returnerade en oväntad sidlänk. Sökningen avbröts.'
    }
}

function Get-GraphTraceBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][scriptblock]$AccessTokenProvider,
        [ValidateRange(1,50000)][int]$MaximumItems = 50000,
        [scriptblock]$Request = {
            param($Url, $Headers)
            Invoke-TransportGraphRequest -Url $Url -Headers $Headers -State $requestState
        }
    )
    $requestState = @{}
    $start = ([datetime]$Parameters.StartDate).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $end = ([datetime]$Parameters.EndDate).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $filters = [Collections.Generic.List[string]]::new()
    $filters.Add("receivedDateTime ge $start")
    $filters.Add("receivedDateTime le $end")
    foreach ($entry in @(@('SenderAddress','senderAddress'),@('RecipientAddress','recipientAddress'))) {
        if ($Parameters.ContainsKey($entry[0])) {
            $address = [string]$Parameters[$entry[0]]
            Assert-TraceAddress $address
            $escaped = $address.Replace("'", "''")
            $filters.Add("$($entry[1]) eq '$escaped'")
        }
    }
    $filter = [uri]::EscapeDataString(($filters -join ' and '))
    $url = 'https://graph.microsoft.com/v1.0/admin/exchange/tracing/messageTraces?$top=5000&$filter=' + $filter
    $seenLinks = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rows = [Collections.Generic.List[object]]::new()
    do {
        # Validate before acquiring a token or sending it to a continuation URL.
        Assert-TraceGraphUri $url
        if (-not $seenLinks.Add($url)) { throw 'Graph upprepade samma sidlänk. Sökningen avbröts.' }
        $token = [string](& $AccessTokenProvider)
        if ([string]::IsNullOrWhiteSpace($token) -or $token -match '[\r\n]') {
            throw 'Ingen giltig åtkomsttoken för Graph är tillgänglig.'
        }
        $page = & $Request $url @{ Authorization = "Bearer $token"; Accept = 'application/json' }
        if ($null -eq $page -or $null -eq $page.PSObject.Properties['value'] -or $null -eq $page.value) {
            throw 'Graph returnerade ett oväntat svar. Sökningen avbröts.'
        }
        foreach ($item in @($page.value)) {
            if ($rows.Count -ge $MaximumItems) { throw 'Graph-sökningen har för många träffar. Begränsa period eller verksamhetsadress.' }
            foreach ($required in @('id','receivedDateTime','senderAddress','recipientAddress','status')) {
                if ($null -eq $item -or $null -eq $item.PSObject.Properties[$required] -or
                    [string]::IsNullOrWhiteSpace([string]$item.$required)) {
                    throw 'Graph returnerade en ofullständig träff. Sökningen avbröts.'
                }
            }
            $received = [DateTimeOffset]::Parse([string]$item.receivedDateTime, [Globalization.CultureInfo]::InvariantCulture)
            $subject = if ($null -ne $item.PSObject.Properties['subject']) { [string]$item.subject } else { '' }
            $rows.Add([pscustomobject]@{
                Received = $received.UtcDateTime
                SenderAddress = [string]$item.senderAddress
                RecipientAddress = [string]$item.recipientAddress
                MessageTraceId = [string]$item.id
                Status = [string]$item.status
                Subject = $subject
            })
        }
        $url = if ($null -ne $page.PSObject.Properties['@odata.nextLink']) { [string]$page.'@odata.nextLink' } else { '' }
    } while ($url)
    # Emit only after every page has succeeded.
    $rows.ToArray()
}

function Invoke-GraphTransportSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [string]$OrganizationAddress = '',
        [Parameter(Mandatory)][string[]]$AllowedDomains,
        [ValidateSet('Båda','Till verksamheten','Från verksamheten')][string]$Direction = 'Båda',
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][datetime]$EndUtc,
        [Parameter(Mandatory)][scriptblock]$AccessTokenProvider,
        [scriptblock]$Progress = { param($Message) },
        [ValidateRange(1,50000)][int]$MaximumRows = 50000,
        [scriptblock]$Request = {
            param($Url, $Headers)
            Invoke-TransportGraphRequest -Url $Url -Headers $Headers -State $requestState
        }
    )
    $query = {
        param($Parameters)
        Get-GraphTraceBatch -Parameters $Parameters -AccessTokenProvider $AccessTokenProvider -Request $Request -MaximumItems $MaximumRows
    }
    Invoke-TransportSearch -Address $Address -OrganizationAddress $OrganizationAddress -AllowedDomains $AllowedDomains `
        -Direction $Direction -StartUtc $StartUtc -EndUtc $EndUtc -Query $query -CompleteQuery -QueryAttempts 1 -Progress $Progress -MaximumRows $MaximumRows
}
