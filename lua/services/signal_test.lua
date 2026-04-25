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
--     Text: "[SIGT]P <nonce>" / "[SIGT]R <nonce>". Goes through the
--     normal encrypted DM path, which WILL be forwarded by repeaters —
--     the chart then reflects last-hop RSSI, not end-to-end.
--
-- The `signal_test/sample` bus event fires with:
--   { mode, pub_key_hex, nonce, rssi, snr, t_ms, name }
-- regardless of which transport produced the reply, so the chart screen
-- can treat both modes uniformly.

local cp = require("services.custom_packets")

local M = {}

local SUBTYPE     = "SIGT"
local DM_PREFIX   = "[SIGT]"
local DM_PING_TAG = "P "
local DM_PONG_TAG = "R "

local active    = false
local dm_sub_id = nil

local function parse_dm(text)
    if not text or #text < (#DM_PREFIX + 3) then return nil end
    if text:sub(1, #DM_PREFIX) ~= DM_PREFIX then return nil end
    local tag = text:sub(#DM_PREFIX + 1, #DM_PREFIX + 2)
    if tag ~= DM_PING_TAG and tag ~= DM_PONG_TAG then return nil end
    return {
        kind  = tag:sub(1, 1),
        nonce = text:sub(#DM_PREFIX + #DM_PING_TAG + 1),
    }
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
        dm.send(msg.sender_key, DM_PREFIX .. DM_PONG_TAG .. parsed.nonce)
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
    dm.send(pub_key_hex, DM_PREFIX .. DM_PING_TAG .. nonce)
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
