#!/usr/bin/env bash
# LoKation OpenSign security gate.
#
# Fast, deploy-free checks that MUST pass before any production deployment.
# Wired as the `security-gate` job in .github/workflows/lokation-esign.yml, which
# deploy-prod depends on (needs: [security-gate]). Also part of the re-runnable
# validation harness invoked on every OpenSign upgrade.
#
# Exit non-zero on the first failing check (no silent pass).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
INFRA="${REPO_ROOT}/lokation/src/infra"
SERVER="${REPO_ROOT}/apps/OpenSignServer"
CLIENT="${REPO_ROOT}/apps/OpenSign"

fail() { echo "  [FAIL] $1" >&2; exit 1; }
pass() { echo "  [PASS] $1"; }

echo "==> LoKation OpenSign security gate"

# 1. All Bicep templates compile.
echo "-- Bicep compile"
for f in "${INFRA}/main.bicep" "${INFRA}"/modules/*.bicep; do
  az bicep build --file "${f}" --stdout >/dev/null 2>/tmp/bicep-err || { cat /tmp/bicep-err >&2; fail "bicep compile: ${f}"; }
done
az bicep build-params --file "${INFRA}/prod.bicepparam" --outfile /dev/null >/dev/null 2>&1 || fail "bicepparam compile: prod.bicepparam"
pass "all Bicep templates + prod params compile"

# 2. getDocument.js ACL hardening is intact (the OTP-bypass must NOT return early).
echo "-- getDocument ACL hardening"
GETDOC="${SERVER}/cloud/parsefunction/getDocument.js"
[[ -f "${GETDOC}" ]] || fail "missing ${GETDOC}"
# The original insecure early-return must be absent.
if grep -Eq 'if[[:space:]]*\([[:space:]]*!IsEnableOTP[[:space:]]*\)[[:space:]]*return' "${GETDOC}"; then
  fail "getDocument.js still contains the !IsEnableOTP early-return bypass"
fi
# Server-to-server master path must be present.
grep -q 'request.master === true' "${GETDOC}" || fail "getDocument.js missing master-key server path guard"
pass "getDocument.js enforces ACL/session unconditionally"

# 3. AGPL v3 section 13 source offer is present in the served footer.
echo "-- AGPL source offer"
grep -q 'agpl-source-offer' "${CLIENT}/src/components/Footer.jsx" || fail "AGPL section 13 source link missing from Footer.jsx"
pass "AGPL section 13 source offer present"

# 4. No secret literals committed in infra params.
echo "-- secret hygiene"
# A real connection string carries credentials (user:pass@host); the literal
# "mongodb+srv://..." placeholder in @description comments is allowed.
if grep -RInE 'mongodb(\+srv)?://[^[:space:]"'\'')]*@' "${INFRA}" --include='*.bicepparam' --include='*.bicep'; then
  fail "a literal MongoDB connection string with credentials is present in infra source"
fi
pass "no literal DB connection strings in infra source"

echo "==> Security gate PASSED"
