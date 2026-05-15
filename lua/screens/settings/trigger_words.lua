-- Settings -> Notifications -> Trigger words.
--
-- Lets the user edit the comma-separated list of words that, in
-- addition to their node name, cause a "Mentions only" channel
-- message to ring through. The list is stored under the
-- `notify_words` pref in NVS (services.notifications). See the
-- "Trigger-word matching" header in lua/services/notifications.lua
-- for the storage / matching semantics.
--
-- One text field, comma-separated. Matching is case-insensitive
-- substring, so "dog" matches "Lost dog reported at the park";
-- the user doesn't need to think about word boundaries.

local ui            = require("ezui")
local notifications = require("services.notifications")

local TriggerWords = { title = "Trigger words" }

function TriggerWords.initial_state()
    return {
        text = table.concat(notifications.get_trigger_words(), ", "),
    }
end

function TriggerWords:build(state)
    local items = {}

    items[#items + 1] = ui.title_bar("Trigger words", { back = true })

    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget(
            "Comma-separated list. A channel message on a " ..
            "'Mentions only' channel that contains any of these " ..
            "words (case-insensitive) rings through as if it " ..
            "mentioned you.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 6, 8, 4, 8 },
        ui.text_widget("Words", { font = "small_aa", color = "TEXT_SEC" })
    )
    content[#content + 1] = ui.padding({ 0, 8, 6, 8 },
        ui.text_input({
            value = state.text or "",
            placeholder = "e.g. alert, storm, dog",
            on_change = function(val)
                state.text = val
            end,
        })
    )

    content[#content + 1] = ui.padding({ 6, 8, 4, 8 },
        ui.button("Save", {
            on_press = function()
                notifications.set_trigger_words(state.text or "")
                local screen = require("ezui.screen")
                screen.pop()
            end,
        })
    )

    content[#content + 1] = ui.padding({ 4, 8, 8, 8 },
        ui.text_widget(
            "Leave empty to disable. Your node name is always a " ..
            "trigger and doesn't need to be listed here.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content))

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function TriggerWords:handle_key(key)
    -- Don't pop while the user is typing into the text input.
    local focus_mod = require("ezui.focus")
    if not focus_mod.editing then
        if key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
    end
    return nil
end

return TriggerWords
