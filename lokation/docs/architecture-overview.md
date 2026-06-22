# LoKation Sphere e-Sign: Architecture Overview

This document explains how LoKation adds in-portal PDF signing to Sphere by
self-hosting OpenSign on Azure. It is written for Sphere engineering and business
stakeholders. It describes the goals, the deployed design, how it fits the
existing Sphere platform, and how to run the end-to-end realtor signature test.

The production service is **live** at **`https://esign.lokationagent.com`**.

## Goal

Replace the current third-party e-signature integration with a self-hosted
signing service built into the Sphere portal. Realtors sign and send documents
without leaving Sphere, and external parties (buyers, sellers, co-agents, title)
sign through a simple emailed link. This removes a recurring per-use third-party
cost and brings the signing experience under LoKation's brand and control.

## Why self-host OpenSign

- OpenSign is an open-source e-signature platform that LoKation runs on its own
  Azure infrastructure.
- Self-hosting keeps signing data inside LoKation's environment and removes
  per-transaction vendor fees.
- The platform is branded as part of Sphere so realtors and signers experience
  one cohesive product.

## Workload at a glance

| Dimension | Scale |
| --- | --- |
| Realtors (senders) | ~5,000+, across several states |
| Transactions | ~13,000 per year |
| Documents | ~5-10 per transaction (~100,000 per year) |
| Signers per document | Multiple (realtor + buyers/sellers/co-agents/title) |
| Most signers | External guests, no account required |

The expected concurrency is modest (tens of simultaneous signing sessions at
peak), so the design scales through configuration rather than re-architecture.

## High-level architecture (as deployed)

```text
   Realtor browser                         External signer (guest)
        |                                          |
        v                                          v
   +-----------------------------------------------------------+
   |                     Sphere Web UI (React)                  |
   |   /esign route -> EsignAPI -> redirect to signing URL     |
   +-----------------------------------------------------------+
        |  /api/v1/esign                            ^
        v                                           | branded signing link + OTP
   +-----------------------------------------------------------+
   |             Sphere Backend (Spring Boot, Java)            |
   |   - esign service package (OpenSignClient/EsignService)   |
   |   - realtor auto-provisioning (RealtorEsignAccount)       |
   |   - reuses existing EmailService for notifications        |
   +-----------------------------------------------------------+
        |  server-to-server API calls (master key kept here)
        v   https://esign.lokationagent.com/api/app
   +-----------------------------------------------------------+
   |   OpenSign on Azure Container Apps (rg-loka-esign-prod)   |
   |                                                          |
   |   [ Caddy proxy ]  -- public HTTPS + esign.lokationagent  |
   |        |              managed TLS cert (auto-renew)       |
   |        +--> /api/* --> OpenSign server (Parse, internal)  |
   |        +--> /     --> OpenSign client (React, internal)   |
   |                                                          |
   |   Azure Files (PDFs)  |  Key Vault (secrets)  | Log       |
   |                       |                       | Analytics |
   +-----------------------------------------------------------+
                                |
                                v   mongodb+srv (TLS)
                       +-------------------------+
                       |  MongoDB Atlas (M10)    |
                       |  on Azure (eastus2),    |
                       |  billed via Azure       |
                       |  Marketplace            |
                       +-------------------------+
```

### Components (deployed)

- **Sphere Web UI:** a `/esign` route lets a realtor enter a document title,
  signer, and PDF; it calls `EsignAPI`, then redirects the realtor into the
  branded OpenSign signing experience. The browser never holds OpenSign secrets.
- **Sphere backend (`esign` package):** brokers all signing operations
  server-to-server — create document, send for signature, check status, download
  the signed PDF — and reuses the existing `EmailService` for branded
  notifications. The OpenSign master key never leaves the backend. Realtors are
  auto-provisioned into a single shared OpenSign organization on first use, with
  the realtor → OpenSign mapping persisted in `RealtorEsignAccount`.
- **OpenSign on Azure Container Apps:** three coordinated container apps behind a
  single hostname in resource group `rg-loka-esign-prod` (region `eastus`):
  - **proxy** (`ca-loka-esign-proxy-prod`) — Caddy; public HTTPS, custom domain,
    terminates TLS, routes `/api/*` to the server and everything else to the
    client,
  - **server** (`ca-loka-esign-server-prod`) — the OpenSign Parse signing engine
    (internal ingress only),
  - **client** (`ca-loka-esign-client-prod`) — the OpenSign React UI, branded as
    LoKation Sphere (internal ingress only).
- **MongoDB Atlas (M10):** the production datastore, running on Azure infra
  (eastus2) and billed through the Azure Marketplace. OpenSign requires MongoDB;
  Azure Cosmos DB for MongoDB (vCore) is **not** compatible (its Parse boot
  migrations fail on a collation index), so Atlas is the supported backend.
- **Azure Files:** persistent storage for signed-document PDFs.
- **Azure Key Vault:** holds all secrets; nothing sensitive is committed to code.
- **Log Analytics + Application Insights:** centralized logs and telemetry.

### Why MongoDB Atlas (not a self-hosted replica set)

Atlas runs the cluster on Azure infrastructure in the LoKation subscription's
region and is billed through Azure, while remaining a supported, managed MongoDB.
Self-hosting a MongoDB replica set on Container Apps was rejected because
Container Apps only offers Azure Files (SMB) for persistent volumes, and
MongoDB/WiredTiger is not supported on SMB shares (a documented data-integrity
risk). The cluster is provisioned as code via the Atlas Administration API
(`lokation/src/infra/scripts/provision-atlas.py`, invoked by `deploy.sh`).

## How it fits the existing Sphere platform

- **Reuses Sphere services.** Signer notifications go through the existing
  `EmailService` rather than OpenSign's own email, keeping all messaging on the
  LoKation brand and infrastructure.
- **Follows existing integration patterns.** The new `esign` package mirrors how
  Sphere already integrates other external services (a service client plus a
  controller), so it is familiar to the Sphere team.
- **Same cloud.** It runs in the existing Azure subscription.

## Onboarding experience

- **Realtors:** provisioned automatically by Sphere on first use (the backend
  creates the OpenSign user with the master key and mints a per-realtor API
  token). There is no separate OpenSign sign-up screen and no second login.
- **External signers:** receive a branded email link, verify with a one-time
  code, sign, and finish. No account, no password, minimal friction.

## Branding

OpenSign is themed to look and feel like LoKation Sphere across every screen a
realtor or signer sees, including the signing pages and the completion
certificate. Branding is applied as a thin, additive overlay (color theme plus
asset replacement) by `lokation/src/scripts/apply-branding.sh`, so the underlying
OpenSign code stays easy to update as new versions are released. Brand assets are
bundled with the application so the experience never depends on an external
server being reachable.

## Security and confidentiality

Real estate documents are confidential, so access control is a first-class
requirement:

- Every document access requires proper authorization — a valid signed-in
  session, a per-realtor credential, or a short-lived secure link. The
  `getDocument` cloud function is hardened to enforce ACL/session checks
  unconditionally; there is no unauthenticated path to a document.
- A realtor can only access their own organization's documents; cross-account
  access is denied and verified by an automated negative-access test.
- The signing engine (server) is reachable only through the public proxy; its
  ingress is internal.
- All secrets are stored in Azure Key Vault; deployment authenticates with
  short-lived OIDC federated credentials rather than stored passwords.
- The production deployment is blocked automatically until the document-access
  security tests pass (CI security gate), and a human reviewer must approve the
  protected `production` GitHub environment before any prod deploy runs.

## License compliance (AGPL v3)

OpenSign is licensed under AGPL-3.0. Because realtors and signers interact with
it over the network, the served UI includes an AGPL §13 "source code" link in the
footer pointing to the public fork (`github.com/maddie-llc/OpenSign`). This link
is injected by the branding overlay so it survives OpenSign upgrades.

## Ease of update (a core directive)

OpenSign stays easy to update as the open-source project releases new versions:

- LoKation-specific files are isolated in a dedicated `lokation/` folder so they
  do not collide with OpenSign's own files during updates.
- Branding and configuration are applied additively, minimizing changes to
  OpenSign's source. The only in-place OpenSign edits are the `getDocument`
  security hardening and a one-line theme import (both documented in
  `lokation/README.md`).
- A re-runnable validation harness gives a green/red verdict after every upgrade
  (see below), so LoKation's security and branding changes can be confirmed in
  sync with upstream releases.

## Re-runnable validation harness

`lokation/src/scripts/validate/validate.sh` is the single entry point that
certifies a LoKation-ready build. Run it after pulling a new OpenSign release and
re-applying the branding overlay:

```bash
# Static checks only (no deployment needed)
bash lokation/src/scripts/validate/validate.sh

# Full check against a running deployment
bash lokation/src/scripts/validate/validate.sh --live \
  https://esign.lokationagent.com opensign "<MASTER_KEY>"
```

It validates: Bicep compiles, `getDocument` ACL hardening is intact, the AGPL §13
link is present, no secret literals are committed, the branding overlay is
applied, there are no merge conflicts in `lokation/`, the Sphere project compiles,
and (with `--live`) the server is healthy and the getDocument ACL negative test
passes. The CI security gate runs this harness; `deploy-prod` depends on it.

## Configuration for the Sphere backend

The Sphere backend reads four values (env vars → `application.properties`). None
are secrets in source; the master key comes from Key Vault / the ACA secret.

| `application.properties` key | Env var | Value |
| --- | --- | --- |
| `opensign.base-url` | `OPENSIGN_BASE_URL` | `https://esign.lokationagent.com/api/app` |
| `opensign.app-id` | `OPENSIGN_APP_ID` | `opensign` |
| `opensign.master-key` | `OPENSIGN_MASTER_KEY` | (from Key Vault — see below) |
| `opensign.organization-id` | `OPENSIGN_ORG_ID` | shared LoKation org id (see E2E setup) |

Retrieve the master key from the deployed ACA secret (do not commit it):

```bash
az containerapp secret show \
  --name ca-loka-esign-server-prod \
  --resource-group rg-loka-esign-prod \
  --secret-name master-key \
  --query value -o tsv
```

> Note on routing: the Caddy proxy strips the `/api` prefix and forwards to the
> OpenSign server, which is mounted at `/app` (`PARSE_MOUNT=/app`). So the Parse
> base URL the backend talks to is `https://esign.lokationagent.com/api/app`, and
> cloud functions are at `.../api/app/functions/<name>`.

## End-to-end realtor signature test (for Sphere engineers)

This is the procedure to confirm the full path once the Sphere backend update is
deployed with the configuration above.

### Prerequisites

1. **Backend config set:** the four `opensign.*` values above are present in the
   Sphere environment (master key sourced from Key Vault, never committed).
2. **Shared OpenSign organization (one-time):** set `OPENSIGN_ORG_ID` to the
   shared LoKation organization id. Obtain it once by signing in to the branded
   OpenSign admin UI at `https://esign.lokationagent.com` and creating the
   LoKation organization, then copy its id. (Until this is set, realtor
   auto-provisioning has no organization to attach users to.)
3. **A test realtor** with a `USER` authority and a reachable email address.
4. **SMTP for OTP (optional but recommended):** so the one-time code email
   reaches the external signer. Without SMTP, verify status via the API instead.

### Quick connectivity check (no Sphere required)

Confirm the service is reachable and healthy before involving the portal:

```bash
# Health (expect: {"status":"ok"})
curl -s https://esign.lokationagent.com/api/app/health

# Client UI (expect: HTTP 200)
curl -s -o /dev/null -w '%{http_code}\n' https://esign.lokationagent.com/
```

### Full E2E through Sphere

1. **Log in to Sphere** as the test realtor.
2. **Open the e-sign entry point** (`/esign` in the Sphere Web UI).
3. **Create a signature request:** enter a document title, add a signer
   (use a mailbox you control for the external signer), attach a small PDF, and
   submit. The Web UI calls `POST /api/v1/esign/documents`; on success the
   backend returns a `documentId`, then the UI fetches the signing URL via
   `GET /api/v1/esign/documents/{documentId}/signed-url` and redirects the
   realtor into the branded OpenSign signing experience.
4. **First-use provisioning:** on the realtor's first request the backend
   auto-creates their OpenSign user under the shared org and persists the mapping
   in `realtor_esign_account`. Confirm a row exists for the realtor
   (`enduserid`, `opensign_user_id`, `api_token`).
5. **Realtor signs** their portion in the branded UI.
6. **External signer:** open the branded email link, enter the one-time code,
   and complete signing.
7. **Check status from Sphere:** `GET /api/v1/esign/documents/{documentId}`
   should report the document progressing to completed.
8. **Download the signed PDF:** `GET /api/v1/esign/documents/{documentId}/signed-url`
   returns a URL to the completed, signed document.

### What "pass" looks like

- The realtor never sees an OpenSign login or signup screen.
- The signing UI is LoKation-branded (colors, logo, fonts) and the footer shows
  the AGPL §13 source link.
- The completed PDF downloads via the signed-url endpoint.
- A second signature request by the same realtor reuses the persisted mapping
  (no duplicate OpenSign user).

### Negative security check (expected to be denied)

Confirm an unauthenticated caller cannot read a document. This is also part of
the automated harness:

```bash
# Anonymous getDocument must NOT return document fields (expect an access error)
curl -s -X POST https://esign.lokationagent.com/api/app/functions/getDocument \
  -H "X-Parse-Application-Id: opensign" \
  -H "Content-Type: application/json" \
  -d '{"docId":"anyid"}'
```

## Operations reference

| Item | Value |
| --- | --- |
| Public URL | `https://esign.lokationagent.com` |
| Default ACA URL | `https://ca-loka-esign-proxy-prod.purpleriver-c7c2c851.eastus.azurecontainerapps.io` |
| Resource group | `rg-loka-esign-prod` (region `eastus`) |
| Container apps | `ca-loka-esign-{proxy,server,client}-prod` |
| Database | MongoDB Atlas M10 cluster `esign-prod` (Azure eastus2) |
| Deploy | `lokation/src/infra/scripts/deploy.sh --env prod` |
| Tear down | `lokation/src/infra/scripts/teardown.sh --env prod` |
| Validate | `lokation/src/scripts/validate/validate.sh [--live URL appId masterKey]` |

## Related documents

- `licensing-and-legal.md` — licensing and legal considerations for this build.
- `realtor-offboarding-plan.md` — realtor account lifecycle and offboarding.
- `../README.md` — overlay strategy and the OpenSign-upgrade process.
