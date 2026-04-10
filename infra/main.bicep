targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string

@minLength(1)
param location string

@description('Entra ID principal ID for SQL admin')
param principalId string

@description('Entra ID principal display name for SQL admin')
param principalName string

var resourceSuffix = take(uniqueString(subscription().id, environmentName, location), 6)
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources './modules/resources.bicep' = {
  scope: rg
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
    principalId: principalId
    principalName: principalName
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.containerRegistryEndpoint
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.containerRegistryName
output AZURE_SQL_SERVER_NAME string = resources.outputs.sqlServerName
output AZURE_SQL_DATABASE_NAME string = resources.outputs.sqlDatabaseName
output API_URL string = resources.outputs.apiUrl
output SERVICE_WEB_NAME string = resources.outputs.containerAppName
