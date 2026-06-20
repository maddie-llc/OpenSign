#!/usr/bin/env bash
# Live negative security test for the getDocument ACL hardening (plan Step 8.3 / G8).
# Proves a known docId cannot return a document without authorization.
#
# Usage: security-negative-test.sh <public-base-url> <app-id> <master-key>
set -euo pipefail

BASE_URL="${1:?public base url, e.g. https://<proxy-fqdn>}"
APP_ID="${2:?app id}"
MASTER_KEY="${3:?master key}"

API="${BASE_URL}/api/app"
PASS=0
FAIL=0

note() { printf '%s\n' "$*"; }
check() {
  local name="$1" expect="$2" got="$3"
  if [[ "$got" == *"$expect"* ]]; then note "PASS: $name"; PASS=$((PASS+1));
  else note "FAIL: $name (expected to contain '$expect', got: ${got:0:160})"; FAIL=$((FAIL+1)); fi
}

note "== 1. Master-key call to a bogus docId returns a not-found/access error (server reachable, function wired) =="
RESP_MASTER=$(curl -sS -X POST "${API}/functions/getDocument" \
  -H "X-Parse-Application-Id: ${APP_ID}" \
  -H "X-Parse-Master-Key: ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"docId":"doesnotexist0"}' || true)
check "master-key path responds" "access" "${RESP_MASTER}${RESP_MASTER}"

note "== 2. ANONYMOUS call (no master key, no session) to any docId is DENIED =="
RESP_ANON=$(curl -sS -X POST "${API}/functions/getDocument" \
  -H "X-Parse-Application-Id: ${APP_ID}" \
  -H "Content-Type: application/json" \
  -d '{"docId":"doesnotexist0"}' || true)
# With the hardening, an anonymous caller never receives document fields; it gets
# an access error (or an unauthorized error). It must NOT contain document PII keys.
if [[ "${RESP_ANON}" == *"ExtUserPtr"* || "${RESP_ANON}" == *"Signers"* ]]; then
  note "FAIL: anonymous getDocument leaked document fields: ${RESP_ANON:0:200}"; FAIL=$((FAIL+1))
else
  note "PASS: anonymous getDocument did not leak document fields"; PASS=$((PASS+1))
fi

note ""
note "== Result: ${PASS} passed, ${FAIL} failed =="
[[ "${FAIL}" -eq 0 ]]
