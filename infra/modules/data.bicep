metadata description = 'OpenSign data layer: Log Analytics, App Insights, managed identity, Key Vault, storage + Azure Files share, and Cosmos DB for MongoDB vCore. Resource-group scoped.'

@description('Resource names from the naming module.')
param names object

@description('Azure region.')
param location string

@description('Standard tag set.')
param tags object

@description('Mongo admin username.')
param mongoAdminUser string

@description('Mongo admin password.')
@secure()
param mongoAdminPassword string

@description('Cosmos vCore compute tier (Free | M25 | M30 ...).')
param mongoTier string

@description('Mongo server version.')
param mongoServerVersion string = '7.0'

@description('Mongo storage GiB.')
param mongoStorageGib int

@description('High availability mode.')
param mongoHaEnabled bool

@description('Azure Files share quota GiB.')
param fileShareQuotaGib int

@description('Storage SKU, e.g. Standard_ZRS or Premium_ZRS.')
param storageSku string

@description('Storage kind, StorageV2 or FileStorage.')
param storageKind string

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.logAnalytics
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: names.appInsights
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.identity
  location: location
  tags: tags
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: names.keyVault
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// Key Vault Secrets User role for the managed identity.
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, identity.id, 'kv-secrets-user')
  scope: keyVault
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: names.storage
  location: location
  tags: tags
  sku: {
    name: storageSku
  }
  kind: storageKind
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  parent: storage
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: fileService
  name: 'opensign-files'
  properties: {
    shareQuota: fileShareQuotaGib
    enabledProtocols: 'SMB'
  }
}

resource mongo 'Microsoft.DocumentDB/mongoClusters@2024-07-01' = {
  name: names.mongo
  location: location
  tags: tags
  properties: {
    administrator: {
      userName: mongoAdminUser
      password: mongoAdminPassword
    }
    serverVersion: mongoServerVersion
    compute: {
      tier: mongoTier
    }
    storage: {
      sizeGb: mongoStorageGib
    }
    sharding: {
      shardCount: 1
    }
    highAvailability: {
      targetMode: mongoHaEnabled ? 'SameZone' : 'Disabled'
    }
    publicNetworkAccess: 'Enabled'
  }
}

// Rehearsal firewall rule: allow all (throwaway environment, torn down after validation).
resource mongoFirewallAll 'Microsoft.DocumentDB/mongoClusters/firewallRules@2024-07-01' = {
  parent: mongo
  name: 'allow-all-rehearsal'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

output logAnalyticsId string = logAnalytics.id
output logAnalyticsCustomerId string = logAnalytics.properties.customerId
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output identityId string = identity.id
output identityClientId string = identity.properties.clientId
output keyVaultName string = keyVault.name
output storageName string = storage.name
output fileShareName string = fileShare.name
output mongoName string = mongo.name
output mongoHost string = '${mongo.name}.global.mongocluster.cosmos.azure.com'
