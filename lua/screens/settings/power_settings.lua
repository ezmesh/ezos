-- Settings -> Power.
--
-- Two manual overrides for the battery-aware power policy in
-- services.power:
--
--   * "Always Normal" pins the device to Normal regardless of battery
--     (useful when sat at a powered desk -- you don't care about
--     Frugal kicking in at 30%).
--   * "Force Survival now" pins the device to Survival regardless of
--     battery (useful when you need this to last another 4 hours).
--
-- The two are mutually exclusive; the service clears the other when
-- one flips on. A status line shows the current tier so the user can
-- tell whether the policy is doing anything.

local ui    = require("ezui")
local power = require("services.power")

local PowerSettings = { title = "Power" }

function PowerSettings.initial_state()
    return {
        always_normal = power.always_normal_on(),
        force_surv    = power.force_survival_on(),
    }
end

local function tier_label()
    local mode = power.current_mode()
    if mode == "survival" then return "Survival" end
    if mode == "frugal"   then return "Low power" end
    return "Normal"
end

local function tier_description(mode)
    if mode == "survival" then
        return "Radio ADVERTs quartered. GPS sync and NTP stopped. " ..
               "Non-DM custom packets suppressed. Display brightness " ..
               "clamped. TX power one notch down."
    elseif mode == "frugal" then
        return "Radio ADVERTs halved. GPS sync paused. NTP cadence " ..
               "stretched. Otherwise normal."
    end
    return "All radios and timers at their normal cadence."
end

function PowerSettings:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
        ui.text_widget("Current tier: " .. tier_label(),
            { color = "ACCENT", font = "small_aa" })
    )
    content[#content + 1] = ui.padding({ 0, 8, 8, 8 },
        ui.text_widget(tier_description(power.current_mode()),
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    -- ---- Always Normal ----
    content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
        ui.toggle("Always Normal", state.always_normal, {
            on_change = function(v)
                power.set_always_normal(v)
                self:set_state({
                    always_normal = v,
                    -- `v and false or state.force_surv` would always
                    -- return state.force_surv (Lua: v and false == false,
                    -- false or x == x). Use `not v and state.force_surv`
                    -- so flipping Always Normal on clears the visual
                    -- state of the mutually-exclusive Force Survival.
                    force_surv = not v and state.force_surv,
                })
            end,
        })
    )
    content[#content + 1] = ui.padding({ 0, 8, 8, 8 },
        ui.text_widget(
            "Pin to Normal even when battery drops. Useful when the " ..
            "device is on a powered desk and you don't want Frugal " ..
            "to start backing off at 30 %.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    -- ---- Force Survival ----
    content[#content + 1] = ui.padding({ 6, 8, 2, 8 },
        ui.toggle("Force Survival now", state.force_surv, {
            on_change = function(v)
                power.set_force_survival(v)
                self:set_state({
                    force_surv = v,
                    always_normal = not v and state.always_normal,
                })
            end,
        })
    )
    content[#content + 1] = ui.padding({ 0, 8, 8, 8 },
        ui.text_widget(
            "Pin to Survival regardless of battery. Useful when you " ..
            "need the device to last another few hours and are OK " ..
            "with GPS / NTP / non-DM packets being suppressed.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 12, 8, 8, 8 },
        ui.text_widget(
            "Default thresholds: Frugal kicks in at <= 30 %, " ..
            "Survival at <= 10 %. Hysteresis: leave Frugal at >= 35 %, " ..
            "leave Survival at >= 15 %.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Power", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function PowerSettings:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return PowerSettings
