-- Nodes Screen for T-Deck OS
-- Compact list of all heard mesh nodes (live + cached)

local TimeUtils = load_module("/scripts/ui/time_utils.lua")
local NodeUtils = load_module("/scripts/ui/node_utils.lua")
local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local Nodes = {
    title = "Nodes",
    selected = 1,
    scroll_offset = 0,
    VISIBLE_ROWS = 9,  -- More rows visible with small font
    ROW_HEIGHT = 20,   -- Compact row height
    nodes = {},

    -- Autoreload settings
    RELOAD_INTERVAL = 10000,  -- Reload every 10 seconds
    reload_timer = nil,
    loading = false,
}

-- Apply list mixin for navigation helpers
ListMixin.apply(Nodes)

function Nodes:get_item_count()
    return #self.nodes
end

function Nodes:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
        VISIBLE_ROWS = self.VISIBLE_ROWS,
        ROW_HEIGHT = self.ROW_HEIGHT,
        nodes = {},
        reload_timer = nil,
        loading = false,
    }
    setmetatable(o, {__index = Nodes})
    return o
end

function Nodes:on_enter()
    -- Initial load with indicator
    self.loading = true
    if _G.StatusBar then _G.StatusBar.show_loading("Loading nodes...") end
    self:refresh_nodes()
    self.loading = false
    if _G.StatusBar then _G.StatusBar.hide_loading() end

    -- Start autoreload timer
    self:start_autoreload()
end

function Nodes:on_leave()
    -- Stop autoreload timer
    self:stop_autoreload()

    -- Clear nodes array to free memory
    self.nodes = {}
    run_gc("collect", "nodes-leave")
end

function Nodes:start_autoreload()
    if self.reload_timer then return end

    local self_ref = self
    self.reload_timer = set_timeout(function()
        self_ref:do_autoreload()
    end, self.RELOAD_INTERVAL)
end

function Nodes:stop_autoreload()
    if self.reload_timer then
        clear_timeout(self.reload_timer)
        self.reload_timer = nil
    end
end

function Nodes:do_autoreload()
    self.reload_timer = nil

    -- Show loading indicator
    self.loading = true
    if _G.StatusBar then _G.StatusBar.show_loading("Refreshing...") end
    ScreenManager.invalidate()

    -- Refresh in next frame to allow UI to update
    local self_ref = self
    set_timeout(function()
        self_ref:refresh_nodes()
        self_ref.loading = false
        if _G.StatusBar then _G.StatusBar.hide_loading() end
        ScreenManager.invalidate()

        -- Schedule next reload
        self_ref:start_autoreload()
    end, 50)
end

function Nodes:refresh_nodes()
    self.nodes = {}

    -- Use Contacts service if available (includes cached nodes with 7-day expiry)
    if _G.Contacts and _G.Contacts.get_discovered then
        self.nodes = _G.Contacts.get_discovered()
    elseif ez.mesh.is_initialized() then
        -- Fallback to direct mesh query (live nodes only)
        self.nodes = ez.mesh.get_nodes() or {}
        table.sort(self.nodes, function(a, b)
            return (a.last_seen or 0) > (b.last_seen or 0)
        end)
    end

    self:clamp_selection()
end

function Nodes:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    ListMixin.draw_background(display)

    -- Title bar with node count
    local title_str = string.format("Nodes (%d)", #self.nodes)
    TitleBar.draw(display, title_str)

    -- List area
    local list_start_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local scrollbar_width = 6

    -- Use small font throughout for density
    display.set_font_size("small")

    if #self.nodes == 0 then
        display.draw_text_centered(list_start_y + 40, "No nodes heard", colors.TEXT_SECONDARY)
        display.draw_text_centered(list_start_y + 60, "Nodes appear when they", colors.TEXT_SECONDARY)
        display.draw_text_centered(list_start_y + 75, "send messages nearby", colors.TEXT_SECONDARY)
        return
    end

    -- Column layout: Name | Role | RSSI | Seen
    local name_x = 6
    local role_x = 140
    local rssi_x = 165
    local seen_x = 200
    local hops_x = 235

    -- Header row
    display.draw_text(name_x, list_start_y - 14, "Name", colors.TEXT_MUTED)
    display.draw_text(rssi_x, list_start_y - 14, "Sig", colors.TEXT_MUTED)
    display.draw_text(seen_x, list_start_y - 14, "Seen", colors.TEXT_MUTED)
    display.draw_text(hops_x, list_start_y - 14, "Hop", colors.TEXT_MUTED)

    -- Draw visible nodes
    for i = 0, self.VISIBLE_ROWS - 1 do
        local item_idx = self.scroll_offset + i + 1
        if item_idx > #self.nodes then break end

        local node = self.nodes[item_idx]
        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (item_idx == self.selected)

        -- Selection highlight
        if is_selected then
            display.fill_rect(2, y - 1, w - 8 - scrollbar_width, self.ROW_HEIGHT - 2, colors.ACCENT)
        end

        -- Node name (sanitized and truncated)
        local name = node.name or string.format("%02X", (node.path_hash or 0) % 256)
        local max_name_width = role_x - name_x - 4
        local clean_name = NodeUtils.sanitize_name(name, max_name_width, display)

        -- Prefix for saved contacts
        if node.is_saved then
            clean_name = "*" .. clean_name
        end

        -- Color based on state
        local text_color
        if is_selected then
            text_color = colors.BLACK
        elseif node.is_cached then
            text_color = colors.TEXT_MUTED
        else
            text_color = colors.WHITE
        end

        display.draw_text(name_x, y + 2, clean_name, text_color)

        -- Role abbreviation
        local role_str = NodeUtils.role_abbrev(node.role or 0)
        if role_str and role_str ~= "?" then
            display.draw_text(role_x, y + 2, role_str, text_color)
        end

        -- RSSI indicator
        local rssi = node.rssi or -999
        local rssi_str = NodeUtils.rssi_indicator(rssi)
        local rssi_color
        if is_selected then
            rssi_color = colors.BLACK
        elseif rssi > -80 then
            rssi_color = colors.SUCCESS
        elseif rssi > -100 then
            rssi_color = colors.WARNING
        else
            rssi_color = colors.ERROR
        end
        display.draw_text(rssi_x, y + 2, rssi_str, rssi_color)

        -- Last seen
        local seen_str = TimeUtils.format_relative(node.last_seen or 0)
        display.draw_text(seen_x, y + 2, seen_str, text_color)

        -- Hop count
        local hops = node.hops or 0
        if hops > 0 then
            display.draw_text(hops_x, y + 2, tostring(hops), text_color)
        end
    end

    -- Scrollbar
    ListMixin.draw_scrollbar(display,
        w - scrollbar_width - 2,
        list_start_y,
        self.VISIBLE_ROWS * self.ROW_HEIGHT,
        self.VISIBLE_ROWS,
        #self.nodes,
        self.scroll_offset,
        colors)

    -- Footer hint
    display.draw_text(4, h - 14, "M:Msg  R:Refresh  Enter:Details", colors.TEXT_MUTED)
end

function Nodes:handle_key(key)
    -- Handle list navigation first
    if self:handle_list_key(key) then
        ScreenManager.invalidate()
        return "continue"
    end

    -- Page navigation with left/right
    if key.special == "LEFT" then
        self:page_up()
        ScreenManager.invalidate()
        return "continue"
    elseif key.special == "RIGHT" then
        self:page_down()
        ScreenManager.invalidate()
        return "continue"
    elseif key.special == "ENTER" then
        -- Open app menu for selected node actions
        if _G.AppMenu then
            _G.AppMenu.show()
        end
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "m" or key.character == "M" then
        self:send_message()
    elseif key.character == "r" or key.character == "R" then
        -- Manual refresh with loading indicator
        self.loading = true
        if _G.StatusBar then _G.StatusBar.show_loading("Refreshing...") end
        ScreenManager.invalidate()

        -- Refresh in next frame
        local self_ref = self
        set_timeout(function()
            self_ref:refresh_nodes()
            self_ref.loading = false
            if _G.StatusBar then _G.StatusBar.hide_loading() end
            ScreenManager.invalidate()
        end, 50)
    end

    return "continue"
end

function Nodes:send_message()
    if #self.nodes == 0 then return end

    local node = self.nodes[self.selected]
    if not node.pub_key_hex then
        if _G.MessageBox then
            _G.MessageBox.show({title = "Cannot message", subtitle = "No public key for node"})
        end
        return
    end

    spawn_screen("/scripts/ui/screens/dm_conversation.lua", node.pub_key_hex, node.name)
end

function Nodes:view_details()
    if #self.nodes == 0 then return end
    spawn_screen("/scripts/ui/screens/node_details.lua", self.nodes[self.selected])
end

-- Menu items for app menu
function Nodes:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Refresh",
        action = function()
            -- Refresh with loading indicator
            self_ref.loading = true
            if _G.StatusBar then _G.StatusBar.show_loading("Refreshing...") end
            ScreenManager.invalidate()

            set_timeout(function()
                self_ref:refresh_nodes()
                self_ref.loading = false
                if _G.StatusBar then _G.StatusBar.hide_loading() end
                ScreenManager.invalidate()
            end, 50)
        end
    })

    if #self.nodes > 0 then
        table.insert(items, {
            label = "Details",
            action = function()
                self_ref:view_details()
            end
        })

        -- Send Message option for selected node
        local selected_node = self.nodes[self.selected]
        if selected_node and selected_node.pub_key_hex then
            local pk, nm = selected_node.pub_key_hex, selected_node.name
            table.insert(items, {
                label = "Send Message",
                action = function()
                    spawn_screen("/scripts/ui/screens/dm_conversation.lua", pk, nm)
                end
            })
        end

        -- Add Contact option for selected node
        local selected_node = self.nodes[self.selected]
        if selected_node and selected_node.pub_key_hex then
            -- Check if already saved
            local already_saved = _G.Contacts and _G.Contacts.is_saved(selected_node.pub_key_hex)
            if not already_saved then
                table.insert(items, {
                    label = "Add Contact",
                    action = function()
                        if _G.Contacts and _G.Contacts.add then
                            local ok = _G.Contacts.add(selected_node)
                            if ok then
                                if _G.MessageBox then
                                    _G.MessageBox.show({title = "Contact saved"})
                                end
                            else
                                if _G.MessageBox then
                                    _G.MessageBox.show({title = "Failed to save"})
                                end
                            end
                            self_ref:refresh_nodes()
                            ScreenManager.invalidate()
                        end
                    end
                })
            end
        end

        -- Clock Sync option for nodes with timestamp
        local selected_node = self.nodes[self.selected]
        if selected_node and selected_node.timestamp and selected_node.timestamp > 0 then
            table.insert(items, {
                label = "Clock Sync",
                action = function()
                    -- Convert node's Unix timestamp to local time and set system clock
                    local ts = selected_node.timestamp
                    if ts and ts > 1000000000 then
                        -- Get time components from Unix timestamp
                        local date_info = os.date("*t", ts)
                        if date_info then
                            local ok = ez.system.set_time(
                                date_info.year,
                                date_info.month,
                                date_info.day,
                                date_info.hour,
                                date_info.min,
                                date_info.sec
                            )
                            if ok then
                                if _G.SoundUtils then pcall(_G.SoundUtils.confirm) end
                                if _G.MessageBox then
                                    _G.MessageBox.show({title = "", body = "Clock synced from " .. (selected_node.name or "node")})
                                end
                                -- Save sync timestamp
                                if ez.storage and ez.storage.set_pref then
                                    ez.storage.set_pref("lastTimeSet", ez.system.get_time_unix())
                                end
                            else
                                if _G.SoundUtils then pcall(_G.SoundUtils.error) end
                                if _G.MessageBox then
                                    _G.MessageBox.show({title = "Failed to sync clock"})
                                end
                            end
                        end
                    else
                        if _G.MessageBox then
                            _G.MessageBox.show({title = "Node has no valid timestamp"})
                        end
                    end
                end
            })
        end

        table.insert(items, {
            label = "Clear",
            action = function()
                -- Clear discovered cache in Contacts service
                if _G.Contacts and _G.Contacts.clear_discovered then
                    _G.Contacts.clear_discovered()
                end
                -- Refresh to show empty list
                self_ref:refresh_nodes()
                ScreenManager.invalidate()
            end
        })
    end

    return items
end

return Nodes
