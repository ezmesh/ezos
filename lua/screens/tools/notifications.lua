-- Notifications center: list of recent notifications.
--
-- Tap (or ENTER) on an entry that has an action opens a context menu
-- with the action + Dismiss as separate buttons -- earlier this fired
-- the action immediately, which meant accidentally hovering Enter on
-- the OTA "Firmware ready" notice was enough to reboot the device.
-- Notifications without an action dismiss directly (still the old
-- behaviour). BACKSPACE on the focused entry dismisses just that
-- one; the empty-list path returns the user to the previous screen
-- so the back key still feels intuitive.

local ui         = require("ezui")
local icons      = require("ezui.icons")
local screen_mod = require("ezui.screen")
local notifications = require("services.notifications")

-- Push a small action picker so destructive notification actions
-- (reboot, etc) need a deliberate second click.
local function show_action_menu(n)
    local Menu = { title = n.title or "Notification" }

    function Menu:build(_state)
        local items = {}
        items[#items + 1] = ui.title_bar(n.title or "Notification",
            { back = true })

        if n.body and n.body ~= "" then
            items[#items + 1] = ui.padding({ 8, 12, 6, 12 },
                ui.text_widget(n.body,
                    { font = "small_aa", color = "TEXT_MUTED", wrap = true }))
        end

        local actions = {}
        if n.action and type(n.action.on_press) == "function" then
            actions[#actions + 1] = ui.list_item({
                title    = n.action.label or "Run",
                subtitle = "Run this notification's action",
                on_press = function()
                    -- Pop the menu first so a long action (e.g. a
                    -- reboot that returns immediately) doesn't leave
                    -- a stale menu instance focused.
                    screen_mod.pop()
                    n.action.on_press()
                end,
            })
        end
        actions[#actions + 1] = ui.list_item({
            title    = "Dismiss",
            subtitle = "Remove from this list",
            on_press = function()
                notifications.dismiss(n.id)
                screen_mod.pop()
            end,
        })
        actions[#actions + 1] = ui.list_item({
            title    = "Cancel",
            subtitle = "Keep notification, go back",
            on_press = function() screen_mod.pop() end,
        })

        items[#items + 1] = ui.scroll({ grow = 1 },
            ui.vbox({ gap = 0 }, actions))

        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function Menu:handle_key(k)
        if k.special == "BACKSPACE" or k.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    screen_mod.push(screen_mod.create(Menu, {}))
end

local Center = { title = "Notifications" }

local function fmt_age(ts_ms)
    local now = ez.system.millis()
    local age = math.max(0, math.floor((now - (ts_ms or now)) / 1000))
    if age < 60   then return age .. "s ago" end
    if age < 3600 then return math.floor(age / 60) .. "m ago" end
    return math.floor(age / 3600) .. "h ago"
end

function Center.initial_state()
    return { focus_id = nil }
end

function Center:on_enter()
    -- Mark non-sticky as read once the user actually sees the list.
    notifications.mark_all_read()

    self._sub = ez.bus.subscribe("notifications/changed", function()
        self:set_state({})
    end)
end

function Center:on_exit()
    if self._sub then ez.bus.unsubscribe(self._sub); self._sub = nil end
end

function Center:build(state)
    local items = notifications.list()
    local content = {}

    if #items == 0 then
        content[#content + 1] = ui.padding({ 24, 14, 6, 14 },
            ui.text_widget("No notifications.", {
                color = "TEXT_MUTED", text_align = "center",
            }))
        content[#content + 1] = ui.padding({ 4, 14, 4, 14 },
            ui.text_widget("Background events post here when something needs your attention.", {
                color = "TEXT_MUTED", font = "small_aa", wrap = true,
                text_align = "center",
            }))
    else
        for _, n in ipairs(items) do
            local icon = icons.info
            if n.source == "ota" then icon = icons.settings end

            local subtitle_parts = { fmt_age(n.timestamp) }
            if n.source and n.source ~= "system" then
                subtitle_parts[#subtitle_parts + 1] = n.source
            end
            if n.body and n.body ~= "" then
                subtitle_parts[#subtitle_parts + 1] = n.body
            end

            content[#content + 1] = ui.list_item({
                title    = n.title,
                subtitle = table.concat(subtitle_parts, "  --  "),
                icon     = icon,
                trailing = (n.action and n.action.label) or nil,
                on_press = function()
                    if n.action and type(n.action.on_press) == "function" then
                        -- Open an action menu instead of running the
                        -- action straight from a list-item press, so
                        -- the user has to confirm destructive ones
                        -- (notably the OTA reboot) deliberately.
                        show_action_menu(n)
                    else
                        notifications.dismiss(n.id)
                    end
                end,
            })
        end

        -- Bulk-dismiss action so users with a long list don't have to
        -- backspace through every entry.
        content[#content + 1] = ui.padding({ 8, 8, 8, 8 },
            ui.button("Dismiss all", {
                on_press = function()
                    for _, n in ipairs(notifications.list()) do
                        notifications.dismiss(n.id)
                    end
                    self:set_state({})
                end,
            }))
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Notifications", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Center:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Center
