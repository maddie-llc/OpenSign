#!/usr/bin/env bash
# LoKation OpenSign validation harness — single re-runnable entry point.
#
# Purpose: give a green/red LoKation-integration verdict whenever OpenSign is
# upgraded. Run after pulling a new upstream release and re-applying the overlay.
#
# Usage:
#   validate.sh                 # static checks only (no deployment required)
#   validate.sh --live URL APPID MASTERKEY   # also run live checks against a deployment
#
# Static checks (always):
#   1. security-gate.sh        (bicep compile, getDocument ACL hardening, AGPL link, secret hygiene)
#   2. branding-applied        (theme + AGPL injected into the client tree)
#   3. upstream-merge-clean    (LoKation custom files have no conflict markers)
#   4. sphere-compile          (optional; only if the Sphere repo is present)
#
# Live checks (with --live):
#   5. security-negative-test  (anonymous/cross-realtor getDocument leaks nothing)
#   6. health                  (server /api/app/health reachable)
#
# Exit non-zero if any check fails (no silent pass).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLIENT="${REPO_ROOT}/apps/OpenSign"
SCRIPTS="${REPO_ROOT}/lokation/src/scripts"
INFRA_SCRIPTS="${REPO_ROOT}/lokation/src/infra/scripts"
SPHERE_DIR="${SPHERE_DIR:-/home/davesee/repos/e-sign/sphere}"

LIVE=false
LIVE_URL=""; LIVE_APPID=""; LIVE_MASTERKEY=""
if [[ "${1:-}" == "--live" ]]; then
  LIVE=true
  LIVE_URL="${2:?--live requires URL}"; LIVE_APPID="${3:?--live requires APPID}"; LIVE_MASTERKEY="${4:?--live requires MASTERKEY}"
fi

TOTAL=0; PASSED=0; FAILED=0
declare -a RESULTS

run_check() {
  local name="$1"; shift
  TOTAL=$((TOTAL+1))
  printf '\n=== [%d] %s ===\n' "${TOTAL}" "${name}"
  if "$@"; then
    PASSED=$((PASSED+1)); RESULTS+=("PASS  ${name}")
  else
    FAILED=$((FAILED+1)); RESULTS+=("FAIL  ${name}")
  fi
}

# --- static checks ---------------------------------------------------------

check_security_gate() {
  bash "${SCRIPTS}/validate/security-gate.sh"
}

check_branding_applied() {
  local ok=0
  grep -q 'lokation-theme.css' "${CLIENT}/src/index.jsx" || { echo "  theme import missing in index.jsx"; ok=1; }
  grep -q 'agpl-source-offer' "${CLIENT}/src/components/Footer.jsx" || { echo "  AGPL source offer missing in Footer.jsx"; ok=1; }
  test -f "${CLIENT}/src/styles/lokation-theme.css" || { echo "  lokation-theme.css not installed"; ok=1; }
  [[ "${ok}" -eq 0 ]] && echo "  branding overlay present"
  return "${ok}"
}

check_upstream_merge_clean() {
  # No unresolved git conflict markers in any LoKation-owned file.
  local hits
  hits=$(grep -RIl -E '^(<<<<<<<|=======|>>>>>>>)' "${REPO_ROOT}/lokation" 2>/dev/null || true)
  if [[ -n "${hits}" ]]; then
    echo "  conflict markers found in:"; echo "${hits}" | sed 's/^/    /'
    return 1
  fi
  echo "  no conflict markers in lokation/"
  return 0
}

check_sphere_compile() {
  if [[ ! -d "${SPHERE_DIR}" ]]; then
    echo "  SKIP: Sphere repo not found at ${SPHERE_DIR} (set SPHERE_DIR to enable)"
    return 0
  fi
  ( cd "${SPHERE_DIR}" && JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}" ./mvnw -q -DskipTests compile ) \
    && echo "  Sphere compiles" || { echo "  Sphere compile FAILED"; return 1; }
}

# --- live checks -----------------------------------------------------------

check_live_health() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' "${LIVE_URL}/api/app/health" || echo "000")
  echo "  health HTTP ${code}"
  [[ "${code}" == "200" ]]
}

check_live_security_negative() {
  bash "${INFRA_SCRIPTS}/security-negative-test.sh" "${LIVE_URL}" "${LIVE_APPID}" "${LIVE_MASTERKEY}"
}

# --- run -------------------------------------------------------------------

echo "==> LoKation OpenSign validation harness  (live=${LIVE})"

run_check "security gate (static security checks)" check_security_gate
run_check "branding overlay applied"               check_branding_applied
run_check "upstream merge clean (no conflicts)"    check_upstream_merge_clean
run_check "sphere compiles"                        check_sphere_compile

if [[ "${LIVE}" == "true" ]]; then
  run_check "live: server health"                  check_live_health
  run_check "live: getDocument ACL negative test"  check_live_security_negative
fi

echo ""
echo "================ VALIDATION SUMMARY ================"
for r in "${RESULTS[@]}"; do echo "  ${r}"; done
echo "---------------------------------------------------"
echo "  ${PASSED}/${TOTAL} passed, ${FAILED} failed"
echo "==================================================="

if [[ "${FAILED}" -eq 0 ]]; then
  echo "GREEN: LoKation integration validated."
  exit 0
else
  echo "RED: LoKation integration NOT validated — fix the failures above."
  exit 1
fi
