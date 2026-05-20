targetScope = 'resourceGroup'

param location string = resourceGroup().location
param tags object = {}

@description('Resolved resource names from main.bicep')
param names object

@description('Entra ID principal ID for SQL admin')
param principalId string

@description('Entra ID principal display name for SQL admin')
param principalName string

@description('Container image for the API app')
param apiContainerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Container image for the UI app')
param uiContainerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('ASP.NET Core environment (Development, Production)')
param aspnetEnvironment string = 'Production'

@description('Resource ID of the subnet used by the Container Apps environment.')
param acaSubnetId string

@description('Resource ID of the subnet used for private endpoints.')
param peSubnetId string

@description('Resource ID of the privatelink.database.windows.net private DNS zone.')
param sqlPrivateDnsZoneId string

@description('Resource ID of the privatelink.azurecr.io private DNS zone.')
param acrPrivateDnsZoneId string

@description('Resource ID of the privatelink.blob.core.windows.net private DNS zone.')
param storageBlobPrivateDnsZoneId string

@description('Resource ID of the privatelink.<region>.azurecontainerapps.io private DNS zone (used by the Container Apps env private endpoint).')
param caePrivateDnsZoneId string

@description('Entra ID tenant ID hosting the AAD app registrations used by Easy Auth.')
param tenantId string

@description('Application (client) ID of the AAD app registration backing the API\'s Easy Auth.')
param apiAppClientId string

@description('Application (client) ID of the AAD app registration backing the UI sign-in (Microsoft.Identity.Web).')
param uiAppClientId string

@secure()
@description('Client secret for the UI AAD app registration. Surfaced to the UI container as the AzureAd__ClientSecret env var via a Container Apps secret.')
param uiAppClientSecret string

@description('Object ID of the Entra ID security group whose members are authorized for admin actions (API writes + UI access).')
param adminGroupId string

@description('Deploy a small dev/jump VM in snet-dev. Default false. Reachable only via Azure Bastion (no public IP).')
param deployDevVm bool = false

@description('Resource ID of the snet-dev subnet (from network module).')
param devSubnetId string = ''

@description('CIDR of the AzureBastionSubnet -- used as the NSG source for RDP, so only Bastion can reach the VM.')
param bastionSubnetPrefix string = '10.100.20.0/26'

@description('Dev VM size (default Standard_B2s -- burstable, ~$30/mo running, ~$0 stopped-deallocated).')
param devVmSize string = 'Standard_B2s'

@description('Local admin username on the dev VM. Used only for break-glass; day-to-day login is via AAD through Bastion (AADLoginForWindows extension + Virtual Machine Administrator Login role).')
param devVmAdminUsername string = 'azureuser'

@secure()
@description('Local admin password for the dev VM. Set with: azd env set --secret AZURE_DEV_VM_ADMIN_PASSWORD. Empty when deployDevVm=false. Min 12 chars, mix upper/lower/digit/symbol per Azure VM policy.')
param devVmAdminPassword string = ''

@description('Auto-shutdown time for the dev VM in HHmm (24h) format.')
param devVmShutdownTime string = '1900'

@description('Windows TimeZone Standard name for the auto-shutdown schedule.')
param devVmShutdownTimezone string = 'Central Standard Time'

@description('Optional list of CIDRs allowed to reach the ACR data plane over the public endpoint. When non-empty, ACR networkRuleSet defaults to Deny and only these CIDRs are allowed. Container Apps still pull images privately via the PE regardless. Empty = ACR stays fully open (defaultAction=Allow).')
param extraAllowedSourceCidrs array = []

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: 'logAnalytics'
  params: {
    name: names.logAnalytics
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: 30
  }
}

module containerRegistry 'br/public:avm/res/container-registry/registry:0.12.0' = {
  name: 'containerRegistry'
  params: {
    name: names.containerRegistry
    location: location
    tags: tags
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    // PE for in-VNet pulls (Container Apps env uses managed identity +
    // privatelink.azurecr.io zone to resolve privately). Public endpoint
    // remains reachable so `azd deploy` can push images from the operator's
    // laptop via `az acr build`; tighten further (PNA=Disabled +
    // networkRuleBypassOptions=AzureServices) once a build path inside the
    // VNet is wired up.
    publicNetworkAccess: 'Enabled'
    // AVM defaults exportPolicyStatus=disabled, which requires PNA=Disabled.
    // We keep exports enabled to match PNA=Enabled.
    exportPolicyStatus: 'enabled'
    // When extraAllowedSourceCidrs is provided, lock the public endpoint to
    // those IPs only (laptop, corp net, GitHub Actions egress, etc.). When
    // empty, leave it as Allow so the operator can still push from anywhere.
    // Container Apps always pull via the PE regardless of this setting.
    networkRuleSetDefaultAction: empty(extraAllowedSourceCidrs) ? 'Allow' : 'Deny'
    networkRuleSetIpRules: [for cidr in extraAllowedSourceCidrs: {
      action: 'Allow'
      value: cidr
    }]
    privateEndpoints: [
      {
        name: '${names.containerRegistry}-pe'
        subnetResourceId: peSubnetId
        service: 'registry'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: acrPrivateDnsZoneId
            }
          ]
        }
      }
    ]
    roleAssignments: [
      {
        principalId: managedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull — container apps use managed identity to pull
      }
    ]
  }
}

// Storage account backing the UI Easy Auth token store. The 2024-03-01
// Token-store storage account was previously used to back Container Apps
// Easy Auth on the UI. We removed Easy Auth in favor of running OpenID
// Connect + MSAL token caches inside the UI Blazor Server app itself,
// because tenant policy MCAPSGovDeployPolicies (StorageAccount_DisableLocalAuth_Modify
// at MG root) silently forces allowSharedKeyAccess=false on every storage
// account, and the authConfigs schema only supports a SAS-URL token store
// (no managed identity option). With shared-key auth disabled the SAS URL
// is rejected by storage with 403 KeyBasedAuthenticationNotPermitted and
// Easy Auth can't deposit tokens. See user memory + repo memory for details.

module managedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'managedIdentity'
  params: {
    name: names.managedIdentity
    location: location
    tags: tags
  }
}

var dataProtectionStorageName = take(replace('stdp${uniqueString(resourceGroup().id, names.containerAppUi)}', '-', ''), 24)
var storageBlobDataContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource dataProtectionStorage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: dataProtectionStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
}

resource dataProtectionBlobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: dataProtectionStorage
  name: 'default'
}

resource dataProtectionContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: dataProtectionBlobService
  name: 'dataprotection'
  properties: {
    publicAccess: 'None'
  }
}

resource dataProtectionStorageBlobPe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${dataProtectionStorage.name}-blob-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: dataProtectionStorage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource dataProtectionStorageBlobPeZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: dataProtectionStorageBlobPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: storageBlobPrivateDnsZoneId
        }
      }
    ]
  }
}

resource dataProtectionStorageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dataProtectionStorage
  name: guid(dataProtectionStorage.id, names.managedIdentity, storageBlobDataContributorRoleDefinitionId)
  properties: {
    principalId: managedIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributorRoleDefinitionId
  }
}

module containerAppsEnv 'br/public:avm/res/app/managed-environment:0.13.1' = {
  name: 'containerAppsEnv'
  params: {
    name: names.containerAppsEnv
    location: location
    tags: tags
    zoneRedundant: false
    // External env (internal:false) + publicNetworkAccess:Enabled exposes app
    // FQDNs on the public envoy so spec-compliant external clients (e.g.
    // GitHub Copilot Enterprise's "MCP registry URL" org policy, which calls
    // the registry from GitHub-owned infrastructure outside this VNet) can
    // reach the API. Per-endpoint security still applies:
    //   - GET /v0.1/servers* are anonymous per the MCP Registry v0.1 spec.
    //   - POST/DELETE require an admin group claim (RequireAdmin policy).
    //   - The Blazor UI is gated by Microsoft.Identity.Web sign-in.
    // The privatelink.<region>.azurecontainerapps.io zone is retained but
    // unused; Azure rejects PNA=Enabled while a Container Apps env private
    // endpoint exists, so the env PE was removed. App-to-app calls inside
    // the env still route internally through envoy without crossing the
    // public edge.
    internal: false
    publicNetworkAccess: 'Enabled'
    infrastructureSubnetResourceId: acaSubnetId
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    }
  }
}

// Note: a Container Apps env private endpoint cannot coexist with
// publicNetworkAccess:Enabled (Azure rejects with
// ManagedEnvironmentInvalidPublicNetworkAccessWithPrivateEndpoint). Since
// the env is now publicly addressable so GitHub Copilot Enterprise's
// "MCP registry URL" org policy can reach the API, the env PE has been
// removed. VNet-attached callers continue to reach apps via the same
// public FQDN; app-to-app traffic inside the env still routes internally
// through envoy without crossing the public edge. The
// privatelink.<region>.azurecontainerapps.io zone is retained but unused
// (it will be empty unless the env PE is re-introduced) so peered VNet
// links don't need to be torn down on a future revert.

module sqlServer 'br/public:avm/res/sql/server:0.21.1' = {
  name: 'sqlServer'
  params: {
    name: names.sqlServer
    location: location
    tags: tags
    minimalTlsVersion: '1.2'
    // Private endpoint only. Azure Policy enforces PNA=Disabled at the
    // subscription scope; matching it here keeps Bicep and runtime state
    // consistent and avoids deploy-time drift warnings.
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: principalName
      sid: principalId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
    databases: [
      {
        name: names.sqlDatabase
        collation: 'SQL_Latin1_General_CP1_CI_AS'
        maxSizeBytes: 2147483648
        availabilityZone: 1
        sku: {
          name: 'GP_S_Gen5'
          tier: 'GeneralPurpose'
          family: 'Gen5'
          capacity: 2
        }
        autoPauseDelay: 60
        minCapacity: '0.5'
      }
    ]
    privateEndpoints: [
      {
        name: '${names.sqlServer}-pe'
        subnetResourceId: peSubnetId
        service: 'sqlServer'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: sqlPrivateDnsZoneId
            }
          ]
        }
      }
    ]
    firewallRules: []
  }
}

// Force SQL connection policy to Proxy so all client traffic stays on the
// gateway (port 1433). The default `Redirect` mode resolves the data node
// IP on in-region Azure clients and asks them to reconnect on ports
// 11000-11999 — those ports are NOT exposed by the private endpoint, so the
// Container App login phase succeeds but post-login hangs and times out.
// AVM's sql/server module does not expose connectionPolicy, so declare as a
// raw child resource.
resource sqlServerRef 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: names.sqlServer
  dependsOn: [sqlServer]
}

resource sqlConnectionPolicy 'Microsoft.Sql/servers/connectionPolicies@2023-08-01' = {
  parent: sqlServerRef
  name: 'default'
  properties: {
    connectionType: 'Proxy'
  }
}

module containerApp 'br/public:avm/res/app/container-app:0.22.0' = {
  name: 'containerApp'
  params: {
    name: names.containerApp
    location: location
    tags: union(tags, { 'azd-service-name': 'api' })
    environmentResourceId: containerAppsEnv.outputs.resourceId
    managedIdentities: {
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    activeRevisionsMode: 'Single'
    // The API is publicly addressable so spec-compliant external clients
    // (notably GitHub Copilot Enterprise's "MCP registry URL" org policy,
    // which calls the registry from GitHub-owned infrastructure outside this
    // VNet) can reach it. App FQDN publishes at '<app>.<envDefaultDomain>'
    // and resolves to the env's public LB. Container Apps Easy Auth is
    // deliberately NOT enabled — authn/authz are handled inside the app by
    // Microsoft.Identity.Web. GET /v0.1/servers* are anonymous per the MCP
    // Registry v0.1 spec; POST and DELETE require an admin group claim via
    // the RequireAdmin policy.
    ingressExternal: true
    ingressTargetPort: 8080
    ingressTransport: 'http'
    ingressAllowInsecure: false
    workloadProfileName: 'Consumption'
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: managedIdentity.outputs.resourceId
      }
    ]
    containers: [
      {
        name: 'mcpregistry'
        image: apiContainerImage
        resources: {
          cpu: '0.5'
          memory: '1Gi'
        }
        env: [
          {
            name: 'ASPNETCORE_ENVIRONMENT'
            value: aspnetEnvironment
          }
          {
            name: 'ConnectionStrings__DefaultConnection'
            value: 'Server=tcp:${sqlServer.outputs.fullyQualifiedDomainName},1433;Database=${names.sqlDatabase};Authentication=Active Directory Default;TrustServerCertificate=False;Encrypt=True;User Id=${managedIdentity.outputs.clientId}'
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: managedIdentity.outputs.clientId
          }
          {
            name: 'AzureAd__TenantId'
            value: tenantId
          }
          {
            name: 'AzureAd__ClientId'
            value: apiAppClientId
          }
          {
            name: 'AzureAd__Instance'
            value: environment().authentication.loginEndpoint
          }
          {
            name: 'AzureAd__AdminGroupId'
            value: adminGroupId
          }
        ]
      }
    ]
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 3
      rules: [
        {
          name: 'http-rule'
          http: {
            metadata: {
              concurrentRequests: '100'
            }
          }
        }
      ]
    }
  }
}

module containerAppUi 'br/public:avm/res/app/container-app:0.22.0' = {
  name: 'containerAppUi'
  params: {
    name: names.containerAppUi
    location: location
    tags: union(tags, { 'azd-service-name': 'ui' })
    environmentResourceId: containerAppsEnv.outputs.resourceId
    managedIdentities: {
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    activeRevisionsMode: 'Single'
    // The UI is publicly addressable (env PNA=Enabled + ingressExternal:true)
    // but every route is gated by Microsoft.Identity.Web OIDC sign-in against
    // the UI AAD app registration, so an unauthenticated browser hit
    // immediately redirects to the AAD login.
    ingressExternal: true
    ingressTargetPort: 8080
    ingressTransport: 'http'
    ingressAllowInsecure: false
    workloadProfileName: 'Consumption'
    // UI uses Microsoft.Identity.Web (OIDC + MSAL) directly instead of
    // Container Apps Easy Auth. The AAD client secret is stashed as a
    // container app secret and surfaced to the app via the
    // AzureAd__ClientSecret env var so Microsoft.Identity.Web picks it up
    // from the standard config section.
    secrets: [
      {
        name: 'aad-client-secret'
        value: uiAppClientSecret
      }
    ]
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: managedIdentity.outputs.resourceId
      }
    ]
    containers: [
      {
        name: 'mcpregistry-ui'
        image: uiContainerImage
        resources: {
          cpu: '0.25'
          memory: '0.5Gi'
        }
        env: [
          {
            name: 'ASPNETCORE_ENVIRONMENT'
            value: aspnetEnvironment
          }
          {
            name: 'ApiBaseUrl'
            // API publishes at '<app>.<envDefaultDomain>' on the env's
            // public LB; UI-to-API calls resolve to the same public FQDN
            // but Container Apps routes them internally through envoy.
            value: 'https://${containerApp.outputs.fqdn}'
          }
          {
            name: 'AzureAd__TenantId'
            value: tenantId
          }
          {
            name: 'AzureAd__ClientId'
            value: uiAppClientId
          }
          {
            name: 'AzureAd__ClientSecret'
            secretRef: 'aad-client-secret'
          }
          {
            name: 'AzureAd__ApiAppClientId'
            value: apiAppClientId
          }
          {
            name: 'AzureAd__AdminGroupId'
            value: adminGroupId
          }
          {
            name: 'AzureAd__Instance'
            value: environment().authentication.loginEndpoint
          }
          {
            name: 'AzureAd__CallbackPath'
            value: '/signin-oidc'
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: managedIdentity.outputs.clientId
          }
          {
            name: 'DataProtection__BlobUri'
            value: 'https://${dataProtectionStorage.name}.blob.${environment().suffixes.storage}/${dataProtectionContainer.name}/keys.xml'
          }
        ]
      }
    ]
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 2
      rules: [
        {
          name: 'http-rule'
          http: {
            metadata: {
              concurrentRequests: '50'
            }
          }
        }
      ]
    }
  }
}

// Easy Auth on the API. Validates incoming bearer tokens against the
// API authentication is handled inside the app by Microsoft.Identity.Web
// (AddMicrosoftIdentityWebApi in Program.cs). Container Apps Easy Auth is
// NOT used on the API because its `allowedApplications` check evaluates
// the v1 `appid` claim, which is absent from v2 access tokens issued by
// the UI (the UI app reg has accessTokenAcceptedVersion=2). With Easy Auth
// enabled, every UI -> API call was rejected as 403 before reaching the
// ASP.NET Core pipeline. ASP.NET Core JwtBearer + authorization policies
// already validate audience/issuer/signature and enforce the admin group
// requirement, so the gateway layer is redundant.

// UI Easy Auth has been removed. Authentication is now handled inside the
// Blazor Server UI by Microsoft.Identity.Web (OIDC sign-in + MSAL token
// cache for downstream API calls). This avoids the Easy Auth token store
// which requires a blob storage SAS URL — incompatible with the tenant
// policy MCAPSGovDeployPolicies that forces allowSharedKeyAccess=false on
// every storage account in this tenant. See repo memory for details.

// Dev/jump VM (optional). Reachable only via Azure Bastion:
//   - No public IP on the NIC
//   - NSG locks RDP/3389 inbound source to the AzureBastionSubnet CIDR
//   - AADLoginForWindows extension + RBAC role assignment let `principalId`
//     sign in with their AAD identity through Bastion (no need to remember
//     the local admin password except for break-glass)
//   - Auto-shutdown schedule keeps cost negligible when idle
var devVmName = 'vm-dev-${take(uniqueString(resourceGroup().id, names.vnet), 6)}'

resource devVmNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (deployDevVm) {
  name: 'nsg-${devVmName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowBastionRdpInbound'
        properties: {
          priority: 300
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource devVmNic 'Microsoft.Network/networkInterfaces@2024-05-01' = if (deployDevVm) {
  name: 'nic-${devVmName}'
  location: location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: devVmNsg!.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: devSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource devVm 'Microsoft.Compute/virtualMachines@2024-07-01' = if (deployDevVm) {
  name: devVmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: devVmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${devVmName}'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 127
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: 'dev-vm'
      adminUsername: devVmAdminUsername
      adminPassword: devVmAdminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            rebootSetting: 'IfRequired'
          }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: devVmNic!.id
          properties: {
            deleteOption: 'Detach'
          }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource devVmAadLoginExt 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (deployDevVm) {
  parent: devVm
  name: 'AADLoginForWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

// Grant the deploying principal the right to AAD-login as administrator.
// Role: Virtual Machine Administrator Login (1c0163c0-47e6-4577-8991-ea5c82e286e4).
resource devVmAdminLoginRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployDevVm) {
  scope: devVm
  name: guid(devVm!.id, principalId, 'VirtualMachineAdministratorLogin')
  properties: {
    principalId: principalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')
  }
}

// DevTestLabs auto-shutdown schedule. Daily at devVmShutdownTime in
// devVmShutdownTimezone. No email notification (notificationSettings.status=Disabled).
resource devVmShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployDevVm) {
  name: 'shutdown-computevm-${devVmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: devVmShutdownTime
    }
    timeZoneId: devVmShutdownTimezone
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
    targetResourceId: devVm!.id
  }
}

output containerRegistryEndpoint string = containerRegistry.outputs.loginServer
output containerRegistryName string = containerRegistry.outputs.name
output sqlServerName string = sqlServer.outputs.name
output sqlDatabaseName string = names.sqlDatabase
output apiUrl string = 'https://${containerApp.outputs.fqdn}'
output uiUrl string = 'https://${containerAppUi.outputs.fqdn}'
output containerAppName string = containerApp.outputs.name
output containerAppUiName string = containerAppUi.outputs.name
output managedIdentityName string = managedIdentity.outputs.name
output managedIdentityClientId string = managedIdentity.outputs.clientId
output containerAppsEnvironmentName string = containerAppsEnv.outputs.name
output containerAppsEnvironmentDefaultDomain string = containerAppsEnv.outputs.defaultDomain
output containerAppsEnvironmentStaticIp string = containerAppsEnv.outputs.staticIp
output devVmName string = deployDevVm ? devVm!.name : ''
output devVmPrivateIp string = deployDevVm ? devVmNic!.properties.ipConfigurations[0].properties.privateIPAddress : ''
