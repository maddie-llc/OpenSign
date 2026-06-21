# LoKation Sphere e-Sign: Architecture Overview

This document explains how LoKation will add in-portal PDF signing to Sphere by
self-hosting OpenSign on Azure. It is written for Sphere engineering and business
stakeholders. It describes the goals, the high-level design, how it fits the
existing Sphere platform, and the path to production.

## Goal

Replace the current third-party e-signature integration with a self-hosted
signing service built into the Sphere portal. Realtors sign and send documents
without leaving Sphere, and external parties (buyers, sellers, co-agents, title)
sign through a simple emailed link. This removes a recurring per-use third-party
cost and brings the signing experience under LoKation's brand and control.

## Why self-host OpenSign

- OpenSign is an open-source e-signature platform that LoKation can run on its own
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

## High-level architecture

```text
   Realtor browser                         External signer (guest)
        |                                          |
        v                                          v
   +-----------------------------------------------------------+
   |                     Sphere Web UI (React)                  |
   +-----------------------------------------------------------+
        |  /api/v1/esign                            ^
        v                                           | branded signing link + OTP
   +-----------------------------------------------------------+
   |             Sphere Backend (Spring Boot, Java)            |
   |   - esign service package (new)                          |
   |   - reuses existing EmailService for notifications       |
   +-----------------------------------------------------------+
        |  server-to-server API calls (master key kept here)
        v
   +-----------------------------------------------------------+
   |        OpenSign on Azure Container Apps (self-hosted)     |
   |                                                          |
   |   [ Caddy proxy ]  -- public HTTPS + custom domain       |
   |        |                                                  |
   |        +--> /api/* --> OpenSign server (Parse, internal)  |
   |        +--> /     --> OpenSign client (React, internal)   |
   |                                                          |
   |   Persistent file storage  |  Managed database  |  Secrets|
   |   (Azure Files)            |  (MongoDB)         |  (Key   |
   |                            |                    |   Vault)|
   +-----------------------------------------------------------+
```

### Components

- **Sphere Web UI:** adds a signing entry point that launches the branded
  OpenSign signing experience.
- **Sphere backend (`esign` package):** brokers all signing operations
  server-to-server — create document, send for signature, check status, download
  the signed PDF — and reuses the existing `EmailService` for branded
  notifications. The OpenSign administrative key never leaves the backend.
- **OpenSign on Azure Container Apps:** three coordinated containers behind a
  single hostname:
  - a proxy that routes traffic and terminates TLS,
  - the OpenSign server (the signing engine),
  - the OpenSign client (the signing UI), branded as LoKation Sphere.
- **Managed database:** stores documents, contacts, and audit records.
- **Azure Files:** persistent storage for the document PDFs.
- **Azure Key Vault:** holds all secrets; nothing sensitive is committed to code.

## How it fits the existing Sphere platform

- **Reuses Sphere services.** Signer notifications go through the existing
  `EmailService` rather than OpenSign's own email, keeping all messaging on the
  LoKation brand and infrastructure.
- **Follows existing integration patterns.** The new `esign` package mirrors how
  Sphere already integrates other external services (a service client plus a
  controller), so it is familiar to the Sphere team.
- **Same cloud and registry.** It runs in the existing Azure subscription and uses
  the existing container registry, aligning with current operations.

## Onboarding experience

- **Realtors:** provisioned automatically by Sphere on first use. There is no
  separate OpenSign sign-up screen and no second login — realtors stay within
  Sphere.
- **External signers:** receive a branded email link, verify with a one-time
  code, sign, and finish. No account, no password, minimal friction. This is the
  highest-volume path and is intentionally the simplest.

## Branding

OpenSign is themed to look and feel like LoKation Sphere across every screen a
realtor or signer sees, including the signing pages and the completion
certificate. Branding is applied as a thin, additive overlay (color theme plus
asset replacement) so the underlying OpenSign code stays easy to update as new
versions are released. Brand assets are bundled with the application so the
experience never depends on an external server being reachable.

## Security and confidentiality

Real estate documents are confidential, so access control is a first-class
requirement:

- Every document access requires proper authorization — a valid signed-in
  session, a per-realtor credential, or a short-lived secure link. There is no
  unauthenticated path to a document.
- A realtor can only access their own organization's documents; cross-account
  access is denied and verified by automated tests.
- The signing engine is reachable only through the public proxy; its
  administrative interfaces are kept internal.
- All secrets are stored in Azure Key Vault, and deployment uses short-lived
  cloud credentials rather than stored passwords.

These protections are validated before launch, and the production deployment is
blocked automatically until the document-access security tests pass.

## Ease of update (a core directive)

A key design principle is keeping OpenSign easy to update as the open-source
project releases new versions:

- LoKation-specific files are isolated in a dedicated `lokation/` folder so they
  do not collide with OpenSign's own files during updates.
- Branding and configuration are applied additively, minimizing changes to
  OpenSign's source.
- A documented update process keeps LoKation's security and branding changes in
  sync with upstream releases.

## Path to production

1. **Infrastructure:** provision the Azure environment as code (compute,
   database, storage, secrets, monitoring).
2. **Hosting:** deploy the three OpenSign containers and confirm the branded
   experience end to end.
3. **Sphere integration:** build the `esign` package, wire up the UI, and reuse
   `EmailService`.
4. **Security hardening:** enforce document access control and confirm with a
   negative-access test that becomes a hard gate on production deployment.
5. **Validation:** run functional, security, performance, and branding checks in
   a development environment before go-live.

## Open items for stakeholder decisions

- Public domain names for the signing experience (development and production).
- Brand-name approach (full LoKation branding vs. a "powered by" attribution).
- Confirmation to reuse the existing container registry and email service.
- Data retention and compliance ownership for in-house signer data.

## Related documents

- `licensing-and-legal.md` — licensing and legal considerations for this build.
