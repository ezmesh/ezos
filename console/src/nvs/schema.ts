// Pref schema, mirroring lua/services/prefs_registry.lua exactly. The Lua
// registry is the source of truth; if it grows or changes, update this file
// in the same commit. A future improvement is to parse the Lua file at
// build time via a Vite plugin, but the registry changes rarely enough that
// hand-mirroring is fine for now -- and keeps the build hermetic.

export type PrefType =
    | "int8"
    | "uint8"
    | "int16"
    | "uint16"
    | "int32"
    | "uint32"
    | "int64"
    | "uint64"
    | "string";

export interface PrefDef {
    key: string;
    type: PrefType;
    default: string | number;
    description: string;
    options?: string[];
    min?: number;
    max?: number;
}

// Pref key the device checks to know whether to launch onboarding. Setting
// this in the seeded NVS image makes the device boot straight to the
// desktop the first time.
export const ONBOARDED_PREF = "onboarded";

// Pref key for the POSIX TZ string. Read on every boot by lua/boot.lua:103
// and applied via ez.system.set_timezone.
export const TZ_POSIX_PREF = "tz_posix";

// Mesh node name lives in the `meshcore` NVS namespace (see
// src/mesh/identity.cpp), keyed by "nodename".
export const NODE_NAME_PREF = "nodename";

export const PREFS: PrefDef[] = [
    // Display
    { key: "screen_bright", type: "int32", default: 200, min: 10, max: 255,
      description: "LCD backlight brightness" },
    { key: "kb_backlight",  type: "int32", default: 0, min: 0, max: 255,
      description: "Keyboard backlight brightness" },
    { key: "accent_color",  type: "int32", default: 0,
      description: "Accent colour (RGB565)" },

    // Wallpaper
    { key: "wallpaper",      type: "string", default: "synthwave",
      description: "Built-in wallpaper name" },

    // Audio
    { key: "audio_volume",   type: "int32", default: 100, min: 0, max: 100,
      description: "Master audio volume" },
    { key: "ui_sounds_on",   type: "int8",  default: 1, min: 0, max: 1,
      description: "UI feedback sounds" },

    // GPS
    { key: "gps_enabled",    type: "int8",   default: 0, min: 0, max: 1,
      description: "GPS receiver power" },
    { key: "gps_sync_mode",  type: "string", default: "auto",
      options: ["auto", "manual", "off"],
      description: "GPS clock-sync mode" },

    // NTP
    { key: "ntp_on",         type: "int8",   default: 0, min: 0, max: 1,
      description: "SNTP client enabled" },
    { key: "ntp_preset",     type: "string", default: "pool",
      options: ["pool", "google", "cloudflare", "nist", "windows", "custom"],
      description: "NTP server preset" },

    // Touch
    { key: "touch_mode",     type: "string", default: "direct",
      options: ["direct", "mouse"],
      description: "Touch input style" },

    // Theme (used by the map renderer; also consumed by the on-device
    // theme system as a hint of what the user last picked).
    { key: "theme",          type: "string", default: "",
      description: "UI theme" },

    // Onboarding-controlled prefs that don't appear in prefs_registry but
    // are written by the onboarding screens directly.
    { key: "radio_freq_mhz", type: "string", default: "868",
      description: "LoRa carrier frequency (MHz)" },
    { key: "tx_throttle_ms", type: "int32", default: 400, min: 50, max: 2000,
      description: "Tx queue drain interval (ms)" },
    { key: "callsign",       type: "string", default: "",
      description: "User callsign (optional)" },

    // WiFi (set by lua/screens/settings/wifi_settings.lua, consumed by
    // lua/boot.lua's auto-connect at line 548).
    { key: "wifi_ssid",      type: "string", default: "",
      description: "WiFi SSID for auto-connect at boot" },
    { key: "wifi_password",  type: "string", default: "",
      description: "WiFi password for auto-connect at boot" },
];

export const PREF_BY_KEY: Map<string, PrefDef> = new Map(
    PREFS.map((p) => [p.key, p]),
);

// Region presets mirror lua/screens/onboarding/region.lua.
export const REGIONS: Array<{ id: string; label: string; freq: string }> = [
    { id: "EU", label: "Europe (868 MHz)", freq: "869.525" },
    { id: "US", label: "North America (915 MHz)", freq: "915" },
    { id: "AS", label: "Asia (433 MHz)", freq: "433.175" },
    { id: "AU", label: "Australia / NZ (915 MHz)", freq: "917" },
];

export const TX_THROTTLES: Array<{ ms: number; label: string }> = [
    { ms: 200, label: "Fast (200 ms)" },
    { ms: 400, label: "Default (400 ms)" },
    { ms: 800, label: "Conservative (800 ms)" },
];

// Timezones mirror lua/util/timezones.lua exactly. The on-device Time
// settings screen uses the same list, so seeded values will round-trip
// through the picker without showing "Custom".
export const TIMEZONES: Array<{ label: string; tz: string }> = [
    { label: "UTC",                        tz: "UTC0" },
    { label: "Amsterdam / Paris / Berlin", tz: "CET-1CEST,M3.5.0,M10.5.0/3" },
    { label: "London",                     tz: "GMT0BST,M3.5.0/1,M10.5.0" },
    { label: "Athens",                     tz: "EET-2EEST,M3.5.0/3,M10.5.0/4" },
    { label: "Moscow",                     tz: "MSK-3" },
    { label: "New York",                   tz: "EST5EDT,M3.2.0,M11.1.0" },
    { label: "Chicago",                    tz: "CST6CDT,M3.2.0,M11.1.0" },
    { label: "Denver",                     tz: "MST7MDT,M3.2.0,M11.1.0" },
    { label: "Los Angeles",                tz: "PST8PDT,M3.2.0,M11.1.0" },
    { label: "Tokyo",                      tz: "JST-9" },
    { label: "Sydney",                     tz: "AEST-10AEDT,M10.1.0,M4.1.0/3" },
];

// Accent colour presets (sample of theme.ACCENT_PRESETS). RGB565 values.
export const ACCENT_PRESETS: Array<{ label: string; rgb565: number }> = [
    { label: "Default",  rgb565: 0 },
    { label: "Cyan",     rgb565: 0x07ff },
    { label: "Magenta",  rgb565: 0xf81f },
    { label: "Amber",    rgb565: 0xfd20 },
    { label: "Green",    rgb565: 0x07e0 },
    { label: "Red",      rgb565: 0xf800 },
];
