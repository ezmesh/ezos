// Per-step renderers. Each step is a function that builds a DOM fragment
// for the current state, with callbacks back into the controller.

import { el } from "./dom";
import {
    REGIONS,
    TX_THROTTLES,
    TIMEZONES,
    ACCENT_PRESETS,
} from "../nvs/schema";
import type { AppState, Variant } from "./state";
import type { Release, FlashImage } from "../github/releases";
import { pickImages, isSigned } from "../github/releases";

function stepsBar(active: AppState["step"]): HTMLElement {
    const labels: Array<{ step: AppState["step"]; label: string }> = [
        { step: "welcome", label: "Connect" },
        { step: "release", label: "Release" },
        { step: "variant", label: "Options" },
        { step: "wizard",  label: "Configure" },
        { step: "flash",   label: "Flash" },
        { step: "done",    label: "Done" },
    ];
    const order = labels.map((l) => l.step);
    const activeIdx = order.indexOf(active);
    return el(
        "div",
        { class: "steps" },
        labels.map((l, i) =>
            el(
                "div",
                {
                    class:
                        "step" +
                        (i === activeIdx ? " active" : "") +
                        (i < activeIdx ? " done" : ""),
                },
                [l.label],
            ),
        ),
    );
}

export function renderCompat(supported: boolean): HTMLElement {
    if (supported) {
        return el("div", {}, [
            stepsBar("welcome"),
            el("div", { class: "card" }, [
                el("h1", {}, ["ezOS Console"]),
                el("p", { class: "lead" }, [
                    "Flash the ezOS firmware to your T-Deck Plus and configure it before you unplug. Everything runs in your browser; identity keys never leave this machine.",
                ]),
                el("div", { class: "banner ok" }, [
                    "Web Serial detected. Plug in a T-Deck Plus over USB-C and click below.",
                ]),
                el("div", { class: "btn-row" }, [
                    el("span", { class: "spacer" }, []),
                    el(
                        "button",
                        { class: "btn", id: "btn-start" },
                        ["Get started"],
                    ),
                ]),
            ]),
        ]);
    }
    return el("div", {}, [
        el("div", { class: "card" }, [
            el("h1", {}, ["Browser not supported"]),
            el("div", { class: "banner err" }, [
                "This page uses the Web Serial API to talk to the T-Deck over USB. It isn't available in this browser.",
            ]),
            el("p", {}, [
                "Open this page in a Chromium-based browser on desktop -- Chrome, Edge, Brave, or Opera. Firefox and Safari do not yet implement Web Serial.",
            ]),
            el("p", {}, [
                "If you have one of those installed, copy the URL and paste it there.",
            ]),
        ]),
    ]);
}

export function renderRelease(
    releases: Release[] | null,
    error: string | null,
    selected: Release | null,
): HTMLElement {
    const card = el("div", { class: "card" }, [
        el("h1", {}, ["Pick a release"]),
        el("p", {}, [
            "These come from GitHub. ",
            el("code", {}, ["rolling-main"]),
            " is the latest stable build; ",
            el("code", {}, ["rolling-test"]),
            " is the preview channel.",
        ]),
    ]);
    if (error) {
        card.appendChild(el("div", { class: "banner err" }, [error]));
    }
    if (!releases) {
        card.appendChild(
            el("p", {}, [
                el("span", { class: "spinner" }, []),
                "  Fetching releases...",
            ]),
        );
        return el("div", {}, [stepsBar("release"), card]);
    }
    const list = el("div", { class: "release-list" });
    for (const r of releases) {
        const images = pickImages(r);
        if (!images) continue;
        const channelLabel =
            r.channel === "rolling-main" ? "stable" :
            r.channel === "rolling-test" ? "preview" :
            r.channel === "stable"       ? "release" : "tag";
        const item = el(
            "div",
            {
                class:
                    "release-item" + (selected?.tag_name === r.tag_name ? " selected" : ""),
                "data-tag": r.tag_name,
            },
            [
                el("span", { class: "tag" }, [r.tag_name]),
                el(
                    "span",
                    {
                        class:
                            "channel" +
                            (r.channel.startsWith("rolling") ? " rolling" : ""),
                    },
                    [channelLabel],
                ),
                el("span", { class: "spacer" }, []),
                el("span", { class: "date" }, [
                    new Date(r.published_at).toLocaleDateString(undefined, {
                        year: "numeric",
                        month: "short",
                        day: "numeric",
                    }),
                ]),
            ],
        );
        list.appendChild(item);
    }
    card.appendChild(list);
    card.appendChild(
        el("div", { class: "btn-row" }, [
            el("button", { class: "btn secondary", id: "btn-back" }, ["Back"]),
            el("span", { class: "spacer" }, []),
            el(
                "button",
                {
                    class: "btn",
                    id: "btn-next",
                    disabled: selected ? null : true,
                },
                ["Continue"],
            ),
        ]),
    );
    return el("div", {}, [stepsBar("release"), card]);
}

export function renderVariant(
    release: Release,
    images: FlashImage,
    variant: Variant,
    eraseAll: boolean,
    seedPrefs: boolean,
): HTMLElement {
    const sizeKB = (n: number) => `${(n / 1024).toFixed(0)} KB`;
    const signed = isSigned(images);
    return el("div", {}, [
        stepsBar("variant"),
        el("div", { class: "card" }, [
            el("h1", {}, ["Flash options"]),
            el("dl", { class: "kv" }, [
                el("dt", {}, ["Release"]),
                el("dd", {}, [release.tag_name]),
                el("dt", {}, ["Published"]),
                el("dd", {}, [new Date(release.published_at).toLocaleString()]),
                el("dt", {}, ["Signed"]),
                el("dd", {}, [signed ? "yes (Ed25519)" : "no"]),
            ]),
            !signed
                ? el("div", { class: "banner err" }, [
                      "This release has no manifest.json + manifest.json.sig. The on-device updater would refuse it too. Pick a rolling-main or rolling-test release.",
                  ])
                : null,
            el("h2", {}, ["Image"]),
            el("div", { class: "checkbox" }, [
                el("input", {
                    type: "radio",
                    name: "variant",
                    id: "variant-full",
                    value: "full",
                    checked: variant === "full",
                }),
                el("label", { for: "variant-full" }, [
                    `Full image (bootloader + partitions + app, ${sizeKB(images.fullSize)})`,
                ]),
            ]),
            images.appUrl
                ? el("div", { class: "checkbox" }, [
                      el("input", {
                          type: "radio",
                          name: "variant",
                          id: "variant-app",
                          value: "app",
                          checked: variant === "app",
                      }),
                      el("label", { for: "variant-app" }, [
                          `App only (${sizeKB(
                              images.appSize ?? 0,
                          )}, leaves NVS untouched -- use for updates)`,
                      ]),
                  ])
                : null,
            el("h2", { style: "margin-top: 12px;" }, ["NVS / settings"]),
            el("div", { class: "checkbox" }, [
                el("input", {
                    type: "checkbox",
                    id: "chk-seed",
                    checked: seedPrefs,
                }),
                el("label", { for: "chk-seed" }, [
                    "Pre-seed first-boot settings (recommended for a fresh device)",
                ]),
            ]),
            el("div", { class: "checkbox" }, [
                el("input", {
                    type: "checkbox",
                    id: "chk-erase",
                    checked: eraseAll && variant === "full",
                    disabled: variant !== "full" ? true : null,
                }),
                el("label", { for: "chk-erase" }, [
                    "Erase entire flash before writing (factory reset, wipes identity)",
                ]),
            ]),
            variant !== "full"
                ? el("div", { class: "hint" }, [
                      "Disabled in app-only mode: erasing the whole chip without rewriting the bootloader and partition table would brick the device. Switch to the full image to combine with a factory erase.",
                  ])
                : null,
            eraseAll && variant === "full"
                ? el("div", { class: "banner warn" }, [
                      "Full erase wipes the device's Ed25519 identity, channel keys, and contacts. Only do this for a fresh setup or when you really mean it.",
                  ])
                : null,
            el("div", { class: "btn-row" }, [
                el("button", { class: "btn secondary", id: "btn-back" }, ["Back"]),
                el("span", { class: "spacer" }, []),
                el(
                    "button",
                    {
                        class: "btn",
                        id: "btn-next",
                        disabled: signed ? null : true,
                    },
                    [seedPrefs ? "Configure" : "Skip to flash"],
                ),
            ]),
        ]),
    ]);
}

function section(title: string, body: Node[]): HTMLElement {
    return el("div", { class: "card" }, [el("h2", {}, [title]), ...body]);
}

function field(
    label: string,
    input: HTMLElement,
    hint?: string,
): HTMLElement {
    return el("div", { class: "field" }, [
        el("label", {}, [label]),
        input,
        hint ? el("div", { class: "hint" }, [hint]) : null,
    ]);
}

export function renderWizard(s: AppState): HTMLElement {
    const w = s.wizard;
    const nodename = el("input", {
        type: "text",
        id: "f-nodename",
        value: w.nodename,
        maxlength: 32,
        placeholder: "e.g. Alice's T-Deck",
    });
    const callsign = el("input", {
        type: "text",
        id: "f-callsign",
        value: w.callsign,
        maxlength: 16,
        placeholder: "(optional)",
    });
    const region = el(
        "select",
        { id: "f-region" },
        REGIONS.map((r) =>
            el(
                "option",
                {
                    value: r.freq,
                    selected: w.radio_freq_mhz === r.freq,
                },
                [r.label],
            ),
        ),
    );
    const throttle = el(
        "select",
        { id: "f-throttle" },
        TX_THROTTLES.map((t) =>
            el(
                "option",
                {
                    value: String(t.ms),
                    selected: w.tx_throttle_ms === t.ms,
                },
                [t.label],
            ),
        ),
    );
    const wifiSsid = el("input", {
        type: "text",
        id: "f-wifi-ssid",
        value: w.wifi_ssid,
        placeholder: "(leave blank to skip)",
    });
    const wifiPass = el("input", {
        type: "password",
        id: "f-wifi-pass",
        value: w.wifi_password,
    });
    const tz = el(
        "select",
        { id: "f-tz" },
        TIMEZONES.map((t) =>
            el(
                "option",
                { value: t.tz, selected: w.tz_posix === t.tz },
                [t.label],
            ),
        ),
    );
    const ntp = el("input", {
        type: "checkbox",
        id: "f-ntp",
        checked: w.ntp_on === 1,
    });
    const theme = el(
        "select",
        { id: "f-theme" },
        [
            el("option", { value: "dark", selected: w.theme === "dark" }, ["Dark"]),
            el("option", { value: "light", selected: w.theme === "light" }, ["Light"]),
        ],
    );
    const accent = el(
        "select",
        { id: "f-accent" },
        ACCENT_PRESETS.map((a) =>
            el(
                "option",
                {
                    value: String(a.rgb565),
                    selected: w.accent_color === a.rgb565,
                },
                [a.label],
            ),
        ),
    );
    const bright = el("input", {
        type: "number",
        id: "f-bright",
        value: String(w.screen_bright),
        min: 10,
        max: 255,
    });
    const volume = el("input", {
        type: "number",
        id: "f-volume",
        value: String(w.audio_volume),
        min: 0,
        max: 100,
    });
    const sounds = el("input", {
        type: "checkbox",
        id: "f-sounds",
        checked: w.ui_sounds_on === 1,
    });

    return el("div", {}, [
        stepsBar("wizard"),
        el("p", {}, [
            "Everything here is optional, but anything you fill in skips that on-device onboarding step.",
        ]),
        section("Identity", [
            field(
                "Node name",
                nodename,
                "Shown to other mesh users. ASCII, 32 chars max.",
            ),
            field("Callsign", callsign, "Optional. ASCII, 16 chars max."),
        ]),
        section("Mesh radio", [
            field(
                "Region",
                region,
                "Sets the LoRa carrier frequency. Picking the wrong region is illegal in most countries.",
            ),
            field(
                "TX throttle",
                throttle,
                "Lower = chattier, higher = more conservative on a busy mesh.",
            ),
        ]),
        section("Network", [
            field(
                "WiFi SSID",
                wifiSsid,
                "Auto-connects at boot. Used for NTP and OTA updates.",
            ),
            field("WiFi password", wifiPass),
            field("Timezone", tz),
            el("div", { class: "checkbox" }, [
                ntp,
                el("label", { for: "f-ntp" }, ["Enable NTP clock sync"]),
            ]),
        ]),
        section("Display", [
            field("Theme", theme),
            field("Accent colour", accent),
            field("Brightness", bright, "10 - 255"),
        ]),
        section("Audio", [
            field("Volume", volume, "0 - 100"),
            el("div", { class: "checkbox" }, [
                sounds,
                el("label", { for: "f-sounds" }, ["UI feedback sounds"]),
            ]),
        ]),
        el("div", { class: "btn-row" }, [
            el("button", { class: "btn secondary", id: "btn-back" }, ["Back"]),
            el("span", { class: "spacer" }, []),
            el("button", { class: "btn", id: "btn-next" }, ["Connect and flash"]),
        ]),
    ]);
}

export interface FlashUiState {
    log: string[];
    label: string;
    written: number;
    total: number;
    chip: string | null;
    error: string | null;
    inProgress: boolean;
}

export function renderFlash(s: AppState, fu: FlashUiState): HTMLElement {
    const pct = fu.total > 0 ? Math.min(100, (fu.written / fu.total) * 100) : 0;
    return el("div", {}, [
        stepsBar("flash"),
        el("div", { class: "card" }, [
            el("h1", {}, ["Flashing"]),
            fu.error
                ? el("div", { class: "banner err" }, [fu.error])
                : el("p", { class: "lead" }, [
                      fu.inProgress
                          ? `${fu.label}...`
                          : fu.chip
                          ? "Ready. Don't unplug until this finishes."
                          : "Click below to pick a serial port and start.",
                  ]),
            fu.chip
                ? el("dl", { class: "kv" }, [
                      el("dt", {}, ["Chip"]),
                      el("dd", {}, [fu.chip]),
                      el("dt", {}, ["Release"]),
                      el("dd", {}, [s.release?.tag_name ?? "?"]),
                      el("dt", {}, ["Image"]),
                      el("dd", {}, [s.variant === "full" ? "full" : "app only"]),
                  ])
                : null,
            el("div", { class: "progress" }, [
                el("div", { style: `width: ${pct.toFixed(1)}%;` }, []),
            ]),
            el("pre", { class: "log" }, [fu.log.join("\n")]),
            el("div", { class: "btn-row" }, [
                el(
                    "button",
                    {
                        class: "btn secondary",
                        id: "btn-back",
                        disabled: fu.inProgress ? true : null,
                    },
                    ["Back"],
                ),
                el("span", { class: "spacer" }, []),
                fu.error || !fu.inProgress
                    ? el(
                          "button",
                          {
                              class: "btn",
                              id: "btn-flash",
                              disabled: fu.inProgress ? true : null,
                          },
                          [fu.error ? "Try again" : "Connect and start"],
                      )
                    : null,
            ]),
        ]),
    ]);
}

export function renderDone(s: AppState): HTMLElement {
    return el("div", {}, [
        stepsBar("done"),
        el("div", { class: "card" }, [
            el("h1", {}, ["Done"]),
            el("div", { class: "banner ok" }, [
                "Flash completed. Unplug and replug the device to boot the new firmware.",
            ]),
            s.seedPrefs
                ? el("p", {}, [
                      "Your settings were pre-seeded, so the device should boot straight to the desktop without going through the onboarding wizard.",
                  ])
                : el("p", {}, [
                      "Settings weren't pre-seeded; the device will run its on-device onboarding wizard on first boot.",
                  ]),
            el("div", { class: "btn-row" }, [
                el(
                    "button",
                    { class: "btn secondary", id: "btn-restart" },
                    ["Flash another device"],
                ),
            ]),
        ]),
    ]);
}
