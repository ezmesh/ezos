---
name: autopilot
description: Loop through eligible open GitHub issues, ship one PR per issue in parallel by fanning out subagents that each work in a dedicated git worktree off `test`. Stop only on user interrupt, no eligible issues, the 5-issue batch cap, or a batch where every agent failed. Use when the user says "keep shipping issues", "work the queue", "autopilot", or anything that asks Claude to make autonomous progress across the backlog.
---

# Goal

Ship one PR per eligible open issue **in parallel**: spawn one subagent per issue, each working in its own dedicated git worktree off `test`. The orchestrator (this skill) does setup + claimability + worktree prep + spawning + reporting; the agents do the per-issue implementation. The user's main checkout stays untouched throughout.

The companion `/work-issue` skill is what each agent runs *inside* its worktree — re-read it for the per-issue conventions (conventional commits, `pio run` gate, PR against `test`, `Closes #N` line, on-device verification caveats).

# Boundaries

- **Don't ask between issues.** A clean parallel batch is the point. Reserve `AskUserQuestion` for genuine blockers that affect more than one issue.
- **When blocked, skip — don't stall.** Log the reason, drop from the batch, continue with the rest.
- **Never merge.** PRs land for the user to review.
- **Never push to `main`** (this repo uses `test` as the integration branch — `main` is release-only). Never delete a worktree the user might be inspecting.
- **Hardware verification is the user's job.** The agent can't reliably share `/dev/ttyACM0` with the user across many issues. Build cleanly with `pio run`; surface "needs hardware QA" in every PR's test plan.
- **Cap parallel batch at 5.** Beyond five, output volume and the user's review queue both balloon. If there are more eligible issues, name them in the report so the user can re-invoke.

# Setup (run once at start in the main checkout)

1. **Pre-flight in the main checkout:**
   ```
   git status                           # must be clean
   git rev-parse --abbrev-ref HEAD      # must be test
   git fetch origin test
   git pull --ff-only
   ```
   If the working tree is dirty or HEAD isn't `test`, stop and tell the user.

2. **Ensure `.worktrees/` is git-ignored.** Add it to `.gitignore` if missing. Direct push to `test` is blocked by branch protection in this repo, so if you added the line, open a small `chore: ignore .worktrees/` PR and continue — don't block the batch waiting for it to merge. The new worktrees are still valid even when their parent path shows untracked.

3. **List candidates:**
   ```
   gh issue list --state open --limit 100 \
     --json number,title,body,labels,assignees
   ```
   Filter out here (cheap):
   - Has any non-bot assignee.
   - Labels: `wontfix`, `duplicate`, `invalid`, `question`.
   - Body is empty or a one-line headline with no scope.
   - Obviously oversized (multi-screen rewrites, audits, multi-week tracks). Those need a focused single-issue session, not a parallel batch.

4. **Show the user the queue.** Numbered list, titles only, with the count. No confirmation needed; visibility only.

# Batch claim phase (orchestrator, before any spawn)

For each candidate `<N>` you intend to spawn an agent for, run the **claimability** sequence centrally. Two parallel agents must never race on the same issue — culling here is what guarantees that:

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

For each survivor, pre-compute:
- `<type>` from the title prefix if present (`feat(...)`, `fix(...)`, `docs:`), else infer (`bug` label → `fix`; `enhancement` → `feat`; doc-shaped issue → `docs`).
- `<slug>` = 2-4 hyphenated words from the title.
- Worktree path: `.worktrees/issue-<N>-<slug>`
- Branch name: `<type>/issue-<N>-<slug>`

Stop at the **first 5 survivors** — the soft cap. Record any further eligible issues so they land in the final report's "Next" section.

# Per-worktree prep (orchestrator, one-time before spawning)

For each survivor, run sequentially:

1. **Create the worktree:**
   ```
   git worktree add .worktrees/issue-<N>-<slug> -b <type>/issue-<N>-<slug> origin/test
   ```
   If this fails (race; branch already exists locally or remotely), drop the issue from the batch and record `#<N>: skipped — claim race`.

2. **Stage gitignored host tools that fresh worktrees lack.** `tools/bin/` is git-ignored, so `tools/bin/luac32` (the host-side Lua bytecode compiler the embedder needs) won't be in the new worktree even though it's in the main checkout. Copy it forward:
   ```
   mkdir -p .worktrees/issue-<N>-<slug>/tools/bin
   cp tools/bin/luac32 .worktrees/issue-<N>-<slug>/tools/bin/luac32
   ```
   Without this the agent's `pio run` will fail before it touches any code. If new gitignored host artefacts appear in future, add them here.

# Parallel agent spawn (the loop body)

Send a **single message** containing one `Agent` call per surviving issue, all with `subagent_type: general-purpose`, foreground (no `run_in_background`). Foreground in a single message means the runtime fans them out concurrently and you wait for the whole batch before the next turn. Do **not** loop calling `Agent` one at a time — that serialises the batch and defeats the purpose.

Each prompt is self-contained — the agent starts cold. Spell out the issue number, the absolute worktree path, the branch name, the work-issue conventions, and the guardrail to stay inside its worktree. Suggested per-agent prompt template (adapt verbatim — the agent doesn't see this skill file):

```
Work issue #<N> for the ezos repo.

Worktree: /home/bastiaan/Desktop/tdeck-os/.worktrees/issue-<N>-<slug>
Branch:   <type>/issue-<N>-<slug>   (already created off origin/test, tracking it)

ALL `git`, `pio`, `gh`, and file edits must run inside the worktree
path above. Never `cd` out of it. Never modify the main checkout.
Never modify any other worktree.

Issue context: read it yourself with `gh issue view <N>` and
`gh issue view <N> --comments`. Plan silently against CLAUDE.md (in
the worktree root) before implementing.

Per-issue conventions:
- Avoid the recurring gotchas: no Ctrl/Esc keybindings (T-Deck has
  no such keys), ASCII-only strings on default fonts, no
  `lua_State*` storage across calls, no `pio device monitor`,
  no public-channel mesh sends.
- `pio run` must pass clean before any commit. If it fails for a
  reason that isn't your code (missing host toolchain, broken
  test branch, etc.), do NOT commit -- report the reason and stop.
- Conventional Commit via HEREDOC (allowed types: feat, fix, build,
  chore, ci, docs, refactor, perf, test, style). The `commit-msg`
  hook enforces this -- do NOT pass `--no-verify`.
- Include the `Co-Authored-By: Claude Opus 4.7 (1M context)
  <noreply@anthropic.com>` trailer.
- `git push -u origin <type>/issue-<N>-<slug>`.
- `gh pr create --base test --title "<type>(<scope>): ..." --body
  "..."`. Body MUST contain `Closes #<N>` and a test-plan checklist
  with one un-checked "Needs hardware QA: flash and verify on
  T-Deck" item.

Do NOT merge the PR. Do NOT push to main. Do NOT delete the
worktree. If you can't complete the work for any reason, leave the
worktree in a clean state (no half-committed junk) and return
SKIPPED with the reason.

Return a short report (<150 words):
- First line: `OPENED #<M>` or `SKIPPED: <reason>`.
- Brief description of what you changed (or why you stopped).
- The branch name and PR URL on success.
```

When all agents return, parse each first line and build the final report.

# Stop conditions

End the run and print the final report when **any** of these hits:

- **No eligible issues** after the filter pass.
- **User interrupt** — abandon the batch. Agents currently inside a tool call will finish that call before returning, but you stop issuing new batches and don't spawn replacements. Any PRs already opened are left alone.
- **Batch cap reached** (5 agents). Single batch only — do not spawn a second batch in the same `/autopilot` run; the user re-invokes if they want more.
- **All agents in the batch returned SKIPPED.** Signals something systemic (network, broken `test`, expired auth, missing host toolchain). Stop and surface the suspected cause; don't retry.

# When to ask the user

Use `AskUserQuestion` **only** if all three are true:

- The blocker affects multiple issues in the batch (e.g. `test` won't build at all).
- A skip would lose information the user would want surfaced *now*, not at the end.
- The decision unblocks the rest of the batch.

Default behaviour inside agents is **skip + log**, not **ask + wait**.

# Output

Per-agent progress is invisible while the batch runs (one tool call per agent in flight). Once they all return, compile the final report (under 200 words):

- **Opened** — bullet per PR with issue number, PR number, title, branch.
- **Skipped** — bullet per issue with one-line reason.
- **Worktrees left behind** — paths under `.worktrees/`. Remind: `git worktree remove .worktrees/<dir>` once each PR is dealt with.
- **Reminder** — "Each PR needs hardware QA — `pio run -t upload` from the worktree and verify."
- **Next** — list any eligible issues that didn't make the 5-cap, so the user can re-invoke.

# Don't

- Don't run from a dirty checkout or a branch that isn't `test`.
- Don't fan out beyond 5 agents in a batch.
- Don't spawn a second batch in the same run.
- Don't issue Agent calls one at a time — a single message must contain all of them so the runtime fans them out.
- Don't have the orchestrator edit code, build, or open PRs itself. The whole point of the parallel layout is that each worktree gets exclusive focus from its own agent.
- Don't merge PRs, force-push, or delete worktrees.
- Don't open a PR with the `Closes #<N>` line missing.
- Don't `--no-verify` the commit-msg hook to slip a non-conforming message through.
- Don't claim hardware verification you didn't do — leave the QA checkbox un-checked.
