-- Firmware update: pull the rolling-main or rolling-test manifest from
-- GitHub Releases, verify its Ed25519 signature against the embedded
-- ez.ota.signing_pubkey(), and stream the firmware-full.bin (bootloader
-- + partition table + app) straight into the inactive OTA partition via
-- ez.ota.apply_full_url. Authenticity comes entirely from the
-- signature -- TLS is opportunistic (setInsecure).
--
-- Flow:
--   on_enter: fetch manifest.json + manifest.json.sig, verify, compare
--             current build_sha against manifest.sha.
--   Install:  call ez.ota.apply_full_url(full_bin_url, full_sha256).
--             Progress arrives via the "ota/progress" bus topic.
--   On end:   ez.ota.pending_partition() flips non-nil; surface a
--             "Reboot to apply" button.

local ui     = require("ezui")
local dialog = require("ezui.dialog")
local whats_new = require("screens.settings.whats_new")
local screen_mod = require("ezui.screen")

local FirmwareUpdate = { title = "Firmware Update" }

local OWNER = "ezmesh"
local REPO  = "ezos"

local CHANNELS = {
    { label = "main",  tag = "rolling-main" },
    { label = "test",  tag = "rolling-test" },
}

local function url_for(tag, file)
    return "https://github.com/" .. OWNER .. "/" .. REPO ..
           "/releases/download/" .. tag .. "/" .. file
end

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

local function is_downgrade(state)
    if not state.manifest then return false end
    local cur_at = current_build_at()
    local m_at   = state.manifest.built_at
    if not cur_at or cur_at == "" or not m_at or m_at == "" then
        return false
    end
    return m_at < cur_at
end

local function short(s, n)
    n = n or 7
    if not s or s == "" then return "?" end
    return s:sub(1, n)
end

function FirmwareUpdate.initial_state()
    local saved = tonumber(ez.storage.get_pref("ota_channel", 1)) or 1
    if saved < 1 or saved > #CHANNELS then saved = 1 end
    return {
        channel       = saved,
        loading       = true,
        error         = nil,
        manifest      = nil,
        verified      = false,
        installing    = false,
        progress_bytes = 0,
        progress_phase = nil,
        progress_error = nil,
        wifi_connected = ez.wifi.is_connected and ez.wifi.is_connected() or false,
        remote_versions = nil,
    }
end

-- Fetch and verify a manifest for the given channel tag. `self` is the
-- screen instance; the result lands via set_state.
local function fetch_manifest(self, tag)
    self:set_state({
        loading       = true,
        error         = nil,
        manifest      = nil,
        verified      = false,
        installing    = false,
        progress_bytes = 0,
        progress_phase = nil,
        progress_error = nil,
    })

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
    local manifest_url  = url_for(tag, "manifest.json")
    local signature_url = manifest_url .. ".sig"
    spawn(function()
        local mres = ez.http.fetch(manifest_url, { timeout = 15000 })
        if not mres.ok or mres.status ~= 200 or not mres.body then
            this:set_state({
                loading = false,
                error   = "Manifest fetch failed (" ..
                          (mres.error or ("HTTP " .. tostring(mres.status))) ..
                          ")",
            })
            return
        end

        local sres = ez.http.fetch(signature_url, { timeout = 15000 })
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

        -- Cross-check the signed channel tag against the channel the
        -- user picked. Without this, a network-position attacker can
        -- swap a rolling-test manifest in for a rolling-main request:
        -- both are signed by the same key, signature verification
        -- passes, and the device silently installs the wrong build.
        -- The tag field is part of the signed payload, so checking
        -- here adds no new trust assumption.
        if manifest.tag ~= tag then
            this:set_state({
                loading = false,
                error   = "Manifest channel mismatch (got '"
                          .. tostring(manifest.tag) .. "', expected '"
                          .. tag .. "') -- update refused.",
            })
            return
        end

        this:set_state({
            loading  = false,
            verified = true,
            manifest = manifest,
        })

        -- Best-effort fetch of remote changelog (non-blocking, no error on failure)
        local vres = ez.http.fetch(url_for(tag, "versions.json"), { timeout = 10000 })
        if vres.ok and vres.status == 200 and vres.body then
            local versions = whats_new.parse_versions(vres.body)
            if versions then
                this:set_state({ remote_versions = versions })
            end
        end
    end)
end

function FirmwareUpdate:on_enter()
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

    local s = self:get_state()
    if s.manifest or s.error or s.installing then return end

    local ch = CHANNELS[s.channel] or CHANNELS[1]
    fetch_manifest(self, ch.tag)
end

function FirmwareUpdate:on_exit()
    if self._sub then
        ez.bus.unsubscribe(self._sub)
        self._sub = nil
    end
end

local function install(self)
    local m = self._state.manifest
    if not m or not m.full_bin_url or not m.full_sha256 then
        self:set_state({
            progress_phase = "error",
            progress_error = "manifest missing full_bin_url -- republish " ..
                "the rolling-" .. (CHANNELS[self._state.channel] or {}).label
                .. " release",
        })
        return
    end
    self:set_state({
        installing     = true,
        progress_phase = "start",
        progress_bytes = 0,
        progress_error = nil,
    })
    local res = ez.ota.apply_full_url(m.full_bin_url, m.full_sha256)
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

    local info = ez.system.get_firmware_info() or {}
    local cur = current_sha() or "(no SHA embedded)"
    local is_local_build = (cur == "(no SHA embedded)")
    local cur_ver = info.version or ""
    local cur_label = cur
    if cur_ver ~= "" then cur_label = cur_ver .. "  " .. cur end
    nodes[#nodes + 1] = ui.padding({ 0, 8, 6, 8 },
        ui.text_widget(cur_label, { font = "default" }))

    if is_local_build then
        nodes[#nodes + 1] = ui.padding({ 0, 8, 6, 8 },
            ui.text_widget(
                "Local dev build -- no downgrade detection.",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))
    end

    if state.manifest then
        local ch = CHANNELS[state.channel] or CHANNELS[1]
        nodes[#nodes + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.text_widget("Latest on " .. ch.tag,
                { color = "ACCENT", font = "small_aa" }))

        local latest = state.manifest.short_sha or short(state.manifest.sha)
        local m_ver = state.manifest.version or ""
        local size_str = format_bytes(state.manifest.size or 0)
        local built = state.manifest.built_at or ""
        local latest_label = latest .. "  -  " .. size_str
        if m_ver ~= "" then latest_label = m_ver .. "  " .. latest_label end
        nodes[#nodes + 1] = ui.padding({ 0, 8, 2, 8 },
            ui.text_widget(latest_label, { font = "default" }))
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
        nodes[#nodes + 1] = ui.padding({ 8, 8, 2, 8 },
            ui.progress(1.0, { height = 10 }))
        nodes[#nodes + 1] = ui.padding({ 2, 8, 4, 8 },
            ui.text_widget("Download complete -- " ..
                format_bytes(state.progress_bytes) ..
                ". Reboot to apply.",
                { wrap = true, color = "ACCENT", font = "small_aa" }))
    else
        -- Compute progress fraction from manifest size
        local total = state.manifest and (state.manifest.full_size or state.manifest.size) or 0
        local frac = 0
        if total > 0 then
            frac = math.min(1, state.progress_bytes / total)
        end
        nodes[#nodes + 1] = ui.padding({ 8, 8, 2, 8 },
            ui.progress(frac, { height = 10 }))
        nodes[#nodes + 1] = ui.padding({ 2, 8, 4, 8 },
            ui.text_widget("Downloading: " ..
                format_bytes(state.progress_bytes) ..
                (total > 0 and (" / " .. format_bytes(total)) or ""),
                { color = "TEXT_MUTED", font = "small_aa" }))
    end

    return nodes
end

function FirmwareUpdate:build(state)
    local content = {}
    -- pending_partition() flips non-nil only after the C++ side has
    -- moved the boot slot, so it's the source of truth for "ready to
    -- reboot" -- both for a fresh install and for resuming a session
    -- where the OTA finished before the screen was opened.
    local pending = ez.ota.pending_partition()

    if not state.installing and not pending then
        content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
            ui.text_widget("Release channel", { color = "ACCENT", font = "small_aa" }))
        local me = self
        content[#content + 1] = ui.padding({ 2, 8, 6, 8 },
            ui.dropdown(CHANNELS, {
                value = state.channel,
                on_change = function(idx)
                    ez.storage.set_pref("ota_channel", idx)
                    local ch = CHANNELS[idx] or CHANNELS[1]
                    me._state.channel = idx
                    fetch_manifest(me, ch.tag)
                end,
            }))
    end

    if state.loading then
        local ch = CHANNELS[state.channel] or CHANNELS[1]
        content[#content + 1] = ui.padding({ 12, 12, 12, 12 },
            ui.text_widget("Checking " .. ch.tag .. "...",
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

        if state.remote_versions and #state.remote_versions > 0 then
            content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
                ui.button("What's changed", {
                    on_press = function()
                        local cur_sha = current_sha()
                        local WN = { title = "What's Changed", granular_scroll = true }
                        function WN:build(s)
                            local items = whats_new.build_version_list(
                                state.remote_versions, cur_sha)
                            return ui.vbox({ gap = 0, bg = "BG" }, {
                                ui.title_bar("What's Changed", { back = true }),
                                ui.scroll({ grow = 1 },
                                    ui.vbox({ gap = 0 }, items)),
                            })
                        end
                        function WN:handle_key(k)
                            if k.special == "BACKSPACE" or k.special == "ESCAPE" then
                                return "pop"
                            end
                        end
                        screen_mod.push(screen_mod.create(WN, {}))
                    end,
                }))
        end

        if state.manifest and not state.installing and not pending then
            local downgrade  = is_downgrade(state)
            local btn_label  = downgrade and "Install (downgrade)"
                                          or "Install update"
            local me = self
            content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
                ui.button(btn_label, {
                    on_press = function()
                        if downgrade then
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

        if pending then
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
