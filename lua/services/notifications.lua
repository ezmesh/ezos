-- Notifications service: in-memory queue of system / app notices.
--
-- post()       creates a notification and emits "notifications/changed"
-- dismiss(id)  removes one
-- list()       returns the current set, newest first
-- unread_count() / mark_all_read()
--
-- Notifications are not persisted across reboots -- the OTA "reboot to
-- apply" notice is the canonical use case and that one specifically
-- shouldn't survive a reboot anyway. If a future use case needs
-- persistence, add a write-through to storage on every change.

local notifications = {}

local _items = {}        -- newest first
local _next_id = 1
local _max_items = 32     -- ring-buffer cap to keep memory bounded

local function emit_changed()
    if ez and ez.bus and ez.bus.post then
        ez.bus.post("notifications/changed", { count = #_items })
    end
end

-- Post a notification. opts shape:
--   title   string  required
--   body    string  optional
--   source  string  short tag, e.g. "ota" / "dm" / "system"
--   sticky  bool    if true, mark_all_read leaves it unread
--   action  table   { label, on_press } -- shown in the center
--   read    bool    initial read state (default false)
-- Returns the new notification's id.
-- Per-source mute: read `notify_<source>` (default "1" = on). Setting
-- the pref to "0" silences every post with that source tag without
-- needing to touch the calling site. Lets a Settings panel offer a
-- "Mute battery / DMs / file transfers" toggle later without churn.
local function source_muted(source)
    if not source or source == "" then return false end
    if not (ez and ez.storage and ez.storage.get_pref) then return false end
    local v = ez.storage.get_pref("notify_" .. source, "1")
    return v == "0" or v == 0 or v == false
end

-- ---------------------------------------------------------------------------
-- Do Not Disturb (issue #116)
-- ---------------------------------------------------------------------------
-- A simple time-window DND mode. Quiet hours are silent (no toast, no
-- sound) but unread counts still increment so the user sees the backlog
-- when they wake. Two exception toggles let critical traffic through:
-- "DMs from favourites" (starred contacts) and "channel mentions" (the
-- existing mention/all/none plumbing in services.channels still gates,
-- DND only widens the "off" side of it).
--
-- A manual DND toggle (`dnd_manual` = "0"/"1") overrides the schedule
-- both ways: setting it to "1" pins DND on regardless of the clock,
-- "0" turns the schedule's effective state off for the rest of the
-- current quiet window. The desktop status bar / notifications screen
-- can flip it.
--
-- Prefs (all NVS, names <= 15 chars):
--   dnd_enabled   "0"/"1"        Whether the schedule is active.
--   dnd_start     minutes 0..1439 (start of quiet window, default 22:00).
--   dnd_end       minutes 0..1439 (end of quiet window, default 07:00).
--                                 Window wraps midnight if end <= start.
--   dnd_favs      "0"/"1"        Let starred contacts ring through.
--   dnd_mentions  "0"/"1"        Let channel mentions ring through.
--   dnd_manual    "0"/"1"        Manual override (wins over schedule).
--
-- The evaluator runs after source_muted() in post(): if a source is
-- muted globally, DND can't un-mute it. DND just suppresses the
-- audible / visible path -- the notification still lands in the list
-- so the user catches up later.

local DND_DEFAULT_START   = 22 * 60   -- 22:00
local DND_DEFAULT_END     =  7 * 60   --  7:00

local function pref_str(key, default)
    if not (ez and ez.storage and ez.storage.get_pref) then return default end
    return ez.storage.get_pref(key, default)
end

local function pref_bool(key, default)
    local v = pref_str(key, default and "1" or "0")
    return v == "1" or v == 1 or v == true
end

local function pref_int(key, default)
    local v = pref_str(key, tostring(default))
    return tonumber(v) or default
end

local function in_quiet_window(now_min, start_min, end_min)
    -- Window wraps midnight if end_min <= start_min. Both endpoints
    -- are inclusive of the start, exclusive of the end, so a window
    -- of 22:00..07:00 covers [22:00, 24:00) U [00:00, 07:00).
    if start_min == end_min then return false end
    if start_min < end_min then
        return now_min >= start_min and now_min < end_min
    else
        return now_min >= start_min or now_min < end_min
    end
end

-- Returns true when DND is currently silencing audible/visible posts.
-- Manual override wins. When the wall clock is unset (year < 2020) the
-- schedule is treated as off (fail-open: noisy is recoverable, missed
-- messages aren't).
function notifications.dnd_active()
    if pref_bool("dnd_manual", false) then return true end
    if not pref_bool("dnd_enabled", false) then return false end
    if not (ez and ez.system and ez.system.get_time) then return false end
    local t = ez.system.get_time()
    if not t or not t.year or t.year < 2020 then return false end
    local now_min = (t.hour or 0) * 60 + (t.min or t.minute or 0)
    return in_quiet_window(now_min,
        pref_int("dnd_start", DND_DEFAULT_START),
        pref_int("dnd_end",   DND_DEFAULT_END))
end

-- A post is exempt from DND when it carries an exception flag the user
-- has allowed through. Two flags are wired today:
--   opts.dnd_fav      -- DM from a starred contact (set in boot.lua's
--                        DM subscriber after consulting contacts.is_favourite).
--   opts.dnd_mention  -- channel message that contains the user's
--                        node name (set in boot.lua's channel/message
--                        subscriber where the mention check already
--                        runs for the per-channel notify_mode).
-- Either gate is opt-in; the post-site decides whether the event
-- qualifies. DND code only consults the user's allow-through prefs.
local function dnd_exempt(opts)
    if opts.dnd_fav and pref_bool("dnd_favs", false) then return true end
    if opts.dnd_mention and pref_bool("dnd_mentions", false) then return true end
    return false
end

-- The on-device bitmap fonts only cover printable ASCII 0x20..0x7E
-- (see CLAUDE.md "On-device font character set"); anything else
-- renders as `[]` boxes. Notification title/body strings often come
-- from peer-originated mesh data (contact names, DM bodies, file
-- names) where there's no upstream guarantee on character set, so
-- sanitize centrally here rather than asking every call site to
-- remember.
local function ascii_safe(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("[^\32-\126]", "?"))
end

function notifications.post(opts)
    opts = opts or {}
    if not opts.title or opts.title == "" then return nil end
    if source_muted(opts.source) then return nil end

    -- DND keeps the item in the list (so unread counts still update
    -- and the user sees the backlog when they wake) but flags it
    -- silent so the toast / sound path is skipped. Exemptions
    -- (favourite-contact DMs, channel mentions) bypass the silence.
    local silent = false
    if notifications.dnd_active() and not dnd_exempt(opts) then
        silent = true
    end

    local n = {
        id        = _next_id,
        title     = ascii_safe(opts.title),
        body      = ascii_safe(opts.body),
        source    = opts.source or "system",
        sticky    = opts.sticky and true or false,
        action    = opts.action,
        read      = opts.read and true or false,
        silent    = silent,
        timestamp = ez.system.millis(),
    }
    _next_id = _next_id + 1
    table.insert(_items, 1, n)
    while #_items > _max_items do table.remove(_items) end
    emit_changed()
    return n.id
end

-- Variant of post() that suppresses the notification when the user is
-- already looking at the screen the notification would lead them to.
-- Useful for e.g. DM message notifications: if the user is sitting in
-- the conversation with that contact, a toast would be redundant
-- (and the screen itself already shows the new message).
--
-- `predicate` receives the current top screen instance and should
-- return true to suppress the post. When the screen stack is empty,
-- or no instance is on top yet, the post goes through unconditionally
-- so we never lose a notification during boot.
--
-- Returns the new notification id, or nil when suppressed.
function notifications.post_unless_focused(opts, predicate)
    if type(predicate) == "function" then
        local ok, screen = pcall(require, "ezui.screen")
        if ok and screen.peek then
            local inst = screen.peek()
            if inst then
                local pred_ok, suppress = pcall(predicate, inst)
                if pred_ok and suppress then return nil end
            end
        end
    end
    return notifications.post(opts)
end

function notifications.dismiss(id)
    for i, n in ipairs(_items) do
        if n.id == id then
            table.remove(_items, i)
            emit_changed()
            return true
        end
    end
    return false
end

-- Drop everything from one source. Useful for the OTA flow: when the
-- staged image changes (or a new OTA arrives), clear the prior reboot
-- notice so the user only sees the latest one.
function notifications.dismiss_source(source)
    local removed = false
    for i = #_items, 1, -1 do
        if _items[i].source == source then
            table.remove(_items, i)
            removed = true
        end
    end
    if removed then emit_changed() end
    return removed
end

function notifications.list() return _items end

function notifications.count() return #_items end

function notifications.unread_count()
    local c = 0
    for _, n in ipairs(_items) do if not n.read then c = c + 1 end end
    return c
end

-- Mark non-sticky entries as read. Sticky ones (e.g. OTA "reboot now")
-- keep blinking until the user actually does the thing.
function notifications.mark_all_read()
    local changed = false
    for _, n in ipairs(_items) do
        if not n.read and not n.sticky then
            n.read = true
            changed = true
        end
    end
    if changed then emit_changed() end
end

return notifications
