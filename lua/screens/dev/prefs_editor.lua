-- Dev prefs editor: browse, edit, reset, delete, and add NVS prefs.
--
-- Lists every pref the firmware uses (from prefs_registry) alongside
-- every ad-hoc user pref found in NVS. Tapping a row opens a detail
-- screen with value + type + description + actions (Edit / Reset /
-- Delete). From the top bar you can also add a brand-new pref.
--
-- "System" prefs are those registered in services.prefs_registry.
-- "User" prefs are anything else that exists in NVS. The distinction
-- matters because system prefs have canonical defaults to reset to,
-- whereas user prefs can only be deleted.

local ui       = require("ezui")
local theme    = require("ezui.theme")
local dialog   = require("ezui.dialog")
local registry = require("services.prefs_registry")

local Editor = { title = "Prefs" }

-- Helpers -------------------------------------------------------------

-- Read the current value of a pref as a display string. We choose a
-- sentinel default value that wouldn't normally appear so we can
-- distinguish "missing" from "stored empty".
local MISSING = "\0__MISSING__"

local function read_display_value(key)
    local v = ez.storage.get_pref(key, MISSING)
    if v == MISSING then return "(unset)" end
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then return tostring(v) end
    if type(v) == "string" then
        if #v > 24 then return v:sub(1, 22) .. ".." end
        return '"' .. v .. '"'
    end
    return tostring(v)
end

-- Coerce a user-entered string into the right Lua type before calling
-- set_pref. Integer types lean on set_pref's integer branch; strings
-- pass through verbatim.
local function write_value(entry, raw)
    local t = entry.type
    if t == "string" then
        ez.storage.set_pref(entry.key, raw)
        return true, nil
    end
    local n = tonumber(raw)
    if not n then return false, "Not a number" end
    if entry.min and n < entry.min then return false, "Below min " .. entry.min end
    if entry.max and n > entry.max then return false, "Above max " .. entry.max end
    ez.storage.set_pref(entry.key, math.floor(n))
    return true, nil
end

-- Detail screen -------------------------------------------------------
-- The entry + is_system flag are stashed in the state table so the
-- detail screen can be instantiated via the standard screen.create
-- path without subclassing.

local Detail = { title = "Pref" }

function Detail:build(state)
    local entry = state.entry
    local is_system = state.is_system
    local rows = {}

    rows[#rows + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget(entry.key, { color = "TEXT", font = "medium_aa" })
    )

    local meta = string.format("[%s] %s", is_system and "SYS" or "USR", entry.type)
    rows[#rows + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget(meta, { color = "TEXT_MUTED", font = "small_aa" })
    )

    if is_system and entry.description then
        rows[#rows + 1] = ui.padding({ 2, 8, 6, 8 },
            ui.text_widget(entry.description,
                { color = "TEXT_MUTED", font = "small_aa", wrap = true })
        )
    end

    rows[#rows + 1] = ui.padding({ 4, 8, 2, 8 },
        ui.text_widget("Current value", { color = "ACCENT", font = "small_aa" })
    )

    local current = read_display_value(entry.key)
    rows[#rows + 1] = ui.padding({ 0, 8, 6, 8 },
        ui.text_widget(current, { color = "TEXT", font = "medium_aa" })
    )

    if is_system and entry.options then
        rows[#rows + 1] = ui.padding({ 4, 8, 2, 8 },
            ui.text_widget("Allowed values", { color = "ACCENT", font = "small_aa" })
        )
        rows[#rows + 1] = ui.padding({ 0, 8, 6, 8 },
            ui.text_widget(table.concat(entry.options, ", "),
                { color = "TEXT_MUTED", font = "small_aa", wrap = true })
        )
    end

    if is_system and (entry.min or entry.max) then
        local r = string.format("min = %s, max = %s",
            tostring(entry.min or "-"), tostring(entry.max or "-"))
        rows[#rows + 1] = ui.padding({ 0, 8, 6, 8 },
            ui.text_widget(r, { color = "TEXT_MUTED", font = "small_aa" })
        )
    end

    rows[#rows + 1] = ui.list_item({
        title = "Edit value",
        icon  = nil,
        on_press = function()
            local current_raw = ez.storage.get_pref(entry.key, "")
            if type(current_raw) ~= "string" then current_raw = tostring(current_raw) end
            local message = entry.options
                and ("One of: " .. table.concat(entry.options, " / "))
                or ("New " .. entry.type .. " value:")
            dialog.prompt({
                title = "Edit " .. entry.key,
                message = message,
                value = current_raw,
            }, function(v)
                local ok, err = write_value(entry, v)
                if not ok then
                    ez.log("[prefs] " .. entry.key .. ": " .. err)
                end
                self:set_state({})
            end)
        end,
    })

    if is_system then
        rows[#rows + 1] = ui.list_item({
            title = "Reset to default",
            subtitle = "Writes " .. tostring(entry.default),
            icon  = nil,
            on_press = function()
                registry.reset(entry.key)
                self:set_state({})
            end,
        })
    else
        rows[#rows + 1] = ui.list_item({
            title = "Delete",
            subtitle = "Remove this pref from NVS",
            icon  = nil,
            on_press = function()
                ez.storage.remove_pref(entry.key)
                local screen_mod = require("ezui.screen")
                screen_mod.pop()
            end,
        })
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Pref", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows)),
    })
end

function Detail:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

-- List screen ---------------------------------------------------------

local function push_detail(entry, is_system)
    local screen_mod = require("ezui.screen")
    screen_mod.push(screen_mod.create(Detail, {
        entry = entry,
        is_system = is_system,
    }))
end

-- Make a row tailored for the list screen. `entry` is a registry
-- entry for system prefs, or a { key, type } tuple for user prefs.
local function make_row(entry, is_system)
    local badge = is_system and "SYS" or "USR"
    local value = read_display_value(entry.key)
    local subtitle = string.format("[%s] %s  %s", badge, entry.type, value)
    return ui.list_item({
        title    = entry.key,
        subtitle = subtitle,
        on_press = function() push_detail(entry, is_system) end,
    })
end

function Editor:build(state)
    local items = {}

    -- Add action row at the very top so the editor stays reachable even
    -- when the list is scrolled. Clicking prompts for a key, then a
    -- type, then a value.
    items[#items + 1] = ui.list_item({
        title = "+ New pref",
        subtitle = "Create a custom string pref",
        on_press = function()
            dialog.prompt({
                title = "New pref",
                message = "Key (<=15 chars):",
                value = "",
            }, function(key_name)
                if not key_name or #key_name == 0 then return end
                if #key_name > 15 then
                    ez.log("[prefs] key too long: " .. key_name)
                    return
                end
                dialog.prompt({
                    title = key_name,
                    message = "Initial string value:",
                    value = "",
                }, function(val)
                    ez.storage.set_pref(key_name, val or "")
                    self:set_state({})
                end)
            end)
        end,
    })

    items[#items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("System", { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    for _, entry in ipairs(registry.all()) do
        items[#items + 1] = make_row(entry, true)
    end

    items[#items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("User (ad-hoc)", { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    local user_prefs = registry.list_user_prefs()
    if #user_prefs == 0 then
        items[#items + 1] = ui.padding({ 2, 8, 6, 8 },
            ui.text_widget("(no unregistered prefs in NVS)",
                { color = "TEXT_MUTED", font = "small_aa" })
        )
    else
        for _, entry in ipairs(user_prefs) do
            items[#items + 1] = make_row(entry, false)
        end
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Prefs Editor", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, items)),
    })
end

function Editor:on_enter()
    -- Rebuild every time we come back so a detail-screen edit is
    -- reflected in the visible value column without a manual refresh.
    self:set_state({})
end

function Editor:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Editor
