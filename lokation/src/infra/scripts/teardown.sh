#!/usr/bin/env bash
# Tear down the OpenSign deployment by deleting its resource group.
# Isolated by design: only touches rg-<slug>-<project>-<env>, never the shared Sphere resources.
set -euo pipefail

ENVIRONMENT="dev"
SLUG="loka"
PROJECT_KEY="esign"
YES="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --yes) YES="true"; shift ;;
    -h|--help) echo "Usage: teardown.sh --env <dev|prod> [--yes]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

RG="rg-${SLUG}-${PROJECT_KEY}-${ENVIRONMENT}"

if ! az group show --name "${RG}" --output none 2>/dev/null; then
  echo "Resource group ${RG} does not exist. Nothing to tear down."
  exit 0
fi

echo "About to DELETE resource group: ${RG} (and everything in it)."
if [[ "${YES}" != "true" ]]; then
  read -r -p "Type the resource group name to confirm: " CONFIRM
  [[ "${CONFIRM}" == "${RG}" ]] || { echo "Mismatch; aborting."; exit 1; }
fi

az group delete --name "${RG}" --yes --no-wait
echo "Deletion initiated for ${RG} (running in background)."
