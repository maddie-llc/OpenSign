metadata description = 'Provisions a MongoDB Atlas cluster as code via the Atlas Administration API, wrapped in an Azure deploymentScript so it runs inside a single Bicep deployment. Creates (or reuses) an Atlas project under the given org, an M-tier cluster in an Azure region, a database user, and a network access entry, then writes the mongodb+srv connection string into Key Vault. There is no native ARM/Bicep resource for an Atlas cluster; this is the supported IaC path alongside the Atlas Terraform provider.'

@description('Azure region for the deploymentScript resource (not the Atlas region).')
param location string

@description('Standard tag set.')
param tags object

@description('User-assigned managed identity resource id. Must have Key Vault Secrets Officer on the target vault so the script can write the connection string.')
param identityId string

@description('Key Vault name that receives the connection string secret.')
param keyVaultName string

@description('Key Vault secret name for the OpenSign MongoDB URI.')
param secretName string = 'opensign-mongodb-uri'

@description('Atlas organization id (24-hex).')
param atlasOrgId string

@description('Existing Atlas project id (24-hex) to deploy the cluster into. When set (e.g. the Azure-Marketplace-linked project), the script uses it directly and does NOT create a new project, preserving the Azure billing link. Empty = resolve/create a project by name.')
param atlasProjectId string = ''

@description('Atlas project name (created if absent and atlasProjectId is empty).')
param atlasProjectName string = 'lokation-esign'

@description('Atlas cluster name.')
param atlasClusterName string = 'esign-prod'

@description('Atlas cluster tier (M10 minimum for a dedicated, production-safe cluster; M0/M2/M5 shared tiers do not support all features).')
param atlasInstanceSize string = 'M10'

@description('Atlas Azure region key, e.g. US_EAST_2 (maps to Azure eastus2) or US_EAST (eastus is not an Atlas Azure region; eastus2 is the closest).')
param atlasRegion string = 'US_EAST_2'

@description('Database name OpenSign connects to.')
param databaseName string = 'opensign'

@description('Atlas database username.')
param dbUsername string = 'opensign_app'

@description('Atlas database password.')
@secure()
param dbPassword string

@description('Atlas Admin API public key.')
@secure()
param atlasPublicKey string

@description('Atlas Admin API private key.')
@secure()
param atlasPrivateKey string

@description('CIDR allowed to reach the cluster. Default allows all (the cluster still requires SCRAM auth + TLS); tighten to your egress range when known.')
param networkAccessCidr string = '0.0.0.0/0'

@description('Force a new run of the provisioning script on each deployment.')
param forceUpdateTag string = utcNow()

resource atlasProvision 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'ds-atlas-${atlasClusterName}'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    azCliVersion: '2.61.0'
    retentionInterval: 'PT1H'
    timeout: 'PT45M'
    cleanupPreference: 'OnSuccess'
    forceUpdateTag: forceUpdateTag
    environmentVariables: [
      { name: 'ATLAS_PUB', secureValue: atlasPublicKey }
      { name: 'ATLAS_PRIV', secureValue: atlasPrivateKey }
      { name: 'ATLAS_ORG_ID', value: atlasOrgId }
      { name: 'PROJECT_ID', value: atlasProjectId }
      { name: 'PROJECT_NAME', value: atlasProjectName }
      { name: 'CLUSTER_NAME', value: atlasClusterName }
      { name: 'INSTANCE_SIZE', value: atlasInstanceSize }
      { name: 'ATLAS_REGION', value: atlasRegion }
      { name: 'DB_NAME', value: databaseName }
      { name: 'DB_USER', value: dbUsername }
      { name: 'DB_PASS', secureValue: dbPassword }
      { name: 'NET_CIDR', value: networkAccessCidr }
      { name: 'KV_NAME', value: keyVaultName }
      { name: 'SECRET_NAME', value: secretName }
    ]
    scriptContent: '''
set -euo pipefail
BASE="https://cloud.mongodb.com/api/atlas/v2"
ACCEPT="Accept: application/vnd.atlas.2023-11-15+json"
CT="Content-Type: application/json"
AUTH=(--digest -u "${ATLAS_PUB}:${ATLAS_PRIV}")

api() {
  # api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "${body}" ]; then
    curl -sS --fail-with-body "${AUTH[@]}" -X "${method}" "${BASE}${path}" -H "${ACCEPT}" -H "${CT}" -d "${body}"
  else
    curl -sS --fail-with-body "${AUTH[@]}" -X "${method}" "${BASE}${path}" -H "${ACCEPT}"
  fi
}

echo "==> Resolve or create project ${PROJECT_NAME} in org ${ATLAS_ORG_ID}"
if [ -n "${PROJECT_ID}" ]; then
  GROUP_ID="${PROJECT_ID}"
  echo "    using pre-linked project ${GROUP_ID}"
else
  GROUP_ID="$(api GET "/groups/byName/${PROJECT_NAME}" 2>/dev/null | jq -r '.id // empty' || true)"
  if [ -z "${GROUP_ID}" ]; then
    GROUP_ID="$(api POST "/groups" "{\"name\":\"${PROJECT_NAME}\",\"orgId\":\"${ATLAS_ORG_ID}\"}" | jq -r '.id')"
    echo "    created project ${GROUP_ID}"
  else
    echo "    reusing project ${GROUP_ID}"
  fi
fi

echo "==> Ensure network access ${NET_CIDR}"
api POST "/groups/${GROUP_ID}/accessList" "[{\"cidrBlock\":\"${NET_CIDR}\",\"comment\":\"lokation-esign iac\"}]" >/dev/null 2>&1 || true

echo "==> Ensure database user ${DB_USER}"
USER_BODY="{\"databaseName\":\"admin\",\"username\":\"${DB_USER}\",\"password\":\"${DB_PASS}\",\"roles\":[{\"databaseName\":\"${DB_NAME}\",\"roleName\":\"readWrite\"}]}"
if ! api POST "/groups/${GROUP_ID}/databaseUsers" "${USER_BODY}" >/dev/null 2>&1; then
  api PATCH "/groups/${GROUP_ID}/databaseUsers/admin/${DB_USER}" "{\"password\":\"${DB_PASS}\"}" >/dev/null 2>&1 || true
fi

echo "==> Ensure cluster ${CLUSTER_NAME} (${INSTANCE_SIZE} @ ${ATLAS_REGION})"
if ! api GET "/groups/${GROUP_ID}/clusters/${CLUSTER_NAME}" >/dev/null 2>&1; then
  CLUSTER_BODY="$(cat <<JSON
{
  "name": "${CLUSTER_NAME}",
  "clusterType": "REPLICASET",
  "replicationSpecs": [{
    "regionConfigs": [{
      "providerName": "AZURE",
      "regionName": "${ATLAS_REGION}",
      "priority": 7,
      "electableSpecs": { "instanceSize": "${INSTANCE_SIZE}", "nodeCount": 3 }
    }]
  }]
}
JSON
)"
  api POST "/groups/${GROUP_ID}/clusters" "${CLUSTER_BODY}" >/dev/null
  echo "    cluster create requested"
else
  echo "    cluster already exists"
fi

echo "==> Wait for cluster IDLE"
SRV=""
for i in $(seq 1 60); do
  RESP="$(api GET "/groups/${GROUP_ID}/clusters/${CLUSTER_NAME}")"
  STATE="$(echo "${RESP}" | jq -r '.stateName // empty')"
  echo "    [$i] state=${STATE}"
  if [ "${STATE}" = "IDLE" ]; then
    SRV="$(echo "${RESP}" | jq -r '.connectionStrings.standardSrv // empty')"
    break
  fi
  sleep 30
done
if [ -z "${SRV}" ]; then echo "ERROR: cluster did not reach IDLE / no SRV string"; exit 1; fi

# SRV looks like mongodb+srv://esign-prod.xxxx.mongodb.net ; inject credentials + db + opts.
HOSTPART="${SRV#mongodb+srv://}"
ENC_USER="$(printf '%s' "${DB_USER}" | jq -sRr @uri)"
ENC_PASS="$(printf '%s' "${DB_PASS}" | jq -sRr @uri)"
URI="mongodb+srv://${ENC_USER}:${ENC_PASS}@${HOSTPART}/${DB_NAME}?retryWrites=true&w=majority&authSource=admin"

echo "==> Write connection string to Key Vault ${KV_NAME}/${SECRET_NAME}"
az keyvault secret set --vault-name "${KV_NAME}" --name "${SECRET_NAME}" --value "${URI}" --output none

echo "{\"groupId\":\"${GROUP_ID}\",\"cluster\":\"${CLUSTER_NAME}\",\"secret\":\"${SECRET_NAME}\"}" > "${AZ_SCRIPTS_OUTPUT_PATH}"
echo "==> Atlas cluster provisioned and connection string stored."
'''
  }
}

output deploymentScriptName string = atlasProvision.name
output result object = atlasProvision.properties.outputs
