#!/usr/bin/env bash
# One-time GitHub settings for this repository, via the GitHub CLI (`gh auth login` first):
#   nix develop ./box --command ./box/scripts/repo-setup.sh
# Needs admin rights on the repository. Safe to re-run.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
repo=$(repo_slug)
echo "Configuring $repo"

echo "==> Actions: enabled, all actions allowed, token read-only by default"
gh api -X PUT "repos/$repo/actions/permissions" -F enabled=true -f allowed_actions=all >/dev/null
gh api -X PUT "repos/$repo/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null
# (workflows that commit request contents: write explicitly)

echo "==> Secret scanning + push protection"
gh api -X PATCH "repos/$repo" --input - >/dev/null <<'JSON'
{"security_and_analysis": {
  "secret_scanning": {"status": "enabled"},
  "secret_scanning_push_protection": {"status": "enabled"}
}}
JSON

echo "==> Vulnerability alerts (GitHub Actions advisories)"
gh api -X PUT "repos/$repo/vulnerability-alerts" >/dev/null

echo "==> Starting the first runs"
for wf in update.yaml box.yaml installer.yaml; do
  gh api -X POST "repos/$repo/actions/workflows/$wf/dispatches" -f ref=main >/dev/null && echo "   $wf started"
done

cat <<TXT

Done. One step needs your browser (GitHub asks for confirmation):
  Install Renovate for $repo:  https://github.com/apps/renovate
It then keeps pinned GitHub Actions and the flake.lock files current. Lock files are
merged automatically; GitHub Actions updates wait for your review (main is root on the box).
TXT
