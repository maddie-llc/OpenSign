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
- Branding: one theme-import line in `apps/OpenSign/src/index.jsx` plus logo
  binary swaps, all applied by `lokation/src/scripts/apply-branding.sh` from the
  source of truth under `lokation/src/`.

## Branding overlay (`src/assets/brand/`, `src/styles/`, `src/scripts/`)

LoKation Sphere look-and-feel is applied as a low-merge-conflict overlay sourced
from the official LoKation brand kit (extracted from `sphere-webui`):

- Palette: primary `#002A4E` (PANTONE 540C), secondary `#083E63`, grays
  `#222222`/`#4D4D4D`/`#8F8F8F`/`#D0D0D0`; brand font Axis Extrabold.
- `src/styles/lokation-theme.css` recolors the existing daisyUI theme names
  (`opensigncss` light / `opensigndark` dark) by overriding their CSS custom
  properties — no OpenSign component edits.
- `src/assets/brand/` holds the canonical logos, icon, and font (source of truth).
- `src/scripts/apply-branding.sh` copies the theme + assets into the OpenSign
  client and adds the single import line. Re-run after each OpenSign upgrade:

```bash
lokation/src/scripts/apply-branding.sh
```

Assets bundle same-origin (font under the client `public/fonts/`), so there is no
new runtime failure boundary. The "OpenSign" name/attribution is intentionally
retained (AGPL-friendly, public-code direction); branding is via logo + color.

