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

@description('MongoDB backend provider. atlas (bring-your-own connection string) | atlas-managed (provision an Atlas cluster as code via the Atlas Admin API) | cosmos-vcore (incompatible with OpenSign).')
@allowed([ 'atlas', 'atlas-managed', 'cosmos-vcore' ])
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

// --- atlas-managed provider inputs (Atlas cluster provisioned as code) ---
@description('Atlas organization id (24-hex). Required when dbProvider = atlas-managed.')
param atlasOrgId string = ''

@description('Existing Atlas project id (the Azure-Marketplace-linked project) to deploy the cluster into. Empty = create a project by name.')
param atlasProjectId string = ''

@description('Atlas Admin API public key. Required when dbProvider = atlas-managed.')
@secure()
param atlasPublicKey string = ''

@description('Atlas Admin API private key. Required when dbProvider = atlas-managed.')
@secure()
param atlasPrivateKey string = ''

@description('Atlas database user password. Required when dbProvider = atlas-managed.')
@secure()
param atlasDbPassword string = ''

@description('Atlas cluster tier when dbProvider = atlas-managed (M10 = smallest dedicated).')
param atlasInstanceSize string = 'M10'

@description('Atlas Azure region key when dbProvider = atlas-managed (eastus2 = US_EAST_2).')
param atlasRegion string = 'US_EAST_2'

var useAtlasManaged bool = dbProvider == 'atlas-managed'

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

// Provision a MongoDB Atlas cluster as code and write its connection string into
// Key Vault. Runs only for dbProvider = atlas-managed. Depends on the data layer
// (Key Vault + identity + Secrets Officer role assignment).
module atlas 'modules/atlas-cluster.bicep' = if (useAtlasManaged) {
  params: {
    location: location
    tags: tags.outputs.tags
    identityId: data.outputs.identityId
    keyVaultName: data.outputs.keyVaultName
    atlasOrgId: atlasOrgId
    atlasProjectId: atlasProjectId
    atlasPublicKey: atlasPublicKey
    atlasPrivateKey: atlasPrivateKey
    dbPassword: atlasDbPassword
    atlasInstanceSize: atlasInstanceSize
    atlasRegion: atlasRegion
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
