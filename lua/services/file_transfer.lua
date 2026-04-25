-- Peer-to-peer file transfer over a WiFi SoftAP.
--
-- LoRa carries only a short three-frame signalling handshake (OFFER →
-- ACCEPT/DECLINE); the actual file body rides over a tdeck-hosted WiFi
-- link. The sender brings up a SoftAP, the receiver associates with it,
-- and the content streams over TCP. LoRa is too slow for non-trivial
-- files (128-byte chunks at ~1 KB/s); WiFi gives us several hundred
-- KB/s between two tdecks at close range.
--
-- The SSID and WPA2 password are derived from the peers' shared ECDH
-- secret (same one the DM service already caches). Both sides know each
-- other's Ed25519 pubkey because they're contacts, so neither side has
-- to pick or exchange credentials — the derivation is deterministic and
-- unique per peer-pair. An eavesdropper who only sees the broadcast
-- SSID learns nothing useful: it's sha256(secret || "SSID")[:6], which
-- does not reverse back to the secret.
--
-- Protocol frame (inside the custom_packets "FILE" subtype):
--   OP_OFFER   0x10  [op:1][xfer_id:4 LE][size:4 LE][name_len:1][name:N]
--
-- There are no chunk frames — the body goes over WiFi. There's also no
-- explicit ACCEPT frame; we reuse the custom_packets ACK. If the armed
-- receiver accepts the OFFER, its handler returns true and the ACK
-- flows back automatically (the sender watches custom/delivered for
-- our subtype to fire serve_file). If the receiver isn't armed or a
-- handler rejects, the ACK is suppressed and custom/undelivered fires
-- so the sender surfaces "peer declined" instead of hanging the AP.
--
-- The service exposes the same bus events the legacy LoRa-only version
-- did, so the file transfer progress screen doesn't need to change:
--   file/offer     — armed receiver accepted the OFFER
--   file/progress  — transfer boundary events (connect, transferring)
--   file/done      — transfer complete
--   file/error     — transfer aborted (signal fail / connect fail / I/O fail)
--   file/armed     — receiver has armed for the next incoming transfer

local cp = require("services.custom_packets")
local dm = require("services.direct_messages")

local M = {}

local SUBTYPE      = "FILE"
local OP_OFFER     = 0x10

-- TCP port used for the file body. Fixed — both sides derive the rest
-- of the connection from the shared secret, but the port doesn't need
-- any privacy so a constant is fine.
local TCP_PORT = 4243

-- Safety cap on a single transfer. 512 KB is generous for the kind of
-- content tdeck users actually swap (notes, logs, short recordings) and
-- bounds the RAM the receiver's blob buffer can grow to.
local MAX_TRANSFER_BYTES = 512 * 1024

-- AP setup grace. Sender brings up its SoftAP on ACK-of-OFFER receipt,
-- then advertises the TCP port. Receiver waits this long before trying
-- to join so the SSID has a chance to actually start broadcasting —
-- ESP32 WiFi.softAP() returns a couple of seconds before the AP is
-- visible to stations, and a race loses the connect attempt to a
-- "network_not_found" status that the Arduino STA layer bakes in.
local AP_SETTLE_MS       = 2500
local JOIN_TIMEOUT_S     = 20
local TCP_TIMEOUT_MS     = 30000

-- Per-direction in-flight state. Both are keyed by xfer_id so the
-- custom_packets delivered/undelivered dispatcher can look them up.
-- Sender survives screen-pop so a user who walks away from the transfer
-- screen doesn't strand the AP.
local tx = {}   -- [xfer_id] = { pub_key_hex, path, name, data, size, stage }
local rx = {}   -- [xfer_id] = { pub_key_hex, target_path, name, size }

-- Target directory the receiver is armed to accept into. Same semantic
-- as the legacy service: nil = not ready, set by the file manager.
-- Consumed after a successful transfer.
local armed_dir = nil

local initialized = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function pack_u32le(v)
    return string.char(v & 0xFF, (v >> 8) & 0xFF,
                       (v >> 16) & 0xFF, (v >> 24) & 0xFF)
end
local function read_u32le(s, o)
    return s:byte(o) + s:byte(o + 1) * 256
         + s:byte(o + 2) * 65536 + s:byte(o + 3) * 16777216
end

local function basename(path)
    return (path or ""):match("([^/]+)$") or path or "file"
end

local function bytes_to_hex(b, n)
    local out = ""
    for i = 1, n do out = out .. string.format("%02x", b:byte(i)) end
    return out
end

-- Derive the AP SSID + password from the ECDH secret we share with the
-- peer. Yields (X25519 on first call), so must run inside a coroutine.
-- Returns (ssid, password) or (nil, error_string).
--
-- SSID is 15 chars: "td-" + 12 hex. Password is 16 hex chars, which
-- meets WPA2's 8-char minimum. The "SSID" / "PASS" domain strings keep
-- the two outputs cryptographically independent.
local function derive_wifi_creds(peer_pub_key_hex)
    local enc = dm._internal.get_enc_key(peer_pub_key_hex)
    if not enc then return nil, "no shared secret (peer pubkey unknown?)" end
    local ssid_seed = ez.crypto.sha256(enc.secret .. "SSID")
    local pass_seed = ez.crypto.sha256(enc.secret .. "PASS")
    return "td-" .. bytes_to_hex(ssid_seed, 6), bytes_to_hex(pass_seed, 8)
end

-- ---------------------------------------------------------------------------
-- Sender
-- ---------------------------------------------------------------------------

-- Bring up the SoftAP and stream the file body to the first client that
-- connects. Called from a coroutine after the receiver sends ACCEPT.
-- Posts progress + done/error events so the UI can follow along.
local function serve_file(xfer_id)
    local t = tx[xfer_id]
    if not t then return end

    local ssid, pass = derive_wifi_creds(t.pub_key_hex)
    if not ssid then
        tx[xfer_id] = nil
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "tx",
            error   = "key derivation failed: " .. tostring(pass),
        })
        return
    end

    -- max_connection = 1: the file transfer flow is strictly one peer
    -- at a time, so there's no reason to reserve driver state for more.
    -- Frees ~2-3 kB internal heap vs. the 4-client default.
    local ok, err = ez.wifi.start_ap(ssid, pass, 1, false, 1)
    if not ok then
        tx[xfer_id] = nil
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "tx",
            error   = "AP start failed: " .. tostring(err),
        })
        return
    end

    ez.bus.post("file/progress", {
        xfer_id      = xfer_id,
        role         = "tx",
        bytes        = 0,
        size         = t.size,
        chunks_done  = 0,
        chunks_total = 1,
        status       = "AP up; waiting for peer",
    })

    -- tcp_serve_blob blocks until a client connects or the timeout
    -- expires, then streams the whole blob and returns byte count.
    -- Nil signals accept/transfer failure.
    local sent = ez.wifi.tcp_serve_blob(TCP_PORT, t.data, TCP_TIMEOUT_MS)

    ez.wifi.stop_ap()

    if sent and sent == t.size then
        ez.bus.post("file/progress", {
            xfer_id      = xfer_id,
            role         = "tx",
            bytes        = t.size,
            size         = t.size,
            chunks_done  = 1,
            chunks_total = 1,
        })
        ez.bus.post("file/done", {
            xfer_id = xfer_id,
            role    = "tx",
            path    = t.path,
            bytes   = t.size,
        })
    else
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "tx",
            error   = "WiFi serve failed",
        })
    end

    tx[xfer_id] = nil
end

-- ---------------------------------------------------------------------------
-- Receiver
-- ---------------------------------------------------------------------------

-- Join the sender's SoftAP, pull the file body over TCP, save to disk.
-- Runs in a coroutine; posts progress + done/error.
local function fetch_file(xfer_id)
    local r = rx[xfer_id]
    if not r then return end

    local ssid, pass = derive_wifi_creds(r.pub_key_hex)
    if not ssid then
        rx[xfer_id] = nil
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "rx",
            error   = "key derivation failed: " .. tostring(pass),
        })
        return
    end

    -- Give the sender AP_SETTLE_MS to get its AP up and broadcasting
    -- before we try to associate. We use a defer-based yield loop
    -- rather than ez.system.delay() because delay() blocks the entire
    -- main loop in C — which would stall the async workers that still
    -- need to finish crunching the ACK crypto for this very OFFER. The
    -- ACK needs to actually reach the sender for it to bring its AP
    -- up, so blocking here would deadlock both sides.
    local wake_at = ez.system.millis() + AP_SETTLE_MS
    while ez.system.millis() < wake_at do defer() end

    ez.bus.post("file/progress", {
        xfer_id      = xfer_id,
        role         = "rx",
        bytes        = 0,
        size         = r.size,
        chunks_done  = 0,
        chunks_total = 1,
        status       = "Joining sender AP",
    })

    -- Retry-on-WL_NO_SSID_AVAIL: the ESP32 STA driver marks the SSID
    -- "not found" permanently after the first unsuccessful scan, even
    -- if the AP comes up a second later. Each attempt does a fresh
    -- WiFi.begin() and waits JOIN_TIMEOUT_S / attempts; between
    -- attempts we disconnect so the next begin() re-scans.
    local up = false
    local attempts = 5
    local per_attempt = math.max(2, math.floor(JOIN_TIMEOUT_S / attempts))
    for i = 1, attempts do
        ez.wifi.connect(ssid, pass)
        up = ez.wifi.wait_connected(per_attempt)
        if up then break end
        ez.wifi.disconnect()
        local again_at = ez.system.millis() + 1500
        while ez.system.millis() < again_at do defer() end
    end
    if not up then
        ez.wifi.disconnect()
        rx[xfer_id] = nil
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "rx",
            error   = "could not join AP " .. ssid,
        })
        return
    end

    local gw = ez.wifi.get_gateway()
    if not gw or gw == "0.0.0.0" then
        ez.wifi.disconnect()
        rx[xfer_id] = nil
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "rx",
            error   = "no gateway after join",
        })
        return
    end

    ez.bus.post("file/progress", {
        xfer_id      = xfer_id,
        role         = "rx",
        bytes        = 0,
        size         = r.size,
        chunks_done  = 0,
        chunks_total = 1,
        status       = "Transferring",
    })

    local blob = ez.wifi.tcp_fetch_blob(gw, TCP_PORT, r.size, TCP_TIMEOUT_MS)
    ez.wifi.disconnect()

    if not blob then
        rx[xfer_id] = nil
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "rx",
            error   = "TCP fetch failed",
        })
        return
    end

    if #blob ~= r.size then
        rx[xfer_id] = nil
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "rx",
            error   = string.format("size mismatch: got %d, expected %d",
                                    #blob, r.size),
        })
        return
    end

    -- Overwrite anything at the target path. unique_target_path has
    -- already ensured this won't clobber an existing file unless the
    -- dir is 100% full of numbered variants.
    local ok = ez.storage.write_file(r.target_path, blob)
    if not ok then
        rx[xfer_id] = nil
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "rx",
            error   = "write failed: " .. r.target_path,
        })
        return
    end

    ez.bus.post("file/progress", {
        xfer_id      = xfer_id,
        role         = "rx",
        bytes        = #blob,
        size         = r.size,
        chunks_done  = 1,
        chunks_total = 1,
    })
    ez.bus.post("file/done", {
        xfer_id = xfer_id,
        role    = "rx",
        path    = r.target_path,
        bytes   = #blob,
    })

    rx[xfer_id] = nil
    armed_dir = nil
end

-- Uniqueness-protect the target path so a fresh transfer of the same
-- name doesn't overwrite a local copy the user wanted to keep.
local function unique_target_path(path)
    if not ez.storage.exists(path) then return path end
    local dir, stem, ext = path:match("^(.-/)([^/]-)(%.[^/.]+)$")
    if not dir then
        dir, stem = path:match("^(.-/)([^/]+)$")
        ext = ""
    end
    for n = 1, 99 do
        local candidate = dir .. stem .. "-" .. n .. ext
        if not ez.storage.exists(candidate) then return candidate end
    end
    return path
end

-- ---------------------------------------------------------------------------
-- Protocol dispatch
-- ---------------------------------------------------------------------------

local function on_file_frame(sender_pub, data, meta)
    if #data < 5 then return false end
    local op = data:byte(1)
    local xfer_id = read_u32le(data, 2)

    if op == OP_OFFER then
        -- Idempotent for sender retries on the OFFER.
        if rx[xfer_id] then return true end
        if not armed_dir then return false end   -- receiver not ready
        if #data < 10 then return false end

        local size     = read_u32le(data, 6)
        local name_len = data:byte(10)
        if #data < 10 + name_len then return false end
        if size > MAX_TRANSFER_BYTES then return false end
        local name = data:sub(11, 10 + name_len)

        -- Only one active receive at a time; reject a different
        -- transfer while one's in flight.
        for existing_id, _ in pairs(rx) do
            if existing_id ~= xfer_id then return false end
        end

        name = basename(name)
        local target = armed_dir
        if target:sub(-1) ~= "/" then target = target .. "/" end
        target = unique_target_path(target .. name)
        local saved_name = basename(target)

        rx[xfer_id] = {
            pub_key_hex = sender_pub,
            target_path = target,
            name        = saved_name,
            size        = size,
        }

        ez.bus.post("file/offer", {
            xfer_id     = xfer_id,
            sender_pub  = sender_pub,
            sender_name = meta and meta.name,
            name        = saved_name,
            original    = name,
            renamed     = saved_name ~= name,
            size        = size,
            chunks      = 1,           -- legacy screen shows N/N — WiFi is monolithic
            target_path = target,
        })

        -- Kick off the fetch. Returning true here causes the
        -- custom_packets layer to send an ACK back to the sender; the
        -- sender watches custom/delivered for our subtype and brings
        -- the AP up when it fires. That implicit ACK replaces a
        -- dedicated ACCEPT frame.
        local id = xfer_id
        spawn(function() fetch_file(id) end)
        return true
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Public API (identical shape to the legacy LoRa service)
-- ---------------------------------------------------------------------------

function M.arm_receive(target_dir)
    armed_dir = target_dir
    ez.bus.post("file/armed", { dir = armed_dir })
end

function M.is_armed()
    return armed_dir ~= nil, armed_dir
end

-- Initiate an outbound transfer. Returns (xfer_id, name, 1) on success
-- or (nil, error). The `chunks=1` return is a compatibility knob for
-- the progress screen which expects three values — WiFi transfers are
-- monolithic so "1 chunk of N bytes" is what we report.
function M.send(pub_key_hex, path)
    local content = ez.storage.read_file(path)
    if not content then return nil, "read failed: " .. path end
    if #content == 0 then return nil, "empty file" end
    if #content > MAX_TRANSFER_BYTES then
        return nil, string.format("too large (%d > %d)",
            #content, MAX_TRANSFER_BYTES)
    end

    local name = basename(path)
    if #name > 255 then return nil, "name too long" end

    local xfer_id = math.random(1, 0x7FFFFFFF)

    tx[xfer_id] = {
        pub_key_hex = pub_key_hex,
        path        = path,
        name        = name,
        data        = content,
        size        = #content,
        stage       = "offered",
    }

    local frame = string.char(OP_OFFER) .. pack_u32le(xfer_id)
        .. pack_u32le(#content) .. string.char(#name) .. name
    cp.send(pub_key_hex, SUBTYPE, frame, { ack = true })

    return xfer_id, name, 1
end

function M.cancel(xfer_id)
    if tx[xfer_id] then
        local t = tx[xfer_id]
        tx[xfer_id] = nil
        -- If the AP was already up (serving stage), tear it down so a
        -- user who backs out of the transfer screen doesn't leave an
        -- open SoftAP broadcasting indefinitely.
        if t.stage == "serving" then
            ez.wifi.stop_ap()
        end
        ez.bus.post("file/error", {
            xfer_id = xfer_id, role = "tx", error = "cancelled",
        })
    end
end

function M.get_tx_state(xfer_id) return tx[xfer_id] end
function M.get_rx_state(xfer_id) return rx[xfer_id] end

function M.init()
    if initialized then return end
    initialized = true

    cp.register({
        id         = "file_transfer",
        label      = "File transfer",
        subtype    = SUBTYPE,
        on_receive = on_file_frame,
    })

    -- When the OFFER we just sent gets ACK'd by a receiver that
    -- accepted it, transition to serving. The custom_packets ACK is
    -- the implicit "I'll take it" signal — we don't need a separate
    -- ACCEPT frame. A non-armed / different-xfer receiver returns
    -- false in its handler, which suppresses the ACK and drives the
    -- undelivered branch below instead.
    ez.bus.subscribe("custom/delivered", function(_topic, info)
        if not info or info.subtype ~= SUBTYPE then return end
        for xfer_id, t in pairs(tx) do
            if t.pub_key_hex == info.pub_key_hex
                    and t.stage == "offered" then
                t.stage = "serving"
                spawn(function() serve_file(xfer_id) end)
                return
            end
        end
    end)

    ez.bus.subscribe("custom/undelivered", function(_topic, info)
        if not info or info.subtype ~= SUBTYPE then return end
        for xfer_id, t in pairs(tx) do
            if t.pub_key_hex == info.pub_key_hex
                    and t.stage == "offered" then
                tx[xfer_id] = nil
                ez.bus.post("file/error", {
                    xfer_id = xfer_id, role = "tx",
                    error   = "OFFER not delivered (peer not armed?)",
                })
                return
            end
        end
    end)

    ez.log("[FileTransfer] Service initialized (WiFi body)")
end

return M
