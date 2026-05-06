-- Firmware update: pull the rolling-main manifest from GitHub
-- Releases, verify its Ed25519 signature against the embedded
-- ez.ota.signing_pubkey(), and stream the firmware.bin straight into
-- the inactive OTA partition via ez.ota.apply_url. Authenticity comes
-- entirely from the signature -- TLS is opportunistic (setInsecure).
--
-- Flow:
--   on_enter: fetch manifest.json + manifest.json.sig, verify, compare
--             current build_sha against manifest.sha. Show whether
--             we're up to date.
--   Install:  call ez.ota.apply_url(bin_url, manifest.sha256). Stream
--             progress via the existing "ota/progress" bus topic.
--   On end:   surface a "Reboot to apply" button.

local ui     = require("ezui")
local dialog = require("ezui.dialog")

local FirmwareUpdate = { title = "Firmware Update" }

local OWNER         = "ezmesh"
local REPO          = "ezos"
local TAG           = "rolling-main"
local MANIFEST_URL  = "https://github.com/" .. OWNER .. "/" .. REPO ..
                     "/releases/download/" .. TAG .. "/manifest.json"
local SIGNATURE_URL = MANIFEST_URL .. ".sig"

local function format_bytes(n)
    n = n or 0
    if n < 1024 then return tostring(n) .. " B" end
    if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
    return string.format("%.2f MB", n / (1024 * 1024))
end

local function parse_json(text)
    local ok, data = pcall(ez.storage.json_decode, text)
    if ok and type(data) == "table" then return data end
    return nil
end

local function current_sha()
    local info = ez.system.get_firmware_info() or {}
    return info.build_sha
end

local function current_build_at()
    local info = ez.system.get_firmware_info() or {}
    return info.build_at
end

-- Detect a manifest that's older than the running firmware. Without
-- this check a MITM on the (intentionally setInsecure()) HTTPS
-- connection to GitHub could serve any previously-published,
-- legitimately-signed manifest -- the standard rollback attack
-- against a signature-only trust model.
--
-- We don't refuse downgrades outright -- they're a useful tool when
-- a freshly-rolled main breaks something the user depends on -- but
-- we surface a clear warning and require a separate confirmation
-- before the install runs, so an unattended click can't quietly
-- regress the firmware.
--
-- ISO 8601 timestamps in the form `YYYY-MM-DDTHH:MM:SSZ` sort
-- correctly under Lua's lexicographic string compare, so a string
-- compare here is intentional -- no date parsing required.
local function is_downgrade(state)
    if not state.manifest then return false end
    local cur_at = current_build_at()
    local m_at   = state.manifest.built_at
    if not cur_at or cur_at == "" or not m_at or m_at == "" then
        return false  -- can't tell; don't false-positive
    end
    return m_at < cur_at
end

local function short(s, n)
    n = n or 7
    if not s or s == "" then return "?" end
    return s:sub(1, n)
end

function FirmwareUpdate.initial_state()
    return {
        loading       = true,
        error         = nil,
        manifest      = nil,        -- decoded manifest table
        verified      = false,      -- signature ok against embedded pubkey
        installing    = false,
        progress_bytes = 0,
        progress_phase = nil,       -- "start" | "write" | "end" | "error"
        progress_error = nil,
        wifi_connected = ez.wifi.is_connected and ez.wifi.is_connected() or false,
    }
end

function FirmwareUpdate:on_enter()
    -- on_enter fires every time the screen resurfaces -- including
    -- when a screen pushed on top is popped. Guard the subscription
    -- and the manifest fetch so we don't leak handles or restart an
    -- in-flight or completed check on every resume.
    if not self._sub then
        self._sub = ez.bus.subscribe("ota/progress", function(_topic, data)
            if type(data) ~= "table" then return end
            self:set_state({
                progress_phase = data.phase,
                progress_bytes = data.bytes or 0,
                progress_error = data.error,
            })
        end)
    end

    -- Already finished checking (manifest in hand or terminal error)
    -- or a download is in flight -- nothing to do on resume.
    local s = self:get_state()
    if s.manifest or s.error or s.installing then return end

    if not (ez.wifi.is_connected and ez.wifi.is_connected()) then
        self:set_state({ loading = false, error = "WiFi not connected." })
        return
    end

    local pub = ez.ota.signing_pubkey()
    if not pub then
        self:set_state({
            loading = false,
            error   = "OTA signing not configured on this device.\n" ..
                      "Burn a firmware whose kOtaSigningPubkey matches the CI signing key.",
        })
        return
    end

    local this = self
    spawn(function()
        local mres = ez.http.fetch(MANIFEST_URL, { timeout = 15000 })
        if not mres.ok or mres.status ~= 200 or not mres.body then
            this:set_state({
                loading = false,
                error   = "Manifest fetch failed (" ..
                          (mres.error or ("HTTP " .. tostring(mres.status))) ..
                          ")",
            })
            return
        end

        local sres = ez.http.fetch(SIGNATURE_URL, { timeout = 15000 })
        if not sres.ok or sres.status ~= 200 or not sres.body
           or #sres.body ~= 64 then
            this:set_state({
                loading = false,
                error   = "Signature fetch failed -- update refused.",
            })
            return
        end

        if not ez.crypto.ed25519_verify(pub, mres.body, sres.body) then
            this:set_state({
                loading = false,
                error   = "Signature mismatch -- update refused.",
            })
            return
        end

        local manifest = parse_json(mres.body)
        if not manifest or type(manifest.sha) ~= "string"
           or type(manifest.bin_url) ~= "string"
           or type(manifest.sha256) ~= "string" then
            this:set_state({
                loading = false,
                error   = "Manifest malformed.",
            })
            return
        end

        this:set_state({
            loading  = false,
            verified = true,
            manifest = manifest,
        })
    end)
end

function FirmwareUpdate:on_exit()
    if self._sub then
        ez.bus.unsubscribe(self._sub)
        self._sub = nil
    end
end

local function install(self)
    local m = self._state.manifest
    if not m then return end
    self:set_state({
        installing     = true,
        progress_phase = "start",
        progress_bytes = 0,
        progress_error = nil,
    })
    local res = ez.ota.apply_url(m.bin_url, m.sha256)
    if not res.ok then
        self:set_state({
            installing     = false,
            progress_phase = "error",
            progress_error = res.error or "failed to start",
        })
    end
end

local function status_section(state)
    local nodes = {}
    nodes[#nodes + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Current build", { color = "ACCENT", font = "small_aa" }))

    local cur = current_sha() or "(no SHA embedded)"
    nodes[#nodes + 1] = ui.padding({ 0, 8, 6, 8 },
        ui.text_widget(cur, { font = "default" }))

    if state.manifest then
        nodes[#nodes + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.text_widget("Latest on rolling-main",
                { color = "ACCENT", font = "small_aa" }))

        local latest = state.manifest.short_sha or short(state.manifest.sha)
        local size_str = format_bytes(state.manifest.size or 0)
        local built = state.manifest.built_at or ""
        nodes[#nodes + 1] = ui.padding({ 0, 8, 2, 8 },
            ui.text_widget(latest .. "  -  " .. size_str,
                { font = "default" }))
        if built ~= "" then
            nodes[#nodes + 1] = ui.padding({ 0, 8, 6, 8 },
                ui.text_widget("built " .. built,
                    { color = "TEXT_MUTED", font = "small_aa" }))
        end

        local up_to_date = (cur ~= "(no SHA embedded)") and
                           (cur:sub(1, 7) == latest:sub(1, 7))
        if up_to_date then
            nodes[#nodes + 1] = ui.padding({ 4, 8, 4, 8 },
                ui.text_widget("Up to date.",
                    { color = "TEXT_MUTED", font = "small_aa" }))
        elseif is_downgrade(state) then
            -- Warning, not block. ACCENT colour is already used for
            -- error text on this screen so it carries the right
            -- visual weight. The wording calls out the rollback-
            -- replay risk explicitly so a user who triggered the
            -- check themselves (and just wants to roll back a bad
            -- main) can confirm with informed consent.
            nodes[#nodes + 1] = ui.padding({ 4, 8, 4, 8 },
                ui.text_widget(
                    "! Older build than running firmware.\n" ..
                    "Installing will downgrade. Could also be a " ..
                    "MITM serving an old signed manifest.",
                    { wrap = true, color = "ACCENT", font = "small_aa" }))
        end
    end

    return nodes
end

local function progress_section(state)
    if not state.installing and not state.progress_phase then return {} end

    local phase = state.progress_phase or ""
    local nodes = {}

    if phase == "error" then
        nodes[#nodes + 1] = ui.padding({ 8, 8, 4, 8 },
            ui.text_widget("Update failed: " .. (state.progress_error or "?"),
                { wrap = true, color = "ACCENT", font = "small_aa" }))
    elseif phase == "end" then
        nodes[#nodes + 1] = ui.padding({ 8, 8, 4, 8 },
            ui.text_widget("Download complete -- " ..
                format_bytes(state.progress_bytes) ..
                ". Reboot to apply.",
                { wrap = true, color = "ACCENT", font = "small_aa" }))
    else
        nodes[#nodes + 1] = ui.padding({ 8, 8, 4, 8 },
            ui.text_widget("Downloading: " ..
                format_bytes(state.progress_bytes),
                { color = "ACCENT", font = "small_aa" }))
    end

    return nodes
end

function FirmwareUpdate:build(state)
    local content = {}

    if state.loading then
        content[#content + 1] = ui.padding({ 12, 12, 12, 12 },
            ui.text_widget("Checking rolling-main...",
                { color = "TEXT_MUTED", font = "small_aa" }))
    elseif state.error then
        content[#content + 1] = ui.padding({ 12, 12, 12, 12 },
            ui.text_widget(state.error,
                { wrap = true, color = "ACCENT", font = "small_aa" }))
    else
        for _, n in ipairs(status_section(state)) do
            content[#content + 1] = n
        end
        for _, n in ipairs(progress_section(state)) do
            content[#content + 1] = n
        end

        local pending = ez.ota.pending_partition()
        local can_install = state.manifest and not state.installing
                            and state.progress_phase ~= "end"
                            and not pending

        if can_install then
            local downgrade  = is_downgrade(state)
            local btn_label  = downgrade and "Install (downgrade)"
                                          or "Install update"
            local me = self
            content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
                ui.button(btn_label, {
                    on_press = function()
                        if downgrade then
                            -- Two-step gate: warning banner + confirm
                            -- dialog. A misclicked Install is the only
                            -- way an attacker's MITM-served old
                            -- manifest could land on a device, so make
                            -- sure the user has to actively agree.
                            dialog.confirm({
                                title    = "Downgrade firmware?",
                                message  = "This manifest is older " ..
                                    "than the running build. Install " ..
                                    "anyway?",
                                ok_label     = "Downgrade",
                                cancel_label = "Cancel",
                            }, function() install(me) end)
                        else
                            install(me)
                        end
                    end,
                }))
        end

        if pending or state.progress_phase == "end" then
            content[#content + 1] = ui.padding({ 4, 8, 8, 8 },
                ui.button("Reboot now", {
                    on_press = function() ez.system.restart() end,
                }))
        end
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Firmware Update", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function FirmwareUpdate:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return FirmwareUpdate
