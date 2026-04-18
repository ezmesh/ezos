-- About screen: firmware version + credits and attributions for third-
-- party assets shipped in the image. Keep entries here in sync with any
-- asset additions so license obligations stay visible.

local ui = require("ezui")
local theme = require("ezui.theme")

local About = { title = "About" }

local VERSION = "ezOS v2 (feature/offline-maps-v5-zlib)"

-- Each entry renders as a block: title, description, and optional link.
-- Licenses/terms are summarised; full text lives with the asset (e.g.
-- data/sounds/snd01/CREDITS.md, LICENSE files in tools/).
local CREDITS = {
    {
        heading = "ezOS",
        lines = {
            VERSION,
            "C++ firmware + Lua userspace for the LilyGo T-Deck Plus.",
        },
    },
    {
        heading = "SND01 \"Sine\" Sound Pack",
        lines = {
            "Yasuhiro Tsuchiya / Dentsu Inc.",
            "https://snd.dev",
            "Free for personal and commercial use;",
            "modified and embedded per snd.dev terms.",
        },
    },
    {
        heading = "Lucide Icons",
        lines = {
            "https://lucide.dev",
            "ISC License. Used to source the glyphs",
            "composited into the desktop icons.",
        },
    },
    {
        heading = "Inter Font",
        lines = {
            "Rasmus Andersson",
            "https://rsms.me/inter/",
            "SIL Open Font License 1.1. Used for the",
            "anti-aliased UI fonts.",
        },
    },
    {
        heading = "MeshCore Protocol",
        lines = {
            "https://github.com/ripplebiz/MeshCore",
            "Reference implementation for the mesh",
            "networking stack.",
        },
    },
    {
        heading = "LovyanGFX",
        lines = {
            "https://github.com/lovyan03/LovyanGFX",
            "FreeBSD License. Display driver.",
        },
    },
}

function About:build(state)
    local items = { ui.title_bar("About", { back = true }) }

    local content = {}
    for _, entry in ipairs(CREDITS) do
        content[#content + 1] = ui.padding({ 8, 10, 2, 10 },
            ui.text_widget(entry.heading, { color = "ACCENT", font = "small_aa" })
        )
        for _, line in ipairs(entry.lines) do
            content[#content + 1] = ui.padding({ 1, 10, 1, 10 },
                ui.text_widget(line, { color = "TEXT", font = "small_aa", wrap = true })
            )
        end
    end
    content[#content + 1] = ui.padding({ 16, 10, 12, 10 },
        ui.text_widget(
            "Full license texts ship alongside each asset in the source tree.",
            { color = "TEXT_MUTED", font = "small_aa", wrap = true }
        )
    )

    items[#items + 1] = ui.scroll({ grow = 1 },
        ui.vbox({ gap = 0 }, content)
    )

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function About:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return About
