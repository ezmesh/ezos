-- Cross-cutting search screen. Hunts contacts / channels / DM history /
-- channel history / settings panels for a substring of the query. v1 is
-- case-insensitive plain substring; no fuzzy / regex / index. On a
-- T-Deck with the typical history size, a linear scan is fast enough.
--
-- Results land in five groups, each capped at 10 rows so a busy query
-- doesn't push the most-relevant matches off-screen. Tap a row to jump
-- to the right screen.

local ui          = require("ezui")
local screen_mod  = require("ezui.screen")
local theme       = require("ezui.theme")

local contacts_svc      = require("services.contacts")
local channels_svc      = require("services.channels")
local dm_svc            = require("services.direct_messages")

local Search = { title = "Search" }

local PER_GROUP_CAP = 10
local DEBOUNCE_MS   = 150

-- Static registry of settings panels. Hand-maintained -- adding a new
-- panel that should be searchable means adding an entry here.
-- Subtitle gives the search engine extra keywords to hit on (e.g.
-- searching "brightness" still finds Display via the subtitle).
local SETTINGS_PANELS = {
    { title = "Display",   subtitle = "Brightness, theme, wallpaper, accent",
      mod = "screens.settings.display_settings" },
    { title = "WiFi",      subtitle = "Scan, connect, save credentials",
      mod = "screens.settings.wifi_settings" },
    { title = "Keyboard",  subtitle = "Repeat, trackball",
      mod = "screens.settings.keyboard_settings" },
    { title = "GPS",       subtitle = "Power, clock sync, constellations",
      mod = "screens.settings.gps_settings" },
    { title = "Map",       subtitle = "Peer pins, staleness",
      mod = "screens.settings.map_settings" },
    { title = "Time",      subtitle = "Timezone, 12 / 24h format, NTP",
      mod = "screens.settings.time_settings" },
    { title = "Radio",     subtitle = "Mesh advert, announce cadence",
      mod = "screens.settings.radio_settings" },
    { title = "Sound",     subtitle = "UI feedback, volume",
      mod = "screens.settings.sound_settings" },
    { title = "Firmware",  subtitle = "OTA update, install rolling-main",
      mod = "screens.settings.firmware_update" },
    { title = "What's New",subtitle = "Changelog for this firmware",
      mod = "screens.settings.whats_new" },
}

local function ascii_lower(s)
    if type(s) ~= "string" then return "" end
    -- Lua string.lower works on bytes; ASCII letters get mapped.
    -- Non-ASCII bytes pass through unchanged, which is fine because
    -- the caller substring-matches against another lower()'d string
    -- using the same byte semantics.
    return s:lower()
end

-- Strip non-printable-ASCII bytes from peer-originated strings before
-- they reach `draw_text`. Same policy services/notifications uses --
-- the on-device bitmap fonts only cover 0x20..0x7E and anything else
-- paints as a `[]` box (see CLAUDE.md "On-device font character set").
local function ascii_safe(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("[^\32-\126]", "?"))
end

local function snippet(text, query, max_len)
    if not text then return "" end
    if #text <= max_len then return text end
    local lo_text = ascii_lower(text)
    local lo_query = ascii_lower(query)
    local hit = lo_text:find(lo_query, 1, true)
    if hit then
        -- Center the snippet on the hit so the user sees context.
        local start = math.max(1, hit - math.floor(max_len / 3))
        local stop = math.min(#text, start + max_len)
        local prefix = start > 1 and "..." or ""
        local suffix = stop < #text and "..." or ""
        return prefix .. text:sub(start, stop) .. suffix
    end
    return text:sub(1, max_len) .. "..."
end

-- Walk a list of records, accumulate matches up to PER_GROUP_CAP +1
-- (the extra slot is used to mark "More..." truncation). The caller
-- supplies how to extract searchable text and how to render a match.
local function scan_list(records, query, extract, max)
    local out = {}
    local lo_query = ascii_lower(query)
    for _, rec in ipairs(records) do
        local hay = extract(rec)
        if hay and ascii_lower(hay):find(lo_query, 1, true) then
            out[#out + 1] = rec
            if #out > max then break end
        end
    end
    return out
end

-- Open the DM conversation with the matching contact.
local function open_contact_dm(c)
    local DMConv = require("screens.chat.dm_conversation")
    screen_mod.push(screen_mod.create(DMConv,
        { contact_key = c.pub_key_hex }))
end

local function open_channel_chat(channel_name)
    local Chat = require("screens.chat.channel_chat")
    screen_mod.push(screen_mod.create(Chat, { channel = channel_name }))
end

local function open_settings_panel(mod_name)
    -- Mirrors how the menu screen loads sub-panels.
    local def = require(mod_name)
    local initial = def.initial_state and def.initial_state() or {}
    screen_mod.push(screen_mod.create(def, initial))
end

-- Run every search source and merge results into a single tree the
-- build() function will turn into a list. Returns a list of groups:
--   { label, rows, truncated }
local function run_search(query)
    local groups = {}

    -- Contacts: search name + pubkey-hex prefix (first 12 hex chars).
    local contacts_all = contacts_svc.get_all()
    local cmatches = scan_list(contacts_all, query, function(c)
        return (c.name or "") .. " " .. (c.pub_key_hex or ""):sub(1, 12)
    end, PER_GROUP_CAP)
    local crows = {}
    for i = 1, math.min(#cmatches, PER_GROUP_CAP) do
        local c = cmatches[i]
        crows[#crows + 1] = ui.list_item({
            title    = ascii_safe(c.name or c.pub_key_hex:sub(1, 8)),
            subtitle = c.pub_key_hex:sub(1, 12) .. "...",
            on_press = function() open_contact_dm(c) end,
        })
    end
    if #crows > 0 then
        groups[#groups + 1] = {
            label     = "Contacts",
            rows      = crows,
            truncated = #cmatches > PER_GROUP_CAP,
        }
    end

    -- Channels: name match.
    local channels_all = channels_svc.get_list() or {}
    local chrows = {}
    local ch_hits = 0
    for _, ch in ipairs(channels_all) do
        if ascii_lower(ch.name or ""):find(ascii_lower(query), 1, true) then
            ch_hits = ch_hits + 1
            if ch_hits <= PER_GROUP_CAP then
                local name = ch.name
                chrows[#chrows + 1] = ui.list_item({
                    title    = ascii_safe(name),
                    subtitle = "Channel",
                    on_press = function() open_channel_chat(name) end,
                })
            end
        end
    end
    if ch_hits > 0 then
        groups[#groups + 1] = {
            label     = "Channels",
            rows      = chrows,
            truncated = ch_hits > PER_GROUP_CAP,
        }
    end

    -- DM history. Linear scan across every conversation.
    local dm_rows = {}
    local dm_hits = 0
    local conversations = dm_svc.get_conversations() or {}
    for _, conv in ipairs(conversations) do
        local pub_key_hex = conv.pub_key_hex
        local hist = dm_svc.get_history(pub_key_hex)
        if hist then
            for _, msg in ipairs(hist) do
                if msg.text and ascii_lower(msg.text):find(ascii_lower(query), 1, true) then
                    dm_hits = dm_hits + 1
                    if dm_hits <= PER_GROUP_CAP then
                        local contact = contacts_svc.get(pub_key_hex)
                        local who = ascii_safe((contact and contact.name)
                            or pub_key_hex:sub(1, 8))
                        local prefix = msg.is_self and "You" or who
                        dm_rows[#dm_rows + 1] = ui.list_item({
                            title    = prefix .. ": " .. ascii_safe(snippet(msg.text, query, 40)),
                            subtitle = "DM with " .. who,
                            on_press = function()
                                local DMConv = require("screens.chat.dm_conversation")
                                screen_mod.push(screen_mod.create(DMConv,
                                    { contact_key = pub_key_hex }))
                            end,
                        })
                    end
                end
            end
        end
    end
    if dm_hits > 0 then
        groups[#groups + 1] = {
            label     = "Messages (DM)",
            rows      = dm_rows,
            truncated = dm_hits > PER_GROUP_CAP,
        }
    end

    -- Channel history.
    local ch_msg_rows = {}
    local ch_msg_hits = 0
    for _, ch in ipairs(channels_all) do
        local hist = channels_svc.get_history(ch.name)
        if hist then
            for _, msg in ipairs(hist) do
                if msg.text and ascii_lower(msg.text):find(ascii_lower(query), 1, true) then
                    ch_msg_hits = ch_msg_hits + 1
                    if ch_msg_hits <= PER_GROUP_CAP then
                        local channel_name = ch.name
                        local sender = ascii_safe(msg.sender_name or "?")
                        ch_msg_rows[#ch_msg_rows + 1] = ui.list_item({
                            title    = sender .. ": " .. ascii_safe(snippet(msg.text, query, 40)),
                            subtitle = "in " .. ascii_safe(channel_name),
                            on_press = function()
                                open_channel_chat(channel_name)
                            end,
                        })
                    end
                end
            end
        end
    end
    if ch_msg_hits > 0 then
        groups[#groups + 1] = {
            label     = "Messages (channel)",
            rows      = ch_msg_rows,
            truncated = ch_msg_hits > PER_GROUP_CAP,
        }
    end

    -- Settings panels. Static list; cheap to walk.
    local settings_rows = {}
    for _, p in ipairs(SETTINGS_PANELS) do
        local hay = (p.title or "") .. " " .. (p.subtitle or "")
        if ascii_lower(hay):find(ascii_lower(query), 1, true) then
            settings_rows[#settings_rows + 1] = ui.list_item({
                title    = p.title,
                subtitle = p.subtitle,
                on_press = function() open_settings_panel(p.mod) end,
            })
        end
    end
    if #settings_rows > 0 then
        groups[#groups + 1] = {
            label     = "Settings",
            rows      = settings_rows,
            truncated = false,
        }
    end

    return groups
end

function Search.initial_state()
    return {
        query        = "",
        last_input_ms = 0,
        groups       = nil,
        running      = false,
    }
end

function Search:on_enter()
    -- Land focus on the input so typing the query is zero-setup.
    self:_rebuild()
    local focus_mod = require("ezui.focus")
    if #focus_mod.chain > 0 then
        focus_mod.index = 1
        focus_mod._update_marks()
        focus_mod.enter_edit()
    end
end

-- Debounce: only run the search when the query has settled for
-- DEBOUNCE_MS milliseconds. Reading state from a private field on the
-- screen instance dodges the cost of carrying everything through
-- set_state on every keystroke.
function Search:update()
    local s = self._state
    if not s.query or s.query == "" then return end
    local now = ez.system.millis()
    if (now - (s.last_input_ms or 0)) >= DEBOUNCE_MS
            and s._last_run_query ~= s.query then
        -- Snapshot the query into a value local before yielding.
        -- `s` and `self._state` point at the same table, so an
        -- `s.query == self._state.query` check after the yield is
        -- always true and the stale-result guard is a no-op.
        local q = s.query
        s._last_run_query = q
        spawn(function()
            local groups = run_search(q)
            -- The user may have kept typing while we yielded; only
            -- accept the result if the query hasn't moved on.
            if self._state.query == q then
                self._state.groups = groups
                self:set_state({})
            end
        end)
    end
end

function Search:build(state)
    local items = { ui.title_bar("Search", { back = true }) }

    items[#items + 1] = ui.padding({ 4, 6, 2, 6 },
        ui.text_input({
            value        = state.query or "",
            placeholder  = "Search contacts, messages, settings...",
            on_change    = function(val)
                state.query = val
                state.last_input_ms = ez.system.millis()
            end,
        }))

    local body = {}
    if not state.query or #state.query < 2 then
        body[#body + 1] = ui.padding({ 30, 12, 12, 12 },
            ui.text_widget("Type 2+ characters to start searching.",
                { color = "TEXT_MUTED", text_align = "center" }))
    elseif state.groups == nil then
        body[#body + 1] = ui.padding({ 30, 12, 12, 12 },
            ui.text_widget("Searching...",
                { color = "TEXT_MUTED", text_align = "center" }))
    elseif #state.groups == 0 then
        body[#body + 1] = ui.padding({ 30, 12, 12, 12 },
            ui.text_widget("No matches.",
                { color = "TEXT_MUTED", text_align = "center" }))
    else
        for _, group in ipairs(state.groups) do
            body[#body + 1] = ui.padding({ 8, 8, 2, 8 },
                ui.text_widget(group.label,
                    { color = "ACCENT", font = "small_aa" }))
            for _, row in ipairs(group.rows) do
                body[#body + 1] = row
            end
            if group.truncated then
                body[#body + 1] = ui.list_item({
                    title    = "More...",
                    subtitle = "(refine the query)",
                    disabled = true,
                })
            end
        end
    end

    items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, body))

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Search:handle_key(key)
    if key.special == "BACKSPACE" then
        local focus_mod = require("ezui.focus")
        -- Don't intercept BACKSPACE while editing the query.
        if focus_mod.editing then return nil end
        return "pop"
    end
    if key.special == "ESCAPE" then return "pop" end
    return nil
end

return Search
