#requires -Version 5.1
[CmdletBinding()]
param([switch]$Demo)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Transportlogg.Core.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:connected = $false
$script:connectedHere = $false
$script:account = ''
$script:results = @()
$script:metadata = $null
$settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Installningar.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:domains = @($settings.VerksamhetensDomaner | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($Demo) { $script:domains = @('kommun.example') }

$form = [Windows.Forms.Form]::new()
$form.Text = if ($Demo) { 'Transportlogg – DEMO, fiktiva uppgifter' } else { 'Transportlogg – Exchange Online' }
$form.Size = [Drawing.Size]::new(1140,800)
$form.MinimumSize = [Drawing.Size]::new(1140,800)
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Segoe UI',10)

function Add-Label($Text, $X, $Y, $Width = 250) {
    $control = [Windows.Forms.Label]::new()
    $control.Text = $Text; $control.Location = [Drawing.Point]::new($X,$Y)
    $control.Size = [Drawing.Size]::new($Width,26)
    $form.Controls.Add($control)
    return $control
}
function Add-TextBox($X,$Y,$Width) {
    $control = [Windows.Forms.TextBox]::new()
    $control.Location = [Drawing.Point]::new($X,$Y); $control.Width = $Width
    $form.Controls.Add($control)
    return $control
}
function Show-Problem([string]$Message) {
    [void][Windows.Forms.MessageBox]::Show($form,$Message,'Transportlogg',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)
}

$heading = Add-Label 'Sök och exportera e-postens transportstatus' 20 15 900
$heading.Font = [Drawing.Font]::new('Segoe UI',16,[Drawing.FontStyle]::Bold)
$heading.Height = 38
$null = Add-Label '1. Logga in   →   2. Sök   →   3. Markera träffar   →   4. Exportera och granska' 20 58 1050
$null = Add-Label 'Arbetskonto för inloggning' 20 98
$login = Add-TextBox 20 126 340
$connect = [Windows.Forms.Button]::new()
$connect.Text = 'Logga in'; $connect.Location = [Drawing.Point]::new(380,123); $connect.Size = [Drawing.Size]::new(150,34)
$form.Controls.Add($connect)
$connectionLabel = Add-Label 'Inte inloggad' 550 128 550

$null = Add-Label 'E-postadress som begäran gäller' 20 172 420
$address = Add-TextBox 20 201 500
$null = Add-Label 'Verksamhetens adress (valfritt, begränsar sökningen)' 550 172 540
$orgAddress = Add-TextBox 550 201 530
$null = Add-Label 'Från och med (svensk tid)' 20 246
$null = Add-Label 'Till och med (svensk tid)' 300 246
$start = [Windows.Forms.DateTimePicker]::new()
$end = [Windows.Forms.DateTimePicker]::new()
foreach ($picker in @($start,$end)) {
    $picker.Format = [Windows.Forms.DateTimePickerFormat]::Custom
    $picker.CustomFormat = 'yyyy-MM-dd HH:mm'; $picker.Width = 255
    $form.Controls.Add($picker)
}
$start.Location = [Drawing.Point]::new(20,275)
$end.Location = [Drawing.Point]::new(300,275)
$nowSweden = ConvertFrom-TraceUtc ([datetime]::UtcNow)
$start.Value = $nowSweden.Date.AddDays(-7)
$end.Value = $nowSweden.Date
$null = Add-Label 'Riktning' 580 246
$direction = [Windows.Forms.ComboBox]::new()
$direction.Location = [Drawing.Point]::new(580,275); $direction.Width = 280
$direction.DropDownStyle = 'DropDownList'
[void]$direction.Items.AddRange([object[]]@('Båda','Till verksamheten','Från verksamheten'))
$direction.SelectedIndex = 0; $form.Controls.Add($direction)
$search = [Windows.Forms.Button]::new()
$search.Text = 'Sök'; $search.Location = [Drawing.Point]::new(890,269); $search.Size = [Drawing.Size]::new(190,38)
$search.Enabled = $false; $form.Controls.Add($search)
$periodHint = Add-Label 'Senaste 90 dygnen. Ange klockslag: 00:00 vid slutdatum betyder början av det dygnet.' 20 315 1070
$status = Add-Label 'Logga in för att börja.' 20 349 1070
$status.Height = 35
$null = Add-Label 'Markera rader med Ctrl/klick eller Shift/klick. Ctrl+A markerar alla träffar.' 20 388 1050
$grid = [Windows.Forms.DataGridView]::new()
$grid.Location = [Drawing.Point]::new(20,418); $grid.Size = [Drawing.Size]::new(1060,230)
$grid.Anchor = 'Top,Bottom,Left,Right'; $grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $true
$grid.AutoGenerateColumns = $false; $grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'Fill'
foreach ($pair in @(@('TidSverige','Tid Sverige'),@('Riktning','Riktning'),@('Avsandare','Avsändare'),@('Mottagare','Mottagare'),@('Status','Status'))) {
    $column = [Windows.Forms.DataGridViewTextBoxColumn]::new()
    $column.Name = $pair[0]; $column.DataPropertyName = $pair[0]; $column.HeaderText = $pair[1]
    [void]$grid.Columns.Add($column)
}
$form.Controls.Add($grid)
$includeSubject = [Windows.Forms.CheckBox]::new()
$includeSubject.Text = 'Visa och exportera ämnesrad (kan innehålla känsliga uppgifter)'
$includeSubject.Location = [Drawing.Point]::new(20,662); $includeSubject.Size = [Drawing.Size]::new(760,28)
$includeSubject.Anchor = 'Bottom,Left'; $form.Controls.Add($includeSubject)
$export = [Windows.Forms.Button]::new()
$export.Text = 'Exportera valda träffar'; $export.Location = [Drawing.Point]::new(810,657)
$export.Size = [Drawing.Size]::new(270,38); $export.Anchor = 'Bottom,Right'
$export.Enabled = $false; $form.Controls.Add($export)
$footer = Add-Label 'Granska uppgifterna enligt verksamhetens utlämningsrutin. Verktyget skickar inga mejl.' 20 707 1060
$footer.Anchor = 'Bottom,Left'; $footer.Height = 38

function Set-Busy([bool]$Busy) {
    foreach ($control in @($connect,$login,$address,$orgAddress,$start,$end,$direction,$includeSubject,$grid)) { $control.Enabled = -not $Busy }
    if ($Demo) { $connect.Enabled = $false; $login.Enabled = $false }
    $search.Enabled = (-not $Busy -and $script:connected)
    $export.Enabled = (-not $Busy -and $script:results.Count -gt 0)
    $form.UseWaitCursor = $Busy
    $form.Refresh()
}

$connect.Add_Click({
    try {
        Assert-TraceAddress $login.Text.Trim()
        if ($script:domains.Count -eq 0) { throw 'IT måste fylla i VerksamhetensDomaner i Installningar.json före användning.' }
        foreach ($domain in $script:domains) { Assert-TraceAddress "kontroll@$domain" }
        Set-Busy $true
        $status.Text = 'Öppnar Microsofts inloggning ...'; $form.Refresh()
        $module = Get-Module -ListAvailable ExchangeOnlineManagement | Where-Object Version -ge ([version]'3.7.0') | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $module) { throw 'ExchangeOnlineManagement 3.7.0 eller senare saknas. Be IT installera modulen enligt README.md.' }
        Import-Module $module.Path -ErrorAction Stop
        Connect-ExchangeOnline -UserPrincipalName $login.Text.Trim() -ShowBanner:$false -CommandName Get-MessageTraceV2 -ErrorAction Stop
        $script:connectedHere = $true
        if (-not (Get-Command Get-MessageTraceV2 -ErrorAction SilentlyContinue)) { throw 'Kontot saknar tillgång till meddelandespårning. Kontakta IT.' }
        $script:connected = $true; $script:account = $login.Text.Trim()
        $connectionLabel.Text = "Inloggad: $script:account"
        $status.Text = 'Ange e-postadress och tidsperiod. Tryck sedan på Sök.'
    } catch {
        $script:connected = $false
        $connectionLabel.Text = 'Inte inloggad'
        $status.Text = 'Inloggningen kunde inte slutföras.'
        Show-Problem $_.Exception.Message
    } finally { Set-Busy $false }
})

$search.Add_Click({
    # Clear the previous result before validating, so an error cannot leave stale rows exportable.
    $script:results = @(); $script:metadata = $null
    $grid.DataSource = $null
    try {
        Set-Busy $true
        $fromUtc = ConvertTo-TraceUtc $start.Value
        $toUtc = ConvertTo-TraceUtc $end.Value
        Assert-TraceAddress $address.Text.Trim()
        Assert-TracePeriod $fromUtc $toUtc
        if ($Demo) {
            if ($orgAddress.Text.Trim()) {
                Assert-TraceAddress $orgAddress.Text.Trim()
                if ($orgAddress.Text.Trim().Split('@')[-1] -ne 'kommun.example') { throw 'Använd domänen kommun.example i demoläget.' }
            }
            $flows = if ($direction.Text -eq 'Båda') { @('Till verksamheten','Från verksamheten') } else { @($direction.Text) }
            $office = if ($orgAddress.Text.Trim()) { $orgAddress.Text.Trim() } else { 'registrator@kommun.example' }
            $script:results = @(foreach ($flow in $flows) {
                $received = $fromUtc.AddTicks([long](($toUtc - $fromUtc).Ticks / 2))
                [pscustomobject]@{
                    TidSverige = (ConvertFrom-TraceUtc $received).ToString('yyyy-MM-dd HH:mm:ss')
                    TidUTC = $received.ToString('yyyy-MM-ddTHH:mm:ssZ'); Riktning = $flow
                    Avsandare = $(if ($flow -eq 'Till verksamheten') { $address.Text.Trim() } else { $office })
                    Mottagare = $(if ($flow -eq 'Till verksamheten') { $office } else { $address.Text.Trim() })
                    Status = 'Levererat enligt Exchange'; TekniskStatus = 'Delivered'
                    Amne = 'Fiktivt testmeddelande'; SparningsId = [guid]::NewGuid().ToString()
                }
            })
        } else {
            $script:results = @(Invoke-TransportSearch -Address $address.Text.Trim() -OrganizationAddress $orgAddress.Text.Trim() -AllowedDomains $script:domains -Direction $direction.Text -StartUtc $fromUtc -EndUtc $toUtc -Progress {
                param($Message) $status.Text = $Message; $status.Refresh()
            })
        }
        $script:metadata = [ordered]@{
            Adress = $address.Text.Trim(); Verksamhetsadress = $orgAddress.Text.Trim()
            Riktning = $direction.Text; FranUTC = $fromUtc.ToString('o'); TillUTC = $toUtc.ToString('o')
            Tidszon = 'Europe/Stockholm'; Domaner = $script:domains
            AntalSoktraffar = $script:results.Count; SokningAvslutadUTC = [datetime]::UtcNow.ToString('o')
            KontouppgiftVidInloggning = $script:account; Demo = [bool]$Demo
        }
        $table = [Data.DataTable]::new()
        foreach ($name in @('TidSverige','TidUTC','Riktning','Avsandare','Mottagare','Status','TekniskStatus','Amne','SparningsId')) { [void]$table.Columns.Add($name,[string]) }
        foreach ($item in $script:results) {
            $row = $table.NewRow()
            foreach ($col in $table.Columns) { $row[$col.ColumnName] = $item.($col.ColumnName) }
            $table.Rows.Add($row)
        }
        $grid.DataSource = $table
        $grid.ClearSelection()
        $prefix = if ($Demo) { 'DEMO – fiktiva uppgifter. ' } else { '' }
        $status.Text = if ($script:results.Count) { "$prefix$($script:results.Count) träffar. Markera rader att exportera." } else { 'Inga träffar. Det bevisar inte att mejl inte har skickats. Kontrollera adresser, period och eventuell fördröjning.' }
    } catch {
        $script:results = @(); $script:metadata = $null; $grid.DataSource = $null
        $status.Text = 'Sökningen misslyckades. Inget resultat kan exporteras.'
        Show-Problem $_.Exception.Message
    } finally { Set-Busy $false }
})

$includeSubject.Add_CheckedChanged({
    if ($includeSubject.Checked) {
        $column = [Windows.Forms.DataGridViewTextBoxColumn]::new()
        $column.Name = 'Amne'; $column.DataPropertyName = 'Amne'; $column.HeaderText = 'Ämne'
        [void]$grid.Columns.Add($column)
    } elseif ($grid.Columns.Contains('Amne')) { $grid.Columns.Remove('Amne') }
})

# Editing search criteria invalidates the old result to keep exports tied to the visible search.
$invalidate = {
    if ($null -ne $script:metadata) {
        $script:results = @(); $script:metadata = $null; $grid.DataSource = $null
        $export.Enabled = $false; $status.Text = 'Sökvillkoren har ändrats. Tryck på Sök igen.'
    }
}
$address.Add_TextChanged($invalidate); $orgAddress.Add_TextChanged($invalidate)
$start.Add_ValueChanged($invalidate); $end.Add_ValueChanged($invalidate); $direction.Add_SelectedIndexChanged($invalidate)

$export.Add_Click({
    try {
        $selected = @($grid.SelectedRows | ForEach-Object {
            $record = $_.DataBoundItem.Row
            $obj = [ordered]@{}
            foreach ($column in $record.Table.Columns) { $obj[$column.ColumnName] = [string]$record[$column.ColumnName] }
            [pscustomobject]$obj
        } | Sort-Object TidUTC,Avsandare,Mottagare)
        if ($selected.Count -eq 0) { throw 'Markera först de rader du vill exportera.' }
        $dialog = [Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = 'Välj verksamhetens godkända lagringsplats för exporten'
        if ($settings.Exportmapp) {
            Assert-TransportFolderPath $settings.Exportmapp
            if (Test-Path -LiteralPath $settings.Exportmapp -PathType Container) { $dialog.SelectedPath = $settings.Exportmapp }
        }
        if ($dialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { $dialog.Dispose(); return }
        $folder = $dialog.SelectedPath; $dialog.Dispose()
        $target = Export-TransportReport -Rows $selected -Folder $folder -Metadata $script:metadata -IncludeSubject:$includeSubject.Checked -Demo:$Demo
        $status.Text = "Exporterade $($selected.Count) valda träffar."
        [void][Windows.Forms.MessageBox]::Show($form,"Exporten finns i:`n$target`n`nGranska HTML-rapporten före utlämning. Internt-underlag.json innehåller interna sökuppgifter och ska hanteras separat.",'Export klar')
        Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $target)
    } catch { Show-Problem $_.Exception.Message }
})

if ($Demo) {
    $script:connected = $true; $script:account = 'DEMO'
    $login.Enabled = $false; $connect.Enabled = $false; $connectionLabel.Text = 'DEMO – ingen Exchangeanslutning'
    $address.Text = 'invanare@example.net'
    $search.Enabled = $true; $status.Text = 'Demoläge. Tryck på Sök för fiktiva träffar.'
}
try { [void]$form.ShowDialog() }
finally {
    $form.Dispose()
    if ($script:connectedHere) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
}
