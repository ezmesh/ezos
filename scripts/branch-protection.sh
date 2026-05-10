#!/usr/bin/env bash
#
# Apply branch protection (rulesets) to main and test on
# github.com/ezmesh/ezos.
#
# What this enforces:
#   - All updates must come through a pull request (no direct pushes
#     from human accounts). PRs need 0 reviewers, so you can self-merge
#     -- the gate is just "go through a PR" -- but the merge button
#     still surfaces failed status checks for read-and-decide.
#   - Linear history (no merge commits land on the branch).
#   - No force-push, no deletion.
#
# Bypass:
#   The GitHub Actions runner identity isn't a queryable Integration
#   on the repo, so we can't add it via the rulesets API. After this
#   script runs, manually add "github-actions" as a bypass actor in
#   the GitHub UI for both rulesets (Settings -> Rules -> ezos-branch-
#   <branch> -> Bypass list -> Add bypass -> "GitHub Actions"). Without
#   it, the auto-release workflow's xtr-changelog --push will fail
#   with GH006.
#
# Why rulesets, not classic branch protection:
#   Classic protection's "required_status_checks" applies to *every*
#   push, and GITHUB_TOKEN can't bypass it -- so the auto-release
#   workflow gets rejected (GH006) when the gate is on. Rulesets
#   support per-actor bypass, which is exactly what we want.
#
#   Classic protection on these branches is removed in the same step
#   to avoid two competing layers of policy.
#
# Run once. Re-running replaces the existing rulesets idempotently
# (delete-then-create per branch).
#
# Requires: gh auth login (admin on the repo).

set -euo pipefail

REPO=ezmesh/ezos

remove_classic_protection() {
    local branch=$1
    if gh api -X DELETE "repos/${REPO}/branches/${branch}/protection" 2>/dev/null; then
        echo "  ${branch}: classic branch protection removed"
    else
        echo "  ${branch}: no classic branch protection (skipping)"
    fi
}

remove_existing_rulesets() {
    # List existing repo rulesets and delete any that target this script's
    # naming convention. Without this, re-running this script accumulates
    # stale ruleset entries.
    gh api "repos/${REPO}/rulesets" --jq '.[] | select(.name | startswith("ezos-branch-")) | .id' \
        | while read -r id; do
            if [ -n "$id" ]; then
                gh api -X DELETE "repos/${REPO}/rulesets/$id" >/dev/null
                echo "  deleted existing ruleset $id"
            fi
        done
}

create_ruleset() {
    local branch=$1
    local payload
    payload=$(cat <<EOF
{
  "name": "ezos-branch-${branch}",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/${branch}"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash", "rebase"]
      }
    }
  ]
}
EOF
)
    echo "Creating ruleset for ${branch}..."
    local resp
    resp=$(printf '%s\n' "$payload" \
        | gh api --method POST -H "Accept: application/vnd.github+json" \
            "repos/${REPO}/rulesets" --input - 2>&1) || {
        echo "  ${branch}: failed"
        echo "$resp" | head -3
        return 1
    }
    echo "  ${branch}: ruleset $(echo "$resp" | jq -r .id) created"
}

echo "Removing classic branch protection..."
remove_classic_protection main
remove_classic_protection test

echo "Removing any existing ezos-branch-* rulesets..."
remove_existing_rulesets

echo "Creating new rulesets..."
create_ruleset main
create_ruleset test

echo "Done. Verify in https://github.com/${REPO}/settings/rules"
