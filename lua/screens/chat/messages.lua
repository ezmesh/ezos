-- Messages screen with Private and Channels tabs
-- Private tab: DM conversations (placeholder)
-- Channels tab: List of joined channels with CRUD

local ui = require("ezui")
local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local icons = require("ezui.icons")
local channels_svc = require("services.channels")
local dm_svc = require("services.direct_messages")
local contacts_svc = require("services.contacts")

local Messages = { title = "Messages" }

-- Register tab_bar node type once
if not node_mod.handler("tab_bar") then
    node_mod.register("tab_bar", {
        measure = function(n, max_w, max_h)
            theme.set_font("medium")
            return max_w, theme.font_height() + 10
        end,

        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, theme.color("SURFACE"))

            theme.set_font("medium")
            local fh = theme.font_height()
            local tabs = n.tabs or {}
            local active = n.active or 1
            local tab_w = math.floor(w / #tabs)

            for i, label in ipairs(tabs) do
                local tx = x + (i - 1) * tab_w
                local lw = theme.text_width(label)
                local lx = tx + math.floor((tab_w - lw) / 2)
                local ly = y + math.floor((h - fh) / 2)

                if i == active then
                    d.draw_text(lx, ly, label, theme.color("TEXT"))
                    d.fill_rect(tx + 4, y + h - 2, tab_w - 8, 2, theme.color("ACCENT"))
                else
                    d.draw_text(lx, ly, label, theme.color("TEXT_MUTED"))
                end
            end

            d.fill_rect(x, y + h - 1, w, 1, theme.color("BORDER"))
        end,
    })
end

function Messages:build(state)
    local items = {}
    local active_tab = state.tab or 1

    items[#items + 1] = ui.title_bar("Messages", { back = true })

    items[#items + 1] = {
        type = "tab_bar",
        tabs = { "Private", "Channels" },
        active = active_tab,
    }

    local content_items = {}

    if active_tab == 1 then
        -- Private tab: DM conversations
        local convos = dm_svc.get_conversations()

        if #convos == 0 then
            content_items[#content_items + 1] = ui.padding({ 20, 10, 10, 10 },
                ui.text_widget("No conversations yet", {
                    color = "TEXT_MUTED",
                    text_align = "center",
                })
            )
            content_items[#content_items + 1] = ui.padding({ 4, 10, 10, 10 },
                ui.text_widget("Start a chat from Contacts.", {
                    color = "TEXT_MUTED",
                    font = "small",
                    text_align = "center",
                })
            )
        else
            for _, conv in ipairs(convos) do
                local subtitle = "No messages"
                if conv.last_msg then
                    local prefix = conv.last_msg.is_self and "You: " or ""
                    subtitle = prefix .. (conv.last_msg.text or "")
                end
                local trailing
                if conv.unread > 0 then
                    trailing = tostring(conv.unread)
                end

                content_items[#content_items + 1] = ui.list_item({
                    title = conv.name,
                    subtitle = subtitle,
                    icon = icons.message,
                    trailing = trailing,
                    on_press = function()
                        local screen_mod = require("ezui.screen")
                        local DMConv = require("screens.chat.dm_conversation")
                        local inst = screen_mod.create(DMConv, { contact_key = conv.pub_key_hex })
                        screen_mod.push(inst)
                    end,
                })
            end
        end
    else
        -- Channels tab: list of joined channels
        local channel_list = channels_svc.get_list()

        for _, ch in ipairs(channel_list) do
            if not ch.hidden then
                -- Build subtitle from last message or status
                local subtitle
                if ch.last_msg then
                    subtitle = ch.last_msg.sender_name .. ": " .. ch.last_msg.text
                else
                    subtitle = "No messages"
                end

                -- Unread count as trailing text
                local trailing
                if ch.unread > 0 then
                    trailing = tostring(ch.unread)
                end

                content_items[#content_items + 1] = ui.list_item({
                    title = ch.name,
                    subtitle = subtitle,
                    icon = icons.hash,
                    trailing = trailing,
                    on_press = function()
                        -- Open channel conversation
                        local screen_mod = require("ezui.screen")
                        local ChannelChat = require("screens.chat.channel_chat")
                        local inst = screen_mod.create(ChannelChat, { channel = ch.name })
                        screen_mod.push(inst)
                    end,
                })
            end
        end

        -- "Add Channel" button
        content_items[#content_items + 1] = ui.list_item({
            title = "Add Channel",
            subtitle = "Join with shared password",
            icon = icons.grid,
            on_press = function()
                local screen_mod = require("ezui.screen")
                local ChannelAdd = require("screens.chat.channel_add")
                local inst = screen_mod.create(ChannelAdd, {})
                screen_mod.push(inst)
            end,
        })
    end

    local content = ui.vbox({ gap = 0 }, content_items)
    items[#items + 1] = ui.scroll({ grow = 1, scroll_offset = state.scroll or 0 }, content)

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Messages:on_enter()
    -- Subscribe to channel list changes and new messages to refresh the view
    self._sub_list = ez.bus.subscribe("channel/list_changed", function()
        self:set_state({})
    end)
    self._sub_msg = ez.bus.subscribe("channel/message", function()
        if self._state.tab == 2 then
            self:set_state({})
        end
    end)
    self._sub_dm = ez.bus.subscribe("dm/message", function()
        if (self._state.tab or 1) == 1 then
            self:set_state({})
        end
    end)
end

function Messages:on_leave()
    if self._sub_list then ez.bus.unsubscribe(self._sub_list); self._sub_list = nil end
    if self._sub_msg then ez.bus.unsubscribe(self._sub_msg); self._sub_msg = nil end
    if self._sub_dm then ez.bus.unsubscribe(self._sub_dm); self._sub_dm = nil end
end

function Messages:on_exit()
    self:on_leave()
end

function Messages:handle_key(key)
    -- LEFT/RIGHT switches tabs
    if key.special == "LEFT" or key.special == "RIGHT" then
        local new_tab = (self._state.tab or 1) == 1 and 2 or 1
        self:set_state({ tab = new_tab, scroll = 0 })
        return "handled"
    end
    -- Back (q or ESC — not BACKSPACE, which ghosts on T-Deck keyboard)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Messages
