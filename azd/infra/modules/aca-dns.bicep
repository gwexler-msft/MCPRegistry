targetScope = 'resourceGroup'

@description('Default domain of the Container Apps environment, e.g. "icyocean-6c328e7e.centralus.azurecontainerapps.io".')
param envDefaultDomain string

@description('Static IP of the Container Apps environment internal load balancer.')
param envStaticIp string

@description('Resource ID of the local VNet (the one hosting the ACA env). Used for the private DNS zone link.')
param vnetId string

@description('Tags applied to the DNS zone and link.')
param tags object = {}

// Wildcard A records cover both <app>.<envDomain> (external-style FQDN) and
// <app>.internal.<envDomain> (the only style usable for internal envs).
// Apps in the local VNet need this zone to resolve to the env's internal load
// balancer staticIp; without it, requests fall back to public DNS which
// returns the same domain but resolution fails inside private envs.
resource envDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: envDefaultDomain
  location: 'global'
  tags: tags
}

resource envDnsRecordWildcard 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: envDnsZone
  name: '*'
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: envStaticIp
      }
    ]
  }
}

resource envDnsRecordWildcardInternal 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: envDnsZone
  name: '*.internal'
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: envStaticIp
      }
    ]
  }
}

resource envDnsLinkLocal 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: envDnsZone
  name: 'link-self'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

output envDnsZoneId string = envDnsZone.id
output envDnsZoneName string = envDnsZone.name
