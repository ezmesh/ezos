-- HTTP server test screen.
--
-- Brings up a SoftAP and an HTTP server on port 80. Any device that
-- joins the AP can hit http://192.168.4.1/ from a browser and see a
-- status page with live tdeck info (uptime, heap, mesh node id).
-- Demonstrates the ez.http.serve_* bindings that wrap Arduino's
-- WebServer class.

local ui         = require("ezui")
local screen_mod = require("ezui.screen")

local SSID = "tdeck-http"
local PASS = "tdeckhttp"
local PORT = 80

local Screen = { title = "HTTP Test" }

function Screen.initial_state()
    return {
        running = false,
        requests = 0,
        last_uri = nil,
    }
end

local function page_html(self)
    -- Keep this small — the response fits in a Lua string and is
    -- bounded by the WebServer internal send buffer. A real app
    -- should stream long pages via send_P + sendContent.
    local uptime_s = math.floor(ez.system.millis() / 1000)
    local heap = ez.system.get_free_heap()
    local nid  = ez.mesh.get_short_id() or "?"
    local name = ez.mesh.get_node_name() or "?"
    return table.concat({
        "<!doctype html><html><head><meta charset='utf-8'>",
        "<meta name='viewport' content='width=device-width,initial-scale=1'>",
        "<title>", name, "</title>",
        "<style>body{font:16px/1.4 -apple-system,sans-serif;",
        "background:#111;color:#eee;margin:20px;max-width:600px}",
        "h1{color:#2c9}table{border-collapse:collapse}",
        "td{padding:4px 12px 4px 0}",
        ".l{color:#888}</style></head><body>",
        "<h1>", name, "</h1>",
        "<table>",
        "<tr><td class='l'>Node ID</td><td>", nid, "</td></tr>",
        "<tr><td class='l'>Uptime</td><td>", uptime_s, " s</td></tr>",
        "<tr><td class='l'>Free heap</td><td>", heap, " B</td></tr>",
        "<tr><td class='l'>Requests served</td><td>",
            self._state.requests, "</td></tr>",
        "</table>",
        "<p><a href='/'>reload</a> · <a href='/json'>json</a></p>",
        "</body></html>",
    })
end

local function page_json(self)
    return string.format(
        '{"uptime_ms":%d,"free_heap":%d,"node_id":"%s","requests":%d}',
        ez.system.millis(),
        ez.system.get_free_heap(),
        ez.mesh.get_short_id() or "?",
        self._state.requests)
end

local function start_server(self)
    spawn(function()
        local ok = ez.wifi.start_ap(SSID, PASS, 1, false, 4)
        if not ok then
            self:set_state({ running = false })
            return
        end
        ez.http.serve_start(PORT, function(req)
            -- Keep track for the UI. A direct field bump on state is
            -- fine here since the UI polls via invalidate(); we don't
            -- need a rebuild per request.
            self._state.requests = self._state.requests + 1
            self._state.last_uri = req.uri
            screen_mod.invalidate()

            if req.uri == "/json" then
                return 200, "application/json", page_json(self)
            elseif req.uri == "/" or req.uri == "/index.html" then
                return 200, "text/html; charset=utf-8", page_html(self)
            else
                return 404, "text/plain", "not found: " .. req.uri
            end
        end)

        -- WebServer needs handleClient() called regularly. 20 Hz is
        -- plenty for a status page; the Lua callback runs inline from
        -- within handleClient so a slower poll just adds latency.
        self._poll = ez.system.set_interval(50, function()
            ez.http.serve_update()
        end)

        self:set_state({ running = true })
    end)
end

local function stop_server(self)
    if self._poll then
        ez.system.cancel_timer(self._poll)
        self._poll = nil
    end
    ez.http.serve_stop()
    ez.wifi.stop_ap()
    self:set_state({ running = false })
end

function Screen:build(state)
    local ip = ez.wifi.is_ap_active() and ez.wifi.get_ap_ip() or "-"
    local clients = ez.wifi.is_ap_active()
        and ez.wifi.get_ap_client_count() or 0

    local info_lines = {
        "SSID:       " .. SSID,
        "Password:   " .. PASS,
        "URL:        http://" .. ip .. "/",
        "Clients:    " .. tostring(clients),
        "Requests:   " .. tostring(state.requests),
        "Last URI:   " .. tostring(state.last_uri or "-"),
    }

    local rows = {
        ui.title_bar("HTTP Test", { back = true }),
        ui.padding({ 8, 10, 4, 10 },
            ui.text_widget(
                state.running
                    and "Server running. Join the SSID and visit the URL."
                    or "Open a SoftAP + HTTP status page on :80.",
                { color = "TEXT_SEC", font = "small_aa", wrap = true })
        ),
    }
    for _, line in ipairs(info_lines) do
        rows[#rows + 1] = ui.padding({ 0, 10, 0, 10 },
            ui.text_widget(line, { font = "tiny_aa", color = "TEXT_MUTED" }))
    end
    rows[#rows + 1] = ui.padding({ 8, 10, 4, 10 },
        ui.button(state.running and "Stop" or "Start", {
            on_press = function()
                if state.running then stop_server(self)
                else                  start_server(self) end
            end,
        })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, rows)
end

function Screen:on_enter()
    self._redraw = ez.system.set_interval(500, function()
        screen_mod.invalidate()
    end)
end

function Screen:on_exit()
    if self._redraw then
        ez.system.cancel_timer(self._redraw)
        self._redraw = nil
    end
    stop_server(self)
end

function Screen:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Screen
