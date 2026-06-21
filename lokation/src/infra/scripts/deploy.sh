#!/usr/bin/env bash
# Deploy the OpenSign self-host to Azure (staged: data layer -> resolve secrets -> compute layer).
# Default DB provider is MongoDB Atlas (Cosmos vCore is proven INCOMPATIBLE with OpenSign).
# Rehearsal-aware: generates throwaway secrets and is fully torn down by teardown.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "${SCRIPT_DIR}")"

ENVIRONMENT="dev"
LOCATION="eastus"
SLUG="loka"
PROJECT_KEY="esign"
DO_WHATIF="true"
DB_PROVIDER="${DB_PROVIDER:-atlas}"
ATLAS_CONNECTION_STRING="${ATLAS_CONNECTION_STRING:-}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
# atlas-managed inputs (provision the Atlas cluster as code)
ATLAS_PUBLIC_KEY="${ATLAS_PUBLIC_KEY:-}"
ATLAS_PRIVATE_KEY="${ATLAS_PRIVATE_KEY:-}"
ATLAS_ORG_ID="${ATLAS_ORG_ID:-}"
ATLAS_DB_PASSWORD="${ATLAS_DB_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)Aa1!}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER_EMAIL="${SMTP_USER_EMAIL:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER_EMAIL="${SMTP_USER_EMAIL:-}"
SMTP_PASS="${SMTP_PASS:-}"

usage() {
  cat <<USAGE
Usage: deploy.sh --env <dev|prod> [--location eastus] [--no-whatif]
Database provider (env DB_PROVIDER, default atlas):
  atlas        -> supply ATLAS_CONNECTION_STRING (mongodb+srv://...). RECOMMENDED.
  cosmos-vcore -> provisions Cosmos vCore (NOT compatible with OpenSign; experimentation only).
Secrets generated if not supplied via env: OPENSIGN_MASTER_KEY, MONGO_ADMIN_PASSWORD
Optional SMTP for OTP testing: SMTP_HOST, SMTP_PORT, SMTP_USER_EMAIL, SMTP_PASS
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --no-whatif) DO_WHATIF="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

RG="rg-${SLUG}-${PROJECT_KEY}-${ENVIRONMENT}"
MONGO_ADMIN_USER="osgnadmin"
MASTER_KEY="${OPENSIGN_MASTER_KEY:-$(openssl rand -hex 16)}"
MONGO_PWD="${MONGO_ADMIN_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)Aa1!}"

if [[ "${DB_PROVIDER}" == "atlas" && -z "${ATLAS_CONNECTION_STRING}" ]]; then
  echo "ERROR: DB_PROVIDER=atlas requires ATLAS_CONNECTION_STRING (mongodb+srv://...)." >&2
  exit 1
fi
if [[ "${DB_PROVIDER}" == "atlas-managed" ]]; then
  if [[ -z "${ATLAS_PUBLIC_KEY}" || -z "${ATLAS_PRIVATE_KEY}" || -z "${ATLAS_ORG_ID}" ]]; then
    echo "ERROR: DB_PROVIDER=atlas-managed requires ATLAS_PUBLIC_KEY, ATLAS_PRIVATE_KEY, ATLAS_ORG_ID." >&2
    exit 1
  fi
fi
if [[ "${DB_PROVIDER}" == "cosmos-vcore" ]]; then
  echo "WARNING: cosmos-vcore is NOT compatible with OpenSign (Parse Server boot creates a collation index vCore rejects). Use only for experimentation." >&2
fi

echo "==> Environment=${ENVIRONMENT}  RG=${RG}  Location=${LOCATION}  DB=${DB_PROVIDER}"

echo "==> Ensuring resource group"
az group create --name "${RG}" --location "${LOCATION}" --tags project=esign solution=opensign environment="${ENVIRONMENT}" managedBy=bicep --output none

DATA_PARAMS=(
  environment="${ENVIRONMENT}"
  location="${LOCATION}"
  slug="${SLUG}"
  projectKey="${PROJECT_KEY}"
  dbProvider="${DB_PROVIDER}"
  atlasConnectionString="${ATLAS_CONNECTION_STRING}"
  mongoAdminUser="${MONGO_ADMIN_USER}"
  mongoAdminPassword="${MONGO_PWD}"
  atlasOrgId="${ATLAS_ORG_ID}"
  atlasPublicKey="${ATLAS_PUBLIC_KEY}"
  atlasPrivateKey="${ATLAS_PRIVATE_KEY}"
  atlasDbPassword="${ATLAS_DB_PASSWORD}"
)

if [[ "${DO_WHATIF}" == "true" ]]; then
  echo "==> What-if (data layer)"
  az deployment group what-if --resource-group "${RG}" --template-file "${INFRA_DIR}/main.bicep" --parameters "${DATA_PARAMS[@]}" || true
fi

echo "==> Deploying data layer"
az deployment group create --resource-group "${RG}" --name "osgn-data-${ENVIRONMENT}" \
  --template-file "${INFRA_DIR}/main.bicep" --parameters "${DATA_PARAMS[@]}" --output none

echo "==> Reading data-layer outputs"
OUT=$(az deployment group show --resource-group "${RG}" --name "osgn-data-${ENVIRONMENT}" --query properties.outputs -o json)
NAMES=$(echo "${OUT}" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["names"]["value"]))')
STORAGE_NAME=$(echo "${OUT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["storageName"]["value"])')
FILE_SHARE=$(echo "${OUT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["fileShareName"]["value"])')
IDENTITY_ID=$(echo "${OUT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["identityId"]["value"])')
LA_CUSTOMER_ID=$(echo "${OUT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["logAnalyticsCustomerId"]["value"])')
MONGO_HOST=$(echo "${OUT}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["mongoHost"]["value"])')
LOG_NAME=$(echo "${NAMES}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["logAnalytics"])')

echo "==> Fetching Log Analytics shared key"
LA_KEY=$(az monitor log-analytics workspace get-shared-keys --resource-group "${RG}" --workspace-name "${LOG_NAME}" --query primarySharedKey -o tsv)

# Resolve the MongoDB connection URI for the compute layer.
if [[ "${DB_PROVIDER}" == "atlas" ]]; then
  MONGO_URI="${ATLAS_CONNECTION_STRING}"
elif [[ "${DB_PROVIDER}" == "atlas-managed" ]]; then
  # The Atlas deploymentScript (run during the data layer) wrote the connection
  # string into Key Vault. Read it back for the compute layer.
  KV_NAME=$(echo "${NAMES}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["keyVault"])')
  echo "==> Reading Atlas connection string from Key Vault ${KV_NAME}"
  MONGO_URI=$(az keyvault secret show --vault-name "${KV_NAME}" --name "opensign-mongodb-uri" --query value -o tsv)
  if [[ -z "${MONGO_URI}" ]]; then echo "ERROR: opensign-mongodb-uri not found in Key Vault (Atlas provisioning may have failed)." >&2; exit 1; fi
else
  # cosmos-vcore: assemble from the provisioned cluster host (experimentation only).
  MONGO_PWD_ENC=$(P="${MONGO_PWD}" python3 -c 'import urllib.parse,os;print(urllib.parse.quote(os.environ["P"],safe=""))')
  MONGO_URI="mongodb+srv://${MONGO_ADMIN_USER}:${MONGO_PWD_ENC}@${MONGO_HOST}/opensign?tls=true&authMechanism=SCRAM-SHA-256&retrywrites=false&maxIdleTimeMS=120000"
fi

COMPUTE_PARAMS=(
  names="${NAMES}"
  location="${LOCATION}"
  tags="{\"project\":\"esign\",\"solution\":\"opensign\",\"environment\":\"${ENVIRONMENT}\",\"costCenter\":\"lokation-esign\",\"managedBy\":\"bicep\"}"
  identityId="${IDENTITY_ID}"
  logAnalyticsCustomerId="${LA_CUSTOMER_ID}"
  logAnalyticsSharedKey="${LA_KEY}"
  storageName="${STORAGE_NAME}"
  fileShareName="${FILE_SHARE}"
  serverImage="docker.io/opensign/opensignserver:main"
  clientImage="docker.io/opensign/opensign:main"
  caddyImage="docker.io/library/caddy:2"
  appId="opensign"
  masterKey="${MASTER_KEY}"
  mongoUri="${MONGO_URI}"
  mongoMaxPoolSize="30"
  docx2pdfConcurrency="1"
  serverScale="{\"minReplicas\":1,\"maxReplicas\":3,\"cpu\":\"1.0\",\"memory\":\"2Gi\",\"concurrency\":40}"
  edgeScale="{\"minReplicas\":1,\"maxReplicas\":2,\"cpu\":\"0.5\",\"memory\":\"1Gi\",\"concurrency\":50}"
  smtpHost="${SMTP_HOST}"
  smtpPort="${SMTP_PORT}"
  smtpUserEmail="${SMTP_USER_EMAIL}"
  smtpPass="${SMTP_PASS}"
  customDomain="${CUSTOM_DOMAIN}"
)

echo "==> Deploying compute layer (ACA env + server/client/proxy)"
az deployment group create --resource-group "${RG}" --name "osgn-compute-${ENVIRONMENT}" \
  --template-file "${INFRA_DIR}/modules/compute.bicep" --parameters "${COMPUTE_PARAMS[@]}" --output none

PROXY_FQDN=$(az deployment group show --resource-group "${RG}" --name "osgn-compute-${ENVIRONMENT}" --query properties.outputs.proxyFqdn.value -o tsv)

echo ""
echo "==> Deployed."
echo "    Public URL : https://${PROXY_FQDN}"
echo "    DB         : ${DB_PROVIDER}"
echo "    Master key : (generated; stored only in the ACA secret)"
echo "    RG         : ${RG}  (tear down with lokation/src/infra/scripts/teardown.sh --env ${ENVIRONMENT})"

if [[ -n "${CUSTOM_DOMAIN}" ]]; then
  CNAME_TARGET=$(az deployment group show --resource-group "${RG}" --name "osgn-compute-${ENVIRONMENT}" --query properties.outputs.dnsCnameTarget.value -o tsv)
  ASUID_HOST=$(az deployment group show --resource-group "${RG}" --name "osgn-compute-${ENVIRONMENT}" --query properties.outputs.dnsAsuidHost.value -o tsv)
  ASUID_VALUE=$(az deployment group show --resource-group "${RG}" --name "osgn-compute-${ENVIRONMENT}" --query properties.outputs.dnsAsuidValue.value -o tsv)
  echo ""
  echo "==> Custom domain: ${CUSTOM_DOMAIN}"
  echo "    Create these DNS records, then re-run deploy.sh to issue the managed TLS cert:"
  echo "      CNAME  ${CUSTOM_DOMAIN}  ->  ${CNAME_TARGET}"
  echo "      TXT    ${ASUID_HOST}  ->  ${ASUID_VALUE}"
fi
