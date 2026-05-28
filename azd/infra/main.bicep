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

@description('Deploy Azure Bastion (Standard SKU) into the VNet for RDP/SSH access without VM public IPs. Default false to avoid the ~$140/mo standing charge in non-dev envs.')
param deployBastion bool = false

@description('AzureBastionSubnet prefix (subnet name fixed by Azure). Always created so toggling deployBastion does not mutate the parent VNet shape.')
param bastionSubnetPrefix string = '10.100.20.0/26'

@description('Override: Bastion host name.')
param bastionName string = ''

@description('Override: Bastion public IP name.')
param bastionPublicIpName string = ''

@description('Deploy a small dev/jump VM in snet-dev for Bastion access. Default false to avoid VM costs in non-dev envs.')
param deployDevVm bool = false

@description('snet-dev subnet prefix. Always created so toggling deployDevVm does not mutate the parent VNet shape.')
param devSubnetPrefix string = '10.100.4.0/27'

@description('Dev VM size (default Standard_B2s).')
param devVmSize string = 'Standard_B2s'

@description('Local admin username on the dev VM (break-glass only; day-to-day login is AAD via Bastion).')
param devVmAdminUsername string = 'azureuser'

@secure()
@description('Local admin password for the dev VM. Set with: azd env set --secret AZURE_DEV_VM_ADMIN_PASSWORD. Required when deployDevVm=true.')
param devVmAdminPassword string = ''

@description('Auto-shutdown time for the dev VM in HHmm (24h).')
param devVmShutdownTime string = '1900'

@description('Windows TimeZone Standard name for the auto-shutdown schedule.')
param devVmShutdownTimezone string = 'Central Standard Time'

@description('Optional resource ID of an existing VNet to peer with for inbound access. Empty = no peering. Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>')
param peerVnetResourceId string = ''

@description('Optional hub VNet resource ID to peer with for VPN/ER gateway transit. When set, this VNet consumes the hub\'s VPN/ExpressRoute gateway so on-prem/VPN clients can reach apps here. Pre-req: the hub side must have allowGatewayTransit=true on its peering back. Empty = no gateway-transit peering.')
param hubVnetResourceId string = ''

@description('Optional comma-separated list of additional VNet resource IDs to link the private DNS zones to (in addition to local + peer). Typical use: VNet hosting a DNS Private Resolver, so cross-VNet clients (e.g. a laptop on VPN) can resolve PE FQDNs (apps, SQL, storage, ACR). Empty = local + peer links only.')
param dnsZoneLinkVnetResourceIdsCsv string = ''

@description('Optional comma-separated CIDRs allowed to reach the ACR data plane over the public endpoint. When set, ACR networkRuleSet defaults to Deny and only these CIDRs are allowed. Container Apps still pull images privately via the PE regardless. Empty = ACR public endpoint stays fully open (defaultAction=Allow).')
param extraAllowedSourceCidrsCsv string = ''

@description('Entra ID tenant ID hosting the AAD app registrations used by Easy Auth. Populated automatically by azd from the active login.')
param tenantId string = subscription().tenantId

@description('Application (client) ID of the AAD app registration backing the API\'s Easy Auth. Created/reused by the preprovision hook (scripts/setup-aad-apps).')
param apiAppClientId string

@description('Application (client) ID of the AAD app registration backing the UI\'s Easy Auth. Created/reused by the preprovision hook (scripts/setup-aad-apps).')
param uiAppClientId string

@secure()
@description('Client secret for the UI AAD app registration, used by Easy Auth\'s auth-code exchange. Generated by the preprovision hook and stored in azd env as AZURE_UI_APP_CLIENT_SECRET. Pushed into the UI container app\'s secrets collection and referenced from authConfigs via clientSecretSettingName.')
param uiAppClientSecret string

@description('Object ID of the Entra ID security group whose members are authorized to call API write endpoints (POST/DELETE) and to use the admin UI. Set with `azd env set AZURE_ADMIN_GROUP_ID <object-id>`.')
param adminGroupId string

var dnsZoneLinkVnetResourceIds = empty(dnsZoneLinkVnetResourceIdsCsv) ? [] : split(dnsZoneLinkVnetResourceIdsCsv, ',')
var extraAllowedSourceCidrs = empty(extraAllowedSourceCidrsCsv) ? [] : split(extraAllowedSourceCidrsCsv, ',')

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
    hubVnetResourceId: hubVnetResourceId
    additionalDnsZoneLinkVnetResourceIds: dnsZoneLinkVnetResourceIds
    deployBastion: deployBastion
    bastionSubnetPrefix: bastionSubnetPrefix
    bastionName: bastionName
    bastionPublicIpName: bastionPublicIpName
    devSubnetPrefix: devSubnetPrefix
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
    storageBlobPrivateDnsZoneId: network.outputs.storageBlobPrivateDnsZoneId
    acrPrivateDnsZoneId: network.outputs.acrPrivateDnsZoneId
    caePrivateDnsZoneId: network.outputs.caePrivateDnsZoneId
    tenantId: tenantId
    apiAppClientId: apiAppClientId
    uiAppClientId: uiAppClientId
    uiAppClientSecret: uiAppClientSecret
    adminGroupId: adminGroupId
    deployDevVm: deployDevVm
    devSubnetId: network.outputs.devSubnetId
    bastionSubnetPrefix: bastionSubnetPrefix
    devVmSize: devVmSize
    devVmAdminUsername: devVmAdminUsername
    devVmAdminPassword: devVmAdminPassword
    devVmShutdownTime: devVmShutdownTime
    devVmShutdownTimezone: devVmShutdownTimezone
    extraAllowedSourceCidrs: extraAllowedSourceCidrs
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.containerRegistryEndpoint
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.containerRegistryName
output AZURE_SQL_SERVER_NAME string = resources.outputs.sqlServerName
output AZURE_SQL_DATABASE_NAME string = resources.outputs.sqlDatabaseName
output API_URL string = resources.outputs.apiUrl
output UI_URL string = resources.outputs.uiUrl
output SERVICE_API_NAME string = resources.outputs.containerAppName
output SERVICE_UI_NAME string = resources.outputs.containerAppUiName
output AZURE_MANAGED_IDENTITY_NAME string = resources.outputs.managedIdentityName
output AZURE_MANAGED_IDENTITY_CLIENT_ID string = resources.outputs.managedIdentityClientId
output AZURE_VNET_NAME string = network.outputs.vnetName
output AZURE_VNET_ID string = network.outputs.vnetId
output AZURE_ACI_SUBNET_ID string = network.outputs.aciSubnetId
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = resources.outputs.containerAppsEnvironmentName
output AZURE_CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN string = resources.outputs.containerAppsEnvironmentDefaultDomain
output AZURE_CONTAINER_APPS_ENVIRONMENT_STATIC_IP string = resources.outputs.containerAppsEnvironmentStaticIp
output AZURE_BASTION_NAME string = network.outputs.bastionName
output AZURE_BASTION_PUBLIC_IP string = network.outputs.bastionPublicIp
output AZURE_DEV_VM_NAME string = resources.outputs.devVmName
output AZURE_DEV_VM_PRIVATE_IP string = resources.outputs.devVmPrivateIp
