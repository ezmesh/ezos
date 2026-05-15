-- Notifications sub-settings: Do Not Disturb / quiet hours.
--
-- Pairs with services.notifications -- this screen only writes the
-- prefs the evaluator there consumes. See the DND header comment in
-- lua/services/notifications.lua for the pref schema and the
-- semantics (window wrap-around, manual override, exemptions).
--
-- The time-of-day inputs are minute-since-midnight sliders rather
-- than a dedicated hour:minute picker -- there's no time-picker
-- widget in ezui yet and one slider per endpoint is enough for
-- "pick when you go to bed / wake up" in 15-min steps. The label
-- under each slider re-renders on change so the user sees the
-- HH:MM, not the raw minute count.

local ui            = require("ezui")
local notifications = require("services.notifications")

local Notifications = { title = "Notifications" }

local DEFAULT_START = 22 * 60   -- 22:00
local DEFAULT_END   =  7 * 60   --  7:00
local STEP_MIN      = 15

local function pref_int(key, default)
    local v = ez.storage.get_pref(key, tostring(default))
    return tonumber(v) or default
end

local function pref_bool(key, default)
    local v = ez.storage.get_pref(key, default and "1" or "0")
    return v == "1" or v == 1 or v == true
end

local function set_bool(key, v)
    ez.storage.set_pref(key, v and "1" or "0")
end

local function set_int(key, v)
    ez.storage.set_pref(key, tostring(math.floor(v)))
end

local function fmt_hhmm(minutes)
    local m = math.floor(minutes) % (24 * 60)
    return string.format("%02d:%02d", math.floor(m / 60), m % 60)
end

local function trigger_summary()
    local words = notifications.get_trigger_words()
    if #words == 0 then return "None" end
    local joined = table.concat(words, ", ")
    if #joined > 40 then return joined:sub(1, 37) .. "..." end
    return joined
end

function Notifications.initial_state()
    return {
        enabled      = pref_bool("dnd_enabled", false),
        start_min    = pref_int("dnd_start", DEFAULT_START),
        end_min      = pref_int("dnd_end",   DEFAULT_END),
        allow_ments  = pref_bool("dnd_mentions", false),
        manual       = pref_bool("dnd_manual", false),
    }
end

function Notifications:on_enter()
    -- Trigger-words editor may have changed the list while we were
    -- pushed underneath. Force a rebuild so the summary is fresh.
    self:set_state({})
end

function Notifications:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Do Not Disturb", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
        ui.toggle("Manual DND now", state.manual, {
            on_change = function(v)
                set_bool("dnd_manual", v)
                self:set_state({ manual = v })
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "Silences toasts and wake-on-notification immediately, " ..
            "until you turn it back off. Wins over the schedule.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 10, 8, 4, 8 },
        ui.toggle("Quiet hours schedule", state.enabled, {
            on_change = function(v)
                set_bool("dnd_enabled", v)
                self:set_state({ enabled = v })
            end,
        })
    )

    if state.enabled then
        content[#content + 1] = ui.padding({ 6, 8, 0, 8 },
            ui.text_widget("Start  " .. fmt_hhmm(state.start_min),
                { color = "TEXT", font = "small_aa" })
        )
        content[#content + 1] = ui.padding({ 0, 6, 2, 6 },
            ui.slider({
                label = "",
                value = state.start_min,
                min = 0, max = 24 * 60 - STEP_MIN, step = STEP_MIN,
                on_change = function(v)
                    set_int("dnd_start", v)
                    self:set_state({ start_min = v })
                end,
            })
        )

        content[#content + 1] = ui.padding({ 6, 8, 0, 8 },
            ui.text_widget("End  " .. fmt_hhmm(state.end_min),
                { color = "TEXT", font = "small_aa" })
        )
        content[#content + 1] = ui.padding({ 0, 6, 2, 6 },
            ui.slider({
                label = "",
                value = state.end_min,
                min = 0, max = 24 * 60 - STEP_MIN, step = STEP_MIN,
                on_change = function(v)
                    set_int("dnd_end", v)
                    self:set_state({ end_min = v })
                end,
            })
        )

        content[#content + 1] = ui.padding({ 6, 8, 4, 8 },
            ui.toggle("Allow channel mentions", state.allow_ments, {
                on_change = function(v)
                    set_bool("dnd_mentions", v)
                    self:set_state({ allow_ments = v })
                end,
            })
        )
        content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
            ui.text_widget(
                "When a channel message mentions your node name during " ..
                "quiet hours, the toast and wake go through anyway.",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )

        content[#content + 1] = ui.padding({ 8, 8, 8, 8 },
            ui.text_widget(
                "Unread counts still update during quiet hours -- only " ..
                "the toast / panel wake is suppressed. DND is treated " ..
                "as off if the clock is unset.",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )
    end

    -- ---- Trigger words ----
    -- Extends the "Mentions only" channel notify mode beyond the
    -- node name. See services.notifications for the matcher.
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Mentions", { color = "ACCENT", font = "small_aa" })
    )
    content[#content + 1] = ui.list_item({
        title    = "Trigger words",
        subtitle = trigger_summary(),
        on_press = function()
            local screen = require("ezui.screen")
            local Editor = require("screens.settings.trigger_words")
            local init = Editor.initial_state and Editor.initial_state() or {}
            screen.push(screen.create(Editor, init))
        end,
    })
    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget(
            "Words that ring through on 'Mentions only' channels in " ..
            "addition to your node name.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Notifications", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Notifications:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Notifications
