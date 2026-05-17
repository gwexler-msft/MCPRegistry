targetScope = 'resourceGroup'

@description('Azure region for all networking resources.')
param location string

@description('Tags applied to all networking resources.')
param tags object = {}

@description('Resolved network resource names (vnet, subnetAca, subnetPe, subnetAci).')
param names object

@description('VNet address space (CIDR).')
param vnetAddressPrefix string = '10.100.0.0/16'

@description('Subnet for the Container Apps environment. Must be /23 or larger; delegated to Microsoft.App/environments.')
param acaSubnetPrefix string = '10.100.0.0/23'

@description('Subnet for private endpoints.')
param peSubnetPrefix string = '10.100.2.0/24'

@description('Subnet for in-VNet test container instances (e.g., curl-test). Delegated to Microsoft.ContainerInstance/containerGroups.')
param aciSubnetPrefix string = '10.100.3.0/27'

@description('Optional resource ID of an existing VNet to peer with for inbound access. Empty = no peering.')
param peerVnetResourceId string = ''

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: names.vnet
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: names.subnetAca
        properties: {
          addressPrefix: acaSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: names.subnetPe
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: names.subnetAci
        properties: {
          addressPrefix: aciSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.ContainerInstance.containerGroups'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource sqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.database.windows.net'
  location: 'global'
  tags: tags
}

resource sqlDnsLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: sqlPrivateDnsZone
  name: '${names.vnet}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Optional peering for inbound access from a hub/dev VNet. Two-sided peering
// requires the corresponding peer to be created in the peer VNet's RG/sub
// (out of scope for this template — instructions below).
resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = if (!empty(peerVnetResourceId)) {
  parent: vnet
  name: 'peer-to-${last(split(peerVnetResourceId, '/'))}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: peerVnetResourceId
    }
  }
}

// Link SQL DNS zone to the peer VNet so apps in the peer can resolve the SQL PE too.
resource sqlDnsLinkPeer 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(peerVnetResourceId)) {
  parent: sqlPrivateDnsZone
  name: 'peer-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: peerVnetResourceId
    }
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output acaSubnetId string = '${vnet.id}/subnets/${names.subnetAca}'
output peSubnetId string = '${vnet.id}/subnets/${names.subnetPe}'
output aciSubnetId string = '${vnet.id}/subnets/${names.subnetAci}'
output sqlPrivateDnsZoneId string = sqlPrivateDnsZone.id
