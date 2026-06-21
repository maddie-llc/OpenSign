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

# The AzureCLI deploymentScript image does not ship curl/jq, but python3 is
# always present. Do the Atlas Admin API work (HTTP digest auth) in Python and
# write the final connection string to a file so it never reaches the logs.
python3 - <<'PY'
import json, os, sys, time, urllib.parse, urllib.request

BASE = "https://cloud.mongodb.com/api/atlas/v2"
ACCEPT = "application/vnd.atlas.2023-11-15+json"
PUB = os.environ["ATLAS_PUB"]; PRIV = os.environ["ATLAS_PRIV"]

mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
mgr.add_password(None, "https://cloud.mongodb.com", PUB, PRIV)
opener = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(mgr))

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Accept", ACCEPT)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with opener.open(req, timeout=60) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw}

org = os.environ["ATLAS_ORG_ID"]
project_id = os.environ.get("PROJECT_ID", "").strip()
project_name = os.environ["PROJECT_NAME"]
cluster = os.environ["CLUSTER_NAME"]
size = os.environ["INSTANCE_SIZE"]; region = os.environ["ATLAS_REGION"]
db = os.environ["DB_NAME"]; user = os.environ["DB_USER"]; pw = os.environ["DB_PASS"]
cidr = os.environ["NET_CIDR"]

if project_id:
    group = project_id
    print(f"==> using pre-linked project {group}", flush=True)
else:
    st, d = api("GET", f"/groups/byName/{project_name}")
    group = d.get("id") if st == 200 else None
    if not group:
        st, d = api("POST", "/groups", {"name": project_name, "orgId": org})
        group = d["id"]
        print(f"==> created project {group}", flush=True)
    else:
        print(f"==> reusing project {group}", flush=True)

print("==> ensure network access", flush=True)
api("POST", f"/groups/{group}/accessList", [{"cidrBlock": cidr, "comment": "lokation-esign iac"}])

print("==> ensure database user", flush=True)
ub = {"databaseName": "admin", "username": user, "password": pw,
      "roles": [{"databaseName": db, "roleName": "readWrite"}]}
st, _ = api("POST", f"/groups/{group}/databaseUsers", ub)
if st >= 400:
    api("PATCH", f"/groups/{group}/databaseUsers/admin/{user}", {"password": pw})

print(f"==> ensure cluster {cluster} ({size} @ {region})", flush=True)
st, _ = api("GET", f"/groups/{group}/clusters/{cluster}")
if st != 200:
    body = {"name": cluster, "clusterType": "REPLICASET",
            "replicationSpecs": [{"regionConfigs": [{
                "providerName": "AZURE", "regionName": region, "priority": 7,
                "electableSpecs": {"instanceSize": size, "nodeCount": 3}}]}]}
    st, d = api("POST", f"/groups/{group}/clusters", body)
    if st >= 400:
        print("ERROR creating cluster:", json.dumps(d)[:300]); sys.exit(1)
    print("    cluster create requested", flush=True)

srv = ""
for i in range(60):
    st, d = api("GET", f"/groups/{group}/clusters/{cluster}")
    state = d.get("stateName", "?")
    print(f"    [{i}] state={state}", flush=True)
    if state == "IDLE":
        srv = (d.get("connectionStrings") or {}).get("standardSrv", "")
        break
    time.sleep(30)
if not srv:
    print("ERROR: cluster did not reach IDLE / no SRV"); sys.exit(1)

host = srv[len("mongodb+srv://"):]
eu = urllib.parse.quote(user, safe=""); ep = urllib.parse.quote(pw, safe="")
uri = f"mongodb+srv://{eu}:{ep}@{host}/{db}?retryWrites=true&w=majority&authSource=admin"
with open("/tmp/atlas_uri", "w") as f:
    f.write(uri)
with open("/tmp/atlas_meta", "w") as f:
    json.dump({"groupId": group, "cluster": cluster}, f)
print("==> cluster IDLE; connection string written", flush=True)
PY

URI="$(cat /tmp/atlas_uri)"


echo "==> Write connection string to Key Vault ${KV_NAME}/${SECRET_NAME}"
az keyvault secret set --vault-name "${KV_NAME}" --name "${SECRET_NAME}" --value "${URI}" --output none

cat /tmp/atlas_meta > "${AZ_SCRIPTS_OUTPUT_PATH}"
rm -f /tmp/atlas_uri
echo "==> Atlas cluster provisioned and connection string stored."
'''
  }
}

output deploymentScriptName string = atlasProvision.name
output result object = atlasProvision.properties.outputs
