// GitHub releases feed for ezmesh/ezos with localStorage cache.
//
// Unauthenticated api.github.com is rate-limited to 60 req/hour per IP. We
// cache the full release list for an hour and surface a stale-cache fallback
// if the network call fails.

export interface Asset {
    name: string;
    size: number;
    browser_download_url: string;
}

export interface Release {
    tag_name: string;
    name: string;
    published_at: string;
    prerelease: boolean;
    draft: boolean;
    html_url: string;
    body: string;
    assets: Asset[];
    channel: "stable" | "rolling-main" | "rolling-test" | "tagged";
}

const REPO = "ezmesh/ezos";
const CACHE_KEY = "ezos-console:releases";
const CACHE_TTL_MS = 60 * 60 * 1000; // 1 hour

interface CacheEntry {
    fetchedAt: number;
    releases: Release[];
}

function classifyChannel(r: { tag_name: string; prerelease: boolean }): Release["channel"] {
    if (r.tag_name === "rolling-main") return "rolling-main";
    if (r.tag_name === "rolling-test") return "rolling-test";
    if (r.prerelease) return "tagged";
    return "stable";
}

function readCache(): CacheEntry | null {
    try {
        const raw = localStorage.getItem(CACHE_KEY);
        if (!raw) return null;
        return JSON.parse(raw) as CacheEntry;
    } catch {
        return null;
    }
}

function writeCache(entry: CacheEntry) {
    try {
        localStorage.setItem(CACHE_KEY, JSON.stringify(entry));
    } catch {
        // localStorage full / disabled -- silently skip.
    }
}

export async function fetchReleases(opts: { force?: boolean } = {}): Promise<Release[]> {
    const cached = readCache();
    const fresh =
        cached && !opts.force && Date.now() - cached.fetchedAt < CACHE_TTL_MS;
    if (fresh) return cached!.releases;

    try {
        const res = await fetch(`https://api.github.com/repos/${REPO}/releases`, {
            headers: { Accept: "application/vnd.github+json" },
        });
        if (!res.ok) {
            throw new Error(`GitHub returned ${res.status}`);
        }
        const json = (await res.json()) as Array<Omit<Release, "channel">>;
        const releases: Release[] = json
            .filter((r) => !r.draft)
            .map((r) => ({ ...r, channel: classifyChannel(r) }))
            // rolling-main first (latest stable build), then rolling-test
            // (preview), then stable tagged releases, then other tagged.
            .sort((a, b) => {
                const rank = (c: Release["channel"]) =>
                    c === "rolling-main" ? 0 :
                    c === "rolling-test" ? 1 :
                    c === "stable"       ? 2 : 3;
                const r = rank(a.channel) - rank(b.channel);
                return r !== 0
                    ? r
                    : new Date(b.published_at).getTime() -
                          new Date(a.published_at).getTime();
            });
        writeCache({ fetchedAt: Date.now(), releases });
        return releases;
    } catch (err) {
        if (cached) {
            console.warn("GitHub fetch failed, using stale cache:", err);
            return cached.releases;
        }
        throw err;
    }
}

export interface FlashImage {
    /** URL of the full bootloader+partitions+app merged binary. */
    fullUrl: string;
    fullName: string;
    fullSize: number;
    /** URL of the app-only image (for update flows). May be undefined. */
    appUrl?: string;
    appName?: string;
    appSize?: number;
    /**
     * URLs of the signed manifest and detached Ed25519 signature, if the
     * release publishes them (every rolling-main / rolling-test build
     * does; tagged releases from build-release.yml currently don't).
     * The console refuses to flash a release without these.
     */
    manifestUrl?: string;
    sigUrl?: string;
}

export function isSigned(image: FlashImage): boolean {
    return !!(image.manifestUrl && image.sigUrl);
}

/**
 * Pick the flashable images out of a release. Handles both:
 *   - rolling releases (firmware.bin / firmware-full.bin)
 *   - tagged releases (ezos-<version>.bin / ezos-<version>-full.bin)
 */
export function pickImages(release: Release): FlashImage | null {
    const full =
        release.assets.find((a) => a.name === "firmware-full.bin") ??
        release.assets.find((a) => /-full\.bin$/.test(a.name));
    if (!full) return null;
    const app =
        release.assets.find((a) => a.name === "firmware.bin") ??
        release.assets.find(
            (a) => /\.bin$/.test(a.name) && !/full|bootloader|partitions/i.test(a.name),
        );
    const manifest = release.assets.find((a) => a.name === "manifest.json");
    const sig = release.assets.find((a) => a.name === "manifest.json.sig");
    return {
        fullUrl: full.browser_download_url,
        fullName: full.name,
        fullSize: full.size,
        appUrl: app?.browser_download_url,
        appName: app?.name,
        appSize: app?.size,
        manifestUrl: manifest?.browser_download_url,
        sigUrl: sig?.browser_download_url,
    };
}
