#!/usr/bin/env bash
# Apply the LoKation Sphere branding overlay to the OpenSign client.
#
# Keeps the source of truth in lokation/ and copies the brand assets + theme into
# the OpenSign client tree at build/setup time, so OpenSign's own source stays
# essentially untouched and upstream updates merge cleanly. Re-run this after
# pulling a new OpenSign release.
#
# In-place OpenSign edits this relies on (kept minimal, see lokation/README.md):
#   - one import line in apps/OpenSign/src/index.jsx (added if missing)
#   - logo.png binary swap (no code change)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BRAND="${REPO_ROOT}/lokation/src/assets/brand"
THEME="${REPO_ROOT}/lokation/src/styles/lokation-theme.css"
CLIENT="${REPO_ROOT}/apps/OpenSign"
SERVER="${REPO_ROOT}/apps/OpenSignServer"

echo "==> Applying LoKation branding overlay"

# 1. Theme CSS into the client styles folder.
install -D "${THEME}" "${CLIENT}/src/styles/lokation-theme.css"

# 2. Brand font into the client public/fonts (referenced as /fonts/...).
install -D "${BRAND}/fonts/Axis_Extrabold.otf" "${CLIENT}/public/fonts/Axis_Extrabold.otf"

# 3. Logo asset replacement (data-driven appInfo.applogo -> no code edit).
cp "${BRAND}/lokation-wordmark-blue.png" "${CLIENT}/src/assets/images/logo.png"

# 4. Favicon / app icons.
cp "${BRAND}/lokation-icon-blue.png" "${CLIENT}/public/favicon.ico" 2>/dev/null || true
cp "${BRAND}/lokation-icon-blue.png" "${CLIENT}/public/logo192.png" 2>/dev/null || true
cp "${BRAND}/lokation-icon-blue.png" "${CLIENT}/public/logo512.png" 2>/dev/null || true

# 5. Certificate-of-completion logo on the server (guest-facing PDF).
if [[ -d "${SERVER}/images" ]]; then
  cp "${BRAND}/lokation-wordmark-blue.png" "${SERVER}/images/logo.png" 2>/dev/null || true
fi

# 6. Ensure the one-line theme import exists in the client entry.
ENTRY="${CLIENT}/src/index.jsx"
if ! grep -q "lokation-theme.css" "${ENTRY}"; then
  # Insert right after the existing index.css import to keep ordering stable.
  sed -i 's#import "./index.css";#import "./index.css";\nimport "./styles/lokation-theme.css";#' "${ENTRY}"
  echo "    + added lokation-theme.css import to index.jsx"
else
  echo "    = theme import already present in index.jsx"
fi

# 7. AGPL v3 section 13 network-use source offer in the served footer.
#    OpenSign is AGPL-3.0; users interacting over the network must be offered the
#    corresponding source. The public fork URL satisfies this. Injected here so it
#    survives upstream upgrades and is re-applied on every overlay run.
FOOTER="${CLIENT}/src/components/Footer.jsx"
SOURCE_URL="https://github.com/maddie-llc/OpenSign"
if [[ -f "${FOOTER}" ]]; then
  if ! grep -q "agpl-source-offer" "${FOOTER}"; then
    # Insert a source-offer paragraph immediately before the footer's </aside>.
    sed -i "s#</aside>#  <p className=\"agpl-source-offer text-[11px] opacity-70\">\n            <a href=\"${SOURCE_URL}\" target=\"_blank\" rel=\"noreferrer\" className=\"hover:underline\">Source code (AGPL v3 \&sect;13)</a>\n          </p>\n        </aside>#" "${FOOTER}"
    echo "    + added AGPL v3 section 13 source offer to Footer.jsx"
  else
    echo "    = AGPL source offer already present in Footer.jsx"
  fi
fi

echo "==> Branding overlay applied. Rebuild the client image to publish."
