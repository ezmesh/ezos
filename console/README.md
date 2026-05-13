# ezOS Console

Hosted web app for flashing and configuring an ezOS T-Deck Plus from a
Chromium-based browser. Deployed by `.github/workflows/docs.yml` to
`https://ezmesh.github.io/ezos/console/` alongside the manual and API
reference. Tracking issue: [#24](https://github.com/ezmesh/ezos/issues/24).

## What it does

- **Flash** the latest `firmware-full.bin` (or `firmware.bin` for an
  app-only update) from any GitHub release, including the rolling-main /
  rolling-test channels. Drives `esptool-js` over Web Serial.
- **Pre-seed** first-boot settings by building a binary NVS partition
  image in the browser and flashing it to offset `0x9000` (see
  `partitions_16MB.csv`). The device boots once into a fully-configured
  state -- no second handshake required.

Tier 3 (bulk identity/contact/map upload) is deferred; see the issue.

## Local dev

```sh
cd console
npm install
npm run dev      # http://localhost:5173/ezos/console/
npm run build    # writes docs/console/, picked up by the Pages workflow
```

`npm run build` runs `tsc --noEmit` first; type errors fail the build.

## NVS encoder smoke test

```sh
npx tsx src/nvs/encoder.test.ts
```

Validates structural invariants of a generated image (size, page header
CRC, per-entry CRCs, namespace routing, string descriptor CRC). A future
improvement is to byte-match against ESP-IDF's `nvs_partition_gen.py` in
CI; see the acceptance criteria on #24.

## Layout

```
console/
|-- index.html
|-- vite.config.ts     # base = /ezos/console/, outDir = ../docs/console
|-- src/
|   |-- main.ts        # entry point
|   |-- style.css
|   |-- nvs/
|   |   |-- crc32.ts
|   |   |-- schema.ts  # mirrors lua/services/prefs_registry.lua + extras
|   |   |-- encoder.ts # NVS partition image builder (multi-namespace)
|   |   '-- encoder.test.ts
|   |-- flash/
|   |   '-- esptool.ts # esptool-js wrapper + binary downloader
|   |-- github/
|   |   '-- releases.ts # api.github.com fetch + localStorage cache
|   |-- protocol/
|   |   '-- remote.ts  # ezOS remote-control protocol client (cmds 0x01-0x0B)
|   '-- ui/
|       |-- app.ts     # controller / state machine
|       |-- state.ts   # AppState + WizardValues + seed builder
|       |-- steps.ts   # per-step renderers
|       '-- dom.ts     # tiny DOM helpers
```

## Browser support

Requires the **Web Serial API**: Chrome, Edge, Brave, Opera, or another
Chromium-based desktop browser. Firefox and Safari do not implement Web
Serial and the connect button is replaced by a "use Chrome" notice.
iOS / Android Chromium do not expose Web Serial either; this is a
desktop tool.

## How the seeded values land on the device

The NVS image declares two namespaces:

- **`lua_storage`** (index 1) -- where `ez.storage.set_pref`/`get_pref`
  live. Almost every wizard value goes here: `onboarded`, `wifi_ssid`,
  `wifi_password`, `tz_posix`, `theme`, `accent_color`, brightness,
  `radio_freq_mhz`, etc. The on-device `lua/boot.lua` already reads
  `tz_posix` (line 103) and the WiFi prefs (line 548) on every boot.
- **`meshcore`** (index 2) -- where `src/mesh/identity.cpp` stores the
  node name. The only wizard value that goes here is `nodename`.

No `boot.lua` changes are needed; everything routes through prefs that
the firmware already consumes. The `onboarded = "1"` sentinel makes
`lua/screens/onboarding/init.lua:is_onboarded()` return true on first
boot, so the device skips the wizard and lands on the desktop.

## Out of scope (for now)

- Backup / restore of an existing device.
- Two-device pairing helper.
- SD-card asset upload (wallpapers, TDMAP archives).
- PWA / offline cache.
- Auth-gated GitHub release fetching (currently unauthenticated, 60
  req/hour per IP).
