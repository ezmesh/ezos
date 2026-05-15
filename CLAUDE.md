# ezOS Project Guidelines

ezOS is a complete embedded operating system for the LilyGo T-Deck Plus
(ESP32-S3 with LoRa). C++ firmware handles hardware drivers and mesh
networking; Lua scripts (embedded into firmware at build time) handle the
UI and all application logic; MeshCore is the on-air protocol.

## Building, flashing, and serial access

```bash
pio run            # build only
pio run -t upload  # build + flash
```

Lua scripts under `lua/` are embedded into the firmware at build time, and
`require()` resolves embedded scripts before LittleFS -- so both Lua and
C++ changes require a full rebuild and flash.

**Never use `stty`, `pio device monitor`, `minicom`, or any other
interactive serial monitor.** The user usually has one open already, and
the second consumer steals the port. Use the remote-control tool instead
(see "Remote control" below).

**Port assignments**: the T-Deck is on `/dev/ttyACM0`. `/dev/ttyUSB0` is
typically the user's separate MeshCore CLI node -- never fall back to it.
If `ttyACM0` isn't present, ask the user to plug it in.

**Don't send to public mesh channels** (e.g. `public <msg>` via
meshcore-cli) -- the public channel is shared with real users. Only DM
the user's own devices for testing.

## Commit messages

All commits **must** use [Conventional Commits](https://www.conventionalcommits.org/):
`type(scope): description`. Allowed types: `feat`, `fix`, `build`,
`chore`, `ci`, `docs`, `refactor`, `perf`, `test`, `style`. A `commit-msg`
hook rejects non-conforming messages, and `@xtr-dev/changelog` parses
these prefixes -- skipping a prefix means the change won't appear under
the right changelog heading.

## Keyboard layout (T-Deck Plus)

The on-device QWERTY keyboard is **not** a PC keyboard: **no Ctrl, no
Esc**, no Shift-lock, no function keys, no Tab. See `tdeck keyboard.png`
in the repo root for the photographed layout.

Physical layout:
- Row 1: `Q W E R T Y U I O P` + Backspace
- Row 2: `A S D F G H J K L` + Enter
- Row 3: `alt Z X C V B N M $`
- Row 4: `0` (mic / 0), `space` (LILYGO logo'd), `sym`, plus two small
  black side keys (microphone / speaker).

Modifiers: **`alt`** and **`shift`** (two physical shift keys, both at
matrix positions `SHIFT1`/`SHIFT2` in `src/hardware/keyboard_matrix.h`,
either sets `key.shift`). `sym` is a third modifier for the punctuation
layer. Numbers and most punctuation are `alt+letter`, **not** a number
row.

Shortcut rules:
- **Never use `key.ctrl` for an on-device shortcut.** The remote tool can
  send it; a user in the field cannot. Use `key.alt` for primary
  shortcuts (Save, Open, New) or expose actions via the M-key (Alt+M)
  context menu.
- **Never rely on `ESCAPE` as the only exit.** The dedicated back-arrow
  icon sends `BACKSPACE`; screens must always treat
  `key.special == "BACKSPACE"` as back/cancel. `ESCAPE` is fine as a
  remote-tool synonym, never as the sole binding.
- Hint text should say "Back" or use the back-arrow glyph, never "ESC".
- The device is held two-handed and thumbed. Single-tap and Alt+letter
  combos are fine. Alt+Shift combos are reachable but reserved for
  system-level global chords (e.g. the input-lock toggle), not per-screen
  actions.
- Don't steal keys the user might want to type as text (e.g. editor
  must not bind bare `s` for Save).
- The trackball acts like arrow keys; design shortcuts to also work
  without taking a hand off the keys.

When porting code/docs that mention Ctrl, replace with Alt and re-test
the chord on the device, not the remote tool.

## On-device font character set

**Scope:** this section applies ONLY to strings rendered by the on-device
bitmap fonts -- any Lua `draw_text` call, the on-device markdown viewer
(`lua/ezui/markdown.lua`), and the firmware-embedded markdown under
`lua/docs/manual/`. It does NOT apply to PR bodies / titles, issue text,
GitHub comments, code comments, host-side tools, or anything that only
renders on github.com or in a normal terminal. Those surfaces are
Unicode-capable; substituting `--` for em-dashes or `->` for arrows there
just makes the text harder to read.

**Commit descriptions are a partial exception.** They appear on-device in
the What's New screen (`lua/screens/settings/whats_new.lua`), which runs
them through `ascii_safe()`. That helper maps the common typographic
characters (em-dash, en-dash, ellipsis, curly quotes, bullet, middle dot)
to ASCII -- but any other non-ASCII byte (e.g. `→`, accented letters,
emoji) is silently **stripped**, not boxed. Prefer ASCII in commit
subjects so on-device changelog entries don't lose characters.

Built-in bitmap fonts (`src/fonts/InterAA*.h`, `Spleen*.h`) only cover
**printable ASCII 0x20..0x7E**. Any other codepoint renders as a `[]`
missing-glyph box.

Common offenders: em-dash (`U+2014`), en-dash (`U+2013`), middle dot
(`U+00B7`), bullet (`U+2022`), ellipsis (`U+2026`), curly quotes, arrows
(`U+2192`/`U+2190`). External-API strings (GPS names, channel names,
contact names) are a frequent source -- sanitize before display.

Safe substitutes: `--` or ` - ` (dashes), `|` (separator), `...`
(ellipsis), `-`/`*` (bullet), `->`/`<-` (arrows), straight `"`/`'`
(quotes).

**Applies equally to docs.** Markdown under `lua/docs/manual/` is
embedded and rendered by `lua/ezui/markdown.lua` with the same fonts --
non-ASCII renders as `[]` there too. The auto-generated `docs/manual/`
and `docs/api/` trees served on GitHub Pages are tolerant either way,
but the source the renderer reads must not be.

If a glyph is genuinely needed, extend the bitmap font (font generator
with wider range); otherwise stay ASCII in any string reaching
`draw_text`.

## Project structure

```
ezos/
├── src/                    # C++ firmware
│   ├── main.cpp           # Boot sequence, main loop
│   ├── hardware/          # Display, keyboard, radio, GPS drivers
│   ├── mesh/              # MeshCore (identity, routing, crypto)
│   ├── lua/bindings/      # C++ wrappers for Lua APIs (@lua-annotated)
│   └── remote/            # USB remote-control protocol
├── lua/                    # Lua, embedded into firmware
│   ├── boot.lua           # Entry point (service init, apply settings)
│   ├── core/              # Module infrastructure
│   ├── engine/            # Long-lived helpers (audio_engine, highscores)
│   ├── ezui/              # Declarative UI framework (see below)
│   ├── screens/           # Screen definitions
│   ├── services/          # Background services
│   └── util/              # Shared helpers
├── scripts/                # Build-time generators (Lua embedder)
├── tools/                  # Host utilities (maps, remote, doc gen, ...)
├── console/                # Browser-based flasher + first-boot
│                          #   pref pre-seed (hosted at
│                          #   ezmesh.github.io/ezos/console/).
│                          #   src/{nvs,flash,github,protocol,ui};
│                          #   vite base=/ezos/console/, outDir=../docs/console
└── docs/                   # User manual + Lua API reference
```

## UI system (ezui)

### Declarative screen model

Screens define `build(state)` returning a node tree. `set_state()`
triggers automatic rebuild + redraw.

```lua
local MyScreen = { title = "My Screen" }

function MyScreen:build(state)
    return ui.vbox({ gap = 4 }, {
        ui.title_bar("My Screen", { back = true }),
        ui.text_widget({ text = state.message or "Hello" }),
    })
end

function MyScreen:on_enter()      -- screen becomes active
function MyScreen:on_leave()      -- screen paused (another pushed on top)
function MyScreen:on_exit()       -- screen popped off the stack
function MyScreen:handle_key(key) -- input not handled by focused nodes
```

### Main loop

C++ `loop()` calls `_G.main_loop()` (set by `ui.start()`):
1. Update mesh network (every 50ms via `ez.mesh.update()`).
2. Screen manager update (input + render at ~30 FPS).
3. Incremental GC (every 2s).

Timers and bus messages are processed by C++ `LuaRuntime::update()`
before the Lua main loop runs.

### Module loading

```lua
load_module(path)        -- async load from LittleFS (yields in coroutine)
require("module.name")   -- standard require; embedded first, then LittleFS
spawn(fn)                -- run function in coroutine
```

### Settings persistence

`ez.storage.set_pref(key, value)` / `ez.storage.get_pref(key, default)`.
Restored in `lua/boot.lua` at startup. NVS keys have a **15-char limit**.

### Chat bubble actions

**All actions on chat bubble content (share cards, time shares, invites)
must be behind a context menu.** Tap opens the menu; destructive or
state-changing actions (sync clock, add contact, join channel) are menu
items inside it. Never fire from `on_press` on a chat bubble -- the
touch target is large and accidental taps are common on the small
screen.

### Services

Services init in order in `lua/boot.lua`:

1. **log_persist** -- runs first so subsequent init lines are captured
2. **contacts** -- CRUD + persistence
3. **channels** -- channel management, GRP_TXT decryption
4. **direct_messages** -- encrypted DMs via TXT_MSG packets
5. **sharing** -- share-card construction and dispatch
6. **reminders** -- 30-second sweep that fires "10 min before" /
   "starting now" toast notifications for `cal/v1` share-card events the
   user accepted. State persisted to NVS under `reminders_v1`.
7. **custom_packets** -- non-MeshCore packet handlers
8. **file_transfer** -- mesh-based file send/receive
9. **ui_sounds** -- UI SFX via the audio engine
10. **notifications** -- toast queue + bus subscribers (OTA, DMs, file
    transfer, low battery, SD connect/disconnect, panic/brownout recovery)
11. **apps** -- file-type → screen handler registry (used by file manager)
12. **gps** -- `start_sync_loop()` always called; loop respects the
    "never / at boot / hourly" pref and no-ops when GPS is disabled
13. **power** -- 30 s battery poll that transitions between Normal /
    Frugal / Survival tiers with hysteresis. Other services (`gps`,
    `ntp`, `custom_packets`) consult `power.gps_sync_allowed()` /
    `power.ntp_allowed()` / `power.allow_non_dm()` predicates rather
    than subscribing to `power/mode_changed`, so a missed bus event
    only delays gating by 30 s. DM traffic is never gated. See
    "Power policy" below.

After services start: `migrations.run()` runs version migrations, then
`ntp` kicks a sync. Other modules under `lua/services/` (`input_lock`,
`map_archive`, `prefs_registry`, `signal_test`) load on demand.

### Notifications service

In-memory toast queue. Bus topic `notifications/changed` fires on every
change; `ezui/screen.lua` subscribes once and renders the most recent as
a toast.

Public API:
- `notifications.post(opts)` -- `{ title, body?, source?, sticky?,
  action? = { label, on_press }, read?, dnd_fav?, dnd_mention? }`.
  Returns id, or nil if suppressed (muted source / missing title).
  `title`/`body` are sanitized to printable ASCII before storage
  (peer-originated, and the fonts can't render anything else).
- `notifications.post_unless_focused(opts, predicate)` -- posts only
  when `predicate(top_screen_inst)` is false. Use for events that lead
  to a screen the user may already be on (DM → DM conversation).
- `notifications.dismiss(id)` / `dismiss_source(s)` / `list()` /
  `unread_count()` / `mark_all_read()`.
- `notifications.dnd_active()` -- returns `true` when DND is currently
  active (manual override or scheduled quiet window). Safe to poll;
  fails open (returns `false`) when the clock is unset.

Per-source mute pref: every `post()` consults `notify_<source>` in NVS
(default `"1"` = on). Setting `notify_dm = "0"` silences every DM toast
without touching wiring. Source tags must stay short to fit NVS's
15-char limit (`dm`, `file`, `battery`, `sd`, `ota`, `channel`,
`system`). Note that `notify_words` lives in the same `notify_*`
keyspace but is NOT a mute pref -- it holds the comma-separated
trigger-word list for "Mentions only" channels (see
`matches_trigger_words()` / `get_trigger_words()` /
`set_trigger_words()` on the service). The `channel/message`
subscriber in `boot.lua` ORs a trigger-word match against the existing
node-name mention check, so a trigger hit behaves identically to a name
mention (gates the DND `dnd_mention` exemption too).

Do Not Disturb (issue #116): `notifications.post()` also evaluates a
time-window DND mode after the source-mute check. When the manual
override `dnd_manual` is `"1"`, OR `dnd_enabled` is `"1"` and the wall
clock falls inside `[dnd_start, dnd_end)` (minutes since midnight;
window wraps midnight if end <= start), the notification still lands in
the list (so `unread_count` advances) but is flagged `silent = true`.
The toast subscriber in `ezui/screen.lua` skips silent items, and the
panel-wake on incoming notification is also suppressed. Two opt-in
exemptions can pass an event through anyway: `opts.dnd_fav` (DM from a
starred contact -- not wired yet pending a favourites field on
`services.contacts`) and `opts.dnd_mention` (channel message containing
the user's node name -- wired in `boot.lua`'s `channel/message`
subscriber). User-facing toggles live under Settings -> Notifications.
DND is treated as off when the clock is unset (year < 2020) so a cold
boot before NTP/GPS sync doesn't accidentally swallow notifications.

### Input lock service

`services/input_lock` is a tiny in-memory gate consulted by the keyboard
and touch chokepoints. While locked, `screen.handle_input` swallows
every key except the unlock chord, the touch bridge swallows every
`touch/*`, and a bottom banner is drawn on top of every screen. Boot
always starts unlocked -- in-memory only by design, so a chord-path
regression can't soft-brick the device across reboots.

API: `input_lock.is_locked()`, `set(new_locked)` (coerces to bool,
deduplicates no-ops), `toggle()`.

Bus: `input_lock/changed`, payload `{ locked = bool }`. Fires on every
real transition so other services can react (dim backlight, suppress
sounds) without polling.

Chord: **Shift+Alt+L** locks, **Shift+Alt+U** unlocks. Recognised inside
`screen.handle_input` before everything else (including `notify_input` /
screensaver dismissal), so unlock works even when the screensaver is up.
The matrix path uppercases letters when shift is held; the remote-inject
path forwards as-is -- the handler accepts both cases.

Touch subscribers: the lock gate is **opt-in** for direct `touch/*`
subscribers via `touch_input.is_locked()`, same as `is_wake_event`. See
next section.

### Power policy

`services/power` polls `ez.system.get_battery_percent()` every 30 s and
moves between three tiers with hysteresis:

| Tier      | Enter        | Exit         |
|-----------|--------------|--------------|
| normal    | (default)    | --           |
| frugal    | pct <= 30    | pct >= 35    |
| survival  | pct <= 10    | pct >= 15    |

Charging snaps the tier toward normal (survival -> frugal, frugal ->
normal) so a USB plug is treated as "full" without flapping. When
`ez.system.get_battery_percent()` returns nil the policy stays in the
current tier.

On a tier transition the service:
- `ez.mesh.set_announce_interval(...)` -- 120 s (normal), 240 s
  (frugal), 480 s (survival).
- `ez.radio.set_tx_power(dbm)` -- 22 dBm (normal/frugal), 17 dBm
  (survival).
- `services.ntp.stop()` on entry to survival; `start_if_enabled()` on
  exit. Frugal leaves NTP alone -- lwIP's SNTP cadence is not
  reachable from Lua, so we can stop NTP cleanly but cannot slow it
  down without a new binding.
- Clamps display brightness to <= 80 / 255 in survival (caches the
  pre-clamp value so it's restored when leaving the tier; the user's
  saved `screen_bright` pref is not touched).
- Posts a notification (source `"power"`) with `dismiss_source` first
  so re-entering doesn't pile up duplicates.
- Emits `power/mode_changed = { mode = "normal" | "frugal" | "survival" }`
  for any UI that wants to react. Consumers in critical paths
  (gps/ntp/custom_packets) poll predicates rather than subscribing, so
  the missed-event case just delays gating by 30 s.

Two prefs gate the policy from settings:
- `pwr_always_norm` -- pin to normal regardless of battery.
- `pwr_force_surv` -- pin to survival regardless of battery.

The two are mutually exclusive; `power.set_always_normal(true)` clears
`pwr_force_surv` and vice versa, so the pref state cannot end up
confused. Both keys are <= 15 chars to dodge the silent-NVS-truncation
trap.

DM traffic (TXT_MSG) is NEVER gated by power -- someone in trouble
might be on 4 % battery and we won't drop their DMs to save airtime.
Only RAW_CUSTOM senders flow through `custom_packets.send()` and get
suppressed in survival. Channel GRP_TXT sends are also not gated;
they're rare and user-initiated.

Status bar surfacing: `power.short_indicator()` returns `""` / `"lp"` /
`"LP"` and `lua/ezui/screen.lua`'s status updater copies it into
`screen.status.power_tag`. The `status_bar` widget renders the tag in
`ACCENT` left of the battery glyph.

### Touch input and the screensaver wake gate

`lua/ezui/touch_input.lua` is the global touch-to-widget bridge. It
subscribes once at boot to `touch/down|move|up` and turns single-finger
taps into focus-chain activations on the widget under the finger -- most
screens get touch for free.

Several developer-facing APIs gate raw `touch/*` events and participate
in the screensaver wake-event flow:

- **`screen.notify_input()`** (`lua/ezui/screen.lua`) -- bumps
  `last_input_time` and, if the idle ladder is anywhere past stage 0
  (pre-dim, screensaver-active, or panel-off), unwinds it: restores the
  LCD backlight, dismisses the screensaver overlay if drawn, and resets
  the stage to 0. Returns `true` when the call cleared a non-zero stage
  (dim, screensaver, OR panel-off) so the caller can swallow the
  originating event -- a tap that wakes the device should not also click
  whatever sat under the finger. The keyboard read loop calls this; you
  usually don't, but it's the single chokepoint if you ever need to
  synthesise a wake.

- **`screen.acquire_wakelock(tag)`** / **`screen.release_wakelock(tag)`**
  (`lua/ezui/screen.lua`) -- tag-keyed counter that pins the idle ladder
  at stage 0 regardless of `ss_timeout`. Pass the same string tag to
  both calls; releasing a tag that was never acquired is a no-op.
  Multiple distinct tags can be held concurrently and the ladder only
  resumes once the last one is released. `release_wakelock` also resets
  `last_input_time` so a long-held wakelock (e.g. a multi-minute file
  transfer) doesn't make the next idle tick jump straight to panel-off.
  There is one implicit wakelock built in: `_wakelocks_held()` polls
  `ez.audio.is_recording()`, so the voice-notes / signal-test capture
  paths stay lit without their screens having to acquire anything.
  Prefer wakelocks over per-frame `notify_input()` pings when a
  background activity needs the display alive for an unbounded duration
  -- they don't fight the user's chosen `ss_timeout` for the *next* idle
  period after release.

- **`touch_input.is_wake_event()`** -- true for ~250ms after a touch
  dismissed the screensaver (or any non-zero idle stage). The bridge
  sets the timestamp inside its own `screensaver_swallow()` guard
  whenever `notify_input()` reports the wake cleared a non-zero stage.

- **`touch_input.is_locked()`** -- true while the global input lock is
  engaged (Shift+Alt+L).

**Call both at the top of every direct `touch/*` subscriber:**

```lua
ez.bus.subscribe("touch/down", function(_, data)
    local ti = require("ezui.touch_input")
    if ti.is_locked() or ti.is_wake_event() then return end
    -- ... real handler
end)
```

Without these guards: a wake-tap on the desktop would launch an icon,
a wake-tap in Paint would seed a stroke, a pocket touch with the device
"locked" would still drive the screen's handler. The bus broadcasts to
every subscriber, so the bridge can't suppress them on its own -- each
direct subscriber has to opt in.

`touch/tap` and `touch/long_press` subscribers (games, custom views)
are **not** affected -- those are synthesised inside the bridge's
`on_up`, which already returns early on wake events AND while locked.

## Theming

`lua/ezui/theme.lua` is the single source of truth for colors and fonts.

- Built-in palettes: `dark` (default) and `light`. Switch via
  `theme.set("dark"|"light")`, persisted under the `theme` pref,
  restored at boot.
- Accent color is independent of dark/light. Stored under `accent_color`,
  picked from `theme.ACCENT_PRESETS`. Settings → Display → Accent colour.
- **Map palette**: `theme.map_palette()` returns the 8-color tile
  palette + label inks/halo for the active theme. The map renderer reads
  this every frame, so a theme switch repaints tiles without invalidating
  the cache. See `lua/ezui/widgets/map_view.lua`.
- User entry: Settings → Display → Theme → Dark mode toggle. The Map
  screen also accepts `T` as a legacy shortcut.

Use `theme.color("NAME")` rather than raw RGB565 literals so values flow
through both palettes.

## Remote control (`tools/remote/`)

Primary tool for automated testing and debugging.

```bash
cd tools/remote && pip install pyserial pillow
```

| Flag | Use |
|------|-----|
| (none) | Test connection |
| `-s out.png` | Screenshot (24-bit BMP, BGR bottom-up) |
| `-k <key>` | Send key (e.g. `enter`, `a`, `up`); add `--ctrl`, `--shift`, `--alt` |
| `--info` | Current screen title and dimensions |
| `--text` | Text rendered in next frame (positions + colors) |
| `--primitives` | Draw calls in next frame (rects, lines, bitmaps) |
| `--logs` | Buffered log entries |
| `--monitor` | Real-time log stream |
| `-e "<lua>"` | Execute Lua, returns JSON |
| `-f script.lua` | Execute Lua file |

### Picking a capture mode

**Prefer `--text` over screenshots when verifying UI content** -- faster,
smaller, programmatically searchable. Use `--primitives` for rendering
issues (e.g. map tiles); reserve screenshots for visual layout, colors,
graphics, or doc/bug-report material.

**Wallpaper convention for Desktop screenshots** included in
`docs/screenshots/`: set `wallpaper` to `green-coastline` first so
re-shoots stay visually consistent.

```bash
python tools/remote/ez_remote.py /dev/ttyACM0 \
    -e "ez.storage.set_pref('wallpaper', 'green-coastline')"
# then navigate back to Desktop and take the shot
```

Non-Desktop shots (Map, Chat, Settings sub-pages, ...) don't care.

### Lua execution examples

```bash
python ez_remote.py /dev/ttyACM0 -e "return collectgarbage('count')"
python ez_remote.py /dev/ttyACM0 -e "ez.storage.get_pref('brightness', 200)"
python ez_remote.py /dev/ttyACM0 -e \
    "local ch = require('services.channels'); return #ch.get_history('#Public')"
```

### Navigating screens

```bash
# Push from LittleFS path
-e "local ui = require('ezui'); ui.push_screen('\$screens/chat/messages.lua')"

# Push from require()'d module
-e "local ui = require('ezui'); local s = require('ezui.screen'); \
    local def = require('screens.chat.contacts'); s.push(s.create(def, {}))"

# Pop
-e "require('ezui.screen').pop()"
```

### Protocol

- Baudrate: 921600.
- Request: `[CMD:1][LEN:2][PAYLOAD:LEN]`.
- Response: `[STATUS:1][LEN:4 LE][DATA:LEN]` -- 4-byte length to fit
  screenshot BMPs (~225 KiB at 320x240); file reads capped at
  `PAYLOAD_CAP = 16 KiB`.

| Cmd | Name | Payload |
|-----|------|---------|
| `0x01` | PING | -- |
| `0x02` | SCREENSHOT | -- |
| `0x03` | KEY_CHAR | char + modifiers |
| `0x04` | KEY_SPECIAL | special key id |
| `0x05` | SCREEN_INFO | -- |
| `0x06` | WAIT_FRAME_TEXT | -- |
| `0x07` | LUA_EXEC | lua source |
| `0x08` | WAIT_FRAME_PRIMITIVES | -- |
| `0x09` | WRITE_FILE | `[path_len:2][path][data]` |
| `0x0A` | READ_FILE | `[path_len:2][path][offset:4][length:4]` |
| `0x0B` | WRITE_AT | `[path_len:2][path][offset:4][data]` |

### Test-only Lua surfaces (ez.debug / ez.bench)

`ez.debug.*` (AsyncIO queue stats, SD remount, heap snapshots, last
panic) and `ez.bench.*` (micro-benchmark scenarios + boot profile
timeline) are test-only scaffolding for the pytest harness under
`tools/remote/tests/`. They live alongside the public bindings but are
**not** part of the public Lua API -- same trust model: don't depend on
them from app Lua, and don't add UI surfaces that expose them. The bench
scenarios are registered in a static array in
`src/lua/bindings/bench_bindings.cpp` -- adding more is a one-line
Scenario struct plus a `run()` function. Boot profile markers are
recorded by `bootProfileMark()` in C++ (early `main.cpp` checkpoints)
and `ez.bench.mark()` in Lua (`lua/boot.lua` service-init marks); the
ring buffer is fixed at 64 entries and dumped via
`ez.bench.boot_profile()`.

## Map tools (`tools/maps/`)

One-command builder that turns a PMTiles source into a TDMAP v7 vector
archive the device renders directly. The pipeline is collapsed to two
modules and a CLI:

| File | Purpose |
|------|---------|
| `make_map.py`  | CLI entry point. `make_map.py <region>` builds a preset; `make_map.py custom <pmtiles> --bounds W,S,E,N --zoom MIN,MAX` rolls a custom region. |
| `tdmap.py`     | TDMAP v7 format: writer, reader, inspect/verify CLI, Douglas-Peucker simplifier, Web Mercator helpers. |
| `regions.py`   | Region preset catalogue (global / europe / netherlands etc). Add a `Region(...)` here and `make_map.py <name>` Just Works. |
| `viewer.html`  | Browser preview (client-side v7 decoder + canvas renderer). |

```bash
cd tools/maps
pip install -r requirements.txt          # pmtiles, mapbox-vector-tile
python make_map.py netherlands           # build the 'netherlands' preset
python make_map.py custom amsterdam.pmtiles \
    --bounds 4.7,52.3,5.0,52.5 --zoom 12,14 -o ams.tdmap
python tdmap.py inspect ams.tdmap        # header + per-feature stats
```

Copy `.tdmap` files to `/sd/maps/`. The Map app's loader
(`screens/tools/map_loader.lua`) lists every archive there; "Set as
default" via the M-key actions menu skips the picker on subsequent
opens.

Failure surfaces (writer-side):
  * empty bounds              → `no tiles in bounds at z<MIN>..z<MAX>`
  * source missing            → `PMTiles not found: <path>`
  * zoom out of source range  → `source covers z<a>..z<b>, asked for z<c>..z<d>`

### TDMAP format (v7)

v7 stores **vector geometry**, not rasterized tiles. The on-device
renderer reads polylines + filled polygons every frame, so themes
swap colors at no extra cost, zoom interpolates smoothly, and there is
no per-zoom raster duplication. Writer emits v7 only; reader rejects
pre-v7 with a "regenerate" message.

- **Header** (33 bytes): magic, version=7, compression (zlib), `grid_dim`
  (spatial-index resolution, default 256), `geom_count`, index offset,
  data offset, zoom range, label offset/count.
- **Metadata block**: 4-byte length + TLV tags (region name, bounds,
  build timestamp, tool version, source hash). **`BB` is mandatory in
  v7** — the spatial-index grid is defined relative to the archive's
  bounding box.
- **Geometry index** (`geom_count` × 14 bytes), sorted by
  `(cell_index, min_zoom)`: cell_index (u32), feature_class (u8),
  geom_type (u8, 0=polyline / 1=polygon), min_zoom, max_zoom, payload
  offset (u32), payload size (u16). A viewport query computes which
  spatial-grid cells fall inside the visible rect and binary-searches
  the index for each.
- **Geometry payload** (per record, zlib-compressed): vertex_count (u8)
  + int32 origin (lat_e6, lon_e6) + (n-1)×int16 deltas (Δlat_e6, Δlon_e6).
  Deltas fit in int16 because Douglas-Peucker at zoom-dependent
  tolerance keeps successive vertices close; the writer interpolates
  midpoints if a pair would overflow.
- **Labels**: same layout as v6 (lat_e6/lon_e6 + zoom range + type +
  utf-8 text, deduped by 1° bucket at build time).

Semantic feature indices (0-7): Land, Water, Park, Building, RoadMinor,
RoadMajor, Highway, Railway — unchanged from v6. Colors live in
`ezui.theme.map_palette()`, so a single archive serves both light and
dark themes.

## Rolling OTA updates

Pushes to `main` / `test` trigger `.github/workflows/main-artifacts.yml`
/ `test-artifacts.yml`. Each builds firmware, generates `manifest.json`
(SHA, version, sha256, size, asset URL, plus `full_*` variants for the
bootloader+partitions+app blob), signs it with the Ed25519 key from the
`OTA_SIGNING_PRIVKEY` secret, runs `xtr-changelog release --commit --tag
--push` to advance `versions.json` and tag the release, and republishes
the `rolling-main` / `rolling-test` GitHub Release. Older builds are
kept as run artefacts (prune caps at 3).

`paths-ignore` excludes generated files (`changelog/versions.json`,
`changelog/archive.json`, `lua/docs/changelog.json`, `CHANGELOG.md`,
`platformio.ini`) so the workflow's own release commit doesn't retrigger
itself. The release commit is also `[skip ci]`-prefixed as defense in
depth.

On-device update (`lua/screens/settings/firmware_update.lua`): user
picks `main` / `test`, screen fetches `manifest.json` and
`manifest.json.sig`, calls `ez.crypto.ed25519_verify` against the
embedded `kOtaSigningPubkey` (`src/ota_pubkey.cpp`), and only on valid
signature passes `full_bin_url` + `full_sha256` into
`ez.ota.apply_full_url`. The streamer writes the firmware straight into
the inactive OTA partition (bootloader/partitions only if they differ
from current flash) and switches the boot slot via direct otadata write.
Trust flows from the signature, not TLS -- `setInsecure()` is used and
SHA-256 is re-checked against the manifest while writing.

**Setup ceremony** (once per project):

1. `pip install pynacl && python tools/ota/gen_signing_key.py`
2. Paste private key into repo secret `OTA_SIGNING_PRIVKEY`.
3. Paste C-array form into `kOtaSigningPubkey` in
   `src/ota_pubkey.cpp` (replacing the all-zero placeholder).
4. Build + flash. Devices flashed before this won't accept rolling-main
   updates -- `ez.ota.signing_pubkey()` returns nil and the screen shows
   "OTA signing not configured on this device".

Key rotation: burn a new firmware containing the new pubkey, then
rotate the secret, then update every consumer of the pubkey. Concretely:
(a) regenerate the keypair with `tools/ota/gen_signing_key.py`,
(b) replace the C array in `src/ota_pubkey.cpp`'s `kOtaSigningPubkey`,
(c) replace the hex constant `OTA_PUBKEY_HEX` in
`console/src/flash/manifest.ts` -- the web flasher verifies the same
manifest signature, and missing this step makes every new release look
"unsigned" to the console even though the on-device updater still
accepts it, (d) rotate the `OTA_SIGNING_PRIVKEY` GitHub secret, (e)
reflash every device in the field. **Don't lose the private key** --
recovery means reflashing every device manually.

### Branch ruleset push gate

The workflow's `xtr-changelog --push` step pushes `[skip ci]` release
commits + tags back to `main` / `test`. Both branches are protected by
repo rulesets (`scripts/branch-protection.sh`); the `pull_request` rule
blocks direct pushes from any actor not on the bypass list, including
the workflow's `GITHUB_TOKEN`. The "GitHub Actions" identity does not
appear in the bypass picker on the free org plan.

**Workaround**: a write-enabled deploy key `auto-release-push` (private
half in repo secret `RELEASE_PUSH_KEY`) **plus a `DeployKey` bypass
actor on each ruleset**. The `*-artifacts.yml` workflows load the key
via `webfactory/ssh-agent` and check out over SSH so the push flows
through the same key. **Deploy keys do NOT bypass rulesets
implicitly** -- the `DeployKey` bypass actor must be present (it
covers any deploy key on the repo; the API stores it with
`actor_id: null`).

If OTA releases stop publishing, check the "Generate changelog, sync
version, and push back" step. `GH013 / Changes must be made through a
pull request` means the push reached GitHub but the `pull_request` rule
fired. Two common causes:

1. The `DeployKey` bypass entry is missing from the ruleset's
   `bypass_actors`. Re-run `scripts/branch-protection.sh`, or add it
   manually:
   ```sh
   gh api repos/ezmesh/ezos/rulesets        # find the ruleset id
   gh api -X PUT repos/ezmesh/ezos/rulesets/<id> -f \
       'bypass_actors[][actor_type]=DeployKey' \
       -f 'bypass_actors[][bypass_mode]=always' ...
   ```
   (The PUT replaces the full payload.)
2. SSH push fell back to HTTPS+`GITHUB_TOKEN` because the deploy key
   is missing or the secret was rotated. Regenerate with
   `ssh-keygen -t ed25519`, register the public half via
   `POST /repos/ezmesh/ezos/keys` with `read_only: false`, re-upload
   the private half to `RELEASE_PUSH_KEY`. The `webfactory/ssh-agent`
   step's log (`Identity added: ...`, fingerprint) confirms whether
   auth got off the ground.

## C++ binding safety

### Dangling `lua_State*`

**CRITICAL:** Never store a `lua_State* L` parameter in a
static/global variable when the function may be called from a Lua
coroutine. The coroutine's state becomes invalid after it is GC'd,
crashing later use of the stored pointer.

Has bitten this codebase twice:
- Packet callbacks in `mesh_bindings.cpp` -- captured the registering
  coroutine's state, crashed once GC'd. Fixed by switching to
  `LUA_STATE` at call sites (`mesh_bindings.cpp:166`).
- `timerLuaState` in `system_bindings.cpp` -- stored boot coroutine's
  state, crashed on 30-second timer. Now uses `LUA_STATE`
  (`system_bindings.cpp:103`).

**Fix pattern**: use the `LUA_STATE` macro
(`LuaRuntime::instance().getState()`), which always returns the main
Lua state. Include `lua_runtime.h`.

```cpp
// BAD: L may be a coroutine state that gets GC'd
static lua_State* savedState = nullptr;
LUA_FUNCTION(my_func) { savedState = L; }

// GOOD: always use main state
void myCallback() {
    lua_State* L = LUA_STATE;
    if (L) { lua_pcall(L, ...); }
}
```

When writing bindings that register callbacks, audit every `lua_State*`
that outlives the current function call. If stored, it must come from
`LUA_STATE`, not the `L` parameter.

### RNG choice for crypto-adjacent values

`math.random` in Lua 5.x is a non-cryptographic PRNG with weak seeding
(we call `math.randomseed(ez.system.millis())` at most points; an
observer who watches a peer come online can narrow the seed to a
millisecond). It is fine for games (board shuffles, spawn positions,
snake apple placement) but **must not** be used for anything that
another node could try to predict or replay:

- invite-token nonces
- packet sequence / id values
- file-transfer ids
- any value passed to a hash that another peer will see
- random delays that gate retransmit / dedup logic

For those, use:

- `ez.crypto.random_bytes(n)` -- n raw hardware-seeded bytes (1..256).
  Backed by `esp_fill_random()` -> ESP32-S3 hardware RNG.
- `ez.crypto.random_int(lo, hi)` -- uniformly distributed integer in
  the inclusive range `[lo, hi]`, rejection-sampled on top of
  `esp_fill_random`. Use this when the call site wants a bounded
  integer (transfer ids, sequence numbers, etc.).

C++ code already does the right thing in most places: `esp_random()` is
used directly in `wifi_bindings.cpp`, `ota_bindings.cpp`, and
`Identity::generateKeyPair` via RadioLib's `RNGClass::rand()`. Anything
new on the C++ side should follow the same pattern -- never call
`rand()` or `random()` from `<stdlib.h>` for security-sensitive output.

Caveat: `esp_fill_random` returns deterministic values **before WiFi or
BT is initialized**. We init the radio early enough that this isn't a
problem for steady-state use; for boot-time crypto (identity key
generation in `Identity::generateKeyPair`) we already seed via RadioLib
which mixes in hardware noise from the LoRa modem. New code that runs
before the first `WiFi.begin()` should be aware of the constraint.

## Documentation

Two doc surfaces under `docs/`:

- `docs/manual/` -- user-facing manual (hand-written prose + generated
  HTML). Covers what the device does, how to use each app, where to find
  settings.
- `docs/api/` -- Lua API reference, **generated from C++ binding
  annotations** by `tools/generate_lua_docs.py`. Do not hand-edit;
  overwritten on next regen.

### Annotation conventions

Every binding under `src/lua/bindings/` is documented inline. The
generator's docstring has the full grammar; common cases:

```cpp
// @module ez.display
// @brief Display drawing and rendering functions
// @description ...
// @end

// @lua ez.display.draw_text(x, y, text, color) -> nil
// @brief Draw a string at (x, y)
// @param x  X coordinate (pixels)
// @param y  Y coordinate (pixels)
// @param text  UTF-8 string (ASCII-only on default fonts)
// @param color  RGB565 color
// @example
// ez.display.draw_text(8, 8, "hello", 0xFFFF)
// @end

// @bus key/down
// @brief Posted on every keypress (before per-screen handling)
// @payload { key: string, special: bool, ctrl: bool, shift: bool }
```

`@bus`, `@param`, `@return`, and `@example` all flow into the published
API page.

### Regenerating

```bash
python tools/generate_lua_docs.py
```

Writes Markdown + HTML to `docs/api/` and `docs/manual/`. No watch
mode; run manually after touching annotations.

### Maintenance contract

- **Adding/modifying a Lua binding**: update the C++ annotation in the
  same diff. `@brief` minimum -- don't ship undocumented surface.
- **Adding/removing a Lua-only API** (service or ezui module, no C++
  binding): document under `docs/manual/` if user-visible, in CLAUDE.md
  if developer-only.
- **New screen / app / settings panel**: add or update the matching
  page under `docs/manual/<area>/index.md`.
- **On-disk format changes** (TDMAP, prefs, transfer protocol): keep
  the Key Components / TDMAP / MeshCore sections honest. Bump version
  constants *and* prose in the same commit.
- **CLAUDE.md itself is a living doc**: when a section becomes wrong
  (renamed module, deleted screen, format bump), fix it in the same
  change set rather than letting drift accumulate.

The on-device docs reader (`lua/screens/tools/help.lua`) browses two
stores: firmware-embedded markdown under `lua/docs/` (hand-authored,
exposed via `ez.docs.list` / `ez.docs.read`) and SD-side markdown under
`/sd/docs/manual/` and `/sd/docs/api/` (bulkier auto-generated
reference). Both render through `lua/ezui/markdown.lua`.

Source-of-truth split:
- `lua/docs/manual/` -- hand-authored, embedded in firmware. Edit
  directly; the embedder picks up on next `pio run`.
- `docs/manual/` and `docs/api/` -- auto-generated. Do not hand-edit;
  deployed to GitHub Pages and meant to be copied to SD for on-device
  reference reading.

## Key components

### Identity (Ed25519)
- Keypairs in NVS (`privkey`, `pubkey`).
- Node ID = first 6 bytes of SHA-256(pubkey).
- Sign/verify for message authentication.

### Channels
- Default `#Public`, joined automatically at startup.
- Encrypted channels: AES-128-ECB with password-derived keys.
- GRP_TXT plaintext: `[timestamp:4 LE][type:1][sendername: text]`.
- Room server relays wrap an additional
  `[timestamp:4][type:1][sender: text]` inside the text.

### Direct messages (TXT_MSG)
- ECDH shared secret (X25519); first 16 bytes = AES key, full 32 = HMAC
  key.
- OTA payload: `[dest_hash:1][src_hash:1][MAC:2][ciphertext:N]`.
- MAC: HMAC-SHA256 truncated to 2 bytes, keyed with full 32-byte shared
  secret.
- Ciphertext: AES-128-ECB, zero-padded to 16-byte boundary.
- Inner plaintext: `[timestamp:4 LE][flags:1][text:N]`.
- Receiver filters by `dest_hash`, then tries contacts/nodes matching
  `src_hash`.

### Radio
- `!RF` indicator = LoRa init failed. Check module wiring.

### Node Store (persisted ADVERT cache)
- Storage path: `/sd/nodes.bin` when SD is mounted, otherwise NVS blob
  `nodes` in the existing `meshcore` namespace (factory reset wipes the
  blob alongside the identity keys).
- Header: `[magic:4 'EZNS' / 0x534E5A45][version:2 LE][count:2 LE]`.
  `kVersion = 1` -- bump in lockstep with any layout change so older
  firmware loading a newer blob fails fast.
- Per-node record: `[pathHash:1][role:1][flags:1][nameLen:1]
  [advertTimestamp:4 LE][lastSeenUnix:4 LE]
  [pubKey:32 if flags&0x01]
  [lat:f32 LE][lon:f32 LE if flags&0x02]
  [name:nameLen]`. Flags: bit 0 = `hasPublicKey`, bit 1 = `hasLocation`.
- Caps: 128 entries on SD, 64 on NVS. On overflow at save time,
  oldest-by-`lastSeen` (local millis() observation time) entries are
  evicted from the *written* set (the in-memory vector is left
  untouched). Deliberately not `advertTimestamp` -- that field is
  peer-chosen and a node with a future-dated or wrap-around ADVERT
  would always survive truncation over genuinely-fresh observations.
- Aging: entries with a `lastSeenUnix` more than 7 days behind the
  current wall clock are dropped at load time. Skipped when the
  system clock is unset (year < 2020), so a cold boot before NTP/GPS
  sync doesn't wipe the list.
- Save policy: `_nodesDirty` flips true the first time `updateNode()`
  changes a persisted field (new node, name, pubkey, role, location,
  advert timestamp). `MeshCore::update()` flushes once
  `millis() - _nodesDirtyAt >= 30000`. The dirty timestamp is *not*
  re-armed on subsequent changes so a steady ADVERT stream still
  gets persisted promptly.
- What is NOT persisted: `lastRssi`, `lastSnr`, `hopCount` describe
  the last *packet*, not the node, and would be stale and misleading
  after a reboot. They are zeroed on restore and refilled by the next
  ADVERT.
- SD writes are atomic: written to `/sd/nodes.bin.tmp`, then renamed
  over `/sd/nodes.bin`. A power loss mid-save loses the *previous*
  save, never corrupts the active blob.
- Names are sanitized to printable ASCII at the deserialise boundary
  (`?` substituted for any byte outside `0x20..0x7E`) so hand-edited
  blobs or older-firmware saves can't poison `draw_text` callers.
  Live ADVERT names still flow unsanitized through `updateNode()`;
  fixing that seam is out of scope.

## MeshCore protocol reference

Reference: https://github.com/ripplebiz/MeshCore

### Sizes
- Identity: `PUB_KEY_SIZE`=32, `PRV_KEY_SIZE`=64, `SIGNATURE_SIZE`=64,
  `SEED_SIZE`=32.
- Cipher: `CIPHER_KEY_SIZE`=16, `CIPHER_BLOCK_SIZE`=16,
  `CIPHER_MAC_SIZE`=2.
- Packet: `MAX_PACKET_PAYLOAD`=184, `MAX_PATH_SIZE`=64,
  `MAX_TRANS_UNIT`=255, `MAX_ADVERT_DATA_SIZE`=32, `PATH_HASH_SIZE`=1.

### Packet header (1 byte)
- Bits 0-1: route type (mask `0x03`).
- Bits 2-5: payload type (shift 2, mask `0x0F`).
- Bits 6-7: payload version (shift 6, mask `0x03`).

Route types: `TRANSPORT_FLOOD`=0x00, `FLOOD`=0x01, `DIRECT`=0x02,
`TRANSPORT_DIRECT`=0x03.

### ADVERT payload

```
[pub_key:32][timestamp:4][signature:64][app_data:variable]
```

- 0: pubkey (32).
- 32: timestamp (4 LE).
- 36: Ed25519 signature (64).
- 100: app data (up to 32) -- name, location, metadata.

**Signature is computed over**: `[pub_key:32][timestamp:4][app_data:variable]`.

App data (all multi-byte ints LE):

| Field | Offset | Size | Type | Notes |
|-------|--------|------|------|-------|
| flags | 0 | 1 | uint8 | presence/type bits |
| latitude | 1 | 4 | int32_le | optional: lat × 1e6 |
| longitude | 5 | 4 | int32_le | optional: lon × 1e6 |
| feature1 | 9 | 2 | uint16_le | optional, reserved |
| feature2 | 11 | 2 | uint16_le | optional, reserved |
| name | var | var | string | UTF-8 |

Flags byte:

| Bit/value | Meaning |
|-----------|---------|
| 0-1 = 0x01 | chat node |
| 0-1 = 0x02 | repeater |
| 0-1 = 0x03 | room server |
| 2 (0x04) | sensor |
| 4 (0x10) | has location |
| 5 (0x20) | has feature1 |
| 6 (0x40) | has feature2 |
| 7 (0x80) | has name |

Lat/lon encoded as `int32_le = decimal_degrees * 1_000_000`
(e.g. 47.543968° → 47543968). Only present when bit 4 (`0x10`) is set.

Device roles (bits 0-1): `0x01` chat client, `0x02` repeater (often
GPS-equipped), `0x03` room server.

### Key MeshCore source files
- [`src/Packet.h`](https://github.com/ripplebiz/MeshCore/blob/main/src/Packet.h) -- packet structure + header format
- [`src/Mesh.cpp`](https://github.com/ripplebiz/MeshCore/blob/main/src/Mesh.cpp) -- packet handling (ADVERT processing)
- [`src/Identity.h`](https://github.com/ripplebiz/MeshCore/blob/main/src/Identity.h) -- Ed25519 identity class
- [`src/MeshCore.h`](https://github.com/ripplebiz/MeshCore/blob/main/src/MeshCore.h) -- main constants
- [`src/helpers/AdvertDataHelpers.h`](https://github.com/ripplebiz/MeshCore/blob/main/src/helpers/AdvertDataHelpers.h) -- ADVERT appdata parsing
