#requires -Version 5.1
# Only built-in Windows PowerShell/.NET APIs are used on the client.
Set-StrictMode -Version Latest

function Assert-TransportClientSettings {
    param([Parameter(Mandatory)]$Settings)
    foreach ($name in @('TenantId','ClientId','ApiAppId')) {
        $parsed = [guid]::Empty
        if ($null -eq $Settings.PSObject.Properties[$name] -or
            -not [guid]::TryParse([string]$Settings.$name, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw "IT måste konfigurera $name i Installningar.json."
        }
    }
    $uri = $null
    if ($null -eq $Settings.PSObject.Properties['ApiBasUrl'] -or
        -not [uri]::TryCreate([string]$Settings.ApiBasUrl,[UriKind]::Absolute,[ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw 'IT måste konfigurera ApiBasUrl som tjänstens HTTPS-adress utan sökväg eller frågeparametrar.'
    }
}

function Get-TransportHttpError {
    param([Parameter(Mandatory)]$Record)
    $code = ''; $message = ''; $requestId = ''
    if ($null -ne $Record.ErrorDetails -and $Record.ErrorDetails.Message) {
        try {
            $body = $Record.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $body.PSObject.Properties['error']) { $code = [string]$body.error }
            if ($null -ne $body.PSObject.Properties['message']) { $message = [string]$body.message }
            if ($null -ne $body.PSObject.Properties['requestId']) { $requestId = [string]$body.requestId }
        } catch { }
    }
    [pscustomobject]@{ Code = $code; Message = $message; RequestId = $requestId }
}

function Start-TransportDeviceLogin {
    param([Parameter(Mandatory)]$Settings, [scriptblock]$Request = {
        param($Url,$Body) Invoke-RestMethod -Uri $Url -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 -ErrorAction Stop
    })
    Assert-TransportClientSettings $Settings
    # Never request Graph permissions or application credentials on the user's computer.
    $response = & $Request "https://login.microsoftonline.com/$($Settings.TenantId)/oauth2/v2.0/devicecode?mkt=sv-SE" @{
        client_id = $Settings.ClientId; scope = "api://$($Settings.ApiAppId)/Transportlogg.Access"
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
    [pscustomobject]@{ AccessToken = [string]$response.access_token; ExpiresUtc = [datetime]::UtcNow.AddSeconds([int]$response.expires_in - 60) }
}

function Invoke-TransportApi {
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Authentication,
        [Parameter(Mandatory)][hashtable]$Body,
        [scriptblock]$Request = {
            param($Url,$Headers,$Json)
            Invoke-RestMethod -Uri $Url -Method Post -Headers $Headers -Body ([Text.Encoding]::UTF8.GetBytes($Json)) `
                -ContentType 'application/json; charset=utf-8' -TimeoutSec 210 -ErrorAction Stop
        }
    )
    Assert-TransportClientSettings $Settings
    if ([datetime]::UtcNow -ge $Authentication.ExpiresUtc) { throw 'Din inloggning har gått ut. Logga in igen.' }
    if ([string]::IsNullOrWhiteSpace($Authentication.AccessToken) -or $Authentication.AccessToken -match '[\r\n]') { throw 'Logga in igen.' }
    try {
        $response = & $Request ($Settings.ApiBasUrl.TrimEnd('/') + '/api/transportlogg') @{
            Authorization = "Bearer $($Authentication.AccessToken)"; Accept = 'application/json'
        } ($Body | ConvertTo-Json -Depth 5 -Compress)
    } catch {
        $failure = Get-TransportHttpError $_
        if ($failure.Message) {
            $reference = if ($failure.RequestId) { " Referens: $($failure.RequestId)" } else { '' }
            throw ($failure.Message + $reference)
        }
        throw 'Tjänsten kunde inte nås eller nekade åtkomst. Kontrollera anslutningen och logga in igen. Kontakta IT om felet kvarstår.'
    }
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['schemaVersion'] -or $response.schemaVersion -ne 1) {
        throw 'Tjänsten returnerade ett oväntat svar. Kontakta IT.'
    }
    $response
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
