metadata description = 'OpenSign rehearsal entry (resource-group scoped). Orchestrates naming + data layer. The compute layer is deployed separately by deploy.sh after the Mongo URI and storage key are resolved.'

@description('4-letter customer slug.')
param slug string = 'loka'

@description('Project key.')
param projectKey string = 'esign'

@description('Deployment environment (dev | prod).')
@allowed([ 'dev', 'prod' ])
param environment string

@description('Azure region (verified live-sub convention = eastus).')
param location string = 'eastus'

@description('Mongo admin username.')
param mongoAdminUser string

@description('Mongo admin password.')
@secure()
param mongoAdminPassword string

@description('Cosmos vCore compute tier.')
param mongoTier string = 'Free'

@description('High availability mode (prod).')
param mongoHaEnabled bool = false

@description('Mongo storage GiB.')
param mongoStorageGib int = 32

@description('Azure Files share quota GiB.')
param fileShareQuotaGib int = 100

@description('Storage SKU.')
param storageSku string = 'Standard_ZRS'

@description('Storage kind.')
param storageKind string = 'StorageV2'

module naming 'modules/naming.bicep' = {
  params: {
    slug: slug
    projectKey: projectKey
    environment: environment
    uniqueSuffix: take(uniqueString(resourceGroup().id), 6)
  }
}

module tags 'modules/tags.bicep' = {
  params: {
    environment: environment
  }
}

module data 'modules/data.bicep' = {
  params: {
    names: naming.outputs.names
    location: location
    tags: tags.outputs.tags
    mongoAdminUser: mongoAdminUser
    mongoAdminPassword: mongoAdminPassword
    mongoTier: mongoTier
    mongoStorageGib: mongoStorageGib
    mongoHaEnabled: mongoHaEnabled
    fileShareQuotaGib: fileShareQuotaGib
    storageSku: storageSku
    storageKind: storageKind
  }
}

output names object = naming.outputs.names
output tags object = tags.outputs.tags
output keyVaultName string = data.outputs.keyVaultName
output identityId string = data.outputs.identityId
output logAnalyticsCustomerId string = data.outputs.logAnalyticsCustomerId
output storageName string = data.outputs.storageName
output fileShareName string = data.outputs.fileShareName
output mongoHost string = data.outputs.mongoHost
