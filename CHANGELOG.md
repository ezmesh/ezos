# Changelog

## [0.0.95] - 2026-05-12

### Features
- **chat:** show RSSI footer on received share/URI cards (939e359)

## [0.0.95] - 2026-05-12

### Features
- **chat:** show RSSI footer on received share/URI cards (939e359)

## [0.0.94] - 2026-05-11

### Other
- **release:** name rolling-main "ezOS v<version>" and mark as full release (8ea3fa7)

## [0.0.93] - 2026-05-11

### Other
- ignore .worktrees/ (4e80bd9)

## [0.0.92] - 2026-05-11

### Other
- **ci:** allow merge commits + drop required_linear_history (b77b256)
- resolve test<->main conflicts ahead of promote PR #87 (#93) (fd0a231)
- **release:** promote test to main (#63) (f6fcb0b)
- **pr-checks:** drop per-commit validation, gate on PR title only (#65) (5ea9b29)
- **pr-checks:** bootstrap workflow on main so GitHub registers it (1b0b014)

## [0.0.87] - 2026-05-11

### Other
- **claude:** add /next, /work-issue, /autopilot skills (#92) (61e4ff1)

## [0.0.86] - 2026-05-11

### Other
- **manual:** regenerate menu + settings pages from current sources (#91) (a0e097e)

## [0.0.85] - 2026-05-11

### Features
- **audio:** wire up onboard ES7210 microphone for audio recording (#89) (b628ef6)

## [0.0.84] - 2026-05-11

### Features
- **boot:** show firmware version and channel on splash (#90) (951f46f)

## [0.0.83] - 2026-05-10

### Features
- **channels:** per-channel history limit + notification mode (#80) (374eb45)

### Fixes
- **release:** packageJson must be an object, not the literal true (#86) (9d253e7)
- **release:** fetch tags so xtr-changelog can advance the version (#85) (d389651)

## [0.0.80] - 2026-05-10

### Features
- **channels:** per-channel history limit + notification mode (#80) (374eb45)

## [0.0.71] - 2026-05-10

### Other
- **release:** add DeployKey bypass actor to branch rulesets (#84) (afc57b3)

## [0.0.79] - 2026-05-10

### Features
- **notifications:** wire DM/file/battery/SD/panic events (#79) (5478bde)

## [0.0.78] - 2026-05-09

### Features
- **boot:** version migration system for pref/data upgrades (f2370c9)
- changelog integration with @xtr-dev/changelog (57de627)

### Fixes
- list_wallpapers crashed on list_dir table entries (f0cef26)
- write default otadata instead of erasing to zeros (4d5f9cf)
- docs: Added a link to the documentation site for more information (e6bca70)

### Other
- sync platformio version from changelog + show in updater (f0c4124)
- add conventional commits hook + CLAUDE.md rule (03239e2)
- auto-erase otadata after upload to fix OTA activation (20cf019)
- confirmation dialogs on all share actions (0ffe867)
- random wallpaper from filesystem instead of hardcoded list (1c5c885)
- charging indicator, wallpaper rotate in settings, dropdown touch fix (4d0c840)
- time share URLs + bold focused desktop label (17f83fe)
- drop icon border glow, strengthen pulse highlight (17aeba4)
- remove geometric wallpaper + replace icon glow with border (62bee00)
- fix repeat-send on others' msgs + add channel context menu (ea3cc17)
- alpha-blended overlay with mixed floating shapes (2ac1d03)
- rename remaining wallpapers to descriptive names (b50c45a)
- remove unused wallpapers to reduce repo size (f1a46b8)
- sync names on ADVERT + fix chat not updating while typing (09557c9)
- force rebuild on incoming messages while compose box is focused (37f7e6e)
- meshcore-cli returns clamped X25519 scalar, not Ed25519 seed (3355593)
- tolerate shell-escaped URL chars + add --debug (fad287a)
- decode_invite.py -- ezme.sh invite -> meshcore-cli channel key (d026ae3)
- card-style bubbles for share URLs + drop redeemed flag (01d2ca3)
- ezme.sh share URLs for contacts + channel invites (f8bfa61)
- send path + HMAC validation + compose UI (7f851e1)
- fix three stacked bugs that broke DM delivery (f459744)
- colour + restructure the help output (d9cb306)
- dev-wrapper script with build + remote-control delegation (09242cf)
- working install path -- PSRAM-back dev-tool buffers + 10 KiB stack (d9df0ef)
- Core 1 pin + watchdog/priority/log instrumentation (3685e31)
- consolidate outbound stack into util/http_client (7ba6d82)
- shrink pull-task stack to fit squeezed internal heap (b26fa88)
- redirect-following + larger URL/header caps (b7e2acb)
- PSRAM mbedtls allocator + raise per-line header cap (b877488)
- drop orphan settings.lua + system_settings.lua (3391473)
- surface Firmware entry on the System tab (bd582ea)
- PSRAM-allocate the panic-flush scratch buffer (0ff7966)
- embed signing pubkey from the 2026-05-06 ceremony (1576aad)
- re-issue HW writes on rollback + document raw_rx + manual (8e42da2)
- roll back _config on partial setProfile failure (6da5ddb)
- multi-protocol profile + configurable TX queue spacing (8464974)
- warn on downgrades, confirm before installing (bb18092)
- trackball and touch scrolling for the log viewer (7a80ea0)
- tolerate missing variant samples (9278a9f)
- persistent log file + crash flush hooks + viewer screen (3b26899)
- JPEG/PNG encode bindings + paint save + PNG wallpapers (8ba40f8)
- tappable Private/Channels + Added/Nearby tab strips (9cc6f3e)
- packet sniffer + tap sound on main-menu tab switch (f34721d)
- touch + mouse-mode wiring (minesweeper + solitaire) (6f714fa)
- 100-step undo (Alt+Z) + exit confirm on dirty buffer (67cf4cd)
- full rewrite -- toolbar, pan/zoom, select, undo, mouse mode (f1a23c4)
- mouse mode + tap/long-press synthesis + confirm dialog helper (8a92218)
- regenerate set + drop pannable / pan-mode feature (f5e5d87)
- wire up touch bridge, notifications, OTA hookup, WiFi auto-connect, NTP (62d87f1)
- on-device chat tool + bearer settings + bot.py polish (a7d4513)
- main menu redesign + Apps category + Paint + Editor + display tweaks (8410a57)
- UI bridge + widget min sizes + slider drag + diagnostic screen (1954b50)
- band-preset picker in radio settings (a7a8114)
- channel sniffer (live GRP_TXT channel hashes seen on the air) (65b13ed)
- render pipe tables (header + alignment + body rows) (ba19d2d)
- in-memory service + viewer + global toast overlay (e747ee2)
- service + settings screen + Time integration (181d89f)
- WiFi settings screen with async scan + saved-credentials rejoin (51fac64)
- Dev OTA push + Rollback firmware screens (887d64e)
- HTTP server overhaul + OTA push + WiFi async scan + NTP + GT911 touch (05a4aaa)
- extend Lucide catalogue + opt-in `padding` background (bba3f54)
- cooperative coroutine scheduler + Lua trace log + EU freq nudge (be93d32)
- seed-based encounter plan + boss sections + drone enemy + thrust pickup + particles / popups / sprite polish (4849cfa)
- in-game pause menu (P toggles) (85e48e2)
- address review feedback - closure capture + lines split (bf33a58)
- Easy / Hard modes with drop-preview on Easy (950960c)
- distinct enemy sprites + ship accel + hold-to-shoot (698ca63)
- TDMAP v4/v5 drop, version macro, http+system binding fixes, docs CI (4457967)
- dialog / persist / transient modules + prefs registry (c3aa8c2)
- extended diagnostics, time-without-fix sync, DST in set_time (d360c60)
- GPS settings, user-position marker + off-screen arrow, H key; fix road-seam artifact with render-halo crop (1e420c2)

## [0.0.70] - 2026-05-09

### Fixes
- docs: Added a link to the documentation site for more information (e6bca70)

### Other
- random wallpaper from filesystem instead of hardcoded list (1c5c885)
- charging indicator, wallpaper rotate in settings, dropdown touch fix (4d0c840)
- time share URLs + bold focused desktop label (17f83fe)
- drop icon border glow, strengthen pulse highlight (17aeba4)
- remove geometric wallpaper + replace icon glow with border (62bee00)
- fix repeat-send on others' msgs + add channel context menu (ea3cc17)
- alpha-blended overlay with mixed floating shapes (2ac1d03)
- rename remaining wallpapers to descriptive names (b50c45a)
- remove unused wallpapers to reduce repo size (f1a46b8)
- sync names on ADVERT + fix chat not updating while typing (09557c9)
- force rebuild on incoming messages while compose box is focused (37f7e6e)
- meshcore-cli returns clamped X25519 scalar, not Ed25519 seed (3355593)
- tolerate shell-escaped URL chars + add --debug (fad287a)
- decode_invite.py -- ezme.sh invite -> meshcore-cli channel key (d026ae3)
- card-style bubbles for share URLs + drop redeemed flag (01d2ca3)
- ezme.sh share URLs for contacts + channel invites (f8bfa61)
- send path + HMAC validation + compose UI (7f851e1)
- fix three stacked bugs that broke DM delivery (f459744)
- colour + restructure the help output (d9cb306)
- dev-wrapper script with build + remote-control delegation (09242cf)
- working install path -- PSRAM-back dev-tool buffers + 10 KiB stack (d9df0ef)
- Core 1 pin + watchdog/priority/log instrumentation (3685e31)
- consolidate outbound stack into util/http_client (7ba6d82)
- shrink pull-task stack to fit squeezed internal heap (b26fa88)
- redirect-following + larger URL/header caps (b7e2acb)
- PSRAM mbedtls allocator + raise per-line header cap (b877488)
- drop orphan settings.lua + system_settings.lua (3391473)
- surface Firmware entry on the System tab (bd582ea)
- PSRAM-allocate the panic-flush scratch buffer (0ff7966)
- embed signing pubkey from the 2026-05-06 ceremony (1576aad)
- re-issue HW writes on rollback + document raw_rx + manual (8e42da2)
- roll back _config on partial setProfile failure (6da5ddb)
- multi-protocol profile + configurable TX queue spacing (8464974)
- warn on downgrades, confirm before installing (bb18092)
- trackball and touch scrolling for the log viewer (7a80ea0)
- tolerate missing variant samples (9278a9f)
- persistent log file + crash flush hooks + viewer screen (3b26899)
- JPEG/PNG encode bindings + paint save + PNG wallpapers (8ba40f8)
- tappable Private/Channels + Added/Nearby tab strips (9cc6f3e)
- packet sniffer + tap sound on main-menu tab switch (f34721d)
- touch + mouse-mode wiring (minesweeper + solitaire) (6f714fa)
- 100-step undo (Alt+Z) + exit confirm on dirty buffer (67cf4cd)
- full rewrite -- toolbar, pan/zoom, select, undo, mouse mode (f1a23c4)
- mouse mode + tap/long-press synthesis + confirm dialog helper (8a92218)
- regenerate set + drop pannable / pan-mode feature (f5e5d87)
- wire up touch bridge, notifications, OTA hookup, WiFi auto-connect, NTP (62d87f1)
- on-device chat tool + bearer settings + bot.py polish (a7d4513)
- main menu redesign + Apps category + Paint + Editor + display tweaks (8410a57)
- UI bridge + widget min sizes + slider drag + diagnostic screen (1954b50)
- band-preset picker in radio settings (a7a8114)
- channel sniffer (live GRP_TXT channel hashes seen on the air) (65b13ed)
- render pipe tables (header + alignment + body rows) (ba19d2d)
- in-memory service + viewer + global toast overlay (e747ee2)
- service + settings screen + Time integration (181d89f)
- WiFi settings screen with async scan + saved-credentials rejoin (51fac64)
- Dev OTA push + Rollback firmware screens (887d64e)
- HTTP server overhaul + OTA push + WiFi async scan + NTP + GT911 touch (05a4aaa)
- extend Lucide catalogue + opt-in `padding` background (bba3f54)
- cooperative coroutine scheduler + Lua trace log + EU freq nudge (be93d32)
- seed-based encounter plan + boss sections + drone enemy + thrust pickup + particles / popups / sprite polish (4849cfa)
- in-game pause menu (P toggles) (85e48e2)
- address review feedback - closure capture + lines split (bf33a58)
- Easy / Hard modes with drop-preview on Easy (950960c)
- distinct enemy sprites + ship accel + hold-to-shoot (698ca63)
- TDMAP v4/v5 drop, version macro, http+system binding fixes, docs CI (4457967)
- dialog / persist / transient modules + prefs registry (c3aa8c2)
- extended diagnostics, time-without-fix sync, DST in set_time (d360c60)
- GPS settings, user-position marker + off-screen arrow, H key; fix road-seam artifact with render-halo crop (1e420c2)
