-- Sound sub-settings: UI sounds toggle + master volume.

local ui        = require("ezui")
local ui_sounds = require("services.ui_sounds")

local Sound = { title = "Sound" }

function Sound.initial_state()
    return {
        enabled = ui_sounds.is_enabled(),
        volume  = ez.audio.get_volume and ez.audio.get_volume() or 100,
    }
end

function Sound:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("UI feedback", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
        ui.toggle("UI sounds", state.enabled, {
            on_change = function(v)
                ui_sounds.set_enabled(v)
                state.enabled = v
                -- Fire a sample so the change is audibly confirmed when
                -- turning sounds on; does nothing when turning off.
                if v then ui_sounds.play("select") end
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "Taps, toggles, and screen transitions play SND01 samples " ..
            "(Yasuhiro Tsuchiya / snd.dev - see About).",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Master volume", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "Volume",
            value = state.volume,
            min = 0, max = 100, step = 5,
            on_change = function(v)
                if ez.audio.set_volume then ez.audio.set_volume(v) end
                ez.storage.set_pref("audio_volume", v)
                state.volume = v
            end,
        })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Sound", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Sound:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Sound
