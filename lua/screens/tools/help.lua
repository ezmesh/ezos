-- Help: browse on-device manual + Lua API docs.
--
-- The app surfaces two stores:
--   * Firmware-embedded markdown via ez.docs.list / ez.docs.read. These are
--     the pages in lua/docs/ and ship in flash.
--   * SD-side markdown under /sd/docs/manual/ and /sd/docs/api/ for the
--     bulkier user guide and the auto-generated Lua API reference.
--
-- Selection pushes a reader screen that renders the chosen file via
-- ezui.markdown — the same renderer that powers the About screen.

local ui         = require("ezui")
local screen_mod = require("ezui.screen")
local async      = require("ezui.async")

local SD_MANUAL_DIR = "/sd/docs/manual"
local SD_API_DIR    = "/sd/docs/api"

-- ---------------------------------------------------------------------------
-- Reader screen — renders one markdown file.
-- ---------------------------------------------------------------------------

-- granular_scroll lets plain UP/DOWN pixel-scroll the first scroll container
-- in the tree. Without it, arrow keys would only move focus, and a markdown
-- reader has no focusable widgets — so the page would never scroll.
local Reader = { granular_scroll = true }

function Reader.initial_state(label, source_kind, path)
    return {
        label = label or "",
        kind  = source_kind,  -- "embedded" | "sd"
        path  = path,
        md    = nil,
        error = nil,
    }
end

function Reader:on_enter()
    local state = self:get_state()
    if state.md or state.error then return end
    self.title = state.label or "Help"

    local kind = state.kind
    local path = state.path
    if kind == "embedded" then
        local md = ez.docs.read(path)
        if md and md ~= "" then
            self:set_state({ md = md })
        else
            self:set_state({ error = "Doc not found: " .. tostring(path) })
        end
        return
    end

    local this = self
    async.task(function()
        local content = async_read(path)
        if content and content ~= "" then
            this:set_state({ md = content })
        else
            this:set_state({ error = "Could not read " .. tostring(path) })
        end
    end)
end

function Reader:build(state)
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
        ui.title_bar(state.label or "Help", { back = true }),
        ui.scroll({ grow = 1 }, ui.padding({ 4, 10, 8, 10 }, body)),
    })
end

function Reader:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

local function open_reader(label, kind, path)
    local inst = screen_mod.create(Reader, Reader.initial_state(label, kind, path))
    screen_mod.push(inst)
end

-- ---------------------------------------------------------------------------
-- Helpers for naming and listing.
-- ---------------------------------------------------------------------------

-- Convert "@manual/getting-started.md" or "/sd/docs/manual/maps.md" into a
-- title-cased label with the extension stripped.
local function label_for(path)
    local name = path:match("([^/]+)$") or path
    name = name:gsub("%.md$", "")
    name = name:gsub("[-_]", " ")
    -- Capitalize first letter; rest stays as authored so acronyms (GPS, API)
    -- are not lowercased.
    return name:sub(1, 1):upper() .. name:sub(2)
end

local function list_sd_dir(dir)
    -- The SD layer returns empty for paths with a trailing slash; strip it.
    local clean = dir:gsub("/+$", "")
    local files = ez.storage.list_dir(clean)
    if not files then return {} end
    local out = {}
    for _, f in ipairs(files) do
        if not f.is_dir and f.name:lower():match("%.md$") then
            out[#out + 1] = clean .. "/" .. f.name
        end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Index screen — main Help entry point.
-- ---------------------------------------------------------------------------

local Help = { title = "Help" }

function Help.initial_state()
    return {
        embedded = {},   -- { {label, path}, ... } resolved on_enter
        sd_manual = {},
        sd_api    = {},
    }
end

function Help:on_enter()
    -- Always re-scan SD: a `pio run -t uploadfs` or a fresh card insert
    -- should surface immediately when the screen reopens.
    local embedded = {}
    local paths = ez.docs.list and ez.docs.list() or {}
    -- Keep "manual/index.md" first if present so the entry list reads
    -- naturally; rest preserves the path-sorted order from the binding.
    local index_path = nil
    for _, p in ipairs(paths) do
        if p == "@manual/index.md" then index_path = p
        else embedded[#embedded + 1] = p
        end
    end
    if index_path then
        table.insert(embedded, 1, index_path)
    end

    local rows_embedded = {}
    for _, p in ipairs(embedded) do
        rows_embedded[#rows_embedded + 1] = { label = label_for(p), path = p }
    end

    local rows_sd_manual = {}
    for _, p in ipairs(list_sd_dir(SD_MANUAL_DIR)) do
        rows_sd_manual[#rows_sd_manual + 1] = { label = label_for(p), path = p }
    end

    local rows_sd_api = {}
    for _, p in ipairs(list_sd_dir(SD_API_DIR)) do
        rows_sd_api[#rows_sd_api + 1] = { label = label_for(p), path = p }
    end

    self:set_state({
        embedded  = rows_embedded,
        sd_manual = rows_sd_manual,
        sd_api    = rows_sd_api,
    })
end

local function section_header(title)
    return ui.padding({ 8, 8, 2, 8 },
        ui.text_widget(title, { color = "ACCENT", font = "small_aa" })
    )
end

function Help:build(state)
    local items = { ui.title_bar("Help", { back = true }) }

    local rows = {}

    if #state.embedded > 0 then
        rows[#rows + 1] = section_header("Manual (firmware)")
        for _, r in ipairs(state.embedded) do
            local row = r
            rows[#rows + 1] = ui.list_item({
                title    = row.label,
                compact  = true,
                on_press = function()
                    open_reader(row.label, "embedded", row.path)
                end,
            })
        end
    end

    if #state.sd_manual > 0 then
        rows[#rows + 1] = section_header("Manual (SD)")
        for _, r in ipairs(state.sd_manual) do
            local row = r
            rows[#rows + 1] = ui.list_item({
                title    = row.label,
                compact  = true,
                on_press = function()
                    open_reader(row.label, "sd", row.path)
                end,
            })
        end
    end

    if #state.sd_api > 0 then
        rows[#rows + 1] = section_header("Lua API (SD)")
        for _, r in ipairs(state.sd_api) do
            local row = r
            rows[#rows + 1] = ui.list_item({
                title    = row.label,
                compact  = true,
                on_press = function()
                    open_reader(row.label, "sd", row.path)
                end,
            })
        end
    end

    if #rows == 0 then
        rows[#rows + 1] = ui.padding({ 16, 12, 12, 12 },
            ui.text_widget("No documentation available.", {
                wrap = true, color = "TEXT_SEC",
            })
        )
        rows[#rows + 1] = ui.padding({ 4, 12, 12, 12 },
            ui.text_widget(
                "Generate with `python tools/generate_lua_docs.py` and copy "
                .. "to /sd/docs/, or rebuild firmware after adding files "
                .. "under lua/docs/manual/.",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )
    end

    items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows))
    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Help:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Help
