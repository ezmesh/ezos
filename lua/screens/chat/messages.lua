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

-- NVS pref controlling the Private-tab filter. When set, DM conversations
-- whose sender isn't in the contact list are hidden — handy for ignoring
-- noise from nodes the user hasn't explicitly adopted yet.
local PREF_DM_KNOWN_ONLY = "msg_known_only"

function Messages.initial_state()
    -- Pref values come back as strings or nil; normalise to a bool.
    local raw = ez.storage.get_pref(PREF_DM_KNOWN_ONLY, nil)
    local known_only = raw == true or raw == 1 or raw == "1" or raw == "true"
    return {
        tab        = 1,
        scroll     = 0,
        known_only = known_only,
    }
end

-- Register tab_bar node type once
if not node_mod.handler("tab_bar") then
    node_mod.register("tab_bar", {
        measure = function(n, max_w, max_h)
            theme.set_font("medium_aa")
            local h = theme.font_height() + 10
            -- Touch-mode floor: a 22 px tab bar is too narrow to land
            -- a finger on cleanly. Grow it the same way every other
            -- focusable widget does so this strip is a real hit
            -- target. Trackball-only units are unaffected.
            local touch_input = require("ezui.touch_input")
            if touch_input.touch_enabled() and h < touch_input.MIN_TARGET_H then
                h = touch_input.MIN_TARGET_H
            end
            return max_w, h
        end,

        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, theme.color("SURFACE"))

            theme.set_font("medium_aa")
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

    -- Persist the tab_bar node on self so the touch handler attached
    -- in on_enter can read its drawn rect (_x/_y/_aw/_ah). A new node
    -- per build would orphan the previous one and the handler would
    -- point at stale geometry between rebuilds.
    if not self._tab_bar_node then
        self._tab_bar_node = {
            type = "tab_bar",
            tabs = { "Private", "Channels" },
        }
    end
    self._tab_bar_node.active = active_tab
    items[#items + 1] = self._tab_bar_node

    local content_items = {}

    if active_tab == 1 then
        -- Private tab: DM conversations
        local all_convos = dm_svc.get_conversations()

        -- Partition into known/unknown so the filter toggle can show a
        -- useful hint like "Hiding 3 unknown". get_conversations() exposes
        -- pub_key_hex, which is exactly what contacts_svc.is_contact wants.
        local known_convos, unknown_count = {}, 0
        for _, c in ipairs(all_convos) do
            if contacts_svc.is_contact(c.pub_key_hex) then
                known_convos[#known_convos + 1] = c
            else
                unknown_count = unknown_count + 1
            end
        end
        local convos = state.known_only and known_convos or all_convos

        -- Filter toggle. Only show the row when it would actually do
        -- something — if every conversation is already with a known
        -- contact, surfacing the toggle is just noise.
        if #all_convos > 0 and (unknown_count > 0 or state.known_only) then
            local sub
            if state.known_only then
                sub = "Hiding " .. unknown_count .. " unknown sender"
                    .. (unknown_count == 1 and "" or "s")
            else
                sub = "Showing all senders"
            end
            content_items[#content_items + 1] = ui.list_item({
                title = "Known contacts only",
                subtitle = sub,
                compact = true,
                trailing = state.known_only and "On" or "Off",
                on_press = function()
                    local new_val = not state.known_only
                    state.known_only = new_val
                    ez.storage.set_pref(PREF_DM_KNOWN_ONLY, new_val and "1" or "0")
                    self:set_state({ scroll = 0 })
                end,
            })
        end

        if #convos == 0 then
            local empty_title, empty_sub
            if state.known_only and unknown_count > 0 then
                empty_title = "No messages from contacts"
                empty_sub   = "Turn off the filter to see " .. unknown_count
                    .. " unknown sender" .. (unknown_count == 1 and "" or "s")
                    .. "."
            else
                empty_title = "No conversations yet"
                empty_sub   = "Start a chat from Contacts."
            end
            content_items[#content_items + 1] = ui.padding({ 20, 10, 10, 10 },
                ui.text_widget(empty_title, {
                    color = "TEXT_MUTED",
                    text_align = "center",
                })
            )
            content_items[#content_items + 1] = ui.padding({ 4, 10, 10, 10 },
                ui.text_widget(empty_sub, {
                    color = "TEXT_MUTED",
                    font = "small_aa",
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

        -- Pending (undecryptable) DMs live at the bottom. Each bucket
        -- groups by src_hash — the one byte we can read from the
        -- envelope. The items are informational only; they can't be
        -- opened until the sender's ADVERT or contact-add auto-promotes
        -- them into the list above.
        local pending_summary = dm_svc.get_pending_summary()
        if #pending_summary > 0 then
            content_items[#content_items + 1] = ui.padding({ 10, 10, 4, 10 },
                ui.text_widget("Unreadable (awaiting sender's advert)", {
                    color = "TEXT_MUTED", font = "tiny_aa",
                })
            )
            for _, b in ipairs(pending_summary) do
                local subtitle = b.count .. " message"
                    .. (b.count == 1 and "" or "s")
                    .. " · src " .. string.format("0x%02X", b.src_hash)
                content_items[#content_items + 1] = ui.list_item({
                    title = "Unknown sender",
                    subtitle = subtitle,
                    icon = icons.message,
                    disabled = true,
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
    -- Pending buffer changes (arrival of an undecryptable DM, or a
    -- retroactive promotion) also affect the Private tab.
    self._sub_pending = ez.bus.subscribe("dm/pending", function()
        if (self._state.tab or 1) == 1 then
            self:set_state({})
        end
    end)

    -- Tap-to-switch on the Private/Channels strip. The tab_bar node
    -- isn't focusable so the global touch_input bridge can't route a
    -- tap there; we handle it locally using the persisted node's
    -- drawn rect. Two equal-width tabs, so the test is just "which
    -- half of the bar's width contains the touch x".
    self._sub_touch = ez.bus.subscribe("touch/down", function(_, data)
        if type(data) ~= "table" then return end
        local n = self._tab_bar_node
        if not n or not n._x then return end
        if data.y < n._y or data.y >= n._y + (n._ah or 0) then return end
        if data.x < n._x or data.x >= n._x + (n._aw or 0) then return end
        local tab_w = (n._aw or 0) / 2
        local idx = math.floor((data.x - n._x) / tab_w) + 1
        if idx < 1 then idx = 1 end
        if idx > 2 then idx = 2 end
        if idx ~= (self._state.tab or 1) then
            local ok, sounds = pcall(require, "services.ui_sounds")
            if ok and sounds and sounds.play then sounds.play("tap") end
            self:set_state({ tab = idx, scroll = 0 })
        end
    end)
end

function Messages:on_leave()
    if self._sub_list then ez.bus.unsubscribe(self._sub_list); self._sub_list = nil end
    if self._sub_msg then ez.bus.unsubscribe(self._sub_msg); self._sub_msg = nil end
    if self._sub_dm then ez.bus.unsubscribe(self._sub_dm); self._sub_dm = nil end
    if self._sub_pending then ez.bus.unsubscribe(self._sub_pending); self._sub_pending = nil end
    if self._sub_touch then ez.bus.unsubscribe(self._sub_touch); self._sub_touch = nil end
end

function Messages:on_exit()
    self:on_leave()
end

function Messages:handle_key(key)
    -- LEFT/RIGHT switches tabs
    if key.special == "LEFT" or key.special == "RIGHT" then
        local new_tab = (self._state.tab or 1) == 1 and 2 or 1
        local ok, sounds = pcall(require, "services.ui_sounds")
        if ok and sounds and sounds.play then sounds.play("tap") end
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
