-- Per-channel settings sheet. Reachable from the channel chat's
-- Alt+M menu. Lets the user tune history retention, notification
-- mode, and visibility, plus leave non-Public channels.

local ui            = require("ezui")
local screen_mod    = require("ezui.screen")
local channels_svc  = require("services.channels")

local ChannelSettings = { title = "Channel" }

local HISTORY_LABELS = { "None", "50",  "200", "500", "1000" }
local HISTORY_VALUES = { 0,      50,    200,   500,   1000 }

local NOTIFY_LABELS  = { "All messages", "Mentions only", "None" }
local NOTIFY_VALUES  = { "all",          "mentions",      "none" }

local function index_of(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return 1
end

function ChannelSettings.initial_state(channel_name)
    local hist  = channels_svc.get_history_limit(channel_name)
    local mode  = channels_svc.get_notify_mode(channel_name)
    local info  = channels_svc.get_info(channel_name) or {}
    return {
        channel    = channel_name,
        hist_idx   = index_of(HISTORY_VALUES, hist),
        notify_idx = index_of(NOTIFY_VALUES,  mode),
        hidden     = info.hidden and true or false,
    }
end

function ChannelSettings:build(state)
    local channel = state.channel or "#Public"
    local is_public = (channel == "#Public")
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget(channel, { color = "ACCENT" }))

    -- ---- History ----
    content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
        ui.text_widget("History", { color = "ACCENT", font = "small_aa" }))
    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(HISTORY_LABELS, {
            value = state.hist_idx,
            on_change = function(idx)
                local v = HISTORY_VALUES[idx]
                channels_svc.set_history_limit(channel, v)
                state.hist_idx = idx
            end,
        }))
    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "Number of messages to keep in memory for this channel. "
            .. "Older messages are dropped.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))

    -- ---- Notifications ----
    content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
        ui.text_widget("Notifications", { color = "ACCENT", font = "small_aa" }))
    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(NOTIFY_LABELS, {
            value = state.notify_idx,
            on_change = function(idx)
                local v = NOTIFY_VALUES[idx]
                channels_svc.set_notify_mode(channel, v)
                state.notify_idx = idx
            end,
        }))
    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "Mentions match your node name (or any trigger word "
            .. "from Settings -> Notifications) as a substring of "
            .. "the message text.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))

    -- ---- Hide ----
    content[#content + 1] = ui.padding({ 8, 6, 2, 6 },
        ui.toggle("Hide channel", state.hidden, {
            on_change = function(on)
                channels_svc.set_hidden(channel, on)
                state.hidden = on
            end,
        }))

    -- ---- Leave (not Public) ----
    if not is_public then
        content[#content + 1] = ui.padding({ 12, 8, 8, 8 },
            ui.button("Leave channel", {
                on_press = function()
                    channels_svc.leave(channel)
                    -- Pop the settings sheet AND the now-empty
                    -- channel chat behind it, returning the user to
                    -- the channel list.
                    screen_mod.pop()
                    screen_mod.pop()
                end,
            }))
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Channel", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function ChannelSettings:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return ChannelSettings
