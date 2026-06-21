// Production parameters for the OpenSign self-host data layer (Atlas via Azure Marketplace).
//
// DB path: MongoDB Atlas provisioned through the Azure Marketplace so the cluster is
// billed and regioned inside the LoKation subscription. The connection string is a
// SECRET and is NOT stored here — deploy.sh injects it at deploy time via:
//   az deployment group create --parameters prod.bicepparam --parameters atlasConnectionString=<uri>
// and the data layer persists it to Key Vault (secret: opensign-mongodb-uri), which the
// compute layer reads by reference. No secret literals live in source.
using 'main.bicep'

param environment = 'prod'
param location = 'eastus'
param slug = 'loka'
param projectKey = 'esign'

// Atlas is the supported production datastore (Cosmos vCore is incompatible with OpenSign).
param dbProvider = 'atlas'

// Premium file storage (zone-redundant) for the OpenSign signed-document share:
// low-latency SMB backing the Parse fs-files adapter. Premium_ZRS requires the
// FileStorage account kind.
param storageSku = 'Premium_ZRS'
param storageKind = 'FileStorage'
param fileShareQuotaGib = 100
