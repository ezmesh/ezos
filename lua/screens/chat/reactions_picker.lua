-- Small palette picker for chat reactions. Renders the 8 ASCII tokens
-- in services.reactions.EMOJI_PALETTE as list rows; tapping one fires
-- reactions.send(target_pub, target_msg_hash, idx) and pops back to
-- the conversation. The pop happens BEFORE the send because the user
-- wants to land back on the chat (and the optimistic local record
-- updates synchronously, so the bubble shows the new reaction
-- immediately on rebuild).

local ui          = require("ezui")
local screen_mod  = require("ezui.screen")
local reactions   = require("services.reactions")

local Picker = { title = "React" }

function Picker.initial_state(target_pub_hex, target_msg_hash, preview_text)
    return {
        target_pub  = target_pub_hex,
        target_hash = target_msg_hash,
        preview     = preview_text or "",
    }
end

function Picker:build(state)
    local items = { ui.title_bar("React", { back = true }) }

    if state.preview and state.preview ~= "" then
        -- preview is peer-originated DM text; sanitize to printable
        -- ASCII so non-ASCII bytes don't render as [] glyph boxes.
        local snippet = state.preview:gsub("[^\32-\126]", "?")
        if #snippet > 40 then snippet = snippet:sub(1, 37) .. "..." end
        items[#items + 1] = ui.padding({ 6, 8, 8, 8 },
            ui.text_widget("Re: " .. snippet, {
                color = "TEXT_MUTED", font = "small_aa", wrap = true,
            }))
    end

    local rows = {}
    for idx = 1, #reactions.EMOJI_PALETTE do
        local emoji = reactions.EMOJI_PALETTE[idx]
        rows[#rows + 1] = ui.list_item({
            title    = emoji,
            on_press = function()
                screen_mod.pop()
                reactions.send(state.target_pub, state.target_hash, idx)
            end,
        })
    end
    items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows))

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Picker:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Picker
