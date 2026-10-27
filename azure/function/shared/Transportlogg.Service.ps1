Set-StrictMode -Version Latest

function Get-TransportCaller {
    param([string]$PrincipalHeader, [string]$TenantId, [string]$ClientId)
    try {
        if (-not $PrincipalHeader -or $PrincipalHeader.Length -gt 65536) { throw 'Missing principal' }
        $principal = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PrincipalHeader)) | ConvertFrom-Json -ErrorAction Stop
        if ($principal.auth_typ -ne 'aad') { throw 'Wrong provider' }
        $claims = @($principal.claims)
        $tenant = @($claims | Where-Object typ -in @('tid','http://schemas.microsoft.com/identity/claims/tenantid') | Select-Object -ExpandProperty val -Unique)
        $client = @($claims | Where-Object typ -in @('azp','appid','http://schemas.microsoft.com/identity/claims/azp','http://schemas.microsoft.com/identity/claims/appid') | Select-Object -ExpandProperty val -Unique)
        $oid = @($claims | Where-Object typ -in @('oid','http://schemas.microsoft.com/identity/claims/objectidentifier') | Select-Object -ExpandProperty val -Unique)
        $roles = @($claims | Where-Object typ -in @('roles','http://schemas.microsoft.com/ws/2008/06/identity/claims/role') | Select-Object -ExpandProperty val)
        $scopes = @($claims | Where-Object typ -in @('scp','http://schemas.microsoft.com/identity/claims/scope') | Select-Object -ExpandProperty val)
        $objectId = [guid]::Empty
        if ($tenant.Count -ne 1 -or $tenant[0] -ne $TenantId -or
            $client.Count -ne 1 -or $client[0] -ne $ClientId -or
            $oid.Count -ne 1 -or -not [guid]::TryParse([string]$oid[0],[ref]$objectId) -or
            'Trace.Reader' -cnotin $roles -or 'Transportlogg.Access' -cnotin (($scopes -join ' ') -split ' ')) { throw 'Access denied' }
        $names = @($claims | Where-Object typ -in @('preferred_username','http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name') | Select-Object -ExpandProperty val)
        $name = if ($names.Count) { [string]$names[0] } else { $objectId.ToString() }
        [pscustomobject]@{ ObjectId = $objectId.ToString(); UserName = $name }
    } catch { throw [UnauthorizedAccessException]::new('Du saknar behörighet till transportloggtjänsten. Kontakta IT.') }
}

function Get-TransportServiceSearchArguments {
    param($Body, [string[]]$AllowedDomains, [int]$MaximumRows)
    try {
        foreach ($name in @('address','organizationAddress','direction','startUtc','endUtc','includeSubject')) {
            if ($null -eq $Body.PSObject.Properties[$name]) { throw 'Missing field' }
        }
        if ([string]$Body.direction -cnotin @('Båda','Till verksamheten','Från verksamheten') -or
            $Body.includeSubject -isnot [bool]) { throw 'Invalid selection' }
        Assert-TraceAddress ([string]$Body.address)
        if ($Body.organizationAddress) {
            Assert-TraceAddress ([string]$Body.organizationAddress)
            if (([string]$Body.organizationAddress).Split('@')[-1] -notin $AllowedDomains) { throw 'Wrong domain' }
        }
        foreach ($value in @($Body.startUtc,$Body.endUtc)) {
            if ([string]$value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?Z$') { throw 'UTC required' }
        }
        $start = [DateTimeOffset]::Parse([string]$Body.startUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $end = [DateTimeOffset]::Parse([string]$Body.endUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        Assert-TracePeriod $start $end
        @{
            Address = [string]$Body.address; OrganizationAddress = [string]$Body.organizationAddress
            Direction = [string]$Body.direction; StartUtc = $start; EndUtc = $end
            AllowedDomains = $AllowedDomains; MaximumRows = $MaximumRows
        }
    } catch { throw [ArgumentException]::new('Kontrollera adresser, riktning och datum. Perioden måste ligga inom de senaste 90 dygnen och verksamhetens adress måste tillhöra en tillåten domän.') }
}

function Invoke-TransportService {
    param(
        [string]$PrincipalHeader, $Body, [string]$TenantId, [string]$ClientId,
        [string[]]$AllowedDomains, [ValidateRange(1,10000)][int]$MaximumRows = 10000,
        [Parameter(Mandatory)][scriptblock]$Search
    )
    $reference = [guid]::NewGuid().ToString()
    $statusCode = 500; $count = 0; $callerId = ''
    try {
        # This header is trusted ONLY behind Azure App Service Authentication.
        # The deployment enforces token signature, issuer, audience and HTTPS before this code runs.
        if (-not $TenantId -or -not $ClientId -or $AllowedDomains.Count -eq 0) { throw 'Server not configured' }
        foreach ($domain in $AllowedDomains) { Assert-TraceAddress "kontroll@$domain" }
        $caller = Get-TransportCaller -PrincipalHeader $PrincipalHeader -TenantId $TenantId -ClientId $ClientId
        $callerId = $caller.ObjectId
        if ($null -eq $Body -or $null -eq $Body.PSObject.Properties['action']) { throw [ArgumentException]::new('Ange en giltig åtgärd.') }
        if ($Body.action -ceq 'session') {
            $response = [ordered]@{
                schemaVersion = 1; requestId = $reference; userName = $caller.UserName
                allowedDomains = $AllowedDomains; maximumRows = $MaximumRows
            }
        } elseif ($Body.action -ceq 'search') {
            $arguments = Get-TransportServiceSearchArguments -Body $Body -AllowedDomains $AllowedDomains -MaximumRows $MaximumRows
            $rows = @(& $Search $arguments)
            if ($rows.Count -gt $MaximumRows) { throw [InvalidOperationException]::new('Too many rows') }
            $safeRows = @(foreach ($item in $rows) {
                [pscustomobject]@{
                    TidSverige = [string]$item.TidSverige; TidUTC = [string]$item.TidUTC
                    Riktning = [string]$item.Riktning; Avsandare = [string]$item.Avsandare; Mottagare = [string]$item.Mottagare
                    Status = [string]$item.Status; TekniskStatus = [string]$item.TekniskStatus; SparningsId = [string]$item.SparningsId
                    Amne = $(if ($Body.includeSubject) { [string]$item.Amne } else { '' })
                }
            })
            $count = $safeRows.Count
            $response = [ordered]@{ schemaVersion = 1; requestId = $reference; rows = $safeRows }
        } else { throw [ArgumentException]::new('Okänd åtgärd.') }
        $statusCode = 200
    } catch {
        $message = 'Sökningen kunde inte slutföras. Begränsa sökningen eller kontakta IT med referensen.'
        if ($_.Exception -is [UnauthorizedAccessException]) { $statusCode = 403; $message = $_.Exception.Message }
        elseif ($_.Exception -is [ArgumentException]) { $statusCode = 400; $message = $_.Exception.Message }
        else { $statusCode = 503 }
        $response = [ordered]@{ schemaVersion = 1; error = 'request_failed'; message = $message; requestId = $reference }
    }
    # No access tokens, search addresses, subjects or raw Graph error bodies in logs.
    Write-Information (ConvertTo-Json -Compress -InputObject @{
        event = 'TransportloggRequest'; requestId = $reference; userObjectId = $callerId; status = $statusCode; rows = $count
    }) -InformationAction Continue
    @{ StatusCode = $statusCode; Body = $response }
}

function Get-TransportManagedIdentityToken {
    param([hashtable]$State)
    if ($State.ContainsKey('Token') -and $State.TokenExpiresUtc -gt [datetime]::UtcNow.AddMinutes(2)) { return $State.Token }
    if (-not $env:IDENTITY_ENDPOINT -or -not $env:IDENTITY_HEADER) { throw 'Managed identity is unavailable' }
    $url = $env:IDENTITY_ENDPOINT + '?api-version=2019-08-01&resource=' + [uri]::EscapeDataString('https://graph.microsoft.com')
    $response = Invoke-RestMethod -Uri $url -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } -Method Get -TimeoutSec 15 -ErrorAction Stop
    $State.Token = [string]$response.access_token
    $State.TokenExpiresUtc = [DateTimeOffset]::FromUnixTimeSeconds([long]$response.expires_on).UtcDateTime
    $State.Token
}

function Invoke-TransportGraphHttp {
    param(
        [string]$Url, [hashtable]$Headers, [hashtable]$State,
        [scriptblock]$Request = { param($Address,$RequestHeaders,$Timeout) Invoke-RestMethod -Uri $Address -Headers $RequestHeaders -Method Get -TimeoutSec $Timeout -ErrorAction Stop },
        [scriptblock]$Wait = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $remaining = [int]($State.DeadlineUtc - [datetime]::UtcNow).TotalSeconds
        if ($remaining -lt 3) { throw 'Search time budget exhausted' }
        # Keep a single worker below the Graph rate; tenant-wide throttling is still possible.
        if ($State.ContainsKey('NextRequestUtc') -and $State.NextRequestUtc -gt [datetime]::UtcNow) {
            $waitSeconds = [int][math]::Ceiling(($State.NextRequestUtc - [datetime]::UtcNow).TotalSeconds)
            if ($waitSeconds -ge $remaining) { throw 'Search time budget exhausted' }
            & $Wait $waitSeconds
        }
        $State.NextRequestUtc = [datetime]::UtcNow.AddSeconds(4)
        try {
            return & $Request $Url $Headers ([math]::Min(30,$remaining))
        } catch {
            $status = 0
            if ($null -ne $_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            if ($status -notin @(429,503,504) -or $attempt -eq 2) { throw }
            $seconds = 5 * ($attempt + 1)
            $retry = $_.Exception.Response.Headers.RetryAfter
            if ($null -ne $retry) {
                if ($null -ne $retry.Delta) { $seconds = [math]::Max($seconds,[math]::Ceiling($retry.Delta.TotalSeconds)) }
                elseif ($null -ne $retry.Date) { $seconds = [math]::Max($seconds,[math]::Ceiling(($retry.Date.UtcDateTime - [datetime]::UtcNow).TotalSeconds)) }
            }
            if ($seconds -ge ($State.DeadlineUtc - [datetime]::UtcNow).TotalSeconds) { throw 'Graph requested a retry beyond the search time budget' }
            & $Wait $seconds
        }
    }
}
