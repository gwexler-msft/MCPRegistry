targetScope = 'subscription'

import { getDefaultName, getDefaultNameNoDashes, generateSuffix } from './modules/naming.bicep'

@minLength(1)
@maxLength(64)
param environmentName string

@minLength(1)
param location string

@description('Entra ID principal ID for SQL admin')
param principalId string

@description('Entra ID principal display name for SQL admin')
param principalName string

@description('Short workload identifier used in resource names (default: mcpreg)')
param workloadName string = 'mcpreg'

@description('Additional tags to apply to all resources')
param customTags object = {}

// Optional resource name overrides — leave empty to use CAF naming convention defaults
@description('Override: resource group name')
param resourceGroupName string = ''
@description('Override: Log Analytics workspace name')
param logAnalyticsWorkspaceName string = ''
@description('Override: Container Registry name (alphanumeric only, 5-50 chars)')
param containerRegistryName string = ''
@description('Override: Managed Identity name')
param managedIdentityName string = ''
@description('Override: Container Apps Environment name')
param containerAppsEnvironmentName string = ''
@description('Override: SQL Server name')
param sqlServerName string = ''
@description('Override: SQL Database name')
param sqlDatabaseName string = 'MCPRegistry'
@description('Override: Container App name')
param containerAppName string = ''
@description('Override: Virtual Network name')
param vnetName string = ''
@description('Override: Container Apps subnet name')
param acaSubnetName string = 'snet-aca'
@description('Override: Private Endpoint subnet name')
param peSubnetName string = 'snet-pe'
@description('Override: ACI test subnet name (for in-VNet curl-test container)')
param aciSubnetName string = 'snet-aci'

@description('Container image for the API app (default: placeholder for initial provision)')
param apiContainerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Container image for the UI app (default: placeholder for initial provision)')
param uiContainerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('ASP.NET Core environment (Development, Production)')
param aspnetEnvironment string = 'Production'

@description('VNet address space (CIDR).')
param vnetAddressPrefix string = '10.100.0.0/16'

@description('Container Apps subnet prefix. Must be /23 or larger.')
param acaSubnetPrefix string = '10.100.0.0/23'

@description('Private endpoint subnet prefix.')
param peSubnetPrefix string = '10.100.2.0/24'

@description('ACI test subnet prefix (delegated to Microsoft.ContainerInstance/containerGroups). Used by curl-test container.')
param aciSubnetPrefix string = '10.100.3.0/27'

@description('Optional resource ID of an existing VNet to peer with for inbound access. Empty = no peering. Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>')
param peerVnetResourceId string = ''

var suffix = generateSuffix(subscription().subscriptionId, environmentName, location)
var tags = union({ 'azd-env-name': environmentName }, customTags)

var resolvedNames = {
  resourceGroup: !empty(resourceGroupName) ? resourceGroupName : 'rg-${environmentName}'
  logAnalytics: !empty(logAnalyticsWorkspaceName) ? logAnalyticsWorkspaceName : getDefaultName('log', workloadName, suffix)
  containerRegistry: !empty(containerRegistryName) ? containerRegistryName : getDefaultNameNoDashes('cr', workloadName, suffix)
  managedIdentity: !empty(managedIdentityName) ? managedIdentityName : getDefaultName('id', workloadName, suffix)
  containerAppsEnv: !empty(containerAppsEnvironmentName) ? containerAppsEnvironmentName : getDefaultName('cae', workloadName, suffix)
  sqlServer: !empty(sqlServerName) ? sqlServerName : getDefaultName('sql', workloadName, suffix)
  sqlDatabase: sqlDatabaseName
  containerApp: !empty(containerAppName) ? containerAppName : getDefaultName('ca', workloadName, suffix)
  containerAppUi: getDefaultName('ca', '${workloadName}-ui', suffix)
  vnet: !empty(vnetName) ? vnetName : getDefaultName('vnet', workloadName, suffix)
  subnetAca: acaSubnetName
  subnetPe: peSubnetName
  subnetAci: aciSubnetName
}

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resolvedNames.resourceGroup
  location: location
  tags: tags
}

module network './modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    location: location
    tags: tags
    names: {
      vnet: resolvedNames.vnet
      subnetAca: resolvedNames.subnetAca
      subnetPe: resolvedNames.subnetPe
      subnetAci: resolvedNames.subnetAci
    }
    vnetAddressPrefix: vnetAddressPrefix
    acaSubnetPrefix: acaSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    aciSubnetPrefix: aciSubnetPrefix
    peerVnetResourceId: peerVnetResourceId
  }
}

module resources './modules/resources.bicep' = {
  scope: rg
  params: {
    location: location
    tags: tags
    principalId: principalId
    principalName: principalName
    names: resolvedNames
    apiContainerImage: apiContainerImage
    uiContainerImage: uiContainerImage
    aspnetEnvironment: aspnetEnvironment
    acaSubnetId: network.outputs.acaSubnetId
    peSubnetId: network.outputs.peSubnetId
    sqlPrivateDnsZoneId: network.outputs.sqlPrivateDnsZoneId
    vnetId: network.outputs.vnetId
    vnetAddressPrefix: vnetAddressPrefix
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.containerRegistryEndpoint
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.containerRegistryName
output AZURE_SQL_SERVER_NAME string = resources.outputs.sqlServerName
output AZURE_SQL_DATABASE_NAME string = resources.outputs.sqlDatabaseName
output API_URL string = resources.outputs.apiUrl
output UI_URL string = resources.outputs.uiUrl
output SERVICE_WEB_NAME string = resources.outputs.containerAppName
output SERVICE_UI_NAME string = resources.outputs.containerAppUiName
output AZURE_MANAGED_IDENTITY_NAME string = resources.outputs.managedIdentityName
output AZURE_MANAGED_IDENTITY_CLIENT_ID string = resources.outputs.managedIdentityClientId
output AZURE_VNET_NAME string = network.outputs.vnetName
output AZURE_VNET_ID string = network.outputs.vnetId
output AZURE_ACI_SUBNET_ID string = network.outputs.aciSubnetId
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = resources.outputs.containerAppsEnvironmentName
output AZURE_CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN string = resources.outputs.containerAppsEnvironmentDefaultDomain
output AZURE_CONTAINER_APPS_ENVIRONMENT_STATIC_IP string = resources.outputs.containerAppsEnvironmentStaticIp
