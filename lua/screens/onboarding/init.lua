-- First-run onboarding wizard.
--
-- Each step is its own screen module under this directory; this file is
-- the orchestrator. start() pushes the welcome screen on top of whatever
-- is currently active (the desktop, on a fresh boot). Each step's ENTER
-- handler calls advance() which pushes the next module; BACKSPACE pops.
-- The welcome screen suppresses BACKSPACE so the user can't escape to
-- the desktop until the required steps are committed.
--
-- The done step writes onboarded = "1" and pops every onboarding screen
-- off, leaving the desktop on top. Onboarding screens are tagged with
-- _onboarding = true on the screen module so the unwind loop knows where
-- to stop without needing absolute stack indices.

local M = {}

-- Order of screens. Required first, then optional. The "Step N / 5"
-- progress label is computed against #REQUIRED.
M.REQUIRED = {
    "screens.onboarding.welcome",
    "screens.onboarding.node_name",
    "screens.onboarding.region",
    "screens.onboarding.timezone",
    "screens.onboarding.theme",
}

M.OPTIONAL = {
    "screens.onboarding.callsign",
    "screens.onboarding.identity",
}

M.DONE = "screens.onboarding.done"

-- Reverse map: module path → 1-based step number among REQUIRED. Keeps
-- the title-bar progress indicator honest if step modules get reordered.
M.REQUIRED_INDEX = {}
for i, path in ipairs(M.REQUIRED) do M.REQUIRED_INDEX[path] = i end

M.PREF_ONBOARDED = "onboarded"

-- Strip non-ASCII bytes from a string. The on-device bitmap fonts only
-- cover 0x20..0x7E, so non-ASCII would render as `[]` in chat/contact
-- lists. Applied to free-text inputs before they're persisted.
function M.ascii_only(s)
    if not s then return "" end
    return (s:gsub("[^\32-\126]", ""))
end

-- True when the user has completed onboarding at least once. Coerces a
-- couple of historical truthy shapes since NVS can return strings.
function M.is_onboarded()
    local v = ez.storage.get_pref(M.PREF_ONBOARDED, nil)
    if v == nil then return false end
    if type(v) == "boolean" then return v end
    if type(v) == "number"  then return v ~= 0 end
    if type(v) == "string"  then return v == "1" or v == "true" end
    return false
end

-- Push a step module by require path. Each push creates a fresh instance
-- so initial_state() runs again — that re-reads any prefs the previous
-- step wrote, which keeps "back, then forward" navigation idempotent.
function M.push_step(path)
    local screen = require("ezui.screen")
    local def = require(path)
    def._onboarding = true
    local init = def.initial_state and def.initial_state() or {}
    screen.push(screen.create(def, init))
end

-- Advance to the next step. The current step's module path is passed in
-- so the navigation table doesn't need to live on the screen instance.
function M.advance(current_path)
    local order = {}
    for _, p in ipairs(M.REQUIRED) do order[#order + 1] = p end
    for _, p in ipairs(M.OPTIONAL) do order[#order + 1] = p end
    order[#order + 1] = M.DONE

    for i, p in ipairs(order) do
        if p == current_path and order[i + 1] then
            M.push_step(order[i + 1])
            return
        end
    end
end

-- Tear down the wizard stack: pop every screen tagged with _onboarding
-- so we land on whatever was underneath (the desktop on first boot, or
-- Settings on a "Repeat onboarding" run).
function M.finish()
    local screen = require("ezui.screen")
    while true do
        local top = screen.peek()
        if not top or not (top._def and top._def._onboarding) then break end
        local depth = screen.depth()
        screen.pop()
        if screen.depth() == depth then break end  -- root guard hit
    end
end

-- Public entry point. Used by boot.lua on first boot and by the
-- "Repeat onboarding" entry under Settings → System.
function M.start()
    M.push_step(M.REQUIRED[1])
end

-- Build the title-bar `right` label for a given step path. Required
-- steps show "Step N / total"; optional steps show "Optional".
function M.progress_label(path)
    local idx = M.REQUIRED_INDEX[path]
    if idx then
        return string.format("Step %d / %d", idx, #M.REQUIRED)
    end
    return "Optional"
end

return M
