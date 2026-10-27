#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$script:checks = 0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "TEST MISSLYCKADES: $Message" }
    $script:checks++
}
$zipPath = & (Join-Path $PSScriptRoot 'azure/Build-Package.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
    foreach ($name in @('host.json','profile.ps1','requirements.psd1','Trace/function.json','Trace/run.ps1','shared/Transportlogg.Core.ps1','shared/Transportlogg.Graph.ps1','shared/Transportlogg.Service.ps1')) {
        Assert ($name -in $names) "Paketet innehåller $name"
    }
    Assert (@($names | Where-Object { $_ -match 'Installningar|Internt-underlag|Transportlogg\.Client|\.log$' }).Count -eq 0) 'Serverpaketet innehåller inga klientinställningar eller exporter'
} finally { $archive.Dispose() }
$compiled = Join-Path $PSScriptRoot 'dist/main.json'
if (-not (Test-Path -LiteralPath $compiled)) { throw 'Kompilera azure/main.bicep till dist/main.json med Bicep före malltestet.' }
$template = Get-Content -LiteralPath $compiled -Raw -Encoding UTF8 | ConvertFrom-Json
$auth = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites/config' -and $_.name -like '*authsettingsV2*' })[0]
Assert ($auth.properties.platform.enabled -and $auth.properties.globalValidation.requireAuthentication) 'Easy Auth är obligatorisk'
Assert ($auth.properties.globalValidation.unauthenticatedClientAction -eq 'Return401') 'Anonyma anrop nekas'
Assert ($auth.properties.httpSettings.requireHttps) 'HTTPS krävs'
Assert (@($auth.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications).Count -eq 1) 'Tillåtna klienter begränsas'
$app = @($template.resources | Where-Object type -eq 'Microsoft.Web/sites')[0]
Assert ($app.identity.type -eq 'SystemAssigned') 'Funktionen har egen managed identity'
Assert ($app.properties.siteConfig.functionAppScaleLimit -eq 1) 'Distributionen begränsar antal instanser'
Write-Output "Godkänt: $script:checks paket- och mallkontroller (utan Azure-distribution)."
