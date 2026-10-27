targetScope = 'resourceGroup'

@description('Globally unique Function App name, lowercase letters, digits and hyphens.')
@minLength(2)
@maxLength(50)
param functionName string
param location string = resourceGroup().location
param tenantId string
param apiAppId string
param clientAppId string
@minLength(1)
param allowedDomains array

var storageName = 'st${uniqueString(resourceGroup().id, functionName)}'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${functionName}-logs'
  location: location
  properties: { retentionInDays: 30, sku: { name: 'PerGB2018' } }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${functionName}-insights'
  location: location
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: workspace.id }
}

resource plan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${functionName}-plan'
  location: location
  sku: { name: 'Y1', tier: 'Dynamic' }
  properties: { reserved: false }
}

resource app 'Microsoft.Web/sites@2022-09-01' = {
  name: functionName
  location: location
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      use32BitWorkerProcess: false
      functionAppScaleLimit: 1
      powerShellVersion: '7.4'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: '7.4' }
        { name: 'FUNCTIONS_WORKER_PROCESS_COUNT', value: '1' }
        { name: 'PSWorkerInProcConcurrencyUpperBound', value: '1' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
        { name: 'AzureWebJobsDisableHomepage', value: 'true' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'TL_TENANT_ID', value: tenantId }
        { name: 'TL_CLIENT_ID', value: clientAppId }
        { name: 'TL_ALLOWED_DOMAINS', value: string(allowedDomains) }
      ]
    }
  }
}

resource auth 'Microsoft.Web/sites/config@2022-09-01' = {
  parent: app
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true, runtimeVersion: '~1' }
    globalValidation: { requireAuthentication: true, unauthenticatedClientAction: 'Return401' }
    httpSettings: { requireHttps: true }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: apiAppId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [apiAppId, 'api://${apiAppId}']
          defaultAuthorizationPolicy: { allowedApplications: [clientAppId] }
        }
      }
    }
    login: { tokenStore: { enabled: false } }
  }
}

output apiBaseUrl string = 'https://${app.properties.defaultHostName}'
output managedIdentityObjectId string = app.identity.principalId
output functionAppName string = app.name
