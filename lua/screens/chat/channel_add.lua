-- Add/Edit channel screen
-- Form with channel name and password fields.

local ui = require("ezui")
local channels_svc = require("services.channels")

local ChannelAdd = { title = "Add Channel" }

function ChannelAdd:build(state)
    local items = {}

    items[#items + 1] = ui.title_bar("Add Channel", { back = true })

    local form_items = {}

    form_items[#form_items + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Channel Name", { font = "small", color = "TEXT_SEC" })
    )
    form_items[#form_items + 1] = ui.padding({ 0, 8, 8, 8 },
        ui.text_input({
            value = state.name or "",
            placeholder = "e.g. Hiking Group",
            on_change = function(val)
                state.name = val
            end,
        })
    )

    form_items[#form_items + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Password (optional)", { font = "small", color = "TEXT_SEC" })
    )
    form_items[#form_items + 1] = ui.padding({ 0, 8, 8, 8 },
        ui.text_input({
            value = state.password or "",
            placeholder = "Leave empty to use name",
            on_change = function(val)
                state.password = val
            end,
        })
    )

    form_items[#form_items + 1] = ui.padding({ 4, 8, 4, 8 },
        ui.text_widget("All members must use the same name and password.", {
            font = "small",
            color = "TEXT_MUTED",
            wrap = true,
        })
    )

    -- Error message
    if state.error then
        form_items[#form_items + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.text_widget(state.error, { font = "small", color = "ERROR" })
        )
    end

    form_items[#form_items + 1] = ui.padding({ 8, 8, 8, 8 },
        ui.button("Join Channel", {
            on_press = function()
                local name = state.name or ""
                local password = state.password or ""

                if name == "" then
                    self:set_state({ error = "Enter a channel name" })
                    return
                end

                -- Prefix with # if not present
                if name:sub(1, 1) ~= "#" then
                    name = "#" .. name
                end

                if channels_svc.is_joined(name) then
                    self:set_state({ error = "Already joined this channel" })
                    return
                end

                -- Use channel name as password if none provided
                if password == "" then
                    password = name
                end

                channels_svc.join(name, password)
                local screen = require("ezui.screen")
                screen.pop()
            end,
        })
    )

    local content = ui.vbox({ gap = 0 }, form_items)
    items[#items + 1] = ui.scroll({ grow = 1 }, content)

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function ChannelAdd:handle_key(key)
    -- Only pop on explicit back when not editing a text field
    local focus_mod = require("ezui.focus")
    if not focus_mod.editing then
        if key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
    end
    return nil
end

return ChannelAdd
