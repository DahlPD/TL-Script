#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]{2,50}$')][string]$Name,
    [Parameter(Mandatory)][ValidateCount(1,100)][guid[]]$UserOrGroupObjectId
)
$ErrorActionPreference = 'Stop'
# Administrator tool, not distributed to case workers. Azure CLI must already be signed in.
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Installera Azure CLI på IT:s administrationsdator och kör az login först.' }
$accountJson = az account show -o json
if ($LASTEXITCODE -ne 0) { throw 'Kör az login med rätt administratörskonto först.' }
$account = $accountJson | ConvertFrom-Json
$token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Kunde inte hämta administratörens Graph-token.' }
$headers = @{ Authorization = "Bearer $token" }
function Invoke-AdminGraph([string]$Path,[string]$Method = 'Get',$Body = $null) {
    $requestArgs = @{ Uri = "https://graph.microsoft.com/v1.0/$Path"; Method = $Method; Headers = $headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $requestArgs.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 12 -Compress))
        $requestArgs.ContentType = 'application/json; charset=utf-8'
    }
    Invoke-RestMethod @requestArgs
}
$stateDir = Join-Path (Split-Path $PSScriptRoot -Parent) '.deployment'
[void](New-Item -ItemType Directory -Path $stateDir -Force)
$stateFile = Join-Path $stateDir "$Name-entra.json"
if (Test-Path -LiteralPath $stateFile) {
    $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.TenantId -ne $account.tenantId) { throw 'Sparad konfiguration tillhör en annan tenant.' }
} else {
    $state = [pscustomobject]@{
        TenantId = $account.tenantId; ApiAppId = ''; ApiObjectId = ''; ApiServicePrincipalId = ''
        ClientId = ''; ClientObjectId = ''; ClientServicePrincipalId = ''
        ScopeId = [guid]::NewGuid().ToString(); RoleId = [guid]::NewGuid().ToString()
    }
}
function Save-State { [IO.File]::WriteAllText($stateFile,($state | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true)) }
Save-State
if (-not $state.ApiObjectId) {
    $app = Invoke-AdminGraph 'applications' Post @{
        displayName = "$Name-api"; signInAudience = 'AzureADMyOrg'
        api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(@{
            id = $state.ScopeId; value = 'Transportlogg.Access'; type = 'Admin'; isEnabled = $true
            adminConsentDisplayName = 'Använd transportloggtjänsten'; adminConsentDescription = 'Låter klienten anropa transportloggtjänsten för inloggad handläggare.'
        }) }
        appRoles = @(@{
            id = $state.RoleId; value = 'Trace.Reader'; displayName = 'Transportlogg – handläggare'
            description = 'Får söka transportloggar via tjänsten.'; allowedMemberTypes = @('User'); isEnabled = $true
        })
    }
    $state.ApiAppId = $app.appId; $state.ApiObjectId = $app.id; Save-State
}
Invoke-AdminGraph "applications/$($state.ApiObjectId)" Patch @{ identifierUris = @("api://$($state.ApiAppId)") } | Out-Null
if (-not $state.ApiServicePrincipalId) {
    $sp = Invoke-AdminGraph 'servicePrincipals' Post @{ appId = $state.ApiAppId; appRoleAssignmentRequired = $true }
    $state.ApiServicePrincipalId = $sp.id; Save-State
}
if (-not $state.ClientObjectId) {
    $app = Invoke-AdminGraph 'applications' Post @{
        displayName = "$Name-klient"; signInAudience = 'AzureADMyOrg'; isFallbackPublicClient = $true
        requiredResourceAccess = @(@{ resourceAppId = $state.ApiAppId; resourceAccess = @(@{ id = $state.ScopeId; type = 'Scope' }) })
    }
    $state.ClientId = $app.appId; $state.ClientObjectId = $app.id; Save-State
}
if (-not $state.ClientServicePrincipalId) {
    $sp = Invoke-AdminGraph 'servicePrincipals' Post @{ appId = $state.ClientId }
    $state.ClientServicePrincipalId = $sp.id; Save-State
}
$apiDefinition = (Invoke-AdminGraph ('applications/' + $state.ApiObjectId + '?$select=api')).api
$apiDefinition | Add-Member -NotePropertyName preAuthorizedApplications -NotePropertyValue @(@{ appId = $state.ClientId; delegatedPermissionIds = @($state.ScopeId) }) -Force
Invoke-AdminGraph "applications/$($state.ApiObjectId)" Patch @{ api = $apiDefinition } | Out-Null
$filter = [uri]::EscapeDataString("clientId eq '$($state.ClientServicePrincipalId)' and resourceId eq '$($state.ApiServicePrincipalId)'")
$grants = Invoke-AdminGraph ('oauth2PermissionGrants?$filter=' + $filter)
if (@($grants.value | Where-Object consentType -eq 'AllPrincipals').Count -eq 0) {
    Invoke-AdminGraph 'oauth2PermissionGrants' Post @{
        clientId = $state.ClientServicePrincipalId; resourceId = $state.ApiServicePrincipalId
        consentType = 'AllPrincipals'; scope = 'Transportlogg.Access'
    } | Out-Null
}
$assignments = Invoke-AdminGraph "servicePrincipals/$($state.ApiServicePrincipalId)/appRoleAssignedTo"
foreach ($objectId in $UserOrGroupObjectId) {
    if (@($assignments.value | Where-Object { $_.principalId -eq $objectId.ToString() -and $_.appRoleId -eq $state.RoleId }).Count -eq 0) {
        Invoke-AdminGraph "servicePrincipals/$($state.ApiServicePrincipalId)/appRoleAssignedTo" Post @{
            principalId = $objectId.ToString(); resourceId = $state.ApiServicePrincipalId; appRoleId = $state.RoleId
        } | Out-Null
    }
}
# Microsoft prerequisite; separate from the two applications above.
$filter = [uri]::EscapeDataString("appId eq '8bd644d1-64a1-4d4b-ae52-2e0cbf64e373'")
$traceService = Invoke-AdminGraph ('servicePrincipals?$filter=' + $filter)
if (@($traceService.value).Count -eq 0) {
    Invoke-AdminGraph 'servicePrincipals' Post @{ appId = '8bd644d1-64a1-4d4b-ae52-2e0cbf64e373' } | Out-Null
}
Write-Output "Entra-konfiguration sparad i $stateFile. Inga klienthemligheter har skapats."
