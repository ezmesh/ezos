-- prefs_registry: authoritative list of every ez.storage pref the
-- firmware itself sets or reads.
--
-- The registry exists for three reasons:
--   1. Documentation: one place to read to know what a pref means and
--      what values are valid.
--   2. Defaults: `reset(key)` knows the canonical default to write back.
--   3. System vs user: the dev prefs editor contrasts registered keys
--      with the full NVS keyset so ad-hoc user prefs stand out.
--
-- Each entry:
--   key         — NVS key (must be <=15 chars)
--   type        — "int8" | "uint8" | "int16" | "uint16" | "int32" |
--                 "uint32" | "int64" | "uint64" | "string" | "blob"
--                 Matches the type label returned by ez.storage.list_prefs.
--                 For bool-ish toggles use "int8" with min=0,max=1.
--   default     — canonical default value (used by reset()).
--   description — human-readable one-liner for the editor.
--   options     — optional array of string values (for enum-ish prefs).
--                 When set the editor offers a picker instead of free text.
--   min, max    — optional numeric bounds for integer prefs.

local registry = {}

local ENTRIES = {
    -- ---- Display ----------------------------------------------------
    { key = "screen_bright", type = "int32", default = 200, min = 10, max = 255,
      description = "LCD backlight brightness (10-255)" },
    { key = "kb_backlight",       type = "int32", default = 0,   min = 0,  max = 255,
      description = "Keyboard backlight brightness (0-255)" },
    { key = "accent_color",       type = "int32", default = 0,
      description = "Accent colour (RGB565; 0 uses the first preset)" },

    -- ---- Wallpaper --------------------------------------------------
    { key = "wallpaper",      type = "string", default = "synthwave",
      description = "Current built-in wallpaper name" },
    { key = "wallpaper_path", type = "string", default = "",
      description = "Custom wallpaper file path (overrides 'wallpaper' when set)" },
    { key = "wp_rotate",      type = "string", default = "off",
      options = { "off", "boot", "shown" },
      description = "Auto-rotate trigger: off, once per boot, or every time shown" },

    -- ---- Keyboard ---------------------------------------------------
    { key = "kb_rep_enable", type = "string", default = "1",
      options = { "0", "1" },
      description = "Key repeat enabled ('1' / '0'; legacy string flag)" },
    { key = "kb_rep_delay",  type = "int32", default = 400, min = 50, max = 1500,
      description = "Initial delay before key repeat (ms)" },
    { key = "kb_rep_rate",   type = "int32", default = 50, min = 20, max = 500,
      description = "Interval between repeated key events (ms)" },
    { key = "kb_tb_intr",    type = "string", default = "1",
      options = { "0", "1" },
      description = "Trackball interrupt mode enabled ('1' / '0')" },

    -- ---- Audio ------------------------------------------------------
    { key = "audio_volume",      type = "int32", default = 100, min = 0, max = 100,
      description = "Master audio volume (0-100)" },
    { key = "ui_sounds_on", type = "int8",  default = 1,  min = 0, max = 1,
      description = "UI feedback sounds (taps, toggles, transitions)" },

    -- ---- GPS --------------------------------------------------------
    { key = "gps_enabled",   type = "int8",   default = 0, min = 0, max = 1,
      description = "GPS receiver power" },
    { key = "gps_sync_mode", type = "string", default = "auto",
      options = { "auto", "manual", "off" },
      description = "How the system clock syncs from GPS" },

    -- ---- NTP --------------------------------------------------------
    { key = "ntp_on",        type = "int8",   default = 0, min = 0, max = 1,
      description = "SNTP client enabled (clock-sync over WiFi)" },
    { key = "ntp_preset",    type = "string", default = "pool",
      options = { "pool", "google", "cloudflare", "nist", "windows", "custom" },
      description = "Which NTP server preset to trust (or 'custom')" },
    { key = "ntp_custom",    type = "string", default = "",
      description = "Hostname when ntp_preset is 'custom'" },

    -- ---- Services / state -------------------------------------------
    { key = "theme",           type = "string", default = "",
      description = "Last selected map theme" },
    { key = "map_last_view",   type = "string", default = "",
      description = "Last map viewport (packed zoom/lat/lon/theme)" },
    { key = "joined_channels", type = "string", default = "",
      description = "Semicolon-separated channel list (edit with care)" },
    { key = "contacts_v1",     type = "string", default = "",
      description = "Contact list blob (edit with care)" },
    { key = "tb_mode",         type = "string", default = "",
      description = "Trackball mode (arrow/pointer/scroll)" },
    { key = "touch_mode",      type = "string", default = "direct",
      options = { "direct", "mouse" },
      description = "Touch input style: direct tap or relative cursor (mouse mode)" },
}

local by_key = {}
for _, e in ipairs(ENTRIES) do by_key[e.key] = e end

-- Public accessors ----------------------------------------------------

function registry.all()
    return ENTRIES
end

function registry.get(key)
    return by_key[key]
end

function registry.is_system(key)
    return by_key[key] ~= nil
end

-- Write the registered default back to NVS. Returns false if the key
-- isn't in the registry (nothing to reset to).
-- We remove the key first so set_pref always creates a fresh NVS
-- entry of the default's type — otherwise a pre-existing wrong-type
-- entry (e.g. a number that was stored as a string by older code)
-- can survive the overwrite.
function registry.reset(key)
    local entry = by_key[key]
    if not entry then return false end
    ez.storage.remove_pref(entry.key)
    ez.storage.set_pref(entry.key, entry.default)
    return true
end

-- Enumerate every NVS pref not in the registry. Returned entries
-- mirror the shape of ez.storage.list_prefs(): { key, type }.
function registry.list_user_prefs()
    local out = {}
    if not ez.storage.list_prefs then return out end
    for _, entry in ipairs(ez.storage.list_prefs()) do
        if not by_key[entry.key] then
            out[#out + 1] = entry
        end
    end
    return out
end

-- Return the registered keys whose entries are present in NVS and the
-- registered keys that have never been written. Useful for showing
-- "currently active" vs "at default" in the editor.
function registry.classify_system()
    if not ez.storage.list_prefs then
        return { stored = {}, unstored = ENTRIES }
    end
    local stored_keys = {}
    for _, entry in ipairs(ez.storage.list_prefs()) do
        stored_keys[entry.key] = true
    end
    local stored, unstored = {}, {}
    for _, e in ipairs(ENTRIES) do
        if stored_keys[e.key] then
            stored[#stored + 1] = e
        else
            unstored[#unstored + 1] = e
        end
    end
    return { stored = stored, unstored = unstored }
end

return registry
