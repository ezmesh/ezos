-- services.link_quality: per-peer RSSI ring buffer used by the map's
-- "Observed coverage" overlay (issue #121).
--
-- Subscribes once to `mesh/node_discovered` and records the rssi field
-- for each peer keyed by pub_key_hex. The map overlay then asks
-- `get_quality(pub_key_hex)` for a coarse bucket so it can render
-- concentric rings sized by the user-to-peer distance.
--
-- Deliberately tiny: 16 samples per peer, in-memory only. The signal
-- describes a packet, not a node, so persisting it across reboots
-- would just leak stale numbers. Same reasoning as the node store's
-- decision NOT to persist lastRssi (see Node Store section of
-- CLAUDE.md).

local M = {}

-- Cap per peer. The issue suggests "start with 16"; 16 is plenty for
-- a stable median without bloating RAM (we keep this for every peer
-- we've ever heard, bounded only by what the node table holds).
local MAX_SAMPLES = 16

-- Time window for "recent" samples. The overlay hides peers with
-- fewer than MIN_RECENT samples inside this window so a single
-- ancient ADVERT does not paint a misleading ring.
local RECENT_WINDOW_MS = 60 * 60 * 1000  -- 1 hour
local MIN_RECENT       = 4

-- RSSI bucket thresholds (dBm). LoRa link quality is roughly:
--   >= -90  good          (clear comms, multi-km in open air)
--   >= -110 marginal      (decodes but loss climbs)
--   <  -110 poor          (intermittent, near the noise floor)
-- These are heuristics; we surface them through a coarse bucket
-- because the underlying number is noisy and meaningless to most
-- users without context.
local RSSI_GOOD     = -90
local RSSI_MARGINAL = -110

-- samples[pub_key_hex] = { { rssi = number, t_ms = millis }, ... }
local samples = {}
local subscribed = false

local function now_ms()
    return ez.system.millis()
end

-- Insert a sample, dropping the oldest once we hit MAX_SAMPLES.
local function record(pub_key_hex, rssi)
    if type(pub_key_hex) ~= "string" or pub_key_hex == "" then return end
    if type(rssi) ~= "number" then return end
    -- Filter out the C++ default of 0 dBm (means "no measurement"
    -- on this code path, not "a perfect packet"). Real LoRa RSSI is
    -- always negative in our deployment.
    if rssi >= 0 then return end

    local ring = samples[pub_key_hex]
    if not ring then
        ring = {}
        samples[pub_key_hex] = ring
    end
    ring[#ring + 1] = { rssi = rssi, t_ms = now_ms() }
    if #ring > MAX_SAMPLES then
        table.remove(ring, 1)
    end
end

-- Median of an array of numbers. Stable for short lists (we sort a
-- copy, so the caller's array is left alone). Returns nil for empty.
local function median(values)
    local n = #values
    if n == 0 then return nil end
    local sorted = {}
    for i = 1, n do sorted[i] = values[i] end
    table.sort(sorted)
    if n % 2 == 1 then return sorted[(n + 1) // 2] end
    return (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

-- get_quality(pub_key_hex) -> { bucket, rssi, samples } or nil
--
-- bucket  "good" | "marginal" | "poor"
-- rssi    smoothed (median) RSSI in dBm
-- samples count of samples used (inside RECENT_WINDOW_MS)
--
-- Returns nil when the peer is unknown or has fewer than MIN_RECENT
-- recent samples. The overlay treats nil as "skip this peer".
function M.get_quality(pub_key_hex)
    if type(pub_key_hex) ~= "string" then return nil end
    local ring = samples[pub_key_hex]
    if not ring then return nil end

    local cutoff = now_ms() - RECENT_WINDOW_MS
    local recent = {}
    for _, s in ipairs(ring) do
        if s.t_ms >= cutoff then
            recent[#recent + 1] = s.rssi
        end
    end
    if #recent < MIN_RECENT then return nil end

    local r = median(recent)
    local bucket
    if r >= RSSI_GOOD then
        bucket = "good"
    elseif r >= RSSI_MARGINAL then
        bucket = "marginal"
    else
        bucket = "poor"
    end
    return { bucket = bucket, rssi = r, samples = #recent }
end

-- Test seam: feed a sample manually. Used by host-side bench and the
-- packet sniffer's signal-test mode; not part of the public surface.
function M._record(pub_key_hex, rssi)
    record(pub_key_hex, rssi)
end

-- Test seam: wipe all state. Not on the public surface either.
function M._reset()
    samples = {}
end

function M.init()
    if subscribed then return end
    subscribed = true
    -- mesh/node_discovered fires on every ADVERT we successfully
    -- parse. The payload carries pub_key_hex (when the ADVERT
    -- included a pubkey, which is always for chat/repeater/room
    -- adverts) and rssi as float dBm.
    ez.bus.subscribe("mesh/node_discovered", function(_topic, node)
        if not node then return end
        record(node.pub_key_hex, node.rssi)
    end)
end

return M
