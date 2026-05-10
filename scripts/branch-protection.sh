#!/usr/bin/env bash
#
# Apply branch protection to main and test on github.com/ezmesh/ezos.
#
# Required status checks: the two jobs from .github/workflows/pr-checks.yml.
# Linear history: blocks merge commits coming in from PRs (squash/rebase
# only), so the merge commit subject lands as a Conventional Commit
# (matching the PR title we already validate).
#
# Run once after the PR-checks workflow has run on at least one PR (so
# GitHub knows the check names exist). Re-running is idempotent --
# branch protection is replace-only via this endpoint.
#
# Requires: gh auth login (admin on the repo).

set -euo pipefail

REPO=ezmesh/ezos
CHECKS=("Conventional Commits" "Version bump required")

# JSON body for the protection PUT call. Notes on each field:
# - required_status_checks.strict=true: PR must be up-to-date with base
# - required_pull_request_reviews=null: don't require reviewers (solo dev)
# - required_linear_history=true: rejects merge commits, forces squash/rebase
# - allow_force_pushes=false / allow_deletions=false: standard
# - enforce_admins=false: lets you override in emergencies
build_payload() {
    local checks_json
    checks_json=$(printf '%s\n' "${CHECKS[@]}" | jq -R . | jq -sc .)
    cat <<EOF
{
  "required_status_checks": {
    "strict": true,
    "contexts": ${checks_json}
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF
}

apply() {
    local branch=$1
    echo "Applying protection to ${branch}..."
    build_payload | gh api \
        --method PUT \
        -H "Accept: application/vnd.github+json" \
        "repos/${REPO}/branches/${branch}/protection" \
        --input -
    echo "  ${branch}: protected."
}

apply main
apply test
echo "Done. Verify in https://github.com/${REPO}/settings/branches"
