#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Handläggare/Transportlogg.Core.ps1')
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
# Do not wait on simulated connection errors in these offline tests.
function Start-Sleep { param([int]$Seconds) }

$now = [datetime]::UtcNow
Assert-TransportFolderPath 'C:/temp'
Assert-TransportFolderPath 'C:\temp'
$invalidConfig = '{"Exportmapp":"C:\temp"}' | ConvertFrom-Json
Assert-Throws { Assert-TransportFolderPath $invalidConfig.Exportmapp } 'JSON-tabulator i exportsökväg avvisas begripligt'
$validConfig = '{"Exportmapp":"C:\\temp"}' | ConvertFrom-Json
Assert ($validConfig.Exportmapp -eq 'C:\temp') 'Dubbla bakstreck i JSON ger korrekt sökväg'
Assert-Throws { Assert-TransportFolderPath 'C:/temp/ogiltig"mapp' } 'Ogiltiga sökvägstecken avvisas'
$from = $now.AddDays(-3); $to = $now.AddDays(-1)
Assert ((ConvertTo-TraceUtc ([datetime]'2026-01-15 12:00')).Hour -eq 11) 'Svensk vintertid'
Assert ((ConvertTo-TraceUtc ([datetime]'2026-07-15 12:00')).Hour -eq 10) 'Svensk sommartid'
Assert-Throws { ConvertTo-TraceUtc ([datetime]'2026-03-29 02:30') } 'Ogiltig sommartid avvisas'
Assert-Throws { ConvertTo-TraceUtc ([datetime]'2026-10-25 02:30') } 'Tvetydig vintertid avvisas'
Assert-Throws { Assert-TracePeriod $to $from } 'Omvänd period avvisas'
Assert-Throws { Assert-TracePeriod $now.AddDays(-91) $to } 'För gammal period avvisas'
Assert-Throws { Assert-TracePeriod $from $now.AddHours(1) } 'Framtid avvisas'
foreach ($bad in @('*@example.net','Namn <a@example.net>','a@example.net;b@example.net','a')) {
    Assert-Throws { Assert-TraceAddress $bad } "Ogiltig adress: $bad"
}

function New-TestRow([string]$Sender, [string]$Recipient, [string]$Id = 'id-1') {
    [pscustomobject]@{ Received = $from.AddHours(1); SenderAddress = $Sender; RecipientAddress = $Recipient
        MessageTraceId = $Id; Subject = '<script>alert(1)</script>'; Status = 'Delivered' }
}
$good = New-TestRow 'invanare@example.net' 'registrator@kommun.example'
$outside = New-TestRow 'invanare@example.net' 'annan@annan.example' 'id-2'
$wrongSender = New-TestRow 'annan@example.net' 'registrator@kommun.example' 'id-3'
$state = @{ Calls = 0; Intervals = [Collections.Generic.List[double]]::new() }
$mock = {
    param($Parameters)
    $state.Calls++
    $state.Intervals.Add(($Parameters.EndDate - $Parameters.StartDate).TotalDays)
    @($good,$good,$outside,$wrongSender)
}
$arguments = @{ Address = 'invanare@example.net'; AllowedDomains = @('kommun.example'); StartUtc = $from; EndUtc = $to; Direction = 'Till verksamheten' }
$result = @(Invoke-TransportSearch @arguments -Query $mock)
Assert ($result.Count -eq 1) 'Domänfilter, adressfilter och deduplicering'
Assert ($result[0].TekniskStatus -eq 'Delivered') 'Ursprunglig status bevaras'
Assert ($result[0].Riktning -eq 'Till verksamheten') 'Inkommande riktning'
Assert-Throws { Invoke-TransportSearch @arguments -OrganizationAddress 'x@annan.example' -Query $mock } 'Verksamhetsadress utanför domänen avvisas'
$result = @(Invoke-TransportSearch @arguments -OrganizationAddress 'annan@kommun.example' -Query $mock)
Assert ($result.Count -eq 0) 'Exakt verksamhetsadress begränsar träffar'

$longArgs = $arguments.Clone(); $longArgs.StartUtc = $now.AddDays(-25)
$state.Calls = 0
$null = @(Invoke-TransportSearch @longArgs -Query $mock)
Assert ($state.Calls -eq 3) 'Lång period delas upp'
Assert (@($state.Intervals | Where-Object { $_ -gt 10 }).Count -eq 0) 'Inget intervall överstiger tio dygn'
$state.Calls = 0
$split = {
    param($Parameters)
    $state.Calls++
    if ($state.Calls -eq 1) { for ($i=0; $i -lt 5000; $i++) { $good } }
    else { $good }
}
$result = @(Invoke-TransportSearch @arguments -Query $split)
Assert ($state.Calls -eq 3 -and $result.Count -eq 1) 'Fullt resultat delas och gränsdubbletter tas bort'
$tinyArgs = $arguments.Clone(); $tinyArgs.EndUtc = $from.AddSeconds(1)
Assert-Throws { Invoke-TransportSearch @tinyArgs -Query { param($p) for ($i=0; $i -lt 5000; $i++) { $good } } } 'Mättat minsta intervall ger fel'
$two = New-TestRow 'invanare@example.net' 'annan@kommun.example' 'id-4'
Assert-Throws { Invoke-TransportSearch @arguments -MaximumRows 1 -Query { param($p) @($good,$two) } } 'Radgräns ger fel utan partiell export'
$state.Calls = 0
Assert-Throws { Invoke-TransportSearch @arguments -Query { param($p) $state.Calls++; throw 'simulerat Exchangefel' } } 'Exchangefel propageras'
Assert ($state.Calls -eq 3) 'Begränsat antal återförsök'
$outgoing = New-TestRow 'registrator@kommun.example' 'invanare@example.net' 'id-5'
$bothArgs = $arguments.Clone(); $bothArgs.Direction = 'Båda'
$result = @(Invoke-TransportSearch @bothArgs -Query { param($p) @($good,$outgoing) })
Assert ($result.Count -eq 2) 'Båda riktningarna söks och filtreras'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('Transportlogg-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try {
    $metadata = [ordered]@{ Adress = 'invanare@example.net'; KontouppgiftVidInloggning = 'hemligtkonto@kommun.example'; AntalSoktraffar = 2 }
    $path = Export-TransportReport -Rows @($result[0]) -Folder $temp -Metadata $metadata -Demo
    $csv = @(Import-Csv -LiteralPath (Join-Path $path 'Transportlogg.csv') -Delimiter ';' -Encoding UTF8)
    Assert ($csv.Count -eq 1) 'Endast valda träffar exporteras'
    Assert ($csv[0].Underlag -eq 'DEMO – FIKTIVA UPPGIFTER') 'CSV med fiktiva uppgifter demomärks'
    Assert ('Ämne' -notin $csv[0].PSObject.Properties.Name) 'Ämne utesluts som standard'
    $html = Get-Content -LiteralPath (Join-Path $path 'Transportlogg.html') -Raw -Encoding UTF8
    Assert ($html -match 'DEMO' -and $html -notmatch 'hemligtkonto') 'Demomärkning och inget arbetskonto i publik rapport'
    $audit = Get-Content -LiteralPath (Join-Path $path 'Internt-underlag.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($audit.AntalExporterade -eq 1 -and $audit.Demo) 'Internt underlag'
    $result[0].Amne = '=1+1;<script>alert(1)</script>'
    $path = Export-TransportReport -Rows @($result[0]) -Folder $temp -Metadata $metadata -IncludeSubject
    $csv = @(Import-Csv -LiteralPath (Join-Path $path 'Transportlogg.csv') -Delimiter ';' -Encoding UTF8)
    Assert ($csv[0].Ämne.StartsWith("'=")) 'CSV-formler neutraliseras'
    $html = Get-Content -LiteralPath (Join-Path $path 'Transportlogg.html') -Raw -Encoding UTF8
    Assert ($html -notmatch '<script>' -and $html -match '&lt;script&gt;') 'HTML-kod kodas som text'
    Assert ((ConvertTo-SafeCsvText '  @SUM(1)') -eq "'  @SUM(1)") 'Formler med inledande blanksteg neutraliseras'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $path 'Transportlogg.csv'))
    Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'UTF-8 BOM för svensk Excel'
    Assert-Throws { Export-TransportReport -Rows @() -Folder $temp -Metadata $metadata } 'Tom export avvisas'
} finally {
    # Only remove files in this test's verified, uniquely named directory.
    $resolved = [IO.Path]::GetFullPath($temp)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'Transportlogg-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output "Godkänt: $script:checks kontroller (utan Exchangeanslutning)."
