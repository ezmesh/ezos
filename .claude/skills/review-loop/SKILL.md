---
name: review-loop
description: Loop through open PRs assigned to (or authored by) the user, read the actionable review feedback on each, implement the concrete asks as new commits, and batch every ambiguous / judgment-needed item into a single set of questions at the end. Never force-pushes. Use when the user says "address my review feedback", "work my review queue", "fix my PR comments", or asks Claude to clear inbound review activity across their open PRs.
---

# Goal

For each open PR the user owns (assigned or authored) with actionable review feedback, push a NEW commit that addresses it — without per-PR confirmation. One worktree per PR, mirroring `/autopilot`. The companion to `/autopilot`: that skill opens PRs, this one iterates on them.

# Boundaries

- **PRs the user owns.** Either `assignee == @me` or `author == @me`. Don't touch a stranger's branch.
- **Never force-push.** Always add a NEW commit; never `--amend` pushed history; never `git push --force`/`--force-with-lease`.
- **Never push to `main`.** This repo's release lane is `test → main` via a release commit; PRs in flight live on feature branches.
- **Don't resolve review threads.** The reviewer marks them resolved when they re-review the new commit.
- **Don't implement vague feedback.** "This could be cleaner" / "what do you think" / "interesting" — queue for the user, don't act.
- **Default to skip-and-queue, not ask-and-wait.** The one exception is the after-loop batch (see "After the per-PR loop — questions for the user").

# Setup (run once at start)

1. **Pre-flight in the main checkout:**
   ```
   git status                          # must be clean
   git fetch origin
   ```
   If the working tree is dirty, stop and ask the user. Don't auto-stash.

2. **Ensure `.worktrees/` is git-ignored:**
   ```
   grep -q '^\.worktrees/$' .gitignore || echo '.worktrees/' >> .gitignore
   ```
   If you added the line, commit it on `test` (`chore: ignore .worktrees/`) before continuing.

3. **List candidate PRs:**
   ```
   gh pr list --state open --limit 50 \
     --search "assignee:@me OR author:@me" \
     --json number,title,headRefName,baseRefName,author,assignees,reviewDecision,isDraft,mergeable,mergeStateStatus
   ```
   Drop drafts. Drop PRs whose `headRefName` matches a branch the user is currently checked out on locally — they're mid-iteration and would clash with worktree creation.

4. **Per-candidate triage** — fetch the inputs that decide actionability:
   ```
   gh pr view <N> --json reviews,reviewRequests,comments,statusCheckRollup,headRefOid,mergeable,mergeStateStatus,baseRefName
   gh api repos/{owner}/{repo}/pulls/<N>/comments      # inline review comments
   gh api repos/{owner}/{repo}/pulls/<N>/files         # what the PR touches (to gauge feasibility)
   ```
   Mark a PR **actionable** if any of:

   - **CHANGES_REQUESTED** review whose `commit_id` predates the PR's current `headRefOid`, body containing imperative cues ("change", "rename", "remove", "add", "fix", "use", "switch to", "drop", "split", "merge").
   - **Inline review comment** with the same cues, not visibly addressed (thread unresolved, no commit after the comment's `created_at` touched the comment's `path`).
   - **Failed CI** (`statusCheckRollup` entry with `conclusion == FAILURE`), only if the failure log points to a deterministic fix: build error (`pio run` failure with a concrete file:line), Lua syntax error, doc-generator failure, conventional-commit hook rejection. Skip flaky / network failures (timeout, ECONNRESET, esp32 toolchain 503).
   - **Top-level PR comment** opening with an imperative ("please ...", "could you ...", "rename ...", "drop ...") authored after the PR's current `headRefOid` was pushed.
   - `mergeable == "CONFLICTING"` (equivalently `mergeStateStatus == "DIRTY"`). `UNKNOWN` is not a trigger on its own; the per-PR step will probe locally.

   If none hit, mark the PR **inactionable** (log `#<P>: skipped — no actionable feedback`).

5. **Show the user the queue.** Numbered list of actionable PRs with `#<P>: <title>` and a one-line cue per PR. Call out conflicts explicitly when present (`2 inline asks; CI build red; conflicts vs test`). No confirmation needed; visibility only.

# Per-PR procedure

For each actionable PR `<P>` (ascending by PR number, cap at 5):

0. **Re-check claimability.** State changes between triage and now (the user pushed a follow-up, the PR closed, a new review landed):
   ```
   gh pr view <P> --json state,headRefName,headRefOid,reviews,statusCheckRollup
   ```
   Skip if any of:
   - `state != OPEN`.
   - The `headRefOid` advanced since triage (the user or someone else pushed; their commit may already address the feedback).
   - The branch has commits on `origin` that aren't on the PR's recorded head.

1. **Worktree:**
   ```
   git fetch origin <head_ref>
   git worktree add .worktrees/pr-<P>-<slug> -B <head_ref> origin/<head_ref>
   ```
   `<slug>` = 2-4 hyphenated words from the PR title. If the path already exists, skip the PR (a previous run is still being inspected).

2. **All subsequent commands run with cwd = the worktree path.**

3. **Reconcile with `<base_ref>` (usually `test`).** Probe the merge before the punch list, so a conflicted PR is either resolved-and-pushed or queued cleanly:
   ```
   git fetch origin <base_ref>
   git merge --no-ff --no-commit origin/<base_ref>
   ```
   - **No conflicts (clean auto-merge):** finalize with `git commit --no-edit`, verify per step 7, push as a normal merge commit. This counts as an addressed item even if the rest of the punch list is empty.
   - **Already up to date:** `git merge --abort` (no-op) and continue.
   - **Conflicts surface:** capture conflicted paths from `git status --short` (`UU`/`AA`/`DD`/`AU`/`UA`/`DU`/`UD`). Try mechanical resolution per the rules below; if any rule applies and tests pass after, finalize the merge. Otherwise, `git merge --abort`, log `conflicts vs <base_ref> need user decision`, and add `{ pr, head_ref, base_ref, conflicted_paths, worktree }` to a **flagged-conflicts** list for the post-loop questions step. Do **not** half-resolve.

   ## Mechanical conflict-resolution rules (ezos-specific)

   **R1 — Release-generated changelog/version files only.**
   The `Test Branch Artifacts` workflow rewrites `CHANGELOG.md`, `changelog/versions.json`, `changelog/archive.json`, `lua/docs/changelog.json`, and the `custom_version = ...` line in `platformio.ini` on every push to `test`. PRs opened before that release commit will conflict on those paths even when no real code conflict exists.
   - **Detector:** the conflicted paths are a strict subset of:
     `{CHANGELOG.md, changelog/versions.json, changelog/archive.json, lua/docs/changelog.json, platformio.ini}`.
     **For `platformio.ini`, additionally verify** the conflict block only differs on the `custom_version =` line — if either side touched `lib_deps`, `build_flags`, or any other key, this rule does **not** apply (flag instead).
   - **Recipe:**
     1. `git checkout --theirs -- CHANGELOG.md changelog/versions.json changelog/archive.json lua/docs/changelog.json` for whichever of those are conflicted.
     2. For `platformio.ini`: take theirs for the `custom_version` line specifically (resolve the conflict marker by deleting our side's version line and keeping their side's), keeping any other PR-side edits to the file intact. Verify the resolved file has no remaining `<<<<<<<` markers.
     3. `git add` the resolved paths.

   No other patterns auto-resolve. Edits to generated source under `src/generated/` are gitignored and shouldn't be in the PR in the first place — if they are, that's a separate bug to surface.

4. **Read feedback in priority order**, building a punch list of concrete edits:
   1. CI failures — read the failing job's log, pin to file:line.
   2. Inline review comments — `path:line` is given; pair each ask with the file location.
   3. CHANGES_REQUESTED review bodies — usually summarise the inline comments; cross-reference and dedup.
   4. Top-level PR comments — only imperative ones; ignore discussion threads.

5. **Skip rules** (queue for the post-loop questions step, don't half-implement):
   - Vague feedback the punch list can't pin to a file edit.
   - Two reviewers asking for opposite things — the user needs to pick direction.
   - Architectural asks (add a new module, swap a framework, restructure tests) — not a review iteration; that's a fresh issue.
   - CLAUDE.md conflicts — flag and queue.

6. **Implement** the punch list. CLAUDE.md applies as always — the recurring traps on this repo:
   - No `Ctrl` / `Esc` keybindings (the T-Deck Plus keyboard has neither). Use `alt+letter`; treat `BACKSPACE` as the back signal.
   - ASCII-only on the default bitmap fonts. Em-dashes / curly quotes / bullets render as `[]`. Use `--`, `'`, `*`.
   - Chat-bubble actions live behind the M-key context menu, not direct `on_press`.
   - Never store `lua_State* L` from the function parameter across calls. Use `LUA_STATE` (`lua_runtime.h`).
   - Lua files under `lua/` are embedded into firmware at build time. Editing them requires `pio run -t upload`, not `uploadfs`.
   - Never send to `#Public` from tests; it's a shared real-user channel.

7. **Verify.** `pio run` must pass clean. After a step-3 merge, run it even if the punch list is empty — a clean text-level merge can still break the build. Hardware verification is **not** automated by this loop (single shared device); call out any hardware-sensitive change in the optional PR-reply comment so the user remembers to flash before merging.

8. **Commit.** Conventional commits enforced by `commit-msg` hook. Subject names what the review asked for — not "address feedback":
   ```
   fix(chat): rename render_bubble to draw_bubble per review
   ```
   Imperative, sentence-case, ≤72 chars. Heredoc through `git commit -m`.

9. **Push** (NEVER `--force` / `--force-with-lease`):
   ```
   git push origin <head_ref>
   ```
   If the push is rejected (non-fast-forward), the branch advanced under us — abandon this PR's commit, log the skip, continue.

10. **Optional reply.** Post one PR comment summarising what changed, referencing the addressed comments by `path:line`:
    ```
    gh pr comment <P> --body "..."
    ```
    Bullets per change, no rebuttal of feedback. Skip the comment if the punch list is one item — the commit message is enough. A bare merge commit doesn't need a reply.

11. **Return to the main checkout** before starting the next PR. Do not delete the worktree.

# After the per-PR loop — questions for the user

Once every PR in the queue has been visited (or the soft cap or stop conditions hit), batch-ask the queued questions before the final report. This is the explicit exception to "don't ask between PRs" — the inner loop refused to guess, and the user is the one to pick.

For each PR with queued questions:

1. **Show one short paragraph of context** — `#<P> <title>`, link, summary of what's ambiguous (e.g. "Reviewer A asks to rename `foo` → `bar`; Reviewer B says keep `foo`. Picking one direction.") Don't dump diffs; the user can open the worktree if they want detail.

2. **One `AskUserQuestion`** per PR, with options scoped to the queued items. Typical option shapes:

   **Disagreement between reviewers:**
   - Take A's direction *(recommended if A reviewed last / has more context)*.
   - Take B's direction.
   - Skip — I'll respond inline.

   **Vague-but-actionable feedback ("clean this up"):**
   - Pick a specific concrete change (e.g. "extract `foo()` into its own file").
   - Ask the reviewer for clarification (post a PR comment).
   - Skip.

   **Conflict the mechanical rules wouldn't touch:**
   - **Take ours** *(PR side wins)* — `git merge -X ours origin/<base_ref>`. Recommend when the PR's edits are authoritative.
   - **Take theirs** *(base side wins)* — `git merge -X theirs origin/<base_ref>`. Recommend when `test` already did what the PR was trying to do.
   - **Skip — I'll resolve manually.** Leaves the PR untouched.
   - **Other** — user types a directive (path-scoped checkout, file deletion, running a known script). Carry it out only if it lives within the existing skill rules (no force-push, no `--no-verify`, no rebase).

3. **Apply the answer in the PR's worktree** — same gates as the inner loop (pio run clean, conventional commit, no force-push, push rejected = abandon).

4. **One ask per PR, no auto-cascading.** Even if multiple PRs share an obviously identical question shape (e.g. five branches asking the same naming question), still ask once per PR. Cross-PR consequences are the judgment the user is being asked to make.

# Hard failure (per PR)

- Tests / build fail in a way the punch list doesn't explain: don't commit, don't push, log the skip with the concrete failure.
- Implementation requires architectural decisions outside the review scope: skip, queue, move on.
- Push rejected (non-fast-forward) after a clean local commit: do not force-push; record the skip with the divergence.
- `git merge origin/<base_ref>` reports conflicts: try R1, then `git merge --abort` and queue if no recipe matches. Tests not run; review edits not attempted (working tree state isn't trustworthy to edit on top of).

# Stop conditions

End the loop and print the final report when **any** of these hits:

- No actionable PRs left.
- User sends an interrupt or message — abandon in-flight *uncommitted* work, leave pushed commits alone, exit cleanly.
- **2 consecutive hard failures.** Signals something systemic (auth expired, CI down, branch protection changed). Stop and tell the user.
- PRs touched ≥ 5 in one run. Soft cap to keep the user's review-of-the-review-loop manageable.

# When to ask the user (during the inner loop)

Use `AskUserQuestion` mid-loop **only** if all three are true:

- The PR is unworkable without a decision Claude can't responsibly make alone.
- A queue-for-later would lose information the user would want surfaced *now*, not in the batch.
- The decision unblocks more than one PR.

Default behavior is **queue + log** for the post-loop batch, not **ask + wait**.

# Output

While running, after each PR: one line — `#<P>: pushed <sha>` (note `(merge)` when step 3 produced a commit, `(merge, -X ours|theirs)` when a post-loop strategy merge produced one) or `#<P>: skipped — <reason>` or `#<P>: queued for user — <reason>`.

Final report (under 200 words):

- **Pushed** — bullet per PR with number, title, the new commit's short SHA, one-line summary. Flag review-feedback commits, step-3 auto-merges, and post-loop strategy merges separately when more than one landed on a single PR.
- **Queued questions resolved** — what the user picked for each post-loop ask.
- **Outstanding** — PRs the user opted to handle manually, plus any "Other" directives the loop couldn't carry out. Echo conflicted paths / directive verbatim so the user can open the worktree and finish without re-deriving context.
- **Skipped** — PRs without actionable feedback or where the loop hit a hard failure; one line each.
- **Worktrees left behind** — paths under `.worktrees/`. Reminder: `git worktree remove .worktrees/<dir>`.
- **Hardware QA reminder** — list the pushed PRs that touched hardware-sensitive paths (audio, radio, display, keyboard, UI). The loop didn't flash anything.
- **Next** — if the loop hit the soft cap, name the suspected cause; if it ran the queue dry, say so.

# Don't

- Don't force-push, don't `--force-with-lease`, don't amend pushed history.
- Don't push to `main`.
- Don't resolve review threads or close other reviewers' reviews — humans mark conversations resolved.
- Don't implement vague feedback or pick a side when reviewers disagree — queue it for the post-loop ask.
- Don't `--no-verify` the commit hook to slip a non-conforming message past it.
- Don't squelch failing tests / builds with `--skip` / `xfail` to keep the loop moving.
- Don't auto-resolve conflicts outside R1. No blanket `-X ours` / `-X theirs`, no hand-edited markers in code files, no "looks additive enough" guessing — those belong in the post-loop `AskUserQuestion` batch.
- Don't extend the mechanical rule set on the fly. New rules need to be written into this skill (detector + recipe + test gate) before they're trusted in a run.
- Don't rebase a PR branch onto its base to "fix" conflicts. Rebase forces force-push, which the loop refuses.
- Don't claim hardware verification you didn't do — the loop never flashes a device.
