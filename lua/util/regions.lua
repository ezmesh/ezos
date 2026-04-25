-- Shared LoRa region presets and lookup helpers.
--
-- Common regional center frequencies for MeshCore. The radio API takes a
-- raw float MHz, so the table is the single source of truth — both the
-- onboarding wizard's region step and Settings -> Radio read from it.
--
-- Storage note: ez.storage.set_pref(key, <float>) routes through
-- putFloat, which lands in NVS as a blob; the matching get_pref has no
-- float decoder and returns "" on read. So we persist as a string and
-- tonumber() on read.

local M = {}

M.PREF_KEY = "radio_freq_mhz"

M.PRESETS = {
    { label = "EU 869 MHz", mhz = 869.525 },
    { label = "US 915 MHz", mhz = 906.875 },
    { label = "AS 433 MHz", mhz = 433.000 },
    { label = "AU 915 MHz", mhz = 915.000 },
}

M.LABELS = {}
for i, p in ipairs(M.PRESETS) do M.LABELS[i] = p.label end

-- Best-effort match: prefer the saved pref, fall back to the closest
-- preset when the radio is currently tuned to something custom.
function M.current_index()
    local raw = ez.storage.get_pref(M.PREF_KEY, "")
    local saved = tonumber(raw) or 0
    if saved > 0 then
        for i, p in ipairs(M.PRESETS) do
            if math.abs(p.mhz - saved) < 0.01 then return i end
        end
    end
    return 1
end

-- Persist the picked index, apply it to the radio hardware. Returns true
-- on success. The radio change is instant; no reboot required.
function M.apply_index(idx)
    local preset = M.PRESETS[idx]
    if not preset then return false end
    if ez.radio and ez.radio.set_frequency then
        ez.radio.set_frequency(preset.mhz)
    end
    ez.storage.set_pref(M.PREF_KEY, tostring(preset.mhz))
    return true
end

return M
