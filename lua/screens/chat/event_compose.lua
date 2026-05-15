-- Event compose screen
-- Small form to build a cal/v1 share URL for an event/meetup. The
-- caller passes an on_submit(url) callback through initial_state so
-- the same screen can drive both DM and channel chat compose flows.
--
-- Date/time entry is two text fields (YYYY-MM-DD, HH:MM) parsed into
-- a unix timestamp at submit. Duration is in minutes, with a 24h
-- ceiling that mirrors sharing.lua's CAL_DUR_MAX. Optional "Use my
-- GPS location" lifts the current fix from the GPS service when
-- enabled.

local ui = require("ezui")
local sharing_svc = require("services.sharing")
local gps_svc = require("services.gps")
local screen_mod = require("ezui.screen")

local EventCompose = { title = "Attach event" }

-- Build a unix timestamp from broken-down UTC fields. The device's
-- lua doesn't expose timegm(); compute via the Howard Hinnant
-- days-from-civil algorithm so we don't depend on the host clock.
local function timegm(y, mo, d, h, mi)
    -- Adjust so March is month 1, Feb is month 12 of the prior year;
    -- this keeps leap-day arithmetic on the year boundary, where it's
    -- easy to reason about.
    if mo <= 2 then y = y - 1; mo = mo + 12 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (mo - 3) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + h * 3600 + mi * 60
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function parse_date(s)
    local y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    if mo < 1 or mo > 12 then return nil end
    -- Per-month max with Gregorian leap-year rule. Without this,
    -- the Howard Hinnant arithmetic in timegm() silently rolls
    -- impossible days into the next month (2026-02-30 -> 2026-03-02)
    -- and the receiver would see the wrong date.
    local is_leap = (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
    local max_d = MONTH_DAYS[mo] + ((mo == 2 and is_leap) and 1 or 0)
    if d < 1 or d > max_d then return nil end
    return y, mo, d
end

local function parse_time(s)
    local h, mi = s:match("^(%d%d):(%d%d)$")
    if not h then return nil end
    h, mi = tonumber(h), tonumber(mi)
    if h < 0 or h > 23 or mi < 0 or mi > 59 then return nil end
    return h, mi
end

-- "YYYY-MM-DD HH:MM" formatter for the default state. Uses today's
-- date + the next round half-hour so the form starts populated with
-- something sensible.
local function default_when()
    local now = ez.system.get_time_unix() or 0
    if now <= 0 then return "", "" end
    -- Round up to the next half hour. Manual since os.date isn't
    -- guaranteed to be UTC on this stack.
    local soon = now + 30 * 60 - (now % 1800)
    local days = math.floor(soon / 86400)
    local secs = soon - days * 86400
    local h = math.floor(secs / 3600)
    local mi = math.floor((secs % 3600) / 60)
    -- Convert epoch days back to YYYY-MM-DD (Howard Hinnant civil_from_days).
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local mo = mp + (mp < 10 and 3 or -9)
    if mo <= 2 then y = y + 1 end
    return string.format("%04d-%02d-%02d", y, mo, d),
           string.format("%02d:%02d", h, mi)
end

function EventCompose.initial_state(opts)
    opts = opts or {}
    local d, t = default_when()
    return {
        title = "",
        date = d,
        time = t,
        duration_min = "60",
        use_gps = false,
        error = nil,
        on_submit = opts.on_submit,
    }
end

local function row(label, input)
    return {
        ui.padding({ 6, 8, 2, 8 },
            ui.text_widget(label, { font = "small_aa", color = "TEXT_SEC" })),
        ui.padding({ 0, 8, 4, 8 }, input),
    }
end

function EventCompose:build(state)
    local items = { ui.title_bar("Attach event", { back = true }) }
    local form = {}

    for _, w in ipairs(row("Title",
        ui.text_input({
            value = state.title or "",
            placeholder = "Meet at the park",
            on_change = function(v) state.title = v end,
        }))) do form[#form + 1] = w end

    for _, w in ipairs(row("Date (YYYY-MM-DD UTC)",
        ui.text_input({
            value = state.date or "",
            placeholder = "2026-05-15",
            on_change = function(v) state.date = v end,
        }))) do form[#form + 1] = w end

    for _, w in ipairs(row("Time (HH:MM UTC)",
        ui.text_input({
            value = state.time or "",
            placeholder = "18:00",
            on_change = function(v) state.time = v end,
        }))) do form[#form + 1] = w end

    for _, w in ipairs(row("Duration (minutes, max 1440)",
        ui.text_input({
            value = state.duration_min or "60",
            placeholder = "60",
            on_change = function(v) state.duration_min = v end,
        }))) do form[#form + 1] = w end

    form[#form + 1] = ui.padding({ 6, 8, 4, 8 },
        ui.toggle("Attach my GPS location", state.use_gps and true or false, {
            on_change = function(v) state.use_gps = v end,
        }))

    if state.error then
        form[#form + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.text_widget(state.error, { font = "small_aa", color = "ERROR" }))
    end

    form[#form + 1] = ui.padding({ 8, 8, 8, 8 },
        ui.button("Send", {
            on_press = function() self:_submit() end,
        }))

    form[#form + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget("All fields use UTC. Title is sanitized to ASCII.", {
            font = "small_aa",
            color = "TEXT_MUTED",
            wrap = true,
        }))

    items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, form))
    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function EventCompose:_submit()
    local s = self._state
    local title = s.title or ""
    if title == "" then
        self:set_state({ error = "Enter a title" })
        return
    end

    local y, mo, d = parse_date(s.date or "")
    if not y then
        self:set_state({ error = "Date must be YYYY-MM-DD" })
        return
    end
    local h, mi = parse_time(s.time or "")
    if not h then
        self:set_state({ error = "Time must be HH:MM (24h)" })
        return
    end
    local ts = timegm(y, mo, d, h, mi)

    local dur_min = tonumber(s.duration_min)
    if not dur_min or dur_min <= 0 then
        self:set_state({ error = "Duration must be a positive number" })
        return
    end
    if dur_min > 1440 then dur_min = 1440 end

    local lat, lon
    if s.use_gps then
        local loc = gps_svc.get_location()
        if not loc or not loc.valid then
            self:set_state({ error = "No GPS fix - disable to send without coords" })
            return
        end
        lat = loc.lat
        lon = loc.lon
    end

    local url, err = sharing_svc.encode_cal(ts, dur_min * 60, title, lat, lon)
    if not url then
        self:set_state({ error = err or "Could not build URL" })
        return
    end

    local cb = s.on_submit
    screen_mod.pop()
    if cb then cb(url) end
end

function EventCompose:handle_key(key)
    local focus_mod = require("ezui.focus")
    if not focus_mod.editing then
        if key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
    end
    return nil
end

return EventCompose
