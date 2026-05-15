# T-Deck Plus Lua key-handler audit (#53)

Survey of `handle_key` and ad-hoc `key.character` / `key.special` checks
under `lua/` looking for bindings or hint text that depend on keys not
reachable from the T-Deck Plus physical keyboard. Source of the rules:
the "Keyboard layout (T-Deck Plus)" section of CLAUDE.md.

The on-device keyboard has:

- letters A-Z, plus the dollar key
- `space`, `Enter`, `Backspace`
- `alt`, `sym`
- two black side keys (mic / speaker)
- trackball (UP/DOWN/LEFT/RIGHT/ENTER from click)

No Ctrl, no Esc, no Tab, no function keys, no number row. Numbers and
most punctuation only arrive via `alt+letter` chords.

Scope of this pass: bindings that block a user-reachable action on the
T-Deck. Remote-tool-only synonyms (e.g. ESCAPE alongside BACKSPACE,
Ctrl in dev-only paths) are not findings.

## Summary of findings

- **0 instances of `key.ctrl`** in Lua. No work needed there.
- **6 `ESCAPE`-only files** -- 5 of them also accept `q` so the user
  has a reachable exit. 1 (`map_loader.lua`) has a usable `q`.
- **1 user-visible hint mentions "Esc"** (`solitaire.lua:607`).
- **2 user-visible help screens binding bare digits** without
  documenting the alt-chord (`wasteland.lua:2343`, `sudoku.lua` --
  digits are part of the gameplay loop, in-game help missing).
- **2 `TAB` bindings** without a clearly documented on-device
  alternative (`desktop.lua:527`, `file_manager.lua:522`). Desktop
  also accepts `m`; file_manager has none.
- Numerous **comment-only** mentions of ESC/Ctrl in source comments
  -- not user-visible, but worth scrubbing during the next pass over
  the corresponding files. Listed at the end for completeness.

## Bare-digit bindings used as primary on-device input

These check `key.character == "1".."9"` (or `>= "1" and <= "9"`).
Digits require `alt+letter` on the T-Deck, so the binding only fires
via an alt-chord -- which is fine in itself, but the user-facing hint
must say so.

- `lua/screens/games/wasteland.lua:3173-3181` -- weapon-slot
  selection bound to bare `1`..`5`. The in-game help at
  `lua/screens/games/wasteland.lua:2343` shows `1/2/3/4/5 Weapon
  slot` without mentioning the alt prefix.
  - **Suggested fix:** change the hint to `alt+1..5 Weapon slot`
    (or `alt+Q..T`, repurposing letters), and/or add a secondary
    binding to a contiguous run of letters so a one-hand fire +
    weapon-cycle is possible without two-handed alt-chording mid
    combat.

- `lua/screens/games/sudoku.lua:268,274` -- the entire gameplay is
  digit entry into the grid. Sudoku without digits doesn't really
  work; the alt-chord requirement should be called out on-screen.
  - **Suggested fix:** show a one-line hint (`alt+1..9 fill, alt+0
    clear`) on the sudoku screen, similar to wasteland's help
    layout.

## TAB used as primary input, no on-device fallback

`TAB` does not exist on the T-Deck. Both bindings below send a TAB
when the remote tool runs, so they're invisible to a user holding
the device.

- `lua/screens/desktop.lua:527` -- TAB opens the menu. Also accepts
  `m`, which is reachable, so this one is fine in practice. Worth
  documenting that `m` is the on-device path (the comment block at
  the top of `menu.lua:1-13` mentions Tab + the More icon but not
  `m`).

- `lua/screens/tools/file_manager.lua:522` -- TAB switches between
  `/fs/` and `/sd/`. **No on-device fallback.** The user has no way
  to swap roots without the remote tool.
  - **Suggested fix:** bind `alt+S` (or another alt-chord) to the
    same handler, and surface the binding in the title-bar hint or
    a one-line help line on the screen.

## ESCAPE without BACKSPACE fallback

`grep` of files containing `ESCAPE` but not `BACKSPACE`. All six are
games / tools where `q` is the documented "quit" key, and `q` is
reachable on the device, so the user can always exit.

| File | Line(s) | On-device alt |
|---|---|---|
| `lua/screens/games/minesweeper.lua` | 289 | `q` |
| `lua/screens/games/breakout.lua` | 469 | `q` |
| `lua/screens/games/solitaire.lua` | 685-686 | `q` (line 685) |
| `lua/screens/games/wasteland.lua` | 2982, 3021, 3054, 3078, 3109 | `q` |
| `lua/screens/tools/map_loader.lua` | 87 | `q` |
| `lua/screens/tools/pixel_fix.lua` | 164 | `q` |

No functional fix needed -- `q` is reachable. But the **screen
comments** in `pixel_fix.lua:3` and `image_viewer.lua:2` say
"q/ESC quits" / "Press Q or ESCAPE to exit". The ESC half is
misleading documentation -- harmless because `q` works, but a future
reader copying the comment to a screen without `q` would carry the
bug forward. Suggest dropping the ESC mention or appending "(remote
tool only)".

## User-visible hint text mentioning Esc / Ctrl / bare digits

Strings that are drawn to the screen via `draw_text` (or a widget
text field) and reference keys the on-device user cannot press
directly.

- `lua/screens/games/solitaire.lua:607` -- hint reads
  `"Enter:place  Esc:cancel"`. **Esc is unreachable.**
  - **Suggested fix:** change to `"Enter:place  Back:cancel"`. The
    handler at line 686 already handles BACKSPACE via `ESCAPE`'s
    fall-through being absent -- actually, re-check: at line 685-692,
    BACKSPACE is NOT handled in this handler. Cancelling the
    selection on-device requires pressing `q`, which is also not
    documented in the hint. Either:
      1. Add `BACKSPACE` handling alongside `ESCAPE` at line 686-692
         (cleanest), and update hint to `"Enter:place  Back:cancel"`.
      2. Update hint to `"Enter:place  Q:cancel"` and live with the
         remote-only ESC.

- `lua/screens/games/wasteland.lua:2343` -- help line
  `"1/2/3/4/5 Weapon slot"`. Reachable only via alt+chord on
  device.
  - **Suggested fix:** rewrite as `"alt+1..5 Weapon slot"` or rebind
    to letters.

## Source comments mentioning ESC/Ctrl (not user-visible)

These do not affect on-device behaviour but contradict CLAUDE.md and
should be cleaned up during any future touch of the file:

- `lua/screens/menu.lua:13` -- "ESC / BKSP : back to desktop"
  (header comment).
- `lua/screens/apps/editor.lua:33,294` -- mentions Ctrl+S/O/N.
  Editor already binds Alt+letter; the comment is historical.
- `lua/screens/apps/paint.lua:29` -- describes BACKSPACE correctly,
  parenthetically notes "T-Deck has no Esc key" -- accurate, leave.
- `lua/screens/chat/messages.lua:339` -- comment says "Back
  (q or ESC -- not BACKSPACE...)". Verify whether BACKSPACE actually
  ghosts in the chat input or if this is stale.
- `lua/screens/chat/channel_chat.lua:128` -- mentions "no Esc key
  exists" -- accurate.
- `lua/screens/tools/image_viewer.lua:2` -- header says
  "q/ESC quits". Misleading; handler also accepts BACKSPACE
  (line 168) which is the actual on-device exit. Suggest:
  `"Arrows pan, z/x zoom in/out, r resets, Back/q quits"`.
- `lua/screens/onboarding/welcome.lua:3` -- "BACKSPACE/ESC are
  deliberately ignored" -- accurate.
- `lua/screens/games/shooter.lua:1789` -- "ESC / BACKSPACE / Q
  resume" -- accurate.
- `lua/screens/games/wasteland.lua:3052,3107` -- comments refer to
  ESC alongside Q -- accurate.
- `lua/docs/manual/key-bindings.md:12` -- the embedded manual says
  "Backspace / Esc | Go back". On the device the "Esc" half cannot
  be pressed; consider rewriting as "Backspace / Back arrow".
- `lua/ezui/dialog.lua:49` -- "Back/ESC key" in a docstring -- the
  dialog handler check is fine, comment is informational.

## Triage suggestion

Highest leverage to fix in order:

1. `file_manager.lua:522` -- add an `alt+S` (or similar) binding to
   swap `/fs/` <-> `/sd/` so the on-device user has a working
   alternative to TAB.
2. `solitaire.lua:685-692` + `:607` -- add BACKSPACE handling and
   update the hint to "Back:cancel".
3. `wasteland.lua:2343` -- fix the in-game help to say `alt+1..5`.
4. `sudoku.lua` -- add a one-line hint explaining the alt-chord for
   digit entry.
5. `lua/docs/manual/key-bindings.md` -- rewrite "Esc" mentions.
6. Source-comment cleanup -- low priority; do opportunistically
   when touching nearby code.

The dev-only ESC and Ctrl references in source comments are not
worth a dedicated pass.
