-- Identity settings: view + edit the local node's mesh identity.
--
-- Three sections:
--   1. Public identity — read-only short ID and full hex pubkey.
--   2. Profile         — editable node name (max 32 ASCII) and callsign
--                        (max 16 ASCII). ENTER on the input submits.
--   3. Reset           — destructive: regenerate the Ed25519 keypair via
--                        ez.mesh.regenerate_identity. Two-step confirm
--                        so a stray ENTER on the button can't wipe the
--                        identity.

local ui = require("ezui")

local Identity = { title = "Identity" }

local NAME_MAX = 32
local CALL_MAX = 16

-- ASCII-only filter. The on-device fonts only cover 0x20..0x7E; non-ASCII
-- would render as `[]` boxes in the chat and contact lists.
local function ascii_only(s)
    if not s then return "" end
    return (s:gsub("[^\32-\126]", ""))
end

local function read_short_id()
    if ez.mesh and ez.mesh.get_node_id then
        local id = ez.mesh.get_node_id()
        if id and id ~= "" then return id end
    end
    return "(radio not initialised)"
end

local function read_pub_hex()
    if ez.mesh and ez.mesh.get_public_key_hex then
        local k = ez.mesh.get_public_key_hex()
        if k and k ~= "" then return k end
    end
    return nil
end

local function read_node_name()
    if ez.mesh and ez.mesh.get_node_name then
        return ascii_only(ez.mesh.get_node_name() or "")
    end
    return ""
end

function Identity.initial_state()
    return {
        node_name = read_node_name(),
        callsign  = ascii_only(ez.storage.get_pref("callsign", "") or ""),
        confirm_reset = false,
        last_status = nil,
    }
end

-- Refresh fields from the live mesh state. Used after a regenerate so
-- the screen reflects the new short ID + default node name without a
-- full screen reload.
function Identity:_refresh()
    self._state.node_name = read_node_name()
    self._state.confirm_reset = false
    self:set_state({})
end

function Identity:_save_node_name(raw)
    local v = ascii_only(raw or "")
    if v == "" then
        self._state.last_status = "Node name can't be empty."
        self:set_state({})
        return
    end
    if ez.mesh and ez.mesh.set_node_name then
        ez.mesh.set_node_name(v)
    end
    self._state.node_name = v
    self._state.last_status = "Node name saved."
    self:set_state({})
end

function Identity:_save_callsign(raw)
    local v = ascii_only(raw or "")
    ez.storage.set_pref("callsign", v)
    self._state.callsign = v
    self._state.last_status = (v == "") and "Callsign cleared." or "Callsign saved."
    self:set_state({})
end

function Identity:_regenerate()
    if not (ez.mesh and ez.mesh.regenerate_identity) then
        self._state.last_status = "Regenerate not supported on this build."
        self:set_state({})
        return
    end
    local new_id = ez.mesh.regenerate_identity()
    if not new_id then
        self._state.last_status = "Regenerate failed (radio not ready?)."
        self:set_state({})
        return
    end
    self._state.last_status = "New identity: " .. new_id
    self:_refresh()
end

function Identity:build(state)
    local content = {}

    -- Section: public identity (read-only readout)
    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Public identity", { color = "ACCENT", font = "small_aa" }))
    content[#content + 1] = ui.padding({ 0, 8, 2, 8 },
        ui.text_widget("Short ID",
            { color = "TEXT_SEC", font = "tiny_aa" }))
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget(read_short_id(),
            { color = "TEXT", font = "medium_aa" }))

    local pub = read_pub_hex()
    if pub then
        content[#content + 1] = ui.padding({ 0, 8, 2, 8 },
            ui.text_widget("Public key",
                { color = "TEXT_SEC", font = "tiny_aa" }))
        content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
            ui.text_widget(pub,
                { color = "TEXT_SEC", font = "tiny_aa", wrap = true }))
    end

    -- Section: profile (editable name + callsign)
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Profile", { color = "ACCENT", font = "small_aa" }))
    content[#content + 1] = ui.padding({ 0, 8, 2, 8 },
        ui.text_widget("Node name",
            { color = "TEXT_SEC", font = "tiny_aa" }))
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_input({
            value = state.node_name or "",
            max_length = NAME_MAX,
            placeholder = "Node name",
            on_submit = function(v) self:_save_node_name(v) end,
        }))
    content[#content + 1] = ui.padding({ 6, 8, 2, 8 },
        ui.text_widget("Callsign (optional)",
            { color = "TEXT_SEC", font = "tiny_aa" }))
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_input({
            value = state.callsign or "",
            max_length = CALL_MAX,
            placeholder = "Callsign",
            on_submit = function(v) self:_save_callsign(v) end,
        }))
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget("ENTER inside a field saves. ASCII only.",
            { color = "TEXT_MUTED", font = "tiny_aa" }))

    -- Section: regenerate (destructive, two-step confirm)
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Regenerate identity", { color = "ACCENT", font = "small_aa" }))
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget(
            "Generates a new keypair. Peers will see a different short " ..
            "ID; in-flight DMs encrypted to the old key stop working.",
            { color = "TEXT_MUTED", font = "tiny_aa", wrap = true }))

    if state.confirm_reset then
        content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.hbox({ gap = 8 }, {
                ui.button("Confirm", {
                    on_press = function() self:_regenerate() end,
                }),
                ui.button("Cancel", {
                    on_press = function()
                        self._state.confirm_reset = false
                        self:set_state({})
                    end,
                }),
            }))
    else
        content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.button("Regenerate identity", {
                on_press = function()
                    self._state.confirm_reset = true
                    self._state.last_status = nil
                    self:set_state({})
                end,
            }))
    end

    if state.last_status then
        content[#content + 1] = ui.padding({ 8, 8, 8, 8 },
            ui.text_widget(state.last_status,
                { color = "TEXT_SEC", font = "tiny_aa", wrap = true }))
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Identity", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Identity:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Identity
