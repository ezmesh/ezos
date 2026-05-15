-- Signal tester: scoped responder + initiator for screens/tools/signal_test.
--
-- Not auto-installed at boot. The screen calls M.start() on on_enter and
-- M.stop() on on_exit, so the pingpong only runs while BOTH devices have
-- the tester open. That matches how the user wants to test: deliberate,
-- no background radio traffic, and nothing to clean up afterwards.
--
-- Both sides also need to have each other as contacts so ECDH can derive
-- a shared secret for the replies. The screen's contact picker enforces
-- this on the initiator side; the responder's DM / custom-packet
-- decryptors already fall back to "seen mesh node" if a contact isn't
-- present, but a contact is the reliable path and is what we recommend.
--
-- Transports
--   Direct (custom_packets SUBTYPE "SIGT")
--     Wire payload: [kind:1][nonce:N], kind='P' ping, kind='R' reply.
--     RAW_CUSTOM is not re-flooded by stock MeshCore repeaters, so the
--     RSSI charted in this mode reflects raw direct radio contact.
--   DM (TXT_MSG)
--     Text is a sharing URL: "https://ezme.sh/#sigt/v1?k=P&n=<nonce>"
--     for pings and "...?k=R&n=<nonce>" for replies. Goes through the
--     normal encrypted DM path, which WILL be forwarded by repeaters —
--     the chart then reflects last-hop RSSI, not end-to-end. The chat
--     screens filter these out of conversation views (the URL is a
--     protocol carrier, not user-readable chatter).
--
-- The `signal_test/sample` bus event fires with:
--   { mode, pub_key_hex, nonce, rssi, snr, t_ms, name }
-- regardless of which transport produced the reply, so the chart screen
-- can treat both modes uniformly.

local cp = require("services.custom_packets")
local sharing = require("services.sharing")

local M = {}

local SUBTYPE = "SIGT"
-- Legacy DM text format used before the ezme.sh URL switch. Kept so
-- purge_dm_history can still clean up stranded entries on devices
-- that upgraded mid-conversation, and so the inbound classifier
-- treats them as protocol traffic during an active test instead of
-- letting them resurface as chat bubbles.
local LEGACY_DM_PREFIX = "[SIGT]"
local LEGACY_PING_TAG = "P "
local LEGACY_PONG_TAG = "R "

local active    = false
local dm_sub_id = nil

-- Parse a DM body as a SIGT carrier. Accepts both the new ezme.sh
-- URL form emitted by sharing.encode_sigt and the legacy text form
-- ("[SIGT]P <nonce>" / "[SIGT]R <nonce>") so this firmware can sweep
-- and recognise pingpong entries that landed in history before the
-- URL change. Returns { kind, nonce } on a match or nil.
local function parse_dm(text)
    if type(text) ~= "string" or text == "" then return nil end
    local share = sharing.parse(text)
    if share and share.kind == "sigt" then
        return { kind = share.sigt_kind, nonce = share.nonce }
    end
    if text:sub(1, #LEGACY_DM_PREFIX) == LEGACY_DM_PREFIX then
        local tag = text:sub(#LEGACY_DM_PREFIX + 1, #LEGACY_DM_PREFIX + 2)
        if tag == LEGACY_PING_TAG or tag == LEGACY_PONG_TAG then
            return {
                kind  = tag:sub(1, 1),
                nonce = text:sub(#LEGACY_DM_PREFIX + #LEGACY_PING_TAG + 1),
            }
        end
    end
    return nil
end

-- True when this device has the signal test screen open right now.
-- Used by direct_messages to decide whether a SIGT-shaped DM should
-- be stamped as a protocol carrier and hidden from the chat surface,
-- closing the silent-send vector where a peer could otherwise hand-
-- type a SIGT URL and have it disappear from the recipient's UI. The
-- predicate is scope-by-time-window rather than per-peer because the
-- responder side runs purely off incoming events and has no chosen
-- peer until the first ping arrives.
function M.matches_protocol(msg)
    if not active then return false end
    if not msg or type(msg.text) ~= "string" then return false end
    return parse_dm(msg.text) ~= nil
end

-- Both kinds post a sample so BOTH peers chart a live RSSI trace:
--   P (ping)   → responder side; RSSI is the incoming ping's reception
--   R (reply)  → initiator side; RSSI is the incoming reply's reception
-- Both measure a radio link between the same two nodes; the values are
-- just sampled at different ends. With a single initiator pinging every
-- PING_INTERVAL_MS the two traces advance in lock-step.
local function on_custom_receive(sender_pub, data, meta)
    if #data < 1 then return end
    local kind  = data:sub(1, 1)
    local nonce = data:sub(2)
    local post_sample = function(k)
        ez.bus.post("signal_test/sample", {
            mode        = "direct",
            kind        = k,
            pub_key_hex = sender_pub,
            nonce       = nonce,
            rssi        = meta.rssi,
            snr         = meta.snr,
            name        = meta.name,
            t_ms        = ez.system.millis(),
        })
    end
    if kind == "P" then
        post_sample("P")
        spawn(function()
            cp.send(sender_pub, SUBTYPE, "R" .. nonce)
        end)
    elseif kind == "R" then
        post_sample("R")
    end
end

local function on_dm_message(_topic, msg)
    if not msg or msg.is_self then return end
    local parsed = parse_dm(msg.text)
    if not parsed then return end

    ez.bus.post("signal_test/sample", {
        mode        = "dm",
        kind        = parsed.kind,
        pub_key_hex = msg.sender_key,
        nonce       = parsed.nonce,
        rssi        = msg.rssi,
        snr         = msg.snr,
        name        = msg.sender_name,
        t_ms        = ez.system.millis(),
    })

    if parsed.kind == "P" then
        local dm = require("services.direct_messages")
        local url = sharing.encode_sigt("R", parsed.nonce)
        if url then dm.send(msg.sender_key, url, { protocol = "sigt" }) end
    end
end

-- Install receive hooks. Idempotent — calling start() while already
-- active is a no-op so the screen can safely call it from on_enter even
-- if a prior exit path somehow skipped stop().
function M.start()
    if active then return end
    active = true
    cp.register({
        id         = "signal_test",
        label      = "Signal Test",
        subtype    = SUBTYPE,
        on_receive = on_custom_receive,
    })
    dm_sub_id = ez.bus.subscribe("dm/message", on_dm_message)
    ez.log("[SignalTest] responder active")
end

function M.stop()
    if not active then return end
    active = false
    cp.unregister(SUBTYPE)
    if dm_sub_id then
        ez.bus.unsubscribe(dm_sub_id)
        dm_sub_id = nil
    end
    ez.log("[SignalTest] responder stopped")
end

function M.is_active()
    return active
end

-- Originator helpers. Callers generate a unique nonce per ping; the
-- sample event only carries that nonce back, so the caller correlates
-- send_ms to reply_ms for latency / loss tracking.

function M.ping_direct(pub_key_hex, nonce)
    spawn(function()
        cp.send(pub_key_hex, SUBTYPE, "P" .. nonce)
    end)
end

function M.ping_dm(pub_key_hex, nonce)
    local dm = require("services.direct_messages")
    local url = sharing.encode_sigt("P", nonce)
    if url then dm.send(pub_key_hex, url, { protocol = "sigt" }) end
end

-- After a DM-mode run, the pings/replies sit in the regular DM history
-- with the peer. This sweeps them out so the operator's chat isn't
-- cluttered. Recognizes only strings parse_dm() accepts, so regular
-- chat text is untouched.
function M.purge_dm_history(pub_key_hex)
    local dm = require("services.direct_messages")
    local h = dm.get_history(pub_key_hex)
    if not h then return 0 end
    local removed = 0
    for i = #h, 1, -1 do
        if parse_dm(h[i].text) then
            dm.delete_message(pub_key_hex, i)
            removed = removed + 1
        end
    end
    return removed
end

return M
