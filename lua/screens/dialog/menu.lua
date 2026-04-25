-- Global menu dialog. Pushed by ezui.screen.handle_input when the
-- user hits Alt+Shift+M on a screen whose definition exposes a
-- menu() function.
--
-- Each item is a table: { title, subtitle?, on_press, disabled? }.
-- on_press runs in the usual screen-push context (main loop); if the
-- action needs to yield, wrap in spawn() inside the handler.

local ui = require("ezui")

local Menu = { title = "Menu" }

function Menu.initial_state(items, caller_title)
    return {
        items = items or {},
        caller_title = caller_title or "",
    }
end

function Menu:build(state)
    local items = { ui.title_bar(
        state.caller_title ~= "" and (state.caller_title .. " · Menu") or "Menu",
        { back = true }
    ) }

    local rows = {}
    if #state.items == 0 then
        rows[#rows + 1] = ui.padding({ 20, 10, 10, 10 },
            ui.text_widget("No menu actions on this screen", {
                color = "TEXT_MUTED", text_align = "center",
            })
        )
    else
        local screen_mod = require("ezui.screen")
        for _, item in ipairs(state.items) do
            rows[#rows + 1] = ui.list_item({
                title    = item.title or "",
                subtitle = item.subtitle,
                icon     = item.icon,
                disabled = item.disabled,
                on_press = function()
                    -- Close the menu BEFORE invoking — most actions
                    -- want to operate on the caller screen, which
                    -- becomes active once we pop.
                    screen_mod.pop()
                    if item.on_press then item.on_press() end
                end,
            })
        end
    end

    items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows))
    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Menu:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Menu
