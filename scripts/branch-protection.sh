#!/usr/bin/env bash
#
# Apply branch protection to main and test on github.com/ezmesh/ezos.
#
# Linear history: blocks merge commits, so the squash-merge commit subject
# (which we validate via PR Checks) is what actually lands on the branch.
#
# We deliberately do NOT enforce required_status_checks here. The classic
# branch-protection endpoint applies status-check requirements to ALL
# pushes (including the GITHUB_TOKEN-authenticated push from the auto-
# release workflow), and the GITHUB_TOKEN can't bypass them. The cleaner
# fix would be migrating to branch rulesets with a bypass actor, or
# provisioning a PAT secret with admin rights. For now we leave the gate
# advisory: the PR Checks workflow still runs on every PR and renders
# pass/fail on the PR page, but doesn't block the merge button via
# branch protection. Functionally, "read the status, then click merge"
# is the gate, which is acceptable for the current solo workflow.
#
# Run once. Re-running is idempotent.
#
# Requires: gh auth login (admin on the repo).

set -euo pipefail

REPO=ezmesh/ezos

# JSON body for the protection PUT call. Notes on each field:
# - required_status_checks=null: don't enforce checks at the protection
#   layer (would block the auto-release workflow's git push). Checks
#   still run on PRs and surface in the UI.
# - required_pull_request_reviews=null: don't require reviewers (solo dev)
# - required_linear_history=true: rejects merge commits, forces squash/rebase
# - allow_force_pushes=false / allow_deletions=false: standard
# - enforce_admins=false: lets you override in emergencies
PAYLOAD='{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}'

apply() {
    local branch=$1
    echo "Applying protection to ${branch}..."
    printf '%s\n' "$PAYLOAD" | gh api \
        --method PUT \
        -H "Accept: application/vnd.github+json" \
        "repos/${REPO}/branches/${branch}/protection" \
        --input -
    echo "  ${branch}: protected."
}

apply main
apply test
echo "Done. Verify in https://github.com/${REPO}/settings/branches"
