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

@description('MongoDB backend provider. atlas (recommended/default) vs cosmos-vcore (incompatible with OpenSign). The atlas connection string is supplied externally; for provision-as-code, deploy.sh creates the Atlas cluster first (provision-atlas.py) then passes the string here.')
@allowed([ 'atlas', 'cosmos-vcore' ])
param dbProvider string = 'atlas'

@description('MongoDB Atlas connection string (mongodb+srv://...). Required when dbProvider = atlas.')
@secure()
param atlasConnectionString string = ''

@description('Cosmos vCore admin username (only used when dbProvider = cosmos-vcore).')
param mongoAdminUser string = 'osgnadmin'

@description('Cosmos vCore admin password (only used when dbProvider = cosmos-vcore).')
@secure()
param mongoAdminPassword string = ''

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
    dbProvider: dbProvider
    atlasConnectionString: atlasConnectionString
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
