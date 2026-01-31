-- Nodes Screen for T-Deck OS
-- Compact list of all heard mesh nodes (live + cached)

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

    -- Clamp selection
    if self.selected > #self.nodes then
        self.selected = math.max(1, #self.nodes)
    end
    if self.selected < 1 then
        self.selected = 1
    end
end

-- Convert RSSI to signal indicator character
local function rssi_indicator(rssi)
    if rssi > -60 then return "+++"
    elseif rssi > -80 then return "++"
    elseif rssi > -100 then return "+"
    elseif rssi > -110 then return "-"
    else return "--"
    end
end

-- Format last seen timestamp as compact string
local function format_seen(timestamp)
    local now = ez.system.millis()
    local diff = math.floor((now - timestamp) / 1000)

    if diff < 60 then
        return "now"
    elseif diff < 3600 then
        return string.format("%dm", math.floor(diff / 60))
    elseif diff < 86400 then
        return string.format("%dh", math.floor(diff / 3600))
    else
        return string.format("%dd", math.floor(diff / 86400))
    end
end

-- Role abbreviation
local function role_abbrev(role)
    local ROLE = ez.mesh.ROLE
    if role == ROLE.CLIENT then return "C"
    elseif role == ROLE.REPEATER then return "R"
    elseif role == ROLE.ROUTER then return "Rt"
    elseif role == ROLE.GATEWAY then return "G"
    else return ""
    end
end

function Nodes:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Fill background
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

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

        -- Node name (truncated to fit column)
        local name = node.name or string.format("%02X", (node.path_hash or 0) % 256)
        -- Sanitize name (ASCII only)
        local clean_name = ""
        for c in name:gmatch(".") do
            local b = string.byte(c)
            if b >= 32 and b < 127 then
                clean_name = clean_name .. c
            end
        end
        if #clean_name == 0 then
            clean_name = string.format("%02X", (node.path_hash or 0) % 256)
        end

        -- Prefix for saved contacts
        if node.is_saved then
            clean_name = "*" .. clean_name
        end

        -- Truncate to fit within column (name_x to role_x with padding)
        local max_name_width = role_x - name_x - 4
        while #clean_name > 1 and display.text_width(clean_name) > max_name_width do
            clean_name = string.sub(clean_name, 1, #clean_name - 1)
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
        local role_str = role_abbrev(node.role or 0)
        if role_str ~= "" then
            display.draw_text(role_x, y + 2, role_str, text_color)
        end

        -- RSSI indicator
        local rssi = node.rssi or -999
        local rssi_str = rssi_indicator(rssi)
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
        local seen_str = format_seen(node.last_seen or 0)
        display.draw_text(seen_x, y + 2, seen_str, text_color)

        -- Hop count
        local hops = node.hops or 0
        if hops > 0 then
            display.draw_text(hops_x, y + 2, tostring(hops), text_color)
        end
    end

    -- Scrollbar
    if #self.nodes > self.VISIBLE_ROWS then
        local sb_x = w - scrollbar_width - 2
        local sb_top = list_start_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT

        -- Track
        display.fill_rect(sb_x, sb_top, 3, sb_height, colors.SURFACE)

        -- Thumb
        local thumb_height = math.max(10, math.floor(sb_height * self.VISIBLE_ROWS / #self.nodes))
        local scroll_range = #self.nodes - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top
        if scroll_range > 0 then
            thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)
        end

        display.fill_rect(sb_x, thumb_y, 3, thumb_height, colors.ACCENT)
    end

    -- Footer hint
    display.draw_text(4, h - 14, "M:Msg  R:Refresh  Enter:Details", colors.TEXT_MUTED)
end

function Nodes:handle_key(key)
    if key.special == "UP" then
        self:select_previous()
    elseif key.special == "DOWN" then
        self:select_next()
    elseif key.special == "LEFT" then
        -- Page up
        for _ = 1, self.VISIBLE_ROWS do
            self:select_previous()
        end
    elseif key.special == "RIGHT" then
        -- Page down
        for _ = 1, self.VISIBLE_ROWS do
            self:select_next()
        end
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

function Nodes:select_next()
    if #self.nodes == 0 then return end

    if self.selected < #self.nodes then
        self.selected = self.selected + 1
        if self.selected > self.scroll_offset + self.VISIBLE_ROWS then
            self.scroll_offset = self.scroll_offset + 1
        end
        ScreenManager.invalidate()
    end
end

function Nodes:select_previous()
    if #self.nodes == 0 then return end

    if self.selected > 1 then
        self.selected = self.selected - 1
        if self.selected <= self.scroll_offset then
            self.scroll_offset = self.scroll_offset - 1
        end
        ScreenManager.invalidate()
    end
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
