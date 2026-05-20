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

@description('Optional hub VNet resource ID to peer with for VPN/ER gateway transit. When set, creates a separate peering with useRemoteGateways=true and allowForwardedTraffic=true so this VNet consumes the hub gateway. Pre-req: the hub side must have allowGatewayTransit=true. Empty = no gateway-transit peering.')
param hubVnetResourceId string = ''

@description('Optional additional VNet resource IDs to link the private DNS zones to (in addition to local + peer). Typical use: a VNet hosting a DNS Private Resolver so cross-VNet clients (e.g. a laptop on VPN) can resolve PE FQDNs.')
param additionalDnsZoneLinkVnetResourceIds array = []

@description('Deploy an Azure Bastion host into this VNet. When true, also creates a Standard SKU Public IP and uses the AzureBastionSubnet defined below. Default false to avoid the ~$140/mo standing charge in non-dev envs.')
param deployBastion bool = false

@description('Subnet prefix for AzureBastionSubnet. Must be /26 or larger; subnet name is fixed by Azure as \'AzureBastionSubnet\'. Always created (cheap empty subnet) so toggling deployBastion does not mutate the parent VNet shape.')
param bastionSubnetPrefix string = '10.100.20.0/26'

@description('Bastion host resource name. Empty = caller-resolved default.')
param bastionName string = ''

@description('Bastion public IP name. Empty = derived from bastionName.')
param bastionPublicIpName string = ''

@description('Dev/jump VM subnet prefix. Always created (cheap empty subnet) so toggling deployDevVm in resources.bicep does not mutate the parent VNet shape.')
param devSubnetPrefix string = '10.100.4.0/27'

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
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
      {
        name: 'snet-dev'
        properties: {
          addressPrefix: devSubnetPrefix
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

// Storage Blob private DNS zone. The token-store storage account uses a
// private endpoint (group 'blob') so app replicas resolve it inside the VNet.
resource storageBlobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource storageBlobDnsLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: storageBlobPrivateDnsZone
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

// ACR private DNS zone. ACR Premium + PE allows the Container Apps env to
// pull images privately (no public ACR endpoint exposed).
resource acrPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurecr.io'
  location: 'global'
  tags: tags
}

resource acrDnsLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: acrPrivateDnsZone
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

// Container Apps env private DNS zone. The env's private endpoint
// (groupId=managedEnvironments) auto-registers '<envDefaultDomain>' as an A
// record in this zone, pointing to the PE NIC IP. App FQDNs of the form
// '<app>.<envDefaultDomain>' CNAME into this private zone. Zone name follows
// the MS-recommended scheme privatelink.<region>.azurecontainerapps.io
// (see https://learn.microsoft.com/azure/private-link/private-endpoint-dns).
resource caePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.${location}.azurecontainerapps.io'
  location: 'global'
  tags: tags
}

resource caeDnsLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: caePrivateDnsZone
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

// Optional gateway-transit peering for laptop/on-prem inbound via a hub VNet's
// VPN/ER gateway. The hub side must have allowGatewayTransit=true; here we set
// useRemoteGateways=true to consume that gateway. allowForwardedTraffic=true
// lets the gateway forward packets whose source isn't this VNet (i.e., the
// laptop VPN client pool CIDR).
resource hubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = if (!empty(hubVnetResourceId)) {
  parent: vnet
  name: 'peer-to-hub-${last(split(hubVnetResourceId, '/'))}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
    remoteVirtualNetwork: {
      id: hubVnetResourceId
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

resource storageBlobDnsLinkPeer 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(peerVnetResourceId)) {
  parent: storageBlobPrivateDnsZone
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

resource acrDnsLinkPeer 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(peerVnetResourceId)) {
  parent: acrPrivateDnsZone
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

resource caeDnsLinkPeer 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!empty(peerVnetResourceId)) {
  parent: caePrivateDnsZone
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

// Additional VNet links for the Container Apps env private DNS zone only
// (e.g. a hub VNet hosting a DNS Private Resolver so VPN clients can reach
// our apps by FQDN). NOTE: we deliberately do NOT link sql/storage/acr
// zones to these extras — those PEs only need to be reachable from inside
// our local VNet (the apps consume them). Linking the hub VNet to multiple
// zones with the same name (e.g. another deployment's
// privatelink.blob.core.windows.net) would fail with "A virtual network
// cannot be linked to multiple zones with overlapping namespaces". The
// cae zone is region-suffixed (privatelink.<location>.azurecontainerapps.io)
// and unique to this env's location, so it doesn't collide.
resource caeDnsLinkExtras 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (vnetResourceId, i) in additionalDnsZoneLinkVnetResourceIds: {
  parent: caePrivateDnsZone
  name: 'extra-link-${i}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetResourceId
    }
  }
}]

// Azure Bastion (Standard SKU) for RDP/SSH into the VNet without exposing
// VM public IPs. Standard SKU is required for: peered-VNet targeting (so the
// same host can reach VMs in dev-vnet via the existing peering), native
// client connections (az network bastion rdp / tunnel), and IP-based
// connection (RDP to an arbitrary IP without registering a VM resource).
var resolvedBastionName = !empty(bastionName) ? bastionName : 'bas-${names.vnet}'
var resolvedBastionPipName = !empty(bastionPublicIpName) ? bastionPublicIpName : 'pip-${resolvedBastionName}'

resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployBastion) {
  name: resolvedBastionPipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = if (deployBastion) {
  name: resolvedBastionName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    enableIpConnect: true
    enableShareableLink: false
    enableFileCopy: true
    disableCopyPaste: false
    scaleUnits: 2
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/AzureBastionSubnet'
          }
          publicIPAddress: {
            id: bastionPip.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output acaSubnetId string = '${vnet.id}/subnets/${names.subnetAca}'
output peSubnetId string = '${vnet.id}/subnets/${names.subnetPe}'
output aciSubnetId string = '${vnet.id}/subnets/${names.subnetAci}'
output devSubnetId string = '${vnet.id}/subnets/snet-dev'
output sqlPrivateDnsZoneId string = sqlPrivateDnsZone.id
output storageBlobPrivateDnsZoneId string = storageBlobPrivateDnsZone.id
output acrPrivateDnsZoneId string = acrPrivateDnsZone.id
output caePrivateDnsZoneId string = caePrivateDnsZone.id
output bastionName string = deployBastion ? resolvedBastionName : ''
output bastionPublicIp string = deployBastion ? bastionPip!.properties.ipAddress : ''
