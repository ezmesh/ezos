-- About screen: firmware version + credits for third-party assets.
--
-- Content lives in `data/about.md` on LittleFS (flashed via `pio run
-- -t uploadfs`). Keeping it out of the embedded-Lua blob means the doc
-- can grow without stealing from the firmware flash budget, and the
-- markdown renderer gets a real-world exercise of the LittleFS async
-- load path every time the screen opens.

local ui    = require("ezui")
local async = require("ezui.async")

local About = { title = "About" }

local MD_PATH = "/fs/about.md"

-- Cache loaded markdown across screen open/close so the LittleFS read
-- only runs once per boot. The state dict still carries it per-instance
-- so hot-reload can drop it cleanly.
local _cached_md = nil

function About.initial_state()
    return { md = _cached_md, error = nil }
end

function About:on_enter()
    local state = self:get_state()
    if state.md or state.error then return end

    local this = self
    async.task(function()
        local content = async_read(MD_PATH)
        if content and content ~= "" then
            _cached_md = content
            this:set_state({ md = content, error = nil })
        else
            -- Fall back gracefully. The most common reason for a missing
            -- file is a user that has flashed the firmware but not yet
            -- run `uploadfs`; point them at it in the error copy.
            this:set_state({
                md = nil,
                error = "about.md not found on LittleFS.\nRun `pio run -t uploadfs`.",
            })
        end
    end)
end

function About:build(state)
    local body
    if state.md then
        body = ui.markdown(state.md)
    elseif state.error then
        body = ui.text_widget(state.error, {
            font = "small_aa", color = "ERROR", wrap = true,
        })
    else
        body = ui.text_widget("Loading...", {
            font = "small_aa", color = "TEXT_MUTED",
        })
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("About", { back = true }),
        ui.scroll({ grow = 1 },
            ui.padding({ 4, 10, 8, 10 }, body)
        ),
    })
end

function About:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return About
