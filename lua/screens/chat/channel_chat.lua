-- Channel conversation screen
-- Shows messages for a specific channel with live updates and a
-- compose input.  Pass channel name via initial state: { channel = "#Public" }

local ui = require("ezui")
local channels_svc = require("services.channels")
require("screens.chat.chat_common")  -- registers chat_bubble node type

-- Pin the scroll viewport to the most recent message after a rebuild.
-- ezui persists scroll_offset across rebuilds, which would otherwise
-- override the build()-time `scroll_offset = 99999` -- so we reach in
-- after the rebuild and set the live node directly. Mirrors what
-- dm_conversation.lua does; keep the two screens in sync.
local function find_scroll(node)
    if not node then return nil end
    if node.type == "scroll" then return node end
    if node.children then
        for _, c in ipairs(node.children) do
            local s = find_scroll(c)
            if s then return s end
        end
    end
    return nil
end

local function stick_to_bottom(inst)
    local s = find_scroll(inst._tree)
    if s then s.scroll_offset = 99999 end
    require("ezui.screen").invalidate()
end

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
            ui.text_widget("Type a message below to send to this channel.", {
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

    -- Compose bar at bottom. on_submit blanks the input via
    -- self:set_state, then snaps to the latest bubble so the user's
    -- own message is visible immediately.
    items[#items + 1] = ui.padding({ 4, 4, 4, 4 },
        ui.text_input({
            value = state.input or "",
            placeholder = "Type a message...",
            on_change = function(val)
                state.input = val
            end,
            on_submit = function(val)
                if val and #val > 0 then
                    channels_svc.send(channel, val)
                    self:set_state({ input = "" })
                    stick_to_bottom(self)
                end
            end,
        })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function ChannelChat:on_enter()
    local channel = self._state.channel or "#Public"
    channels_svc.mark_read(channel)

    -- Land focus on the compose box and enter edit mode immediately so
    -- typing a reply needs zero setup keystrokes. screen.push runs
    -- on_enter before the first _rebuild, so force one now to populate
    -- the focus chain. See dm_conversation.lua for the same pattern.
    self:_rebuild()
    local focus_mod = require("ezui.focus")
    if #focus_mod.chain > 0 then
        focus_mod.index = #focus_mod.chain
        focus_mod._update_marks()
        focus_mod.enter_edit()
    end
    stick_to_bottom(self)

    -- Force-rebuild (not set_state) so a new message shows up even
    -- while the compose box is in edit mode. Same reasoning as
    -- dm_conversation -- see the comment there. Text input cursor +
    -- value survive via _PERSISTENT_FIELDS and the state.input
    -- round-trip.
    local screen = require("ezui.screen")
    self._sub = ez.bus.subscribe("channel/message", function(topic, msg)
        if msg.channel == (self._state.channel or "#Public") then
            self:_rebuild()
            stick_to_bottom(self)
            screen.invalidate()
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
    local focus_mod = require("ezui.focus")
    if not focus_mod.editing then
        if key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
    end
    return nil
end

return ChannelChat
