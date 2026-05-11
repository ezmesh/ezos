---
name: next
description: Survey open GitHub issues on the ezOS repo, recommend one concrete issue to work on next (with 2-3 runners-up), and offer to hand off to `/work-issue`. Use when the user says "what's next", "what should I work on", "pick something", or any other prioritisation question.
---

# Goal

Recommend ONE concrete issue. Don't dump raw command output — synthesise. Hand the user a decision they can make in five seconds.

# Signals to gather

Run in parallel:

1. **Open issues:**
   ```
   gh issue list --state open --limit 50 \
     --json number,title,body,labels,assignees,createdAt,comments
   ```

2. **Filter out** before scoring:
   - Has any non-bot assignee.
   - Has a linked open PR (search PR bodies for `closes|fixes|resolves #<N>`):
     ```
     gh pr list --state open --search "<N> in:body" --json number,body | \
       jq --argjson n <N> 'any(.[]; (.body // "") | test("(?i)(closes|fixes|resolves)\\s+#\($n)([^0-9]|$)"))'
     ```
   - Labels: `wontfix`, `duplicate`, `invalid`, `question`. Those need a decision, not implementation.

3. **Recent commits** — `git log --oneline -20` — so the recommendation builds on the current thread rather than context-switching.

# Prioritisation

Prefer issues that:
- Match the area the user just worked in (commits / labels overlap).
- Are well-scoped (clear acceptance criteria in the body, ≤3 days of work).
- Unblock other work (foundations, shared widgets, services touched by other open issues).
- Have `good first issue` if the user is onboarding someone.

Deprioritise:
- Long-running architecture discussions (issues with >10 comments and no concrete proposal in the body).
- Issues whose body is just a one-line headline and no specifics — they need scoping, not coding.
- Anything mentioning hardware variants we don't have (some issues reference T-Deck *non-Plus*).

# Output

Under 300 words, in this shape:

- **Recommendation** — one issue: number + title. One sentence on *what*, one sentence on *why now*. Cite the issue (`#42`) and any relevant commit / file path.
- **Runners-up** — 2-3 alternates, one line each with citation.
- **Survey** — counts only: open issues total, filtered out (assigned / has-PR / non-actionable), candidate pool size.

# Next step — ask, don't tell

After the report, call `AskUserQuestion` so the user picks without retyping anything:

- "Work on `#<recommended>` (Recommended)" — invoke `/work-issue` with that number.
- "Pick a runner-up" — follow up with another `AskUserQuestion` listing them, then invoke `/work-issue` on the chosen number.
- "Run `/autopilot`" — start the batch loop instead.
- "Not now" — stop and wait.

# Don't

- Don't pick an issue assigned to a human (even if PR-less).
- Don't recommend an issue whose body reads as a discussion thread — those need scoping first.
- Don't hide low-effort issues just because they're cosmetic; sometimes the best "next" is closing a small one to bank momentum.
