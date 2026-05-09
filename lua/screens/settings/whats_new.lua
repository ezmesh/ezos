-- What's New: shows the changelog embedded in firmware.
-- Reads lua/docs/changelog.json (embedded as @changelog.json).
-- Also used by the firmware update screen to show remote changes.

local ui = require("ezui")

local WhatsNew = { title = "What's New", granular_scroll = true }

-- Parse the versions.json content. Returns a list of version entries
-- sorted newest-first, or nil on error.
local function parse_versions(json_str)
    if not json_str or json_str == "" then return nil end
    local ok, data = pcall(ez.storage.json_decode, json_str)
    if not ok or type(data) ~= "table" then return nil end
    return data.versions
end

-- Read the firmware-embedded changelog.
local function load_embedded()
    local raw = ez.docs and ez.docs.read and ez.docs.read("@changelog.json")
    if not raw then return nil end
    return parse_versions(raw)
end

-- Build a scrollable list of version entries from a versions table.
-- If current_sha is provided, entries newer than it are highlighted.
function WhatsNew.build_version_list(versions, current_sha)
    if not versions or #versions == 0 then
        return { ui.padding({ 12, 12, 12, 12 },
            ui.text_widget("No changelog available.",
                { color = "TEXT_MUTED", font = "small_aa" })) }
    end

    local items = {}
    local found_current = false

    for _, v in ipairs(versions) do
        local is_current = current_sha and v.commit
            and current_sha:sub(1, 7) == v.commit:sub(1, 7)
        if is_current then found_current = true end

        -- Version header
        local header = v.version or "?"
        if v.date then header = header .. "  (" .. v.date .. ")" end
        if is_current then header = header .. "  -- installed" end

        local is_new = not found_current and current_sha
        items[#items + 1] = ui.list_item({
            title = header,
            subtitle = is_new and "new" or nil,
            disabled = true,
        })

        -- Group entries
        local groups = v.groups or {}
        for _, gkey in ipairs({ "features", "fixes", "other" }) do
            local group = groups[gkey]
            if group and #group > 0 then
                local label = gkey == "features" and "Features"
                           or gkey == "fixes" and "Fixes"
                           or "Other"
                items[#items + 1] = ui.padding({ 2, 16, 0, 8 },
                    ui.text_widget(label, {
                        font = "small_aa", color = "TEXT_SEC",
                    }))
                for _, entry in ipairs(group) do
                    local desc = entry.description or "?"
                    if entry.scope and entry.scope ~= "" then
                        desc = entry.scope .. ": " .. desc
                    end
                    local sha_short = entry.commit and entry.commit:sub(1, 7) or ""
                    items[#items + 1] = ui.padding({ 0, 24, 1, 8 },
                        ui.text_widget("- " .. desc .. "  " .. sha_short, {
                            font = "small_aa", color = "TEXT_MUTED",
                            wrap = true,
                        }))
                end
            end
        end

        -- Divider between versions
        items[#items + 1] = ui.divider()
    end

    return items
end

function WhatsNew.initial_state()
    return { versions = load_embedded() }
end

function WhatsNew:build(state)
    local current_sha = nil
    local info = ez.system.get_firmware_info and ez.system.get_firmware_info() or {}
    current_sha = info.build_sha

    local content = WhatsNew.build_version_list(state.versions, current_sha)

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("What's New", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function WhatsNew:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

-- Expose parse helper for the firmware update screen
WhatsNew.parse_versions = parse_versions

return WhatsNew
