# LoKation customizations overlay

This `lokation/` tree holds all LoKation-specific customizations to OpenSign,
isolated from OpenSign's own source so upstream version updates stay easy to
merge. When a new OpenSign release lands, the goal is that nothing here
conflicts.

## Layout

- `lokation/docs/` — architecture, licensing/legal, and offboarding docs for the
  LoKation + Sphere stakeholders.
- `lokation/src/infra/` — Azure infrastructure as code (Bicep) and deploy
  scripts. Self-contained; deploy with `lokation/src/infra/scripts/deploy.sh`.
- `lokation/src/assets/` — LoKation brand assets for the OpenSign theming overlay
  (logos/favicon to drop in when branding lands).

## Infrastructure (`src/infra/`)

- `main.bicep` — resource-group-scoped entry (naming + tags + data layer).
- `modules/` — `naming`, `tags`, `data` (Log Analytics, App Insights, identity,
  Key Vault, Storage + Azure Files, optional Cosmos vCore), `compute` (Container
  Apps environment + server/client/Caddy-proxy apps).
- `scripts/` — `deploy.sh` (staged: data → resolve secrets → compute),
  `teardown.sh` (deletes only the isolated resource group), and
  `security-negative-test.sh` (live `getDocument` ACL check).

### Database provider

Default is **MongoDB Atlas**. A live deploy proved **Cosmos DB for MongoDB vCore
is incompatible with OpenSign**: Parse Server's boot creates a case-insensitive
`username` index using a collation that vCore rejects
(`CommandNotSupported: createIndex.collation is not implemented yet`), so the
server crash-loops.

```bash
# Atlas (recommended)
DB_PROVIDER=atlas \
ATLAS_CONNECTION_STRING='mongodb+srv://user:pass@cluster.mongodb.net/opensign' \
  lokation/src/infra/scripts/deploy.sh --env dev

# Cosmos vCore (experimentation only — known incompatible)
DB_PROVIDER=cosmos-vcore lokation/src/infra/scripts/deploy.sh --env dev
```

Region is `eastus` (matches the live LoKation/Sphere workload).

## Unavoidable in-place edits (outside this folder)

A few customizations must edit OpenSign's own files because they hook into its
runtime; they cannot live under `lokation/`. Keep this list short and reviewed on
every upstream update:

- `apps/OpenSignServer/cloud/parsefunction/getDocument.js` — document-access ACL
  hardening (enforces the ACL/session check unconditionally; master-key
  server-to-server calls allowed). OpenSign loads this as a Parse cloud function
  from its own path.
- Branding hooks (when added): a 1–2 line theme import in the OpenSign client
  plus asset replacements; the bulk of branding stays additive under
  `lokation/src/assets/`.
