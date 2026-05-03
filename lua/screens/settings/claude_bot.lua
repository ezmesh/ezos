-- Claude Bot settings: URL + bearer token for the WiFi chat server.
--
-- Stored under prefs claude_bot_url / claude_bot_token. The chat
-- screen (screens.tools.claude) reads these on demand. A "Test"
-- button hits the bot's GET /ping endpoint (no auth required) so the
-- user gets immediate feedback that the server is reachable before
-- typing their first message.

local ui     = require("ezui")
local icons  = require("ezui.icons")
local dialog = require("ezui.dialog")

local Bot = { title = "Claude Bot" }

-- NVS key length is capped at 15 characters, so the verbose
-- "claude_bot_*" names from earlier drafts don't fit. The shorter
-- ones below are also used by screens.tools.claude.
local PREF_URL   = "claude_url"
local PREF_TOKEN = "claude_token"

function Bot.initial_state()
    return {
        url    = ez.storage.get_pref(PREF_URL, ""),
        token  = ez.storage.get_pref(PREF_TOKEN, ""),
        status = nil,
    }
end

local function masked(token)
    if not token or token == "" then return "(unset)" end
    if #token <= 4 then return string.rep("*", #token) end
    return token:sub(1, 2) .. string.rep("*", #token - 4) .. token:sub(-2)
end

local function set_url(self, value)
    value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    ez.storage.set_pref(PREF_URL, value)
    self:set_state({ url = value, status = nil })
end

local function set_token(self, value)
    value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    ez.storage.set_pref(PREF_TOKEN, value)
    self:set_state({ token = value, status = nil })
end

local function test_connection(self)
    local url = self._state.url or ""
    if url == "" then
        self:set_state({ status = "Set the URL first." })
        return
    end
    self:set_state({ status = "Testing..." })
    spawn(function()
        local resp = ez.http.fetch(url .. "/ping", { timeout = 5000 })
        if resp.ok and resp.status == 200 then
            self:set_state({ status = "Reachable: " .. (resp.body or "ok") })
        else
            self:set_state({
                status = "Unreachable: " .. (resp.error or
                    ("HTTP " .. tostring(resp.status))),
            })
        end
    end)
end

function Bot:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Claude Bot", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, {
            ui.padding({ 8, 8, 4, 8 },
                ui.text_widget("Connection",
                    { color = "ACCENT", font = "small_aa" })),

            ui.list_item({
                title    = "URL",
                subtitle = (state.url and state.url ~= "") and state.url
                                                            or "(unset)",
                icon     = icons.radio_tower,
                on_press = function()
                    dialog.prompt({
                        title       = "Bot URL",
                        message     = "e.g. http://192.168.1.10:8765",
                        value       = state.url or "",
                        placeholder = "http://host:port",
                    }, function(v) set_url(self, v) end)
                end,
            }),

            ui.list_item({
                title    = "Token",
                subtitle = masked(state.token),
                icon     = icons.settings,
                on_press = function()
                    dialog.prompt({
                        title       = "Bearer token",
                        message     = "Shown when the bot starts up",
                        value       = state.token or "",
                        placeholder = "bot bearer token",
                    }, function(v) set_token(self, v) end)
                end,
            }),

            ui.padding({ 8, 8, 4, 8 },
                ui.button("Test connection", {
                    on_press = function() test_connection(self) end,
                })),

            state.status and ui.padding({ 4, 8, 8, 8 },
                ui.text_widget(state.status, {
                    color = "TEXT_MUTED", font = "small_aa", wrap = true,
                })) or nil,

            ui.padding({ 12, 8, 4, 8 },
                ui.text_widget("How to run the bot",
                    { color = "ACCENT", font = "small_aa" })),
            ui.padding({ 0, 8, 8, 8 },
                ui.text_widget(
                    "On your dev host:\n" ..
                    "  python tools/dev/claude_wifi_bot.py\n" ..
                    "Copy the printed URL + token here.",
                    { color = "TEXT_MUTED", font = "small_aa", wrap = true })),
        })),
    })
end

function Bot:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Bot
