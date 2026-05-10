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
# Bypass for the auto-release workflow:
#   The "GitHub Actions" identity does not appear in the bypass-actor
#   picker on the free org plan, so the runner can't be added to the
#   rulesets' bypass list directly. The auto-release workflow pushes
#   over SSH using a write-enabled deploy key (repo secret
#   RELEASE_PUSH_KEY, public half registered as deploy key
#   "auto-release-push") and we add a DeployKey bypass actor here so
#   the push lands. (Deploy keys do NOT bypass rulesets implicitly
#   on GitHub today; the `pull_request` rule fires on every push,
#   including SSH/deploy-key auth, unless an explicit DeployKey
#   bypass actor is in `bypass_actors`. The actor_type `DeployKey`
#   covers any deploy key registered on the repo, so a single entry
#   bypasses all of them -- there is no per-key id to set, and the
#   API returns `actor_id: null`.) See CLAUDE.md "Rolling OTA
#   updates" for the wiring.
#
# Why rulesets, not classic branch protection:
#   Classic protection's "required_status_checks" applies to *every*
#   push and GITHUB_TOKEN can't bypass it. Rulesets support per-actor
#   bypass (and deploy-key exemption), which is what we want.
#
#   Classic protection on these branches is removed in the same step
#   to avoid two competing layers of policy.
#
# Run once. Re-running is idempotent: it snapshots existing
# ezos-branch-* rulesets, creates fresh ones, drops classic
# protection, then prunes the snapshotted IDs (create-then-delete,
# so a creation failure leaves the existing protection intact).
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

list_stale_ruleset_ids() {
    # Print IDs of any existing ezos-branch-* rulesets, one per line.
    # Captured BEFORE creating the new ones so that a later cleanup pass
    # only removes the pre-existing entries, not the ones we just made.
    gh api "repos/${REPO}/rulesets" \
        --jq '.[] | select(.name | startswith("ezos-branch-")) | .id'
}

delete_ruleset_ids() {
    # Delete each ruleset ID passed on stdin. Safe to call with an empty
    # list; just logs nothing.
    while read -r id; do
        if [ -n "$id" ]; then
            gh api -X DELETE "repos/${REPO}/rulesets/$id" >/dev/null
            echo "  deleted stale ruleset $id"
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
  "bypass_actors": [
    { "actor_id": null, "actor_type": "DeployKey", "bypass_mode": "always" }
  ],
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

# Order matters: snapshot any pre-existing rulesets, then CREATE the
# new ones, then remove the old protection layers. With `set -euo
# pipefail`, a delete-then-create order would leave both branches
# fully unprotected (direct pushes, force-pushes, deletions all
# allowed) if create_ruleset failed mid-run. Create-then-delete keeps
# the existing protection in place if creation hits a transient API
# error, rate limit, or 422.
echo "Snapshotting any existing ezos-branch-* rulesets..."
STALE_IDS=$(list_stale_ruleset_ids)
if [ -n "$STALE_IDS" ]; then
    echo "  found $(echo "$STALE_IDS" | wc -l) stale ruleset(s) to remove after new ones are in place"
fi

echo "Creating new rulesets..."
create_ruleset main
create_ruleset test

echo "Removing classic branch protection..."
remove_classic_protection main
remove_classic_protection test

if [ -n "$STALE_IDS" ]; then
    echo "Removing snapshotted stale rulesets..."
    printf '%s\n' "$STALE_IDS" | delete_ruleset_ids
fi

echo "Done. Verify in https://github.com/${REPO}/settings/rules"
