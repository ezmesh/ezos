// Shared wizard state. One object, passed by reference into every step so
// the user can navigate back-and-forth without losing input.

import type { Release, FlashImage } from "../github/releases";

export type Step =
    | "compat"
    | "welcome"
    | "release"
    | "variant"
    | "wizard"
    | "flash"
    | "done";

export type Variant = "full" | "app";

export interface WizardValues {
    // Identity
    nodename: string;
    callsign: string;

    // Mesh / radio
    radio_freq_mhz: string;
    tx_throttle_ms: number;

    // Network
    wifi_ssid: string;
    wifi_password: string;
    ntp_on: number;
    tz_posix: string;

    // Display
    theme: string;
    accent_color: number;
    wallpaper: string;
    screen_bright: number;

    // Audio
    audio_volume: number;
    ui_sounds_on: number;
}

export function defaultWizardValues(): WizardValues {
    return {
        nodename: "",
        callsign: "",
        radio_freq_mhz: "869.525", // EU default, matches lua/screens/onboarding/region.lua
        tx_throttle_ms: 400,
        wifi_ssid: "",
        wifi_password: "",
        ntp_on: 1,
        tz_posix: "UTC0",
        theme: "dark",
        accent_color: 0,
        wallpaper: "synthwave",
        screen_bright: 200,
        audio_volume: 100,
        ui_sounds_on: 1,
    };
}

export interface AppState {
    step: Step;
    release: Release | null;
    images: FlashImage | null;
    variant: Variant;
    eraseNvs: boolean;
    seedPrefs: boolean;
    wizard: WizardValues;
}

export function makeState(): AppState {
    return {
        step: "compat",
        release: null,
        images: null,
        variant: "full",
        eraseNvs: false,
        seedPrefs: true,
        wizard: defaultWizardValues(),
    };
}

/**
 * Build the flat seed dict the NVS encoder consumes. Skips empty strings
 * so the encoder doesn't emit zero-length STR entries.
 */
export function buildSeedValues(s: AppState): Record<string, string | number> {
    const w = s.wizard;
    const out: Record<string, string | number> = {
        onboarded: "1",
        // Stamp the migration tracker so on-device migrations don't replay
        // against a fresh install. The string stays empty if we don't know
        // a version yet; lua/services/migrations.lua treats empty as
        // "never migrated" and just stamps the current version on boot.
    };
    if (w.nodename)        out.nodename = w.nodename;
    if (w.callsign)        out.callsign = w.callsign;
    if (w.radio_freq_mhz)  out.radio_freq_mhz = w.radio_freq_mhz;
    out.tx_throttle_ms = w.tx_throttle_ms;
    if (w.wifi_ssid)       out.wifi_ssid = w.wifi_ssid;
    if (w.wifi_password)   out.wifi_password = w.wifi_password;
    out.ntp_on = w.ntp_on;
    if (w.tz_posix)        out.tz_posix = w.tz_posix;
    if (w.theme)           out.theme = w.theme;
    out.accent_color = w.accent_color;
    if (w.wallpaper)       out.wallpaper = w.wallpaper;
    out.screen_bright = w.screen_bright;
    out.audio_volume = w.audio_volume;
    out.ui_sounds_on = w.ui_sounds_on;
    return out;
}
