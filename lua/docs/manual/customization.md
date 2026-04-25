# Customization

The Settings app covers the common knobs (theme, brightness, accent
preset). This page is for the rest -- the things you can do from the
Lua REPL when the built-in pickers aren't enough.

Every recipe below works from the terminal in lua mode. Open
Tools -> Terminal, type `lua`, then enter the snippets one line at
a time.

The REPL pre-populates `ezui`, `services`, and `screens` as lazy
proxies, so submodule access auto-requires on first use. That means
you can type `ezui.theme.save_accent(...)` without first calling
`require("ezui.theme")` -- the snippets below assume that. The same
trick does NOT apply in regular app code (use explicit requires
there).

## Custom accent color

Settings -> Display -> Accent colour gives you eight presets. To set
any RGB565 value:

    ezui.theme.save_accent(0xFC18)

That repaints every focus highlight, button, and accent-tagged text
in the same frame, and writes the value to NVS so it survives reboot.

Look up the saved pref:

    return ez.storage.get_pref("accent_color", 0)

To return to a preset, pass its hex value:

    ezui.theme.save_accent(0x2C9F)  -- Blue (default)

The eight built-in presets are:

| Name   | RGB565 |
|--------|--------|
| Blue   | 0x2C9F |
| Teal   | 0x07F0 |
| Green  | 0x07E0 |
| Purple | 0x881F |
| Red    | 0xF800 |
| Orange | 0xFBE0 |
| Pink   | 0xF81F |
| Yellow | 0xFFE0 |

Tip: `save_accent` also derives `ACCENT_DIM` and `SELECTION` for you.
If you want different dim/selection colors, write directly to the
palette table (see "Direct palette tweaks" below).

## RGB565 encoding

The display uses 16 bits per pixel, packed as 5 red + 6 green + 5 blue
bits:

    R5 << 11 | G6 << 5 | B5

`ez.display.rgb(r, g, b)` does the packing for you, taking standard
0-255 channel values:

    ezui.theme.save_accent(ez.display.rgb(255, 32, 200))

A few gotchas:

- The green channel has 64 levels, red and blue only 32. Pure-gray
  RGB triplets often pick up a slight green tint after packing.
- Round-tripping through hex strings loses precision -- store the
  packed integer if you need exactness.
- The 8-bit-per-channel form maps to RGB565 by truncation, not
  rounding. `255 -> 0x1F` (red/blue) and `255 -> 0x3F` (green).

## Registering a custom theme palette

`theme.register(name, palette)` adds a brand new named palette
alongside the built-in `dark` and `light`. After registration,
`theme.set("name")` switches to it.

    ezui.theme.register("solarized", {
        BG          = 0x18C3,
        SURFACE     = 0x2945,
        SURFACE_ALT = 0x39A8,
        BORDER      = 0x4A49,
        TEXT        = 0xC638,
        TEXT_SEC    = 0x8410,
        TEXT_MUTED  = 0x4A49,
        ACCENT      = 0xFD80,
        ACCENT_DIM  = 0x9320,
        SUCCESS     = 0x07E0,
        WARNING     = 0xFE60,
        ERROR       = 0xF800,
        INFO        = 0x067F,
        SELECTION   = 0x9320,
        SCROLLBAR   = 0x4208,
        SCROLLBAR_T = 0x7BCF,
        STATUS_BG   = 0x18C3,
    })
    ezui.theme.set("solarized")
    ez.storage.set_pref("theme", "solarized")  -- survives reboot

Every key from `dark`/`light` should be present, otherwise the
matching widget will draw the magenta missing-color sentinel
(0xF81F).

Caveat: the map renderer reads `theme.map_palette()` for tile
colors. That function only knows about `dark` and `light` -- a
custom theme falls back to the dark map palette. To get matching
tile colors you would need to extend `lua/ezui/theme.lua` and
rebuild firmware.

## Direct palette tweaks

`theme.colors()` returns the live palette table. Mutating it skips
the persistence and helper logic in `set_accent`:

    local p = ezui.theme.colors()
    p.SELECTION = ez.display.rgb(120, 30, 30)
    p.SUCCESS   = ez.display.rgb(0, 220, 80)

These changes do NOT persist. They are reset to the active theme's
defaults whenever `theme.set` runs, including on the next boot.

Use this for one-off experiments before committing the values
to a registered palette or to the firmware-side `theme.lua`.

## Saving any pref from the REPL

`ez.storage.set_pref(key, value)` accepts strings, numbers, and
booleans. `ez.storage.get_pref(key, default)` reads them back at any
time. boot.lua applies a few prefs at startup (theme, accent_color,
display_brightness, kb_backlight, gps_enabled, ...). Setting these
takes effect on the next boot:

    ez.storage.set_pref("display_brightness", 60)
    ez.system.restart()

Prefs that target the running system (accent, theme) often have a
helper that applies them live -- check `lua/ezui/theme.lua` for the
pattern.

## Resetting everything

To wipe a single pref:

    ez.storage.set_pref("accent_color", 0)

To start fresh on every settings, the cleanest path is the Settings
app's "Restore defaults" entry. The REPL equivalent is to delete the
keys you care about; there is no global wipe through the binding
(by design, so a typo can't brick the device).
