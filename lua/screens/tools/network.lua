-- Network screen (issue #130).
--
-- Lists every node we've heard via ADVERTs grouped by role:
-- Repeaters, Room servers, Other clients. Contacts and the user's
-- own node are filtered out -- they have their own surfaces.
--
-- Tap a row to open an info pane with the node's pubkey hash, last
-- advert time, hop count, advertised location (if any), and a
-- per-role action set:
--
--   Chat clients : "Add as contact"
--   Room servers : "Join channel" (prefills the channel-add form)
--   Repeaters    : info only
--
-- The list polls ez.mesh.get_nodes() at ~1 Hz while the screen is
-- focused (the mesh stack does not emit a "nodes changed" bus event
-- yet), rebuilding only when the fingerprint actually changes so the
-- user's focus and scroll survive across refreshes. Mirrors the
-- approach used by screens/chat/contacts.lua's Nearby tab.

local ui            = require("ezui")
local icons         = require("ezui.icons")
local screen_mod    = require("ezui.screen")
local contacts_svc  = require("services.contacts")

local Network = { title = "Network" }

-- Role ids mirrored from src/mesh/meshcore.h:
--   0 = ROLE_UNKNOWN, 1 = CLIENT, 2 = REPEATER, 3 = ROUTER (room),
--   4 = SENSOR, 5 = GATEWAY.
local ROLE_CLIENT   = 1
local ROLE_REPEATER = 2
local ROLE_ROUTER   = 3

-- Sanitize peer-originated strings to printable ASCII so the bitmap
-- font's missing-glyph boxes don't appear in titles. Mirrors the
-- sanitisation used elsewhere on ADVERT-derived names.
local function ascii_safe(s)
    if type(s) ~= "string" or s == "" then return s end
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        out[#out + 1] = string.char((b >= 0x20 and b <= 0x7E) and b or 0x3F)
    end
    return table.concat(out)
end

-- Format the time-since-last-advert in a fixed-width-ish way so the
-- subtitle column visually aligns across rows. ASCII only -- this
-- string lands in draw_text on the device.
local function format_age(age_seconds)
    if type(age_seconds) ~= "number" or age_seconds < 0 then
        return "?"
    end
    if age_seconds < 60         then return tostring(math.floor(age_seconds)) .. "s ago" end
    if age_seconds < 60 * 60    then return tostring(math.floor(age_seconds / 60)) .. " min ago" end
    if age_seconds < 24 * 3600  then return tostring(math.floor(age_seconds / 3600)) .. " h ago" end
    return tostring(math.floor(age_seconds / 86400)) .. " d ago"
end

local function format_hops(hops)
    if type(hops) ~= "number" then return "" end
    if hops <= 0 then return "direct" end
    if hops == 1 then return "1 hop"  end
    return tostring(hops) .. " hops"
end

-- Get a snapshot of nodes grouped by role. Skips the user's own node
-- and anything already in the contacts list (those have their own
-- surfaces in Chat -> Contacts). Sort each group by recency so the
-- freshest sighting bubbles to the top.
local function gather_grouped()
    local groups = { repeaters = {}, rooms = {}, others = {} }
    if not ez.mesh.is_initialized() then return groups end

    local nodes  = ez.mesh.get_nodes() or {}
    local my_pub = ez.mesh.get_public_key_hex and
                   ez.mesh.get_public_key_hex() or nil

    for _, n in ipairs(nodes) do
        if not (my_pub and n.pub_key_hex == my_pub) then
            if n.role == ROLE_REPEATER then
                groups.repeaters[#groups.repeaters + 1] = n
            elseif n.role == ROLE_ROUTER then
                groups.rooms[#groups.rooms + 1] = n
            elseif n.role == ROLE_CLIENT or n.role == 0 then
                if not (n.pub_key_hex and contacts_svc.is_contact(n.pub_key_hex)) then
                    groups.others[#groups.others + 1] = n
                end
            end
        end
    end

    local function by_recency(a, b)
        return (a.age_seconds or math.huge) < (b.age_seconds or math.huge)
    end
    table.sort(groups.repeaters, by_recency)
    table.sort(groups.rooms,     by_recency)
    table.sort(groups.others,    by_recency)
    return groups
end

-- Cheap fingerprint of the visible set. Includes role, pubkey, name,
-- and a coarse age bucket so a row's "x min ago" updating once per
-- minute triggers a rebuild, but a 1 Hz poll while the age is steady
-- doesn't. Same trick as contacts.lua's Nearby fingerprint.
local function fingerprint(groups)
    local parts = {}
    for _, g in ipairs({ "repeaters", "rooms", "others" }) do
        parts[#parts + 1] = g .. "#" .. tostring(#groups[g])
        for _, n in ipairs(groups[g]) do
            local age_bucket = math.floor((n.age_seconds or 0) / 60)
            parts[#parts + 1] = (n.pub_key_hex or n.name or ""):sub(1, 12)
                .. "@" .. tostring(age_bucket)
        end
    end
    return table.concat(parts, "|")
end

-- Info-pane sub-screen for a single node. Shows the bits of the
-- ADVERT we kept around plus a per-role action set. Pulls the
-- live record from get_nodes() inside build() so a fresh ADVERT
-- updates the rssi / age in-place.
local function open_info(node)
    local Info = { title = node.name and ascii_safe(node.name) or "Node" }

    function Info:build(state)
        -- Refresh from the live node table by pub_key_hex so the
        -- screen always shows current data when re-rendered.
        local fresh = node
        if node.pub_key_hex then
            for _, n in ipairs(ez.mesh.get_nodes() or {}) do
                if n.pub_key_hex == node.pub_key_hex then
                    fresh = n
                    break
                end
            end
        end

        local items = {}
        local title = fresh.name and ascii_safe(fresh.name) or "Node"
        if title == "" then title = "(unnamed)" end
        items[#items + 1] = ui.title_bar(title, { back = true })

        local lines = {}
        local function add_field(label, value)
            if value == nil or value == "" then return end
            lines[#lines + 1] = ui.padding({ 4, 12, 0, 12 },
                ui.text_widget(label, { font = "small_aa", color = "TEXT_SEC" }))
            lines[#lines + 1] = ui.padding({ 0, 12, 4, 12 },
                ui.text_widget(value, { font = "small_aa", wrap = true }))
        end

        -- Role label drives the "what to do with this" actions
        -- further down, so format it explicitly for the user.
        local role_label = "Unknown"
        if fresh.role == ROLE_CLIENT      then role_label = "Chat client"
        elseif fresh.role == ROLE_REPEATER then role_label = "Repeater"
        elseif fresh.role == ROLE_ROUTER   then role_label = "Room server"
        end
        add_field("Role", role_label)

        if fresh.pub_key_hex then
            local short = fresh.pub_key_hex:sub(1, 16) .. "..."
            add_field("Pubkey", short)
        end
        add_field("Last seen",
            (fresh.age_seconds and format_age(fresh.age_seconds)) or nil)
        if fresh.hops then add_field("Distance", format_hops(fresh.hops)) end
        if type(fresh.rssi) == "number" and fresh.rssi < 0 then
            add_field("Signal",
                string.format("%d dBm  (SNR %.1f)",
                    math.floor(fresh.rssi), fresh.snr or 0))
        end
        if fresh.has_location then
            add_field("Location",
                string.format("%.4f, %.4f", fresh.lat or 0, fresh.lon or 0))
        end

        -- Per-role actions. Disabled actions are still surfaced so
        -- the user understands the per-role contract -- e.g. the
        -- "Join channel" entry on a repeater shows up greyed-out,
        -- explaining why we can't act on it.
        if fresh.role == ROLE_CLIENT then
            local pkh = fresh.pub_key_hex
            local already = pkh and contacts_svc.is_contact(pkh)
            lines[#lines + 1] = ui.list_item({
                title = already and "Already in contacts" or "Add as contact",
                subtitle = already and "Open the Contacts app to manage"
                                   or "Save this node to your contacts list",
                icon = icons.users,
                disabled = (not pkh) or already,
                on_press = function()
                    if pkh and not already then
                        contacts_svc.add(pkh, ascii_safe(fresh.name or "Unknown"), "")
                        self:set_state({})
                    end
                end,
            })
        elseif fresh.role == ROLE_ROUTER then
            local nm = ascii_safe(fresh.name or "")
            lines[#lines + 1] = ui.list_item({
                title = "Join channel...",
                subtitle = "Open the join form with a password prompt",
                icon = icons.radio_tower,
                disabled = (nm == ""),
                on_press = function()
                    if nm == "" then return end
                    -- Prefill the channel-add form with the room
                    -- server's advertised name -- the user supplies
                    -- the password (room servers do NOT broadcast
                    -- their channel password; only the operator
                    -- can share it out-of-band).
                    local ChannelAdd = require("screens.chat.channel_add")
                    screen_mod.push(screen_mod.create(ChannelAdd, {
                        name = nm,
                        password = "",
                    }))
                end,
            })
        end

        items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, lines))
        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function Info:handle_key(key)
        if key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    return Info
end

local function open_info_for(node)
    local Info = open_info(node)
    screen_mod.push(screen_mod.create(Info, {}))
end

-- Build a section: a small header row followed by zero-or-more
-- list_item rows. Returns the items appended (so the caller can
-- vbox them with everything else).
local function section(items, label, count, nodes_in_section, screen)
    items[#items + 1] = ui.padding({ 8, 8, 2, 8 },
        ui.text_widget(label .. " (" .. tostring(count) .. ")", {
            font = "small_aa", color = "TEXT_SEC",
        })
    )
    if count == 0 then
        items[#items + 1] = ui.padding({ 2, 16, 4, 16 },
            ui.text_widget("None heard yet.", {
                font = "small_aa", color = "TEXT_MUTED",
            })
        )
        return
    end

    for _, n in ipairs(nodes_in_section) do
        local name = ascii_safe(n.name or "")
        if name == "" then name = "(unnamed)" end
        local sub_parts = {}
        sub_parts[#sub_parts + 1] = format_age(n.age_seconds or 0)
        local h = format_hops(n.hops)
        if h ~= "" then sub_parts[#sub_parts + 1] = h end
        if type(n.rssi) == "number" and n.rssi < 0 then
            sub_parts[#sub_parts + 1] = tostring(math.floor(n.rssi)) .. "dBm"
        end
        -- The bullet character lives outside the bitmap font's ASCII
        -- range, so use the existing pipe convention used elsewhere
        -- in status strips.
        local subtitle = table.concat(sub_parts, "  |  ")

        items[#items + 1] = ui.list_item({
            title    = name,
            subtitle = subtitle,
            icon     = icons.radio_tower,
            on_press = function() open_info_for(n) end,
        })
    end
end

function Network:build(state)
    local groups = gather_grouped()
    local items = {}
    items[#items + 1] = ui.title_bar("Network", { back = true })

    local list_items = {}
    section(list_items, "Repeaters",     #groups.repeaters, groups.repeaters, self)
    section(list_items, "Room servers",  #groups.rooms,     groups.rooms,     self)
    section(list_items, "Other clients", #groups.others,    groups.others,    self)

    if #groups.repeaters == 0 and #groups.rooms == 0 and #groups.others == 0 then
        list_items[#list_items + 1] = ui.padding({ 12, 16, 4, 16 },
            ui.text_widget("No nodes heard yet. Stay near the antenna and "
                .. "wait for adverts to arrive.", {
                font = "small_aa", color = "TEXT_MUTED", wrap = true,
            })
        )
    end

    items[#items + 1] = ui.scroll(
        { grow = 1, scroll_offset = state.scroll or 0 },
        ui.vbox({ gap = 0 }, list_items))

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Network:on_enter()
    self._last_refresh = 0
    self._fp = nil
    -- contacts/changed re-renders because we filter contacts out of
    -- the "Other clients" group; an add inside the info pane should
    -- be reflected in the list when the user backs out.
    self._sub = ez.bus.subscribe("contacts/changed", function()
        self:set_state({})
    end)
end

function Network:on_leave()
    if self._sub then ez.bus.unsubscribe(self._sub); self._sub = nil end
end

function Network:on_exit() self:on_leave() end

-- Poll get_nodes() at ~1 Hz and rebuild only when the visible set
-- (or any row's coarse age bucket) actually changes. Mesh has no
-- "nodes changed" bus event, so this is the cheapest way to surface
-- new arrivals without spamming rebuilds at every frame.
function Network:update()
    local now = ez.system.millis()
    if now - (self._last_refresh or 0) < 1000 then return end
    self._last_refresh = now
    local fp = fingerprint(gather_grouped())
    if fp ~= self._fp then
        self._fp = fp
        self:set_state({})
    end
end

function Network:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Network
