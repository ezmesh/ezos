-- Onboarding step 2 of 5 — node name.
--
-- Free-text, max 32 chars, ASCII only (the on-device fonts only cover
-- 0x20..0x7E — non-ASCII would render as `[]` boxes in the chat list).
-- Pre-fills with the current node name (the chip-MAC default for a
-- fresh device, or whatever a previous onboarding run wrote).

local ui = require("ezui")
local M  = require("screens.onboarding")

local PATH = "screens.onboarding.node_name"
local MAX_LEN = 32

local NodeName = { title = "Node name" }

function NodeName.initial_state()
    local current = (ez.mesh and ez.mesh.get_node_name and ez.mesh.get_node_name()) or ""
    return { value = M.ascii_only(current) }
end

function NodeName:_commit(raw)
    local value = M.ascii_only(raw or "")
    if value == "" then
        self._state.error = "Node name can't be empty."
        self:set_state({})
        return
    end
    if ez.mesh and ez.mesh.set_node_name then
        ez.mesh.set_node_name(value)
    end
    M.advance(PATH)
end

function NodeName:build(state)
    local children = {
        ui.padding({ 0, 0, 6, 0 },
            ui.text_widget("What name should appear on the mesh?",
                { color = "TEXT", font = "small_aa", wrap = true })
        ),
        ui.text_input({
            value = state.value or "",
            max_length = MAX_LEN,
            placeholder = "Node name",
            on_change = function(v)
                state.value = v
            end,
            on_submit = function(v)
                self:_commit(v)
            end,
        }),
        ui.padding({ 4, 0, 0, 0 },
            ui.text_widget(
                "Letters, digits, spaces, basic punctuation. Max " ..
                tostring(MAX_LEN) .. " characters.",
                { color = "TEXT_MUTED", font = "tiny_aa", wrap = true })
        ),
    }

    if state.error then
        children[#children + 1] = ui.padding({ 6, 0, 0, 0 },
            ui.text_widget(state.error,
                { color = "ERROR", font = "tiny_aa" })
        )
    end

    children[#children + 1] = ui.padding({ 12, 0, 0, 0 },
        ui.button("Continue", {
            on_press = function() self:_commit(state.value) end,
        })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Node name", { back = true, right = M.progress_label(PATH) }),
        ui.scroll({ grow = 1 },
            ui.padding({ 10, 12, 10, 12 },
                ui.vbox({ gap = 6 }, children)
            )
        ),
    })
end

function NodeName:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return NodeName
