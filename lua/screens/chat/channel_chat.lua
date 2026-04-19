-- Channel conversation screen
-- Shows messages for a specific channel with live updates.
-- Pass channel name via initial state: { channel = "#Public" }

local ui = require("ezui")
local channels_svc = require("services.channels")
require("screens.chat.chat_common")  -- registers chat_bubble node type

local ChannelChat = { title = "Channel" }

function ChannelChat:build(state)
    local channel = state.channel or "#Public"
    local items = {}

    items[#items + 1] = ui.title_bar(channel, { back = true })

    local msgs = channels_svc.get_history(channel)
    local content_items = {}

    if #msgs == 0 then
        content_items[#content_items + 1] = ui.padding({ 20, 10, 10, 10 },
            ui.text_widget("No messages yet", {
                color = "TEXT_MUTED",
                text_align = "center",
            })
        )
        content_items[#content_items + 1] = ui.padding({ 4, 10, 10, 10 },
            ui.text_widget("Listening for messages on this channel.", {
                color = "TEXT_MUTED",
                font = "small_aa",
                text_align = "center",
            })
        )
    else
        for _, msg in ipairs(msgs) do
            content_items[#content_items + 1] = {
                type = "chat_bubble",
                msg = msg,
            }
        end
    end

    local content = ui.vbox({ gap = 0 }, content_items)
    items[#items + 1] = ui.scroll({ grow = 1, scroll_offset = state.scroll or 99999 }, content)

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function ChannelChat:on_enter()
    local channel = self._state.channel or "#Public"
    channels_svc.mark_read(channel)

    self._sub = ez.bus.subscribe("channel/message", function(topic, msg)
        if msg.channel == (self._state.channel or "#Public") then
            self:set_state({ scroll = 99999 })
        end
    end)
end

function ChannelChat:on_leave()
    if self._sub then ez.bus.unsubscribe(self._sub); self._sub = nil end
end

function ChannelChat:on_exit()
    self:on_leave()
end

function ChannelChat:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return ChannelChat
