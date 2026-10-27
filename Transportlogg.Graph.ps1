#requires -Version 5.1
# Module-free REST adapter. With application permissions this belongs on a trusted service,
# not on the case worker's computer. It does not obtain or store application credentials.
$coreFile = Join-Path $PSScriptRoot 'Transportlogg.Core.ps1'
if (-not (Test-Path -LiteralPath $coreFile)) { $coreFile = Join-Path $PSScriptRoot 'Handläggare/Transportlogg.Core.ps1' }
. $coreFile

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
            Invoke-RestMethod -Uri $Url -Method Get -Headers $Headers -TimeoutSec 120 -ErrorAction Stop
        }
    )
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
            Invoke-RestMethod -Uri $Url -Method Get -Headers $Headers -TimeoutSec 120 -ErrorAction Stop
        }
    )
    $query = {
        param($Parameters)
        Get-GraphTraceBatch -Parameters $Parameters -AccessTokenProvider $AccessTokenProvider -Request $Request -MaximumItems $MaximumRows
    }
    Invoke-TransportSearch -Address $Address -OrganizationAddress $OrganizationAddress -AllowedDomains $AllowedDomains `
        -Direction $Direction -StartUtc $StartUtc -EndUtc $EndUtc -Query $query -CompleteQuery -Progress $Progress -MaximumRows $MaximumRows
}
