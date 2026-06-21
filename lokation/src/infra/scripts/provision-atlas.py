#!/usr/bin/env python3
"""Provision (idempotently) a MongoDB Atlas cluster via the Atlas Administration API.

Runs locally as part of deploy.sh (not inside an Azure deploymentScript — the ACI
image lacks curl and the deploymentScript lifecycle proved slow/fragile for this).
Creates or reuses project -> network access -> database user -> M-tier cluster,
waits for IDLE, and prints ONLY the mongodb+srv connection string to stdout so the
caller can capture it. All progress logging goes to stderr.

Required environment variables:
  ATLAS_PUBLIC_KEY, ATLAS_PRIVATE_KEY, ATLAS_ORG_ID, ATLAS_DB_PASSWORD
Optional:
  ATLAS_PROJECT_ID  (existing Azure-Marketplace-linked project; skips project create)
  ATLAS_PROJECT_NAME (default lokation-esign), ATLAS_CLUSTER_NAME (default esign-prod)
  ATLAS_INSTANCE_SIZE (default M10), ATLAS_REGION (default US_EAST_2)
  ATLAS_DB_NAME (default opensign), ATLAS_DB_USER (default opensign_app)
  ATLAS_NET_CIDR (default 0.0.0.0/0)
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://cloud.mongodb.com/api/atlas/v2"
ACCEPT = "application/vnd.atlas.2023-11-15+json"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def env(name, default=None, required=False):
    val = os.environ.get(name, default)
    if required and not val:
        log(f"ERROR: {name} is required")
        sys.exit(2)
    return val


def make_opener(pub, priv):
    mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    mgr.add_password(None, "https://cloud.mongodb.com", pub, priv)
    return urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(mgr))


def main():
    pub = env("ATLAS_PUBLIC_KEY", required=True)
    priv = env("ATLAS_PRIVATE_KEY", required=True)
    org = env("ATLAS_ORG_ID", required=True)
    pw = env("ATLAS_DB_PASSWORD", required=True)
    project_id = (env("ATLAS_PROJECT_ID", "") or "").strip()
    project_name = env("ATLAS_PROJECT_NAME", "lokation-esign")
    cluster = env("ATLAS_CLUSTER_NAME", "esign-prod")
    size = env("ATLAS_INSTANCE_SIZE", "M10")
    region = env("ATLAS_REGION", "US_EAST_2")
    db = env("ATLAS_DB_NAME", "opensign")
    user = env("ATLAS_DB_USER", "opensign_app")
    cidr = env("ATLAS_NET_CIDR", "0.0.0.0/0")

    opener = make_opener(pub, priv)

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

    if project_id:
        group = project_id
        log(f"==> using pre-linked project {group}")
    else:
        st, d = api("GET", f"/groups/byName/{project_name}")
        group = d.get("id") if st == 200 else None
        if not group:
            st, d = api("POST", "/groups", {"name": project_name, "orgId": org})
            if st >= 400:
                log(f"ERROR creating project: {json.dumps(d)[:300]}")
                sys.exit(1)
            group = d["id"]
            log(f"==> created project {group}")
        else:
            log(f"==> reusing project {group}")

    log("==> ensure network access")
    api("POST", f"/groups/{group}/accessList",
        [{"cidrBlock": cidr, "comment": "lokation-esign iac"}])

    log("==> ensure database user")
    ub = {"databaseName": "admin", "username": user, "password": pw,
          "roles": [{"databaseName": db, "roleName": "readWrite"}]}
    st, _ = api("POST", f"/groups/{group}/databaseUsers", ub)
    if st >= 400:
        api("PATCH", f"/groups/{group}/databaseUsers/admin/{user}", {"password": pw})

    log(f"==> ensure cluster {cluster} ({size} @ {region})")
    st, _ = api("GET", f"/groups/{group}/clusters/{cluster}")
    if st != 200:
        body = {"name": cluster, "clusterType": "REPLICASET",
                "replicationSpecs": [{"regionConfigs": [{
                    "providerName": "AZURE", "regionName": region, "priority": 7,
                    "electableSpecs": {"instanceSize": size, "nodeCount": 3}}]}]}
        st, d = api("POST", f"/groups/{group}/clusters", body)
        if st >= 400:
            log(f"ERROR creating cluster: {json.dumps(d)[:300]}")
            sys.exit(1)
        log("    cluster create requested")

    srv = ""
    for i in range(80):
        st, d = api("GET", f"/groups/{group}/clusters/{cluster}")
        state = d.get("stateName", "?")
        log(f"    [{i}] state={state}")
        if state == "IDLE":
            srv = (d.get("connectionStrings") or {}).get("standardSrv", "")
            break
        time.sleep(30)
    if not srv:
        log("ERROR: cluster did not reach IDLE / no SRV string")
        sys.exit(1)

    host = srv[len("mongodb+srv://"):]
    eu = urllib.parse.quote(user, safe="")
    ep = urllib.parse.quote(pw, safe="")
    uri = (f"mongodb+srv://{eu}:{ep}@{host}/{db}"
           "?retryWrites=true&w=majority&authSource=admin")
    # Only the connection string goes to stdout.
    print(uri)


if __name__ == "__main__":
    main()
