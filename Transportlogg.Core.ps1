# Core functions may be loaded without opening the Windows interface.
Set-StrictMode -Version Latest

function Get-StockholmZone {
    [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
}

function ConvertTo-TraceUtc {
    param([Parameter(Mandatory)][datetime]$LocalTime)
    $local = [datetime]::SpecifyKind($LocalTime, [DateTimeKind]::Unspecified)
    $zone = Get-StockholmZone
    if ($zone.IsInvalidTime($local) -or $zone.IsAmbiguousTime($local)) {
        throw 'Klockslaget ligger vid omställning av sommartid. Välj ett annat klockslag.'
    }
    [TimeZoneInfo]::ConvertTimeToUtc($local, $zone)
}

function ConvertFrom-TraceUtc {
    param([Parameter(Mandatory)][datetime]$UtcTime)
    # Exchange returns UTC, sometimes as a DateTime with an unspecified Kind.
    $utc = [datetime]::SpecifyKind($UtcTime, [DateTimeKind]::Utc)
    [TimeZoneInfo]::ConvertTimeFromUtc($utc, (Get-StockholmZone))
}

function Assert-TraceAddress {
    param([Parameter(Mandatory)][string]$Address)
    try { $mail = [System.Net.Mail.MailAddress]::new($Address) }
    catch { throw 'Ange en fullständig e-postadress, exempelvis namn@exempel.se.' }
    if ($mail.Address -ne $Address -or $Address -match '[\s*;,<>]' -or $mail.Host -notmatch '\.') {
        throw 'Ange en enda fullständig e-postadress utan visningsnamn eller jokertecken.'
    }
}

function Assert-TracePeriod {
    param([datetime]$StartUtc, [datetime]$EndUtc, [datetime]$NowUtc = [datetime]::UtcNow)
    if ($StartUtc -ge $EndUtc) { throw 'Starttiden måste vara före sluttiden.' }
    if ($StartUtc -lt $NowUtc.AddDays(-90)) { throw 'Starttiden får inte ligga mer än 90 dygn tillbaka.' }
    if ($EndUtc -gt $NowUtc) { throw 'Sluttiden får inte ligga i framtiden.' }
}

function Get-TraceStatusText {
    param([string]$Status)
    switch ($Status) {
        'Delivered' { 'Levererat enligt Exchange'; break }
        'Failed' { 'Leverans misslyckades'; break }
        'Pending' { 'Leverans pågår'; break }
        'Quarantined' { 'Placerat i karantän'; break }
        'FilteredAsSpam' { 'Filtrerat som skräppost'; break }
        'Expanded' { 'Distributionsgrupp expanderad'; break }
        'GettingStatus' { 'Status hämtas'; break }
        default { "Annan status: $Status" }
    }
}

function Invoke-TransportSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [string]$OrganizationAddress = '',
        [Parameter(Mandatory)][string[]]$AllowedDomains,
        [ValidateSet('Båda','Till verksamheten','Från verksamheten')][string]$Direction = 'Båda',
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][datetime]$EndUtc,
        [Parameter(Mandatory)][scriptblock]$Query,
        [switch]$CompleteQuery,
        [scriptblock]$Progress = { param($Message) },
        [int]$MaximumRows = 50000
    )
    Assert-TraceAddress $Address
    Assert-TracePeriod $StartUtc $EndUtc
    if ($AllowedDomains.Count -eq 0) { throw 'IT måste konfigurera verksamhetens e-postdomäner.' }
    $domains = @($AllowedDomains | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if ($OrganizationAddress) {
        Assert-TraceAddress $OrganizationAddress
        if (($OrganizationAddress.Split('@')[-1]).ToLowerInvariant() -notin $domains) {
            throw 'Verksamhetens adress måste tillhöra en konfigurerad domän.'
        }
    }
    $rows = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $requests = [Collections.Generic.Queue[datetime]]::new()
    $directions = if ($Direction -eq 'Båda') { @('Till verksamheten','Från verksamheten') } else { @($Direction) }
    foreach ($flow in $directions) {
        $windowStart = $StartUtc
        while ($windowStart -lt $EndUtc) {
            $windowEnd = $windowStart.AddDays(10)
            if ($windowEnd -gt $EndUtc) { $windowEnd = $EndUtc }
            $pending = [Collections.Generic.Stack[object]]::new()
            $pending.Push(@{ Start = $windowStart; End = $windowEnd })
            while ($pending.Count -gt 0) {
                $window = $pending.Pop()
                $parameters = @{ StartDate = $window.Start; EndDate = $window.End; ResultSize = 5000 }
                if ($flow -eq 'Till verksamheten') {
                    $parameters.SenderAddress = $Address
                    if ($OrganizationAddress) { $parameters.RecipientAddress = $OrganizationAddress }
                } else {
                    $parameters.RecipientAddress = $Address
                    if ($OrganizationAddress) { $parameters.SenderAddress = $OrganizationAddress }
                }
                & $Progress "Söker: $flow, $($window.Start.ToString('yyyy-MM-dd')) – $($window.End.ToString('yyyy-MM-dd')) (UTC)"
                # Keep our own request rate below the tenant limit. Other clients may still cause throttling.
                while ($requests.Count -gt 0 -and $requests.Peek() -lt [datetime]::UtcNow.AddMinutes(-5)) { [void]$requests.Dequeue() }
                while ($requests.Count -ge 80) {
                    & $Progress 'Väntar på Exchange för att undvika för många anrop ...'
                    Start-Sleep -Seconds 2
                    while ($requests.Count -gt 0 -and $requests.Peek() -lt [datetime]::UtcNow.AddMinutes(-5)) { [void]$requests.Dequeue() }
                }
                $batch = @()
                for ($attempt = 0; $attempt -lt 3; $attempt++) {
                    try {
                        $requests.Enqueue([datetime]::UtcNow)
                        $batch = @(& $Query $parameters)
                        break
                    } catch {
                        if ($attempt -eq 2) { throw "Sökningen avbröts. Inget fullständigt resultat finns. Exchange: $($_.Exception.Message)" }
                        & $Progress 'Exchange svarade med ett fel. Försöker igen ...'
                        Start-Sleep -Seconds (5 * ($attempt + 1))
                    }
                }
                if ($batch.Count -ge 5000 -and -not $CompleteQuery) {
                    # Inclusive overlapping windows avoid skipping boundary records; keys remove duplicates.
                    if (($window.End - $window.Start).TotalSeconds -le 1) {
                        throw 'För många träffar vid samma tidpunkt. Begränsa med en verksamhetsadress. Resultatet exporteras inte som fullständigt.'
                    }
                    $midpoint = $window.Start.AddTicks([long](($window.End - $window.Start).Ticks / 2))
                    $pending.Push(@{ Start = $midpoint; End = $window.End })
                    $pending.Push(@{ Start = $window.Start; End = $midpoint })
                    continue
                }
                foreach ($item in $batch) {
                    $sender = [string]$item.SenderAddress
                    $recipient = [string]$item.RecipientAddress
                    $orgSide = if ($flow -eq 'Till verksamheten') { $recipient } else { $sender }
                    if (($orgSide.Split('@')[-1]).ToLowerInvariant() -notin $domains) { continue }
                    # Defense in depth: also enforce the requested address pair locally.
                    if ($flow -eq 'Till verksamheten' -and $sender -ne $Address) { continue }
                    if ($flow -eq 'Från verksamheten' -and $recipient -ne $Address) { continue }
                    if ($OrganizationAddress -and $orgSide -ne $OrganizationAddress) { continue }
                    $utc = [datetime]::SpecifyKind([datetime]$item.Received, [DateTimeKind]::Utc)
                    if ($utc -lt $StartUtc -or $utc -gt $EndUtc) { continue }
                    if ([string]::IsNullOrWhiteSpace([string]$item.MessageTraceId)) { throw 'Exchange returnerade en träff utan spårnings-ID. Sökningen avbröts.' }
                    $key = "$($item.MessageTraceId)|$recipient"
                    if (-not $seen.Add($key)) { continue }
                    if ($rows.Count -ge $MaximumRows) { throw 'Sökningen har för många träffar. Begränsa perioden eller ange verksamhetens adress.' }
                    $rows.Add([pscustomobject]@{
                        TidSverige = (ConvertFrom-TraceUtc $utc).ToString('yyyy-MM-dd HH:mm:ss')
                        TidUTC = $utc.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        Riktning = $flow
                        Avsandare = $sender
                        Mottagare = $recipient
                        Status = Get-TraceStatusText ([string]$item.Status)
                        TekniskStatus = [string]$item.Status
                        Amne = [string]$item.Subject
                        SparningsId = [string]$item.MessageTraceId
                    })
                }
            }
            $windowStart = $windowEnd
        }
    }
    $rows | Sort-Object TidUTC, Avsandare, Mottagare
}

function ConvertTo-SafeCsvText {
    param([AllowNull()][string]$Value)
    # Excel may interpret formulas even inside quoted CSV fields.
    if ($Value -match '^[\s\x00-\x1f]*[=+@-]' -or $Value -match '^[\t\r\n]') { return "'$Value" }
    $Value
}

function Assert-TransportFolderPath {
    param([Parameter(Mandatory)][string]$Folder)
    $message = 'Exportmappens sökväg är ogiltig. Använd exempelvis C:/temp eller dubbla bakstreck (C:\\temp) i Installningar.json.'
    if ([string]::IsNullOrWhiteSpace($Folder) -or $Folder -match '["<>|*?\x00-\x1f]') {
        throw $message
    }
    try { [void][IO.Path]::GetFullPath($Folder) }
    catch { throw $message }
}

function Export-TransportReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Metadata,
        [switch]$IncludeSubject,
        [switch]$Demo
    )
    if ($Rows.Count -eq 0) { throw 'Välj minst en träff att exportera.' }
    Assert-TransportFolderPath $Folder
    $target = Join-Path $Folder ('Transportlogg_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0,8)))
    [void](New-Item -ItemType Directory -Path $target -ErrorAction Stop)
    try {
        $export = @($Rows | ForEach-Object {
            $row = [ordered]@{}
            if ($Demo) { $row['Underlag'] = 'DEMO – FIKTIVA UPPGIFTER' }
            $row['Tid Sverige'] = $_.TidSverige
            $row['Tid UTC'] = $_.TidUTC
            $row['Riktning'] = $_.Riktning
            $row['Avsändare'] = $_.Avsandare
            $row['Mottagare'] = $_.Mottagare
            $row['Status'] = $_.Status
            $row['Statuskod Exchange'] = $_.TekniskStatus
            if ($IncludeSubject) { $row['Ämne'] = $_.Amne }
            [pscustomobject]$row
        })
        $safeCsv = @($export | ForEach-Object {
            $safe = [ordered]@{}
            foreach ($property in $_.PSObject.Properties) { $safe[$property.Name] = ConvertTo-SafeCsvText ([string]$property.Value) }
            [pscustomobject]$safe
        })
        $utf8 = [Text.UTF8Encoding]::new($true)
        [IO.File]::WriteAllLines((Join-Path $target 'Transportlogg.csv'), [string[]]@($safeCsv | ConvertTo-Csv -Delimiter ';' -NoTypeInformation), $utf8)
        $title = if ($Demo) { 'DEMO – FIKTIVA UPPGIFTER – Transportlogg' } else { 'Transportlogg – valda träffar' }
        $encodedTitle = [Net.WebUtility]::HtmlEncode($title)
        $reportMetadata = [ordered]@{}
        foreach ($key in @('Adress','Verksamhetsadress','Riktning','FranUTC','TillUTC','Tidszon','AntalSoktraffar','SokningAvslutadUTC','Demo')) {
            if ($Metadata.Contains($key)) { $reportMetadata[$key] = $Metadata[$key] }
        }
        $criteria = [Net.WebUtility]::HtmlEncode(($reportMetadata | ConvertTo-Json -Depth 5))
        $table = ($export | ConvertTo-Html -Fragment) -join [Environment]::NewLine
        $html = @"
<!doctype html><html lang="sv"><head><meta charset="utf-8"><title>$encodedTitle</title>
<style>body{font:15px Segoe UI,Arial,sans-serif;margin:32px;color:#172536}table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #bac5d1;padding:8px;text-align:left;overflow-wrap:anywhere}th{background:#eaf0f6}pre{white-space:pre-wrap}h1{font-size:26px}@media print{body{margin:10mm}thead{display:table-header-group}}</style>
</head><body><h1>$encodedTitle</h1><p>Exporten innehåller $($Rows.Count) valda mottagarträffar. Ett mejl till flera mottagare kan visas på flera rader.</p>
<p>Tider visas i svensk tid (Europe/Stockholm, inklusive sommartid) och UTC. Status kommer från Exchange Online och avser transport. Levererat innebär inte att mejlet har lästs. För externa mottagare kan leverans avse mottagarens e-postsystem.</p>
$table
<h2>Sökunderlag</h2><pre>$criteria</pre>
<p>Inga mejltexter eller bilagor ingår. Exporten är ett valt utdrag, inte ett intyg över all e-post. Nyligen skickade mejl kan saknas på grund av fördröjning i spårningen.</p>
</body></html>
"@
        [IO.File]::WriteAllText((Join-Path $target 'Transportlogg.html'), $html, $utf8)
        $audit = [ordered]@{
            SkapadUTC = [datetime]::UtcNow.ToString('o'); WindowsAnvandare = [Environment]::UserName
            Demo = [bool]$Demo; AntalExporterade = $Rows.Count; InkluderarAmne = [bool]$IncludeSubject
            Sokning = $Metadata; ValdaSparningsId = @($Rows | Select-Object SparningsId, Mottagare)
            Filer = @('Transportlogg.csv','Transportlogg.html')
        }
        [IO.File]::WriteAllText((Join-Path $target 'Internt-underlag.json'), ($audit | ConvertTo-Json -Depth 8), $utf8)
        $target
    } catch {
        # Leave no apparently complete report after a partial write.
        foreach ($name in @('Transportlogg.csv','Transportlogg.html','Internt-underlag.json')) {
            $file = Join-Path $target $name
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
        throw
    }
}
