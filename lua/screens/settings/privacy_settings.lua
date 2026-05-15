-- Privacy settings: global toggles for signals the device sends to
-- other nodes about the user's behaviour. Issue #113 introduces the
-- first such toggle (send_read_rcpt for DM read receipts).
--
-- Per-contact overrides aren't in this panel -- they'd live on the
-- contact's detail screen alongside notification mute. v1 covers the
-- global default only.

local ui = require("ezui")

local Privacy = { title = "Privacy" }

local function pref_on(key, default_on)
    local v = ez.storage.get_pref(key, default_on and "1" or "0")
    return v == "1" or v == 1 or v == true
end

local function set_pref_bool(key, on)
    ez.storage.set_pref(key, on and "1" or "0")
end

function Privacy.initial_state()
    return {
        read_receipts = pref_on("send_read_rcpt", false),
    }
end

function Privacy:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Outbound signals",
            { color = "ACCENT", font = "small_aa" }))

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.toggle("Send DM read receipts", state.read_receipts, {
            on_change = function(val)
                set_pref_bool("send_read_rcpt", val)
                self:set_state({ read_receipts = val })
            end,
        }))

    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget(
            "When on, opening a DM conversation tells the sender "
            .. "their message was read. Default off -- some people "
            .. "don't want their reading habits broadcast. "
            .. "Per-contact overrides aren't here yet.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))

    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Delivery acks",
            { color = "ACCENT", font = "small_aa" }))

    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget(
            "DMs already use MeshCore's protocol-level ACK to confirm "
            .. "delivery -- that path is always on and isn't user-"
            .. "tunable. The status dot on your sent bubble flips to "
            .. "green once the ACK lands.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Privacy", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Privacy:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Privacy
