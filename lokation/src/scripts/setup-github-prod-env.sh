#!/usr/bin/env bash
# Configure the GitHub `production` environment protection for the OpenSign fork.
#
# The lokation-esign.yml workflow deploys to `environment: production`. This script
# adds the protection that makes a human approve every production deploy, even when
# the security-gate is green:
#   - required reviewer(s)
#   - deployments restricted to the LoKation branch
#
# PREREQUISITE: the gh token must have "Environments: read and write" on the repo.
#   Fine-grained PAT: Settings -> Developer settings -> Fine-grained tokens ->
#     (token) -> Repository permissions -> Environments: Read and write.
#   Classic PAT: the `repo` scope is sufficient.
#
# Re-runnable: PUT is idempotent; the branch policy is created only if absent.
set -euo pipefail

REPO="${REPO:-maddie-llc/OpenSign}"
BRANCH="${BRANCH:-LoKation}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-$(gh api user --jq '.login')}"

REVIEWER_ID=$(gh api "users/${REVIEWER_LOGIN}" --jq '.id')
echo "==> Configuring ${REPO} environment 'production' (reviewer: ${REVIEWER_LOGIN} / ${REVIEWER_ID})"

gh api -X PUT "repos/${REPO}/environments/production" \
  -f wait_timer=0 \
  -F "reviewers[][type]=User" \
  -F "reviewers[][id]=${REVIEWER_ID}" \
  -F "deployment_branch_policy[protected_branches]=false" \
  -F "deployment_branch_policy[custom_branch_policies]=true" \
  --jq '"    env: " + .name + " (" + (.protection_rules|length|tostring) + " protection rules)"'

# Restrict deployments to the LoKation branch (idempotent).
EXISTING=$(gh api "repos/${REPO}/environments/production/deployment-branch-policies" --jq ".branch_policies[].name" 2>/dev/null || true)
if ! grep -qx "${BRANCH}" <<<"${EXISTING}"; then
  gh api -X POST "repos/${REPO}/environments/production/deployment-branch-policies" \
    -f "name=${BRANCH}" --jq '"    branch policy added: " + .name'
else
  echo "    = branch policy already present: ${BRANCH}"
fi

echo "==> Production environment protection configured."
