-- Direct message conversation screen
-- Shows chat bubbles for a specific contact with text input for sending.
-- Pass contact via initial state: { contact_key = "ABCDEF..." }

local ui = require("ezui")
local dm_svc = require("services.direct_messages")
local contacts_svc = require("services.contacts")
require("screens.chat_common")  -- registers chat_bubble node type

local screen_mod = require("ezui.screen")

-- Context menu shown when pressing Enter on a chat bubble
local function show_context_menu(self, key, msg, msg_index)
    local MenuDef = { title = "Message" }

    function MenuDef:build(state)
        local items = {}
        local preview = msg.text or ""
        if #preview > 30 then preview = preview:sub(1, 27) .. "..." end

        items[#items + 1] = ui.title_bar(preview, { back = true })

        local actions = {}

        if msg.is_self and (msg.status == "failed" or msg.status == "unconfirmed") then
            actions[#actions + 1] = ui.list_item({
                title = "Retry Send",
                subtitle = "Resend this message",
                on_press = function()
                    dm_svc.send(key, msg.text)
                    screen_mod.pop()
                end,
            })
        end

        if msg.is_self then
            actions[#actions + 1] = ui.list_item({
                title = "Status: " .. (msg.status or "sent"),
                disabled = true,
            })
        end

        if not msg.is_self then
            local sender_name = msg.sender_name or "?"
            local rssi_str = msg.rssi and string.format("%d dBm", math.floor(msg.rssi)) or "unknown"
            actions[#actions + 1] = ui.list_item({
                title = "From: " .. sender_name,
                subtitle = "Signal: " .. rssi_str,
                disabled = true,
            })
        end

        actions[#actions + 1] = ui.list_item({
            title = "Repeat Send",
            subtitle = "Send this text again",
            on_press = function()
                dm_svc.send(key, msg.text)
                screen_mod.pop()
            end,
        })

        actions[#actions + 1] = ui.list_item({
            title = "Delete Message",
            subtitle = "Remove from history",
            on_press = function()
                dm_svc.delete_message(key, msg_index)
                screen_mod.pop()
            end,
        })

        local content = ui.vbox({ gap = 0 }, actions)
        items[#items + 1] = ui.scroll({ grow = 1 }, content)

        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function MenuDef:handle_key(k)
        if k.character == "q" or k.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    local inst = screen_mod.create(MenuDef, {})
    screen_mod.push(inst)
end

local DMConversation = { title = "Chat" }

function DMConversation:build(state)
    local key = state.contact_key or ""
    local contact = contacts_svc.get(key)
    local name = contact and contact.name or key:sub(1, 8)
    local items = {}

    items[#items + 1] = ui.title_bar(name, { back = true })

    local msgs = dm_svc.get_history(key)
    local content_items = {}

    if #msgs == 0 then
        content_items[#content_items + 1] = ui.padding({ 20, 10, 10, 10 },
            ui.text_widget("No messages yet", {
                color = "TEXT_MUTED",
                text_align = "center",
            })
        )
        content_items[#content_items + 1] = ui.padding({ 4, 10, 10, 10 },
            ui.text_widget("Type a message below to start chatting.", {
                color = "TEXT_MUTED",
                font = "small",
                text_align = "center",
            })
        )
    else
        for i, msg in ipairs(msgs) do
            content_items[#content_items + 1] = {
                type = "chat_bubble",
                msg = msg,
                on_press = function()
                    show_context_menu(self, key, msg, i)
                end,
            }
        end
    end

    local content = ui.vbox({ gap = 0 }, content_items)
    items[#items + 1] = ui.scroll({ grow = 1, scroll_offset = state.scroll or 99999 }, content)

    -- Text input bar at bottom
    items[#items + 1] = ui.padding({ 4, 4, 4, 4 },
        ui.text_input({
            value = state.input or "",
            placeholder = "Type a message...",
            on_change = function(val)
                state.input = val
            end,
            on_submit = function(val)
                if val and #val > 0 then
                    dm_svc.send(key, val)
                    self:set_state({ input = "", scroll = 99999 })
                end
            end,
        })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function DMConversation:on_enter()
    local key = self._state.contact_key or ""
    dm_svc.mark_read(key)

    -- Focus the text input (last focusable item) instead of the first chat bubble
    local focus_mod = require("ezui.focus")
    if #focus_mod.chain > 0 then
        focus_mod.index = #focus_mod.chain
        focus_mod._update_marks()
    end

    self._sub = ez.bus.subscribe("dm/message", function(topic, msg)
        if msg and (msg.sender_key == key or msg.is_self) then
            self:set_state({ scroll = 99999 })
        end
    end)

    -- Refresh on delivery status changes (ACK received, retry, failed)
    self._status_sub = ez.bus.subscribe("dm/status", function(topic, info)
        if info and info.pub_key_hex == key then
            self:set_state({})
        end
    end)
end

-- Keep screen redrawing while messages have pending status (for spinner animation)
function DMConversation:update()
    local key = self._state.contact_key or ""
    local msgs = dm_svc.get_history(key)
    for i = #msgs, math.max(1, #msgs - 5), -1 do
        if msgs[i] and msgs[i].status == "pending" then
            require("ezui.screen").invalidate()
            return
        end
    end
end

function DMConversation:on_leave()
    if self._sub then ez.bus.unsubscribe(self._sub); self._sub = nil end
    if self._status_sub then ez.bus.unsubscribe(self._status_sub); self._status_sub = nil end
end

function DMConversation:on_exit()
    self:on_leave()
end

function DMConversation:handle_key(key)
    local focus_mod = require("ezui.focus")
    if not focus_mod.editing then
        if key.character == "q" or key.special == "ESCAPE" then
            return "pop"
        end
    end
    return nil
end

return DMConversation
