---
name: work-issue
description: Pick up a GitHub issue by number, branch off `test` with a conventional-commit prefix, implement following CLAUDE.md, build clean with `pio run`, and open a PR back to `test` that closes the issue. Use when the user says "work on issue N", "implement #N", "let's do #N", or similar.
---

# Goal

Take an issue number → ship a PR that closes it. Honor every convention in CLAUDE.md.

# Pre-flight

In the main checkout, before touching anything:

```
git status                          # must be clean
git fetch origin test
git rev-parse --abbrev-ref HEAD     # ideally `test`, otherwise warn
```

If the working tree is dirty or HEAD is unrelated, stop and ask the user. Don't auto-stash.

# Steps

1. **Fetch the issue.**
   ```
   gh issue view <N> --json number,title,body,labels,state,assignees,comments
   ```
   Stop if:
   - State is closed.
   - A PR already links to it (body contains `closes|fixes|resolves #<N>` — same search as `/next`).
   - The body is just a discussion / one-liner with no scope to implement against.

2. **Plan, then surface to the user.** Under 150 words:
   - The conventional-commit `<type>` (feat / fix / docs / refactor / chore / ...).
   - Scope (e.g. `audio`, `chat`, `desktop`) if applicable.
   - Files to touch — discover with grep/find, don't guess.
   - How you'll verify it works (build only? remote-tool screenshot? Lua exec via `tools/remote/ez_remote.py`?).
   - Skip this step only when the issue is unambiguous and ≤3 files of change.

3. **Branch.**
   ```
   git checkout -b <type>/issue-<N>-<slug> origin/test
   ```
   `<slug>` = 2-4 hyphenated words from the title.

4. **Implement.** CLAUDE.md is authoritative. The non-obvious gotchas:
   - **Keyboard:** no Ctrl, no Esc. Use `alt+letter` for shortcuts; `key.special == "BACKSPACE"` is the back signal. Don't bind to letter keys the user might want to type.
   - **Fonts:** built-in bitmap fonts are ASCII-only. Em-dashes, curly quotes, bullets, arrows render as `[]`. Use `--`, `...`, `->`, `*`.
   - **Chat-bubble actions:** behind the M-key context menu, not direct `on_press`.
   - **`lua_State*`:** never store the `L` argument across calls. Use `LUA_STATE` from `lua_runtime.h`.
   - **Embedded Lua:** scripts under `lua/` are embedded into firmware at build time. Editing them requires `pio run -t upload`, not `uploadfs`.
   - **Don't broadcast on `#Public`.** That channel is shared with real users.

5. **Verify.**
   - **Always:** `pio run` must succeed clean.
   - **When the change affects the on-device UI / audio / radio:** flash and probe with `tools/remote/ez_remote.py`. Take a screenshot or pull `--text` for a sanity check. Use `-e "..."` to run Lua snippets on-device.
   - **Don't use `pio device monitor` or `stty`** — they steal the serial port from the user's other tools. Use `ez_remote.py --logs` / `--monitor` instead.
   - If hardware isn't available (no `/dev/ttyACM0`), say so explicitly in the PR body's test plan rather than claiming success.

6. **Commit.** Conventional commits are enforced by a `commit-msg` hook. Format:
   ```
   <type>(<scope>): short description
   ```
   Imperative, sentence-case, ≤72 chars. Pass the message via heredoc.

7. **Push and open the PR vs `test`** (not `main`):
   ```bash
   git push -u origin <type>/issue-<N>-<slug>
   gh pr create --base test --title "<type>(<scope>): ..." --body "$(cat <<'EOF'
   ## Summary
   <one paragraph: what + why>

   ## Test plan
   - [x] `pio run` clean (RAM x%, flash y%)
   - [ ] Flashed to T-Deck Plus and verified — <briefly, or "user to QA on hardware">

   Closes #<N>
   EOF
   )"
   ```
   The `Closes #<N>` line is required for auto-close on merge. PR title must satisfy conventional-commits (the repo's pr-checks workflow rejects non-conforming titles).

8. **Report the PR URL** and stop.

# Stop and ask when

- The plan substantially expands the issue's scope.
- An architectural decision (new module, new service, new dep) is implied but not asked for.
- The on-device font / keyboard rules force a UX change the issue didn't anticipate.
- The change touches more than ~15 files.

# Don't

- Don't target `main`. PRs land on `test` first; promotion is a separate release commit.
- Don't merge the PR — that's the user's call.
- Don't `--no-verify` the commit hook. If the message is rejected, fix the message.
- Don't write a comment in code unless the WHY is non-obvious (CLAUDE.md).
- Don't claim hardware verification you didn't do. The PR body's test-plan checkboxes should reflect reality.
