// Main controller: holds state, dispatches step rendering, wires events.

import { mount } from "./dom";
import {
    renderCompat,
    renderRelease,
    renderVariant,
    renderWizard,
    renderFlash,
    renderDone,
    type FlashUiState,
} from "./steps";
import { fetchReleases, pickImages, type Release } from "../github/releases";
import { makeState, buildSeedValues, type AppState, type Variant } from "./state";
import { encodeNvsImage } from "../nvs/encoder";
import {
    Flasher,
    downloadBinary,
    FULL_OFFSET,
    APP_OFFSET,
    NVS_OFFSET,
    type FlashFile,
} from "../flash/esptool";

export class App {
    private state: AppState = makeState();
    private releases: Release[] | null = null;
    private releaseError: string | null = null;
    private flashUi: FlashUiState = {
        log: [],
        label: "",
        written: 0,
        total: 0,
        chip: null,
        error: null,
        inProgress: false,
    };

    constructor(private readonly root: HTMLElement) {}

    start() {
        if (!("serial" in navigator)) {
            this.state.step = "compat";
            this.render();
            return;
        }
        this.state.step = "welcome";
        this.render();
    }

    private render(): void {
        switch (this.state.step) {
            case "compat":
                mount(this.root, renderCompat(false));
                break;
            case "welcome":
                mount(this.root, renderCompat(true));
                this.bindWelcome();
                break;
            case "release":
                mount(
                    this.root,
                    renderRelease(this.releases, this.releaseError, this.state.release),
                );
                this.bindRelease();
                break;
            case "variant":
                if (!this.state.release || !this.state.images) {
                    this.state.step = "release";
                    return this.render();
                }
                mount(
                    this.root,
                    renderVariant(
                        this.state.release,
                        this.state.images,
                        this.state.variant,
                        this.state.eraseNvs,
                        this.state.seedPrefs,
                    ),
                );
                this.bindVariant();
                break;
            case "wizard":
                mount(this.root, renderWizard(this.state));
                this.bindWizard();
                break;
            case "flash":
                mount(this.root, renderFlash(this.state, this.flashUi));
                this.bindFlash();
                break;
            case "done":
                mount(this.root, renderDone(this.state));
                this.bindDone();
                break;
        }
        // Auto-scroll to top whenever we re-render (different step or a
        // mid-step refresh) so users always see the header / new content.
        this.root.scrollIntoView({ behavior: "instant" as ScrollBehavior, block: "start" });
    }

    private goto(step: AppState["step"]) {
        this.state.step = step;
        this.render();
    }

    private bindWelcome() {
        this.root.querySelector("#btn-start")?.addEventListener("click", () => {
            this.goto("release");
            this.loadReleases();
        });
    }

    private async loadReleases() {
        this.releases = null;
        this.releaseError = null;
        this.render();
        try {
            this.releases = await fetchReleases();
        } catch (err) {
            this.releaseError = err instanceof Error ? err.message : String(err);
            this.releases = [];
        }
        this.render();
    }

    private bindRelease() {
        this.root.querySelectorAll(".release-item").forEach((node) => {
            node.addEventListener("click", () => {
                const tag = (node as HTMLElement).dataset.tag!;
                const release = this.releases?.find((r) => r.tag_name === tag);
                if (!release) return;
                this.state.release = release;
                this.state.images = pickImages(release);
                this.render();
            });
        });
        this.root.querySelector("#btn-back")?.addEventListener("click", () => {
            this.goto("welcome");
        });
        this.root.querySelector("#btn-next")?.addEventListener("click", () => {
            if (!this.state.release || !this.state.images) return;
            // Default to "app" if the release lacks a full image -- shouldn't
            // happen with our build, but be defensive.
            if (!this.state.images.fullSize) this.state.variant = "app";
            this.goto("variant");
        });
    }

    private bindVariant() {
        this.root.querySelectorAll<HTMLInputElement>("input[name='variant']").forEach(
            (input) => {
                input.addEventListener("change", () => {
                    if (input.checked) this.state.variant = input.value as Variant;
                });
            },
        );
        this.root
            .querySelector<HTMLInputElement>("#chk-seed")
            ?.addEventListener("change", (e) => {
                this.state.seedPrefs = (e.target as HTMLInputElement).checked;
                // Re-render to update the Continue button label.
                this.render();
            });
        this.root
            .querySelector<HTMLInputElement>("#chk-erase")
            ?.addEventListener("change", (e) => {
                this.state.eraseNvs = (e.target as HTMLInputElement).checked;
                this.render();
            });
        this.root.querySelector("#btn-back")?.addEventListener("click", () => {
            this.goto("release");
        });
        this.root.querySelector("#btn-next")?.addEventListener("click", () => {
            this.goto(this.state.seedPrefs ? "wizard" : "flash");
        });
    }

    private bindWizard() {
        const w = this.state.wizard;
        const bindText = (id: string, key: keyof typeof w) => {
            this.root.querySelector<HTMLInputElement>(id)?.addEventListener("input", (e) => {
                (w as any)[key] = (e.target as HTMLInputElement).value;
            });
        };
        const bindSelect = (id: string, key: keyof typeof w, asNumber = false) => {
            this.root
                .querySelector<HTMLSelectElement>(id)
                ?.addEventListener("change", (e) => {
                    const v = (e.target as HTMLSelectElement).value;
                    (w as any)[key] = asNumber ? Number(v) : v;
                });
        };
        const bindNumber = (id: string, key: keyof typeof w) => {
            this.root.querySelector<HTMLInputElement>(id)?.addEventListener("input", (e) => {
                (w as any)[key] = Number((e.target as HTMLInputElement).value);
            });
        };
        const bindCheck = (id: string, key: keyof typeof w) => {
            this.root.querySelector<HTMLInputElement>(id)?.addEventListener("change", (e) => {
                (w as any)[key] = (e.target as HTMLInputElement).checked ? 1 : 0;
            });
        };

        bindText("#f-nodename", "nodename");
        bindText("#f-callsign", "callsign");
        bindSelect("#f-region", "radio_freq_mhz");
        bindSelect("#f-throttle", "tx_throttle_ms", true);
        bindText("#f-wifi-ssid", "wifi_ssid");
        bindText("#f-wifi-pass", "wifi_password");
        bindSelect("#f-tz", "tz_posix");
        bindCheck("#f-ntp", "ntp_on");
        bindSelect("#f-theme", "theme");
        bindSelect("#f-accent", "accent_color", true);
        bindNumber("#f-bright", "screen_bright");
        bindNumber("#f-volume", "audio_volume");
        bindCheck("#f-sounds", "ui_sounds_on");

        this.root.querySelector("#btn-back")?.addEventListener("click", () => {
            this.goto("variant");
        });
        this.root.querySelector("#btn-next")?.addEventListener("click", () => {
            this.goto("flash");
        });
    }

    private bindFlash() {
        this.root.querySelector("#btn-back")?.addEventListener("click", () => {
            this.goto(this.state.seedPrefs ? "wizard" : "variant");
        });
        this.root.querySelector("#btn-flash")?.addEventListener("click", () => {
            void this.runFlash();
        });
    }

    private bindDone() {
        this.root.querySelector("#btn-restart")?.addEventListener("click", () => {
            this.state = makeState();
            this.flashUi = {
                log: [],
                label: "",
                written: 0,
                total: 0,
                chip: null,
                error: null,
                inProgress: false,
            };
            this.start();
        });
    }

    private appendLog(line: string) {
        this.flashUi.log.push(line);
        if (this.flashUi.log.length > 200) {
            this.flashUi.log.splice(0, this.flashUi.log.length - 200);
        }
        this.render();
    }

    private async runFlash() {
        if (!this.state.release || !this.state.images) {
            this.flashUi.error = "no release selected";
            this.render();
            return;
        }
        this.flashUi = {
            log: [],
            label: "starting",
            written: 0,
            total: 0,
            chip: null,
            error: null,
            inProgress: true,
        };
        this.render();

        const flasher = new Flasher();
        try {
            this.appendLog("Requesting serial port...");
            const { chip } = await flasher.connect({
                onLog: (s) => this.appendLog(s.trim()),
            });
            this.flashUi.chip = chip;
            this.appendLog(`Detected chip: ${chip}`);

            const files: FlashFile[] = [];

            const imageUrl =
                this.state.variant === "full"
                    ? this.state.images.fullUrl
                    : this.state.images.appUrl ?? this.state.images.fullUrl;
            const imageOffset =
                this.state.variant === "full" ? FULL_OFFSET : APP_OFFSET;

            this.appendLog(`Downloading ${imageUrl}...`);
            const fwBytes = await downloadBinary(imageUrl, (rec, total) => {
                this.flashUi.label = "downloading firmware";
                this.flashUi.written = rec;
                this.flashUi.total = total || rec;
                this.render();
            });
            this.appendLog(`Downloaded ${fwBytes.length} bytes.`);
            files.push({
                address: imageOffset,
                data: fwBytes,
                label:
                    this.state.variant === "full" ? "firmware (full)" : "firmware (app)",
            });

            if (this.state.seedPrefs) {
                this.appendLog("Encoding NVS partition image...");
                const nvs = encodeNvsImage(buildSeedValues(this.state));
                this.appendLog(`NVS image: ${nvs.length} bytes.`);
                files.push({
                    address: NVS_OFFSET,
                    data: nvs,
                    label: "NVS (settings)",
                });
            }

            await flasher.flash({
                files,
                eraseAll: this.state.eraseNvs,
                onLog: (s) => this.appendLog(s),
                onProgress: (label, written, total) => {
                    this.flashUi.label = label;
                    this.flashUi.written = written;
                    this.flashUi.total = total;
                    this.render();
                },
            });

            this.appendLog("Resetting device...");
            await flasher.hardReset();
            await flasher.disconnect();
            this.flashUi.inProgress = false;
            this.appendLog("Done.");
            this.goto("done");
        } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            this.flashUi.error = msg;
            this.flashUi.inProgress = false;
            this.appendLog(`ERROR: ${msg}`);
            await flasher.disconnect().catch(() => {});
            this.render();
        }
    }
}
