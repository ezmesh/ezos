-- Claude chat screen.
--
-- Streaming chat: posts a message to the WiFi bot
-- (tools/dev/claude_wifi_bot.py), gets back a request_id, and renders
-- progress events as the bot's worker thread emits them. The bot
-- POSTs each event back to the device's OTA dev server at
-- /chat_event, where ota_bindings forwards them onto the Lua bus
-- topic "claude/event". This screen subscribes to that topic and
-- renders each event as its own message block.
--
-- Block kinds (matches the bot's envelope vocabulary):
--   user        -- the user's own message (bubble, ACCENT)
--   thinking    -- assistant reasoning preview (muted small text)
--   tool_use    -- assistant invoked a tool (accent compact line)
--   tool_result -- tool output snippet (muted compact line)
--   assistant   -- assistant text reply (bubble, SURFACE)
--   system      -- bot/transport diagnostics (muted small text)
--
-- Configuration: Settings -> System -> Claude Bot (URL + bot token).
-- The OTA dev server must also be running so the bot has somewhere
-- to send /chat_event back to.

local ui    = require("ezui")
local theme = require("ezui.theme")
local node  = require("ezui.node")

local Claude = { title = "Claude" }

-- NVS key length cap is 15 chars, so we use the short forms.
local PREF_URL   = "claude_url"
local PREF_TOKEN = "claude_token"

-- Custom node for chat bubbles. Wraps text and colors by role so user
-- and assistant turns are visually distinct without needing a heavier
-- graphics pass. Bubbles are full width with role label up top.
node.register("claude_msg", {
    measure = function(n, max_w, max_h)
        theme.set_font("small_aa")
        local fh = theme.font_height()
        local pad = 6
        local label_h = fh + 2
        local lines = require("ezui.text").wrap(n.text or "",
            max_w - 8 - pad * 2)
        local body_h = #lines * (fh + 1)
        return max_w, label_h + body_h + pad * 2
    end,

    draw = function(n, d, x, y, w, h)
        local is_user = n.role == "user"
        local bg = is_user and theme.color("ACCENT") or theme.color("SURFACE")
        local fg = is_user and theme.color("STATUS_BG") or theme.color("TEXT")
        local label_color = is_user and theme.color("STATUS_BG") or theme.color("TEXT_MUTED")
        local pad = 6

        d.fill_round_rect(x + 4, y + 2, w - 8, h - 4, 4, bg)

        theme.set_font("small_aa")
        local fh = theme.font_height()
        local label = is_user and "You" or "Claude"
        d.draw_text(x + 4 + pad, y + 2 + pad, label, label_color)

        local lines = require("ezui.text").wrap(n.text or "",
            w - 8 - pad * 2)
        local ty = y + 2 + pad + fh + 2
        for _, line in ipairs(lines) do
            d.draw_text(x + 4 + pad, ty, line, fg)
            ty = ty + fh + 1
        end
    end,
})

local function find_scroll(n)
    if not n then return nil end
    if n.type == "scroll" then return n end
    if n.children then
        for _, child in ipairs(n.children) do
            local s = find_scroll(child)
            if s then return s end
        end
    end
    return nil
end

local function stick_to_bottom(inst)
    local s = find_scroll(inst._tree)
    if s then s.scroll_offset = 99999 end
    require("ezui.screen").invalidate()
end

-- Best-effort short-form summary of a tool input table for display.
-- The full input can be huge (entire file contents on Edit/Write); we
-- want one compact line that says what tool ran with what target.
local function summarize_tool_input(name, input)
    if type(input) ~= "table" then return "" end
    if name == "Bash" then
        return tostring(input.command or input.cmd or "")
    elseif name == "Read" or name == "Edit" or name == "Write"
            or name == "NotebookEdit" then
        return tostring(input.file_path or input.path or "")
    elseif name == "Grep" or name == "Glob" then
        local pat = input.pattern or input.glob or ""
        local where = input.path and (" in " .. input.path) or ""
        return tostring(pat) .. where
    elseif name == "WebFetch" or name == "WebSearch" then
        return tostring(input.url or input.query or "")
    end
    -- Generic fallback: dump the first stringable field we find.
    for k, v in pairs(input) do
        if type(v) == "string" and #v < 120 then
            return k .. "=" .. v
        end
    end
    return ""
end

function Claude.initial_state()
    return {
        messages = {},      -- list of { role = "...", text = "...", name = ?, error = ? }
        input    = "",
        sending  = false,
        error    = nil,
        request_id = nil,   -- non-nil while a turn is in flight
        sub_id   = nil,     -- bus subscription handle, set in on_enter
    }
end

local function append_message(self, msg)
    table.insert(self._state.messages, msg)
    self:set_state({})
    stick_to_bottom(self)
end

-- Try to merge a streamed text fragment into the last message if it's
-- already an assistant text block from the same turn. This keeps
-- multi-fragment streamed replies in a single bubble instead of
-- spawning one per chunk.
local function append_or_extend_assistant(self, request_id, text)
    local msgs = self._state.messages
    local last = msgs[#msgs]
    if last and last.role == "assistant" and last.request_id == request_id then
        last.text = (last.text or "") .. "\n" .. text
        self:set_state({})
        stick_to_bottom(self)
        return
    end
    append_message(self, {
        role = "assistant", text = text, request_id = request_id,
    })
end

-- Map an envelope from the bot to a UI message block (or extend an
-- existing one). Called from the bus subscription on the Lua thread.
local function handle_event(self, envelope)
    if type(envelope) ~= "table" then return end
    local rid = envelope.request_id
    -- Drop stale events from a prior turn that's been superseded.
    if self._state.request_id and rid and rid ~= self._state.request_id then
        return
    end
    local kind = envelope.kind

    if kind == "thinking" then
        append_message(self, {
            role = "thinking", text = envelope.text or "",
            request_id = rid,
        })
    elseif kind == "tool_use" then
        local summary = summarize_tool_input(envelope.name or "?", envelope.input)
        append_message(self, {
            role = "tool_use",
            name = envelope.name or "?",
            text = summary,
            request_id = rid,
        })
    elseif kind == "tool_result" then
        append_message(self, {
            role = "tool_result",
            text = envelope.snippet or "",
            error = envelope.is_error == true,
            request_id = rid,
        })
    elseif kind == "text" then
        append_or_extend_assistant(self, rid, envelope.text or "")
    elseif kind == "done" then
        -- The bot also sends the final consolidated text in `text`.
        -- If we never saw any streaming text events, surface it now;
        -- otherwise the streamed pieces already form the bubble.
        local last = self._state.messages[#self._state.messages]
        local saw_assistant =
            last and last.role == "assistant" and last.request_id == rid
        if not saw_assistant and envelope.text and envelope.text ~= "" then
            append_message(self, {
                role = "assistant", text = envelope.text,
                request_id = rid,
            })
        end
        self:set_state({ sending = false, request_id = nil })
    elseif kind == "error" then
        append_message(self, {
            role = "system",
            text = "Error: " .. (envelope.text or "unknown"),
        })
        self:set_state({ sending = false, request_id = nil })
    end
end

local function send_message(self, text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or self._state.sending then return end

    local url   = ez.storage.get_pref(PREF_URL, "")
    local token = ez.storage.get_pref(PREF_TOKEN, "")
    if url == "" or token == "" then
        append_message(self, {
            role = "system",
            text = "Configure Settings -> System -> Claude Bot first.",
        })
        return
    end

    -- Build the callback URL the bot will POST events to. Combines
    -- the device's WiFi IP, the OTA dev server's port (8080 by
    -- default), and the OTA bearer the bot already knows from a prior
    -- "token: XXXXXX" turn or from the Share OTA token menu action.
    local ip = (ez.wifi.get_ip and ez.wifi.get_ip()) or ""
    local ota_token = (ez.ota and ez.ota.get_token and ez.ota.get_token()) or ""
    local callback_url, callback_auth
    if ip ~= "" and ip ~= "0.0.0.0" and ota_token ~= "" then
        callback_url = "http://" .. ip .. ":8080/chat_event"
        callback_auth = "Bearer " .. ota_token
    end
    if not callback_url then
        append_message(self, {
            role = "system",
            text = "Tip: enable Dev OTA so the bot can stream progress (Settings -> System -> Dev OTA).",
        })
    end

    table.insert(self._state.messages, { role = "user", text = text })
    self:set_state({ input = "", sending = true, error = nil })
    stick_to_bottom(self)

    spawn(function()
        local body = ez.storage.json_encode({
            message = text,
            callback_url = callback_url,
            callback_auth = callback_auth,
        })
        local resp = ez.http.fetch(url .. "/chat", {
            method  = "POST",
            timeout = 15000,
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Content-Type"]  = "application/json",
            },
            body = body,
        })

        if resp.ok and (resp.status == 202 or resp.status == 200) then
            local decoded = ez.storage.json_decode(resp.body or "")
            if resp.status == 200 and decoded and decoded.reply then
                -- Token-only short-circuit (or callbacks unavailable).
                append_message(self, {
                    role = "assistant", text = decoded.reply,
                })
                self:set_state({ sending = false, request_id = nil })
            elseif decoded and decoded.request_id then
                self:set_state({ request_id = decoded.request_id })
            else
                append_message(self, {
                    role = "system",
                    text = "Bot accepted the request but didn't return a request_id.",
                })
                self:set_state({ sending = false, request_id = nil })
            end
        elseif resp.status == 401 then
            append_message(self, {
                role = "system",
                text = "Auth failed -- check the token in Settings -> System -> Claude Bot.",
            })
            self:set_state({ sending = false, request_id = nil })
        elseif resp.error then
            local err_str = tostring(resp.error)
            local hint = err_str
            if err_str:lower():find("timeout") then
                hint = "Bot didn't accept the request in 15s. Is it running and reachable?"
            end
            append_message(self, {
                role = "system",
                text = "Network error: " .. hint,
            })
            self:set_state({ sending = false, request_id = nil })
        else
            append_message(self, {
                role = "system",
                text = "HTTP " .. tostring(resp.status) ..
                       ": " .. (resp.body or "?"),
            })
            self:set_state({ sending = false, request_id = nil })
        end
    end)
end

local function render_thinking(text)
    return ui.padding({ 2, 12, 4, 12 },
        ui.text_widget("thinking: " .. (text or ""), {
            color = "TEXT_MUTED", font = "small_aa", wrap = true,
        }))
end

local function render_tool_use(m)
    local label = "-> " .. (m.name or "?")
    if m.text and m.text ~= "" then
        label = label .. ": " .. m.text
    end
    return ui.padding({ 2, 8, 2, 8 },
        ui.text_widget(label, {
            color = "ACCENT", font = "small_aa", wrap = true,
        }))
end

local function render_tool_result(m)
    local marker = m.error and "[err] " or "[ok] "
    return ui.padding({ 0, 16, 4, 8 },
        ui.text_widget(marker .. (m.text or ""), {
            color = m.error and "ERROR" or "TEXT_MUTED",
            font = "small_aa", wrap = true,
        }))
end

function Claude:build(state)
    local items = { ui.title_bar("Claude", { back = true }) }

    local content = {}
    if #state.messages == 0 then
        content[#content + 1] = ui.padding({ 20, 12, 8, 12 },
            ui.text_widget("Ask Claude to make firmware changes.", {
                color = "TEXT_MUTED", text_align = "center", wrap = true,
            }))
        content[#content + 1] = ui.padding({ 6, 12, 12, 12 },
            ui.text_widget(
                'e.g. "add a debug log when the screen wakes" then ' ..
                '"build and push it".',
                { color = "TEXT_MUTED", font = "small_aa",
                  text_align = "center", wrap = true }))
    else
        for _, m in ipairs(state.messages) do
            if m.role == "user" or m.role == "assistant" then
                content[#content + 1] = ui.padding({ 4, 4, 4, 4 }, {
                    type = "claude_msg", role = m.role, text = m.text,
                })
            elseif m.role == "thinking" then
                content[#content + 1] = render_thinking(m.text)
            elseif m.role == "tool_use" then
                content[#content + 1] = render_tool_use(m)
            elseif m.role == "tool_result" then
                content[#content + 1] = render_tool_result(m)
            elseif m.role == "system" then
                content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
                    ui.text_widget(m.text, {
                        color = "TEXT_MUTED", font = "small_aa", wrap = true,
                    }))
            end
        end
    end

    if state.sending then
        content[#content + 1] = ui.padding({ 4, 12, 4, 12 },
            ui.hbox({ gap = 6 }, {
                ui.spinner({ size = 12 }),
                ui.text_widget("Working...", {
                    color = "TEXT_MUTED", font = "small_aa",
                }),
            }))
    end

    items[#items + 1] = ui.scroll({
        grow = 1,
        scroll_offset = state.scroll or 99999,
    }, ui.vbox({ gap = 0 }, content))

    items[#items + 1] = ui.padding({ 4, 4, 4, 4 },
        ui.text_input({
            value = state.input or "",
            placeholder = state.sending and "Wait for reply..." or "Ask Claude...",
            on_change = function(val) state.input = val end,
            on_submit = function(val) send_message(self, val) end,
        }))

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Claude:on_enter()
    -- Same compose-box-focus dance as dm_conversation: rebuild once
    -- so the focus chain populates, then jump focus to the text input
    -- and enter edit mode so keystrokes route there immediately.
    self:_rebuild()
    local focus_mod = require("ezui.focus")
    if #focus_mod.chain > 0 then
        focus_mod.index = #focus_mod.chain
        focus_mod._update_marks()
        focus_mod.enter_edit()
    end
    stick_to_bottom(self)

    -- Subscribe to the streaming events the bot pushes back through
    -- the OTA server's /chat_event handler. The handler forwards the
    -- raw JSON envelope as a string to bus topic "claude/event"; we
    -- decode here to keep the C++ side dumb.
    self._state.sub_id = ez.bus.subscribe("claude/event", function(_, data)
        if type(data) ~= "string" then return end
        local ok, decoded = pcall(ez.storage.json_decode, data)
        if ok and type(decoded) == "table" then
            handle_event(self, decoded)
        end
    end)
end

function Claude:on_exit()
    if self._state.sub_id then
        ez.bus.unsubscribe(self._state.sub_id)
        self._state.sub_id = nil
    end
end

-- Alt+M menu. Convenient way to share the device's persisted OTA
-- bearer token over chat -- the bot recognizes a `token: XXXXXX`
-- line in any DM and updates its cache, so this becomes the
-- one-click flow after pressing Regenerate on the Dev OTA screen.
-- "Clear chat" wipes the on-screen history (the bot's own memory
-- continues; restart the bot or run --clear-memory if you want a
-- truly fresh thread).
function Claude:menu()
    local items = {}

    items[#items + 1] = {
        title    = "Share OTA token",
        subtitle = "Send `token: XXXXXX` so the bot picks it up",
        on_press = function()
            local token = ez.ota.get_token and ez.ota.get_token() or ""
            if token == "" then
                table.insert(self._state.messages, {
                    role = "system",
                    text = "No OTA token available -- start the dev server once first.",
                })
                self:set_state({})
                return
            end
            send_message(self, "token: " .. token)
        end,
    }

    items[#items + 1] = {
        title    = "Bot settings",
        subtitle = "Edit URL / token / test connection",
        on_press = function()
            local screen_mod = require("ezui.screen")
            local def = require("screens.settings.claude_bot")
            local init = def.initial_state and def.initial_state() or {}
            screen_mod.push(screen_mod.create(def, init))
        end,
    }

    if #(self._state.messages or {}) > 0 then
        items[#items + 1] = {
            title    = "Clear chat",
            subtitle = "Wipe on-screen history (bot memory unchanged)",
            on_press = function()
                self:set_state({
                    messages = {}, sending = false,
                    error = nil, request_id = nil,
                })
            end,
        }
    end

    return items
end

function Claude:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        if (self._state.input or "") == "" then return "pop" end
    end
    return nil
end

return Claude
