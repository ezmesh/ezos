-- Channel conversation screen
-- Shows messages for a specific channel with live updates and a
-- compose input.  Pass channel name via initial state: { channel = "#Public" }

local ui = require("ezui")
local channels_svc = require("services.channels")
local sharing_svc = require("services.sharing")
local time_share = require("screens.chat.time_share")
local cal_share = require("screens.chat.cal_share")
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

local screen_mod = require("ezui.screen")

-- Context menu for a channel message bubble
local function show_context_menu(self, channel, msg)
    local MenuDef = { title = "Message" }

    function MenuDef:build(state)
        local items = {}
        local preview = msg.text or ""
        if #preview > 30 then preview = preview:sub(1, 27) .. "..." end

        items[#items + 1] = ui.title_bar(preview, { back = true })

        local actions = {}

        -- Time share actions (before generic actions)
        for _, item in ipairs(time_share.build_actions(msg)) do
            actions[#actions + 1] = item
        end

        -- Event (cal/v1) share actions
        for _, item in ipairs(cal_share.build_actions(msg)) do
            actions[#actions + 1] = item
        end

        if not msg.is_self then
            local sender_name = msg.sender_name or "?"
            local count = msg.count or 1
            -- Header row. Annotate the sender label with the repeat
            -- count when the bubble is the rolled-up view of multiple
            -- receptions of the same text. Single-receipt messages
            -- collapse to a one-line "Signal: -94 dBm" subtitle, which
            -- is what existing users expect.
            if count > 1 then
                actions[#actions + 1] = ui.list_item({
                    title = "From: " .. sender_name
                        .. " (" .. count .. " repeats)",
                    disabled = true,
                })
                -- Range rows (only added if we actually saw the value).
                if msg.rssi_min and msg.rssi_max then
                    actions[#actions + 1] = ui.list_item({
                        title = string.format("RSSI: %d..%d dBm",
                            math.floor(msg.rssi_min),
                            math.floor(msg.rssi_max)),
                        disabled = true,
                    })
                end
                if msg.hops_min and msg.hops_max then
                    actions[#actions + 1] = ui.list_item({
                        title = string.format("Hops: %d..%d",
                            msg.hops_min, msg.hops_max),
                        disabled = true,
                    })
                end
                if msg.snr_min and msg.snr_max then
                    actions[#actions + 1] = ui.list_item({
                        title = string.format("SNR:  %.1f..%.1f dB",
                            msg.snr_min, msg.snr_max),
                        disabled = true,
                    })
                end
            else
                local rssi_str = msg.rssi and
                    string.format("%d dBm", math.floor(msg.rssi))
                    or "unknown"
                actions[#actions + 1] = ui.list_item({
                    title = "From: " .. sender_name,
                    subtitle = "Signal: " .. rssi_str,
                    disabled = true,
                })
            end
        end

        if msg.is_self then
            actions[#actions + 1] = ui.list_item({
                title = "Status: sent",
                disabled = true,
            })

            actions[#actions + 1] = ui.list_item({
                title = "Repeat Send",
                subtitle = "Send this text again",
                on_press = function()
                    channels_svc.send(channel, msg.text)
                    screen_mod.pop()
                end,
            })
        end

        local content = ui.vbox({ gap = 0 }, actions)
        items[#items + 1] = ui.scroll({ grow = 1 }, content)

        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function MenuDef:handle_key(k)
        -- BACKSPACE is the on-device back-arrow; ESCAPE is the
        -- remote-tool synonym. Without BACKSPACE the user has no way
        -- to dismiss this menu on the T-Deck (no Esc key exists).
        if k.character == "q"
            or k.special == "ESCAPE"
            or k.special == "BACKSPACE"
        then
            return "pop"
        end
        return nil
    end

    local inst = screen_mod.create(MenuDef, {})
    screen_mod.push(inst)
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
        content_items[#content_items + 1] = { type = "spacer", h = 2, grow = 0 }
        for _, msg in ipairs(msgs) do
            content_items[#content_items + 1] = {
                type = "chat_bubble",
                msg = msg,
                share = time_share.card_for_message(msg) or cal_share.card_for_message(msg),
                on_press = function()
                    show_context_menu(self, channel, msg)
                end,
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

function ChannelChat:menu()
    local channel = self._state.channel or "#Public"
    return {
        {
            title = "Channel settings",
            subtitle = "History, notifications, hide / leave",
            on_press = function()
                local screen   = require("ezui.screen")
                local Settings = require("screens.chat.channel_settings")
                screen.push(screen.create(Settings,
                    Settings.initial_state(channel)))
            end,
        },
        {
            title = "Share time",
            subtitle = "Send your current clock to the channel",
            on_press = function()
                local url, err = sharing_svc.encode_time()
                if url then
                    channels_svc.send(channel, url)
                end
            end,
        },
        {
            title = "Attach event...",
            subtitle = "Build a cal/v1 meetup invite",
            on_press = function()
                local Compose = require("screens.chat.event_compose")
                local inst = screen_mod.create(Compose,
                    Compose.initial_state({
                        on_submit = function(url)
                            channels_svc.send(channel, url)
                        end,
                    }))
                screen_mod.push(inst)
            end,
        },
    }
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
