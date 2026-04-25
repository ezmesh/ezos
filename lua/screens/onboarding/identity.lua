-- Onboarding optional — identity readout.
--
-- Shows the node's public identity hash so the user can write it down
-- or share it with another mesh participant. The full Ed25519 public
-- key is also displayed for completeness; both values are derived from
-- the keypair stored in NVS, which survives a reflash unless the user
-- explicitly wipes prefs.
--
-- This screen does not back up the private key. SD-based identity
-- backup/restore is tracked separately. A QR rendering of the pubkey
-- is also out of scope here (no QR encoder is present in the firmware
-- yet); a future change can add the QR overlay alongside the hex.

local ui = require("ezui")
local M  = require("screens.onboarding")

local PATH = "screens.onboarding.identity"

local Identity = { title = "Identity" }

local function get_node_id()
    if ez.mesh and ez.mesh.get_node_id then
        local id = ez.mesh.get_node_id()
        if id and id ~= "" then return id end
    end
    return "(radio not initialised)"
end

local function get_pub_key_hex()
    if ez.mesh and ez.mesh.get_public_key_hex then
        local k = ez.mesh.get_public_key_hex()
        if k and k ~= "" then return k end
    end
    return nil
end

function Identity:build(state)
    local rows = {
        ui.text_widget("Your identity on the mesh",
            { color = "TEXT", font = "small_aa", wrap = true }),
        ui.text_widget(
            "Other nodes recognise this device by the short ID below. " ..
            "It's safe to share. The matching private key stays in NVS " ..
            "and survives a reflash unless explicitly cleared.",
            { color = "TEXT_MUTED", font = "tiny_aa", wrap = true }),
        ui.padding({ 8, 0, 0, 0 },
            ui.text_widget("Short ID",
                { color = "ACCENT", font = "small_aa" })
        ),
        ui.text_widget(get_node_id(),
            { color = "TEXT", font = "medium_aa" }),
    }

    local pub = get_pub_key_hex()
    if pub then
        rows[#rows + 1] = ui.padding({ 8, 0, 0, 0 },
            ui.text_widget("Public key",
                { color = "ACCENT", font = "small_aa" })
        )
        rows[#rows + 1] = ui.text_widget(pub,
            { color = "TEXT_SEC", font = "tiny_aa", wrap = true })
    end

    rows[#rows + 1] = ui.padding({ 12, 0, 0, 0 },
        ui.button("Continue", {
            on_press = function() M.advance(PATH) end,
        })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Identity", { back = true, right = M.progress_label(PATH) }),
        ui.scroll({ grow = 1 },
            ui.padding({ 10, 12, 10, 12 },
                ui.vbox({ gap = 6 }, rows)
            )
        ),
    })
end

function Identity:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Identity
