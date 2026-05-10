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

    local n = {
        id        = _next_id,
        title     = ascii_safe(opts.title),
        body      = ascii_safe(opts.body),
        source    = opts.source or "system",
        sticky    = opts.sticky and true or false,
        action    = opts.action,
        read      = opts.read and true or false,
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
