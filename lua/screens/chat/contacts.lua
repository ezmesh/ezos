-- Contacts list screen
-- Two tabs: "Added" (saved contacts) and "Nearby" (discovered mesh nodes).
-- Press Enter on a contact for actions (DM, Remove).
-- Press Enter on a nearby node to add as contact.

local ui = require("ezui")
local icons = require("ezui.icons")
local contacts_svc = require("services.contacts")
local screen_mod = require("ezui.screen")
local theme = require("ezui.theme")
local node_mod = require("ezui.node")

-- Tab bar node: two horizontal buttons, one highlighted as active.
-- Uses the AA Inter medium so it sits in the same visual weight class
-- as list_item titles; "medium" would switch to the bitmap Spleen and
-- read as heavier than everything around it.
if not node_mod.handler("tab_bar") then
    node_mod.register("tab_bar", {
        measure = function(n, max_w, max_h)
            theme.set_font("small_aa")
            return max_w, theme.font_height() + 8
        end,

        draw = function(n, d, x, y, w, h)
            local tabs = n.tabs or {}
            local active = n.active or 1
            local count = #tabs
            if count == 0 then return end

            local tab_w = math.floor(w / count)
            theme.set_font("small_aa")
            local fh = theme.font_height()

            for i, label in ipairs(tabs) do
                local tx = x + (i - 1) * tab_w
                local is_active = (i == active)

                -- Background
                if is_active then
                    d.fill_rect(tx, y, tab_w, h, theme.color("SURFACE"))
                end

                -- Label centered
                local tw = theme.text_width(label)
                local lx = tx + math.floor((tab_w - tw) / 2)
                local ly = y + math.floor((h - fh) / 2)
                local color = is_active and theme.color("ACCENT") or theme.color("TEXT_MUTED")
                d.draw_text(lx, ly, label, color)

                -- Active indicator line at bottom
                if is_active then
                    d.fill_rect(tx + 4, y + h - 2, tab_w - 8, 2, theme.color("ACCENT"))
                end
            end

            -- Bottom border
            d.draw_hline(x, y + h - 1, w, theme.color("BORDER"))
        end,
    })
end

-- Context menu for a saved contact
local function show_contact_menu(self, contact)
    local MenuDef = { title = "Contact" }

    function MenuDef:build(state)
        local items = {}
        items[#items + 1] = ui.title_bar(contact.name, { back = true })

        local actions = {}

        actions[#actions + 1] = ui.list_item({
            title = "Send Message",
            subtitle = "Open DM conversation",
            on_press = function()
                screen_mod.pop()  -- pop menu
                local DMConv = require("screens.chat.dm_conversation")
                local inst = screen_mod.create(DMConv, { contact_key = contact.pub_key_hex })
                screen_mod.push(inst)
            end,
        })

        actions[#actions + 1] = ui.list_item({
            title = "Key: " .. contact.pub_key_hex:sub(1, 16) .. "...",
            disabled = true,
        })

        if contact.ack_enabled then
            actions[#actions + 1] = ui.list_item({
                title = "ACK: enabled",
                subtitle = "Device confirms message delivery",
                disabled = true,
            })
        end

        actions[#actions + 1] = ui.list_item({
            title = "Remove Contact",
            subtitle = "Delete from contact list",
            on_press = function()
                contacts_svc.remove(contact.pub_key_hex)
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

    screen_mod.push(screen_mod.create(MenuDef, {}))
end

local Contacts = { title = "Contacts" }

function Contacts:build(state)
    local tab = state.tab or 1  -- 1 = Added, 2 = Nearby
    local items = {}

    items[#items + 1] = ui.title_bar("Contacts", { back = true })

    -- Tab bar
    items[#items + 1] = { type = "tab_bar", tabs = { "Added", "Nearby" }, active = tab }

    local content_items = {}

    if tab == 1 then
        -- Added contacts
        local contact_list = contacts_svc.get_all()

        if #contact_list == 0 then
            content_items[#content_items + 1] = ui.padding({ 20, 10, 10, 10 },
                ui.text_widget("No contacts yet", {
                    color = "TEXT_MUTED",
                    text_align = "center",
                })
            )
            content_items[#content_items + 1] = ui.padding({ 4, 10, 10, 10 },
                ui.text_widget("Switch to Nearby tab to add nodes.", {
                    color = "TEXT_MUTED",
                    font = "small_aa",
                    text_align = "center",
                })
            )
        else
            for _, c in ipairs(contact_list) do
                content_items[#content_items + 1] = ui.list_item({
                    title = c.name,
                    subtitle = c.pub_key_hex:sub(1, 12) .. "...",
                    icon = icons.users,
                    on_press = function()
                        show_contact_menu(self, c)
                    end,
                })
            end
        end
    else
        -- Nearby mesh nodes
        local nodes = {}
        if ez.mesh.is_initialized() then
            nodes = ez.mesh.get_nodes() or {}
        end

        local eligible = {}
        for _, node in ipairs(nodes) do
            if node.pub_key_hex and #node.pub_key_hex == 64 then
                eligible[#eligible + 1] = node
            end
        end

        if #eligible == 0 then
            content_items[#content_items + 1] = ui.padding({ 20, 10, 10, 10 },
                ui.text_widget("No nodes discovered", {
                    color = "TEXT_MUTED",
                    text_align = "center",
                })
            )
            content_items[#content_items + 1] = ui.padding({ 4, 10, 10, 10 },
                ui.text_widget("Nearby mesh nodes will appear here.", {
                    color = "TEXT_MUTED",
                    font = "small_aa",
                    text_align = "center",
                })
            )
        else
            for _, node in ipairs(eligible) do
                local already = contacts_svc.is_contact(node.pub_key_hex)
                local rssi_str = node.rssi and string.format("%ddBm", math.floor(node.rssi)) or ""

                content_items[#content_items + 1] = ui.list_item({
                    title = node.name or "Unknown",
                    subtitle = rssi_str,
                    icon = icons.users,
                    trailing = already and "Added" or nil,
                    on_press = function()
                        if already then
                            -- Show contact menu for existing contacts
                            local c = contacts_svc.get(node.pub_key_hex)
                            if c then show_contact_menu(self, c) end
                        else
                            contacts_svc.add(node.pub_key_hex, node.name or "Unknown", "")
                            self:set_state({})
                        end
                    end,
                })
            end
        end
    end

    local content = ui.vbox({ gap = 0 }, content_items)
    items[#items + 1] = ui.scroll({ grow = 1, scroll_offset = state.scroll or 0 }, content)

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Contacts:on_enter()
    self._sub = ez.bus.subscribe("contacts/changed", function()
        self:set_state({})
    end)
    self._last_refresh = 0
end

function Contacts:on_leave()
    if self._sub then ez.bus.unsubscribe(self._sub); self._sub = nil end
end

function Contacts:on_exit()
    self:on_leave()
end

-- Nearby tab shows a snapshot of ez.mesh.get_nodes(), but the mesh
-- stack doesn't post an event when that list changes. Poll the list
-- at ~1 Hz while the Nearby tab is active and rebuild only when the
-- node count or ordering actually changes — avoids needless rebuilds
-- that would reset focus or clobber the user's scroll.
local function nearby_fingerprint()
    if not ez.mesh.is_initialized() then return "nomesh" end
    local nodes = ez.mesh.get_nodes() or {}
    local parts = { #nodes }
    for _, n in ipairs(nodes) do
        parts[#parts + 1] = (n.pub_key_hex or ""):sub(1, 8)
    end
    return table.concat(parts, "|")
end

function Contacts:update()
    if (self._state.tab or 1) ~= 2 then return end
    local now = ez.system.millis()
    if now - (self._last_refresh or 0) < 1000 then return end
    self._last_refresh = now

    local fp = nearby_fingerprint()
    if fp ~= self._nearby_fp then
        self._nearby_fp = fp
        self:set_state({})
    end
end

function Contacts:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    -- Tab switching with left/right at screen level
    local focus_mod = require("ezui.focus")
    if not focus_mod.editing then
        if key.special == "LEFT" then
            if (self._state.tab or 1) ~= 1 then
                self:set_state({ tab = 1, scroll = 0 })
                return "handled"
            end
        elseif key.special == "RIGHT" then
            if (self._state.tab or 1) ~= 2 then
                self:set_state({ tab = 2, scroll = 0 })
                return "handled"
            end
        end
    end
    return nil
end

return Contacts
