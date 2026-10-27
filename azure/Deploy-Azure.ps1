#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$')][string]$FunctionName,
    [Parameter(Mandatory)][string]$EntraConfig,
    [Parameter(Mandatory)][string[]]$AllowedDomains,
    [string]$Location = 'swedencentral'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Transportlogg.Core.ps1')
foreach ($domain in $AllowedDomains) { Assert-TraceAddress "kontroll@$domain" }
if ($AllowedDomains.Count -eq 0) { throw 'Ange minst en verksamhetsdomän.' }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI behövs på IT:s administrationsdator.' }
$config = Get-Content -LiteralPath $EntraConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$accountJson = az account show -o json
if ($LASTEXITCODE -ne 0) { throw 'Kör az login först.' }
$account = $accountJson | ConvertFrom-Json
if ($account.tenantId -ne $config.TenantId) { throw 'Azure CLI är inloggad i fel tenant.' }
$zip = & (Join-Path $PSScriptRoot 'Build-Package.ps1')
az group create --name $ResourceGroup --location $Location -o none
if ($LASTEXITCODE -ne 0) { throw 'Kunde inte skapa eller öppna resursgruppen.' }
$deploymentParams = @{
    functionName = @{ value = $FunctionName }; location = @{ value = $Location }
    tenantId = @{ value = $config.TenantId }; apiAppId = @{ value = $config.ApiAppId }
    clientAppId = @{ value = $config.ClientId }; allowedDomains = @{ value = $AllowedDomains }
}
[void](New-Item -ItemType Directory -Path (Join-Path $root '.deployment') -Force)
$parameterFile = Join-Path $root ".deployment/$FunctionName-parameters.json"
[IO.File]::WriteAllText($parameterFile,(@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $deploymentParams } | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$outputsJson = az deployment group create --resource-group $ResourceGroup --name "$FunctionName-deploy" --template-file (Join-Path $PSScriptRoot 'main.bicep') --parameters "@$parameterFile" --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { throw 'Azure-distributionen misslyckades.' }
$outputs = $outputsJson | ConvertFrom-Json
$token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Kunde inte hämta Graph-token för behörighetstilldelning.' }
$headers = @{ Authorization = "Bearer $token" }
$graphFilter = [uri]::EscapeDataString("appId eq '00000003-0000-0000-c000-000000000000'")
$graph = Invoke-RestMethod -Uri ('https://graph.microsoft.com/v1.0/servicePrincipals?$filter=' + $graphFilter) -Headers $headers
$graphSp = @($graph.value)[0]
$role = @($graphSp.appRoles | Where-Object { $_.value -eq 'ExchangeMessageTrace.Read.All' -and 'Application' -in $_.allowedMemberTypes })
if ($role.Count -ne 1) { throw 'Kunde inte hitta Graph-applikationsbehörigheten ExchangeMessageTrace.Read.All.' }
$mi = [string]$outputs.managedIdentityObjectId.value
$assignmentUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$mi/appRoleAssignments"
$existing = Invoke-RestMethod -Uri $assignmentUrl -Headers $headers
if (@($existing.value | Where-Object { $_.resourceId -eq $graphSp.id -and $_.appRoleId -eq $role[0].id }).Count -eq 0) {
    $body = @{ principalId = $mi; resourceId = $graphSp.id; appRoleId = $role[0].id } | ConvertTo-Json
    Invoke-RestMethod -Uri $assignmentUrl -Headers $headers -Method Post -Body $body -ContentType 'application/json' | Out-Null
}
az functionapp deployment source config-zip --resource-group $ResourceGroup --name $FunctionName --src $zip --build-remote false -o none
if ($LASTEXITCODE -ne 0) { throw 'Uppladdningen av funktionskoden misslyckades.' }
# Write a separate deployment artifact; never overwrite the user's local settings silently.
$clientSettings = @{ TenantId = $config.TenantId; ClientId = $config.ClientId; ApiAppId = $config.ApiAppId; ApiBasUrl = $outputs.apiBaseUrl.value; Exportmapp = '' }
$settingsPath = Join-Path $root ".deployment/$FunctionName-Installningar.json"
[IO.File]::WriteAllText($settingsPath,($clientSettings | ConvertTo-Json),[Text.UTF8Encoding]::new($true))
Write-Output "Distribution klar. Klientinställningar: $settingsPath. Kopiera dem till handläggarnas Installningar.json efter acceptanstest."
