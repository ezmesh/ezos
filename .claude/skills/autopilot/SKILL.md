---
name: autopilot
description: Loop through eligible open GitHub issues, ship one PR per issue from a dedicated git worktree off `test`, and only stop on user interrupt, no eligible issues, or repeated hard failures. Use when the user says "keep shipping issues", "work the queue", "autopilot", or anything that asks Claude to make autonomous progress across the backlog.
---

# Goal

Ship one PR per eligible open issue, in a loop, without per-issue confirmation. Use git worktrees so each issue gets a clean isolated branch and the user's main checkout stays untouched.

The companion `/work-issue` skill is what runs *inside* the loop — re-read it for the per-issue conventions (conventional commits, `pio run` gate, PR against `test`, `Closes #N` line, on-device verification caveats).

# Boundaries

- **Don't ask between issues.** A clean PR-per-issue cadence is the point. Reserve `AskUserQuestion` for genuine blockers on a single issue.
- **When blocked, skip — don't stall.** Log the reason, skip, continue. Surface the skip list at the end.
- **Never merge.** PRs land for the user to review.
- **Never push to `main`** (this repo uses `test` as the integration branch — `main` is release-only). Never delete a worktree the user might be inspecting.
- **Hardware verification is the user's job in batch mode.** The agent can't reliably share `/dev/ttyACM0` with the user across many issues. Build cleanly with `pio run`; surface "needs hardware QA" in every PR's test plan.

# Setup (run once at start)

1. **Pre-flight in the main checkout:**
   ```
   git status                           # must be clean
   git rev-parse --abbrev-ref HEAD      # must be test
   git fetch origin test
   git pull --ff-only
   ```
   If the working tree is dirty or HEAD isn't `test`, stop and tell the user.

2. **Ensure `.worktrees/` is git-ignored:**
   ```
   grep -q '^\.worktrees/$' .gitignore || echo '.worktrees/' >> .gitignore
   ```
   If you added the line, commit it on `test` (`chore: ignore .worktrees/`) and push before starting the loop.

3. **List candidates:**
   ```
   gh issue list --state open --limit 100 \
     --json number,title,body,labels,assignees
   ```
   Filter out here (cheap):
   - Has any non-bot assignee.
   - Labels: `wontfix`, `duplicate`, `invalid`, `question`.
   - Body is empty or a one-line headline with no scope.

   The "is there already a PR?" check is **per-issue**, immediately before claiming the worktree (state changes during the run).

4. **Show the user the queue.** Numbered list, titles only, with the count. No confirmation needed; visibility only.

# Per-issue procedure

For each candidate `<N>` (ascending by issue number unless the user named another order):

0. **Re-check claimability** — right before the worktree, every time:
   - **Open + unassigned:**
     ```
     gh issue view <N> --json state,assignees
     ```
     Skip if `state != OPEN` or `assignees` contains a non-bot user.
   - **No claiming PR:**
     ```
     gh pr list --search "<N> in:body" --state all --limit 20 \
       --json number,state,headRefName,body | \
       jq --argjson n <N> '[.[] | select((.body // "") | test("(?i)(closes|fixes|resolves)\\s+#\($n)([^0-9]|$)"))]'
     ```
     Skip if non-empty.
   - **No claiming branch:**
     ```
     git ls-remote --heads origin "*/issue-<N>-*"
     ```
     Skip if anything comes back.

1. **Type prefix + slug.** Read the issue's title and body:
   - `<type>` from the title prefix if present (`feat(...)`, `fix(...)`, `docs:`), else infer (`bug` label → `fix`; `enhancement` → `feat`; doc-shaped issue → `docs`).
   - `<slug>` = 2-4 hyphenated words from the title.

2. **Worktree off `test`:**
   ```
   git worktree add .worktrees/issue-<N>-<slug> -b <type>/issue-<N>-<slug> origin/test
   ```
   If the branch already exists locally or remotely, skip (race; someone else picked it up).

3. **All subsequent commands run with cwd = `.worktrees/issue-<N>-<slug>`** (absolute path under that directory, or `cd` in compound commands).

4. **Run the work-issue flow non-interactively.** Same steps as `/work-issue` but without the surface-the-plan pause:
   - Read the issue body + comments.
   - Plan against CLAUDE.md silently.
   - Implement. Watch the recurring gotchas: no Ctrl/Esc keybindings, ASCII-only on default fonts, no `lua_State*` storage across calls, no `pio device monitor`, no public-channel sends.
   - `pio run` must pass clean before commit.
   - Conventional-commit message via heredoc (the `commit-msg` hook rejects anything else).
   - `git push -u origin <type>/issue-<N>-<slug>`.
   - `gh pr create --base test --title "<type>(<scope>): ..." --body "..."`. The body must contain `Closes #<N>` and a test plan with an explicit "needs hardware QA" checkbox un-checked (the loop doesn't flash).

5. **On hard failure for the issue:**
   - Don't commit junk; reset uncommitted state in the worktree.
   - Record `#<N>: skipped — <reason>` in the skip list.
   - Continue to the next issue.

6. **Return to the main checkout** before starting the next issue. Do **not** delete the worktree — the user may want to inspect or keep iterating on a PR. Worktrees pile up under `.worktrees/`; the user removes them with `git worktree remove .worktrees/issue-<N>-<slug>` when done.

# Stop conditions

End the loop and print the final report when **any** of these hits:

- No eligible issues left.
- User sends an interrupt or message — abandon the in-flight issue's *uncommitted* work, leave any opened PR alone, exit cleanly.
- **2 consecutive hard failures.** Two skips in a row signals something systemic (network, broken `test`, expired auth). Stop and tell the user.
- PRs opened ≥ 5 in one run. Soft cap to keep the user's review-and-flash queue manageable; mention it in the report and let them re-invoke if they want more.

# When to ask the user

Use `AskUserQuestion` **only** if all three are true:

- The issue is unworkable without a decision Claude can't make alone.
- A skip would lose information the user would want surfaced *now*, not at the end.
- The decision unblocks more than one issue (otherwise just skip + log).

Default behavior is **skip + log**, not **ask + wait**.

# Output

While running, after each issue: one line — `#<N>: opened PR #<M>` or `#<N>: skipped — <reason>`.

Final report (under 200 words):

- **Opened** — bullet per PR with issue number, PR number, title, branch.
- **Skipped** — bullet per issue with one-line reason.
- **Worktrees left behind** — paths under `.worktrees/`. Remind the user: `git worktree remove .worktrees/<dir>` when each PR is dealt with.
- **Reminder** — "Each PR needs hardware QA — `pio run -t upload` from the worktree and verify."
- **Next** — if the loop hit a soft cap or repeated failure, name the suspected cause; if it ran the queue dry, say so.

# Don't

- Don't run from a dirty checkout or a branch that isn't `test`.
- Don't merge PRs, don't force-push, don't delete worktrees.
- Don't pause between issues asking "should I continue?". The loop is the point.
- Don't open a PR with the `Closes #<N>` line missing.
- Don't `--no-verify` the commit-msg hook to slip a non-conforming message through.
- Don't claim hardware verification you didn't do — leave the QA checkbox un-checked.
