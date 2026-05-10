// ez.ota module bindings
//
// Firmware-only OTA. Two responsibilities:
//   1. An ESPAsyncWebServer instance (default port 8080) exposing
//      streaming POST /ota authenticated with a per-session bearer
//      token. Bytes flow into Update.write through the body callback
//      as they arrive -- no main-loop blocking, no per-byte multipart
//      parser. Also exposes /info, /logs, /screen.bmp, /lua, /key,
//      /chat_event for the host-side dev console and the Claude bot.
//   2. A handful of helpers around esp_ota_* so boot.lua can mark the
//      running image good (cancelling the IDF's auto-rollback) and
//      callers can introspect / force a rollback.
//
// We sit on AsyncTCP rather than ESP-IDF's esp_http_server. The
// httpd path's BSD-socket send call (lwip_send) silently stalls
// multi-segment responses on Arduino-ESP32 2.0.17 / IDF 4.4.x for
// this board: the first segment makes it onto the wire and the WiFi
// TX queue then locks up entirely until the connection is killed.
// AsyncTCP drives the same stack via the raw lwIP TCP API
// (tcp_write + tcp_sent callback) inside the lwIP task, which
// bypasses the broken socket layer and reliably ships the full
// 230 KiB framebuffer dump.
//
// /lua is the one handler that touches the Lua state. It can't run
// on the AsyncTCP task directly (Lua is single-threaded and the main
// loop is already calling into it) so we queue a stack-allocated
// DeferredLua + block the AsyncTCP request handler on a flag while
// the main loop processes the call, then send the response. Other
// handlers are pure reads of ESP-IDF state (info / logs), use
// already-thread-safe primitives (MessageBus::post for chat_event,
// the keyboard inject queue's single-producer SPSC), or do their own
// heap work (screen.bmp builds a fresh PSRAM buffer -- torn pixels
// possible, never a crash).
//
// The dev server is gated behind the user enabling it from settings.
// It is *not* started automatically at boot.

#include "ota_bindings.h"
#include "bus_bindings.h"
#include "../lua_runtime.h"
#include "../../util/log.h"
#include "../../hardware/display.h"
#include "../../hardware/keyboard.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <Update.h>
#include <WiFi.h>
#include "../../util/http_client.h"
#include <mbedtls/sha256.h>
#include <esp_ota_ops.h>
#include <ESPAsyncWebServer.h>
#include <AsyncTCP.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>
#include <esp_task_wdt.h>
#include <esp_spi_flash.h>

#include "../../ota_pubkey.h"

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

// Hardware globals defined in main.cpp.
extern Display* display;
extern Keyboard* keyboard;

// @module ez.ota
// @brief Firmware over-the-air updates and rollback control
// @description
// Provides a developer-mode HTTP push endpoint and helpers around the
// ESP-IDF OTA partition machinery. The push endpoint is gated behind
// a per-session bearer token (regenerated each start) so a stray
// device on the same WiFi can't reflash you. The new image only
// becomes the running app on the *next* reboot, and is left in the
// "pending verify" state -- call ez.ota.mark_valid() once the new
// image has booted successfully, otherwise the bootloader auto-rolls
// back after a few crash loops.
// @end

// @bus ota/progress
// @brief Push-update progress events
// @payload { phase: "start"|"write"|"end"|"error", bytes: integer, error?: string }
// @end

namespace ota_bindings {

namespace {

constexpr int DEFAULT_PORT = 8080;
constexpr size_t TOKEN_LEN = 7;  // 6 chars + NUL
constexpr size_t MAX_ERROR_LEN = 128;

// Throttle progress events to roughly every 64 KiB so the bus / Lua
// rebuild path don't get hammered during a multi-megabyte upload.
constexpr size_t PROGRESS_INTERVAL = 64 * 1024;

AsyncWebServer* g_server = nullptr;
int g_port = DEFAULT_PORT;
char g_token[TOKEN_LEN] = {0};

// ---------------------------------------------------------------------------
// Main-thread marshalling for /lua
//
// AsyncWebServer handlers fire on the AsyncTCP worker task. lua_pcall
// on the main state from there races with the Lua main loop, so we
// queue a stack-allocated DeferredLua + block the worker until
// update() (Lua main thread) fills in the response slot and signals.
//
// Stack-allocation works because the worker BLOCKS on `done` -- the
// descriptor stays alive until the main thread is done writing into
// it. The /lua handler then sends the response synchronously using
// the filled-in fields. Bounded blocking on AsyncTCP is acceptable
// because /lua is dev-only and we cap the wait at 10 s.
// ---------------------------------------------------------------------------

struct DeferredLua {
    String body;              // request body (Lua source)
    volatile bool done;
    int status;
    String response_body;
};
QueueHandle_t g_mainQueue = nullptr;

// Per-OTA-upload state. AsyncWebServer's body callback fires for each
// chunk; we initialise on the first call (index == 0) and finalise on
// the last (index + len == total). Only one upload at a time, so flat
// globals are fine.
volatile bool g_updateRunning = false;
volatile size_t g_bytesReceived = 0;
size_t g_lastProgressMark = 0;
bool   g_uploadFailed = false;

// Result of the most recent upload attempt. Persisted across requests
// so the settings screen can show "last update: ..." without having
// to subscribe to the bus from boot.
//   0 = none yet, 1 = success, -1 = failure
int g_lastResult = 0;
char g_lastError[MAX_ERROR_LEN] = {0};

// Forward declaration; defined below in the postProgress block.
void postProgress(const char* phase, size_t bytes, const char* error);


void postProgress(const char* phase, size_t bytes, const char* error) {
    std::string phaseStr = phase;
    std::string errorStr = error ? error : "";

    MessageBus::instance().postTable("ota/progress",
        [phaseStr, bytes, errorStr](lua_State* L) {
            lua_newtable(L);
            lua_pushstring(L, phaseStr.c_str());
            lua_setfield(L, -2, "phase");
            lua_pushinteger(L, (lua_Integer)bytes);
            lua_setfield(L, -2, "bytes");
            if (!errorStr.empty()) {
                lua_pushstring(L, errorStr.c_str());
                lua_setfield(L, -2, "error");
            }
        });
}

// Generate a new random token into g_token, no persistence. Used when
// either no token is stored yet or the user explicitly asks for a
// fresh one via ez.ota.regenerate_token().
void generateToken() {
    // Crockford-ish alphabet -- drops vowels and look-alike chars
    // (0/O, 1/I/L) so a token read off the screen is unambiguous.
    static const char alphabet[] = "23456789ABCDEFGHJKMNPQRSTVWXYZ";
    constexpr size_t alphabetLen = sizeof(alphabet) - 1;
    for (size_t i = 0; i < TOKEN_LEN - 1; i++) {
        g_token[i] = alphabet[esp_random() % alphabetLen];
    }
    g_token[TOKEN_LEN - 1] = '\0';
}

// Pull the token out of NVS on first start, generate + persist if it's
// not there yet. Keeping it stable across reboots is what lets the
// user (or a bot) configure it once instead of re-reading the screen
// every power cycle. Caller is responsible for calling this before
// the server starts handing out responses.
void loadOrCreateToken() {
    Preferences prefs;
    if (!prefs.begin("ota", false)) {
        // NVS unavailable -- fall back to a session-only token rather
        // than refusing to start the server at all.
        generateToken();
        return;
    }
    String saved = prefs.getString("token", "");
    if (saved.length() == TOKEN_LEN - 1) {
        strncpy(g_token, saved.c_str(), TOKEN_LEN - 1);
        g_token[TOKEN_LEN - 1] = '\0';
    } else {
        generateToken();
        prefs.putString("token", g_token);
    }
    prefs.end();
}

// Force-rotate the persisted token. Used by the "Regenerate token"
// settings action and by ez.ota.regenerate_token() so a user can
// invalidate a token they leaked.
void rotateAndPersistToken() {
    generateToken();
    Preferences prefs;
    if (prefs.begin("ota", false)) {
        prefs.putString("token", g_token);
        prefs.end();
    }
}

const char* partitionLabelOrNil(const esp_partition_t* part) {
    return part ? part->label : nullptr;
}

// ---------------------------------------------------------------------------
// AsyncWebServer auth + response helpers
// ---------------------------------------------------------------------------

bool checkBearer(AsyncWebServerRequest* req) {
    if (!req->hasHeader("Authorization")) return false;
    const String& auth = req->header("Authorization");
    if (!auth.startsWith("Bearer ")) return false;
    return strcmp(auth.c_str() + 7, g_token) == 0;
}

// Auth check + 401 response on failure. Returns false; caller bails.
bool requireBearer(AsyncWebServerRequest* req) {
    if (checkBearer(req)) return true;
    req->send(401, "application/json",
        "{\"ok\":false,\"error\":\"invalid token\"}");
    return false;
}

// ---------------------------------------------------------------------------
// AsyncWebServer handlers
// ---------------------------------------------------------------------------

void status_handler(AsyncWebServerRequest* req) {
    if (!requireBearer(req)) return;
    char body[160];
    snprintf(body, sizeof(body),
        "{\"running\":true,\"port\":%d,\"in_progress\":%s,\"bytes\":%u}",
        g_port, g_updateRunning ? "true" : "false",
        (unsigned)g_bytesReceived);
    req->send(200, "application/json", body);
}

void info_handler(AsyncWebServerRequest* req) {
    if (!requireBearer(req)) return;
    JsonDocument doc;
    const esp_partition_t* run  = esp_ota_get_running_partition();
    const esp_partition_t* boot = esp_ota_get_boot_partition();
    doc["partition"] = run ? run->label : "?";
    doc["pending_partition"] =
        (boot && run && boot->address != run->address) ? boot->label : (const char*)nullptr;
    doc["sketch_size"] = ESP.getSketchSize();
    doc["free_heap"]   = ESP.getFreeHeap();
    doc["total_heap"]  = ESP.getHeapSize();
    doc["free_psram"]  = ESP.getFreePsram();
    doc["total_psram"] = ESP.getPsramSize();
    doc["uptime_ms"]   = millis();
    doc["chip_model"]  = ESP.getChipModel();
    JsonObject wifi = doc["wifi"].to<JsonObject>();
    wifi["connected"] = WiFi.isConnected();
    wifi["ssid"]      = WiFi.isConnected() ? WiFi.SSID() : "";
    wifi["ip"]        = WiFi.isConnected() ? WiFi.localIP().toString() : "";
    wifi["rssi"]      = WiFi.isConnected() ? WiFi.RSSI() : 0;
    wifi["mac"]       = WiFi.macAddress();
    if (display) {
        JsonObject scr = doc["screen"].to<JsonObject>();
        scr["width"]  = display->getWidth();
        scr["height"] = display->getHeight();
    }
    String body;
    serializeJson(doc, body);
    req->send(200, "application/json", body);
}

void logs_handler(AsyncWebServerRequest* req) {
    if (!requireBearer(req)) return;
    constexpr size_t CAP = 16 * 1024;
    char* buf = (char*)ps_malloc(CAP);
    if (!buf) buf = (char*)malloc(CAP);
    if (!buf) {
        req->send(500, "application/json",
            "{\"ok\":false,\"error\":\"out of memory\"}");
        return;
    }
    size_t n = log_buffer_snapshot(buf, CAP);
    // Hand the buffer to the request via _tempObject; AsyncWebServer
    // free()s it when the request is destroyed, so the chunk filler
    // can safely close over `buf` without us needing to manage its
    // lifetime ourselves.
    req->_tempObject = buf;
    auto* response = req->beginResponse("text/plain; charset=utf-8", n,
        [buf, n](uint8_t* dest, size_t maxLen, size_t index) -> size_t {
            if (index >= n) return 0;
            size_t take = n - index;
            if (take > maxLen) take = maxLen;
            memcpy(dest, buf + index, take);
            return take;
        });
    req->send(response);
}

void screen_handler(AsyncWebServerRequest* req) {
    if (!requireBearer(req)) return;
    if (!display) {
        req->send(503, "application/json",
            "{\"ok\":false,\"error\":\"no display\"}");
        return;
    }
    int w = display->getWidth();
    int h = display->getHeight();
    size_t rowBytes = (size_t)w * 3;
    size_t rowPadded = (rowBytes + 3) & ~3;
    size_t pixelDataSize = rowPadded * (size_t)h;
    size_t fileSize = 54 + pixelDataSize;

    // Build the BMP into a PSRAM buffer (we can't fit 230 KiB in
    // internal DRAM) and let AsyncWebServer pull from it via the
    // chunked filler callback. AsyncTCP keeps reading from `buf` as
    // ACKs come in; _tempObject ownership transfers to the request
    // so the buffer outlives this handler and gets free()d only
    // after the response has fully drained.
    uint8_t* buf = (uint8_t*)ps_malloc(fileSize);
    if (!buf) {
        req->send(500, "application/json",
            "{\"ok\":false,\"error\":\"out of memory\"}");
        return;
    }
    memset(buf, 0, fileSize);

    buf[0] = 'B'; buf[1] = 'M';
    *(uint32_t*)(buf + 2)  = fileSize;
    *(uint32_t*)(buf + 10) = 54;
    *(uint32_t*)(buf + 14) = 40;
    *(int32_t*) (buf + 18) = w;
    *(int32_t*) (buf + 22) = h;
    *(uint16_t*)(buf + 26) = 1;
    *(uint16_t*)(buf + 28) = 24;
    *(uint32_t*)(buf + 34) = pixelDataSize;

    // BMP rows are stored bottom-to-top.
    for (int y = 0; y < h; y++) {
        uint8_t* dst = buf + 54 + (size_t)(h - 1 - y) * rowPadded;
        for (int x = 0; x < w; x++) {
            uint16_t color = display->getBuffer().readPixel(x, y);
            uint8_t r = ((color >> 11) & 0x1F) << 3; r |= r >> 5;
            uint8_t g = ((color >> 5)  & 0x3F) << 2; g |= g >> 6;
            uint8_t b = ( color        & 0x1F) << 3; b |= b >> 5;
            dst[x * 3]     = b;
            dst[x * 3 + 1] = g;
            dst[x * 3 + 2] = r;
        }
    }

    req->_tempObject = buf;
    auto* response = req->beginResponse("image/bmp", fileSize,
        [buf, fileSize](uint8_t* dest, size_t maxLen, size_t index) -> size_t {
            if (index >= fileSize) return 0;
            size_t take = fileSize - index;
            if (take > maxLen) take = maxLen;
            memcpy(dest, buf + index, take);
            return take;
        });
    req->send(response);
}

// /lua: small POST body of Lua source. Body comes in via the chunk
// callback; once we have the full payload we queue a DeferredLua to
// the main loop, block the AsyncTCP handler for up to 10 s, then send
// the result.
//
// Body accumulation lives in a malloc'd char buffer hung off
// _tempObject so the runtime cleans it up on disconnect even if we
// never reach the completion handler (e.g. client hang-up mid-body).
struct LuaBodyBuf {
    size_t cap;
    size_t len;
    char data[];  // flexible array follows
};

void lua_handler_complete(AsyncWebServerRequest* req) {
    if (!requireBearer(req)) return;
    auto* lb = (LuaBodyBuf*)req->_tempObject;
    if (!lb || lb->len == 0) {
        req->send(400, "application/json",
            "{\"ok\":false,\"error\":\"empty body\"}");
        return;
    }
    DeferredLua d;
    d.body = String(lb->data, lb->len);
    d.done = false;
    d.status = 0;
    DeferredLua* p = &d;
    if (!g_mainQueue || xQueueSend(g_mainQueue, &p, 0) != pdTRUE) {
        req->send(503, "application/json",
            "{\"ok\":false,\"error\":\"queue full\"}");
        return;
    }
    // Block on the main thread filling in the response. 10 s ceiling
    // so a wedged main loop can't hold the AsyncTCP task forever.
    uint32_t deadline = millis() + 10000;
    while (!d.done && millis() < deadline) {
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    if (!d.done) {
        req->send(504, "application/json",
            "{\"ok\":false,\"error\":\"main loop timeout\"}");
        return;
    }
    req->send(d.status ? d.status : 500,
        "application/json", d.response_body);
}

void lua_handler_body(AsyncWebServerRequest* req, uint8_t* data,
                      size_t len, size_t index, size_t total) {
    constexpr size_t MAX_LUA = 64 * 1024;
    if (total == 0 || total > MAX_LUA) return;
    auto* lb = (LuaBodyBuf*)req->_tempObject;
    if (index == 0 || !lb) {
        if (lb) { free(lb); req->_tempObject = nullptr; }
        lb = (LuaBodyBuf*)malloc(sizeof(LuaBodyBuf) + total + 1);
        if (!lb) return;
        lb->cap = total;
        lb->len = 0;
        req->_tempObject = lb;
    }
    if (index + len > lb->cap) return;
    memcpy(lb->data + index, data, len);
    if (index + len > lb->len) lb->len = index + len;
    if (lb->len == lb->cap) lb->data[lb->len] = '\0';
}

void key_handler_complete(AsyncWebServerRequest* req) {
    if (!requireBearer(req)) return;
    if (!keyboard) {
        req->send(503, "application/json",
            "{\"ok\":false,\"error\":\"no keyboard\"}");
        return;
    }
    auto* lb = (LuaBodyBuf*)req->_tempObject;
    if (!lb || lb->len == 0) {
        req->send(400, "application/json",
            "{\"ok\":false,\"error\":\"empty body\"}");
        return;
    }
    JsonDocument doc;
    DeserializationError jerr = deserializeJson(doc, lb->data, lb->len);
    if (jerr) {
        req->send(400, "application/json",
            "{\"ok\":false,\"error\":\"bad JSON\"}");
        return;
    }
    bool shift = doc["shift"] | false;
    bool ctrl  = doc["ctrl"]  | false;
    bool alt   = doc["alt"]   | false;
    bool fn    = doc["fn"]    | false;
    if (doc["char"].is<const char*>()) {
        const char* s = doc["char"];
        if (!s || !s[0]) {
            req->send(400, "application/json",
                "{\"ok\":false,\"error\":\"empty char\"}");
            return;
        }
        keyboard->injectEvent(KeyEvent::fromChar(s[0], shift, ctrl, alt, fn));
        req->send(200, "application/json", "{\"ok\":true}");
        return;
    }
    if (doc["special"].is<const char*>()) {
        const char* name = doc["special"];
        SpecialKey key = SpecialKey::NONE;
        if      (!strcasecmp(name, "up"))        key = SpecialKey::UP;
        else if (!strcasecmp(name, "down"))      key = SpecialKey::DOWN;
        else if (!strcasecmp(name, "left"))      key = SpecialKey::LEFT;
        else if (!strcasecmp(name, "right"))     key = SpecialKey::RIGHT;
        else if (!strcasecmp(name, "enter"))     key = SpecialKey::ENTER;
        else if (!strcasecmp(name, "escape"))    key = SpecialKey::ESCAPE;
        else if (!strcasecmp(name, "tab"))       key = SpecialKey::TAB;
        else if (!strcasecmp(name, "backspace")) key = SpecialKey::BACKSPACE;
        else if (!strcasecmp(name, "delete"))    key = SpecialKey::DELETE;
        else if (!strcasecmp(name, "home"))      key = SpecialKey::HOME;
        else if (!strcasecmp(name, "end"))       key = SpecialKey::END;
        else {
            req->send(400, "application/json",
                "{\"ok\":false,\"error\":\"unknown special key\"}");
            return;
        }
        keyboard->injectEvent(KeyEvent::fromSpecial(key, shift, ctrl, alt, fn));
        req->send(200, "application/json", "{\"ok\":true}");
        return;
    }
    req->send(400, "application/json",
        "{\"ok\":false,\"error\":\"need 'char' or 'special'\"}");
}

void key_handler_body(AsyncWebServerRequest* req, uint8_t* data,
                      size_t len, size_t index, size_t total) {
    constexpr size_t MAX_KEY = 1024;
    if (total == 0 || total > MAX_KEY) return;
    auto* lb = (LuaBodyBuf*)req->_tempObject;
    if (index == 0 || !lb) {
        if (lb) { free(lb); req->_tempObject = nullptr; }
        lb = (LuaBodyBuf*)malloc(sizeof(LuaBodyBuf) + total + 1);
        if (!lb) return;
        lb->cap = total;
        lb->len = 0;
        req->_tempObject = lb;
    }
    if (index + len > lb->cap) return;
    memcpy(lb->data + index, data, len);
    if (index + len > lb->len) lb->len = index + len;
    if (lb->len == lb->cap) lb->data[lb->len] = '\0';
}

void chat_event_handler_complete(AsyncWebServerRequest* req) {
    if (!requireBearer(req)) return;
    auto* lb = (LuaBodyBuf*)req->_tempObject;
    if (!lb || lb->len == 0) {
        req->send(400, "application/json",
            "{\"ok\":false,\"error\":\"empty body\"}");
        return;
    }
    // MessageBus::post takes a NUL-terminated string; the body buffer
    // is sized to leave room for one and we wrote the terminator on
    // completion, so this is safe to pass through.
    MessageBus::instance().post("claude/event", lb->data);
    req->send(200, "application/json", "{\"ok\":true}");
}

void chat_event_handler_body(AsyncWebServerRequest* req, uint8_t* data,
                             size_t len, size_t index, size_t total) {
    constexpr size_t MAX_EVENT = 8 * 1024;
    if (total == 0 || total > MAX_EVENT) return;
    auto* lb = (LuaBodyBuf*)req->_tempObject;
    if (index == 0 || !lb) {
        if (lb) { free(lb); req->_tempObject = nullptr; }
        lb = (LuaBodyBuf*)malloc(sizeof(LuaBodyBuf) + total + 1);
        if (!lb) return;
        lb->cap = total;
        lb->len = 0;
        req->_tempObject = lb;
    }
    if (index + len > lb->cap) return;
    memcpy(lb->data + index, data, len);
    if (index + len > lb->len) lb->len = index + len;
    if (lb->len == lb->cap) lb->data[lb->len] = '\0';
}

void ota_handler_complete(AsyncWebServerRequest* req) {
    // Auth was already checked on the first body chunk -- a wrong
    // token there would have set g_uploadFailed and we'd be here just
    // to send the error. If the request had no body at all (no body
    // callback fired), Update never started, so report that case.
    if (!checkBearer(req)) {
        req->send(401, "application/json",
            "{\"ok\":false,\"error\":\"invalid token\"}");
        return;
    }
    if (!g_updateRunning && !g_uploadFailed && g_bytesReceived == 0) {
        req->send(400, "application/json",
            "{\"ok\":false,\"error\":\"empty body\"}");
        return;
    }
    if (g_uploadFailed) {
        char err_body[MAX_ERROR_LEN + 64];
        snprintf(err_body, sizeof(err_body),
            "{\"ok\":false,\"error\":\"%s\",\"bytes\":%u}",
            g_lastError, (unsigned)g_bytesReceived);
        req->send(500, "application/json", err_body);
        return;
    }
    // Last body chunk should already have called Update.end(); if not,
    // it means the body never reached `total`, which AsyncWebServer
    // won't call us back for. Treat as truncated upload.
    if (g_updateRunning) {
        Update.abort();
        g_updateRunning = false;
        g_lastResult = -1;
        snprintf(g_lastError, MAX_ERROR_LEN, "truncated upload at %u bytes",
            (unsigned)g_bytesReceived);
        postProgress("error", g_bytesReceived, g_lastError);
        char err_body[MAX_ERROR_LEN + 64];
        snprintf(err_body, sizeof(err_body),
            "{\"ok\":false,\"error\":\"%s\",\"bytes\":%u}",
            g_lastError, (unsigned)g_bytesReceived);
        req->send(500, "application/json", err_body);
        return;
    }
    char ok_body[64];
    snprintf(ok_body, sizeof(ok_body),
        "{\"ok\":true,\"bytes\":%u}", (unsigned)g_bytesReceived);
    req->send(200, "application/json", ok_body);
}

void ota_handler_body(AsyncWebServerRequest* req, uint8_t* data,
                      size_t len, size_t index, size_t total) {
    if (index == 0) {
        // First chunk: auth + Update.begin. Auth failures here are
        // surfaced via the completion handler -- we just refuse to
        // start the Update so subsequent chunks fall through.
        g_uploadFailed = false;
        g_updateRunning = false;
        g_bytesReceived = 0;
        g_lastProgressMark = 0;
        g_lastError[0] = '\0';

        if (!checkBearer(req)) {
            g_uploadFailed = true;
            snprintf(g_lastError, MAX_ERROR_LEN, "invalid token");
            return;
        }
        if (total == 0 || total > 0x00800000) {
            g_uploadFailed = true;
            snprintf(g_lastError, MAX_ERROR_LEN,
                "bad Content-Length: %u", (unsigned)total);
            return;
        }

        // Prefer the host-supplied X-Firmware-Size hint when present:
        // it lets the device erase only the sectors it'll actually
        // write instead of the whole partition, saving ~5 s of
        // flash-controller monopolisation that would otherwise kill
        // the WiFi link mid-upload.
        size_t firmware_size = total;
        if (req->hasHeader("X-Firmware-Size")) {
            long v = strtol(req->header("X-Firmware-Size").c_str(),
                            nullptr, 10);
            if (v > 0 && v < 0x00800000) firmware_size = (size_t)v;
        }
        LOG("OTA", "begin size=%u (content_len=%u, internal_free=%u)",
            (unsigned)firmware_size, (unsigned)total,
            (unsigned)ESP.getFreeHeap());

        if (!Update.begin(firmware_size, U_FLASH)) {
            g_uploadFailed = true;
            snprintf(g_lastError, MAX_ERROR_LEN,
                "Update.begin failed: %s", Update.errorString());
            g_lastResult = -1;
            postProgress("error", 0, g_lastError);
            return;
        }
        g_updateRunning = true;
    }
    if (g_uploadFailed || !g_updateRunning) return;

    size_t written = Update.write(data, len);
    if (written != len) {
        snprintf(g_lastError, MAX_ERROR_LEN,
            "Update.write short (%u/%u): %s",
            (unsigned)written, (unsigned)len, Update.errorString());
        Update.abort();
        g_uploadFailed = true;
        g_updateRunning = false;
        g_lastResult = -1;
        postProgress("error", g_bytesReceived, g_lastError);
        return;
    }
    g_bytesReceived += written;
    if (g_bytesReceived - g_lastProgressMark >= PROGRESS_INTERVAL) {
        g_lastProgressMark = g_bytesReceived;
        postProgress("write", g_bytesReceived, nullptr);
        LOG("OTA", "wrote %u KiB", (unsigned)(g_bytesReceived / 1024));
    }
    if (index + len == total) {
        // Final chunk: close the Update. Update.end() runs the image
        // hash check and switches the boot partition; it can take a
        // second or two but this is still the AsyncTCP task so we
        // can't afford to vTaskDelay around it.
        if (Update.end(true)) {
            g_lastResult = 1;
            snprintf(g_lastError, MAX_ERROR_LEN, "ok %u bytes",
                (unsigned)g_bytesReceived);
            LOG("OTA", "upload complete: %u bytes",
                (unsigned)g_bytesReceived);
            postProgress("end", g_bytesReceived, nullptr);
        } else {
            g_uploadFailed = true;
            g_lastResult = -1;
            snprintf(g_lastError, MAX_ERROR_LEN,
                "Update.end failed: %s", Update.errorString());
            postProgress("error", g_bytesReceived, g_lastError);
        }
        g_updateRunning = false;
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// Lua bindings
// ---------------------------------------------------------------------------

// @lua ez.ota.dev_server_start(port?) -> table
// @brief Start the dev OTA push server
// @description
// Starts an HTTP server (default port 8080) exposing POST /ota for
// firmware push uploads. Generates a fresh 6-character bearer token
// each call — without it, requests are rejected with 401. Returns a
// table with the running configuration so the UI can show how to
// reach the device.
// @param port  Optional TCP port (default 8080)
// @return Table with fields:
//   - ok: boolean
//   - port: integer
//   - token: string (display this — the host pusher needs it)
//   - ip: string Current WiFi IP, or "" if not connected
// @example
// local s = ez.ota.dev_server_start()
// print("curl --data-binary @firmware.bin -H 'Authorization: Bearer "
//       .. s.token .. "' http://" .. s.ip .. ":" .. s.port .. "/ota")
// @end
LUA_FUNCTION(l_ota_dev_server_start) {
    int port = (int)luaL_optinteger(L, 1, DEFAULT_PORT);

    if (g_server) {
        g_server->end();
        delete g_server;
        g_server = nullptr;
    }
    if (!g_mainQueue) {
        g_mainQueue = xQueueCreate(4, sizeof(DeferredLua*));
    }

    g_port = port;
    loadOrCreateToken();

    g_server = new AsyncWebServer(g_port);
    // The mathieucarbou fork retains every request header by default
    // (collectHeaders() is deprecated), so Authorization and
    // X-Firmware-Size are available without any extra setup.

    g_server->on("/",           HTTP_GET,  status_handler);
    g_server->on("/info",       HTTP_GET,  info_handler);
    g_server->on("/logs",       HTTP_GET,  logs_handler);
    g_server->on("/screen.bmp", HTTP_GET,  screen_handler);
    g_server->on("/lua",        HTTP_POST, lua_handler_complete,
                 nullptr, lua_handler_body);
    g_server->on("/key",        HTTP_POST, key_handler_complete,
                 nullptr, key_handler_body);
    g_server->on("/chat_event", HTTP_POST, chat_event_handler_complete,
                 nullptr, chat_event_handler_body);
    g_server->on("/ota",        HTTP_POST, ota_handler_complete,
                 nullptr, ota_handler_body);

    g_server->begin();
    LOG("OTA", "dev server started on port %d, token=%s", g_port, g_token);

    lua_newtable(L);
    lua_pushboolean(L, true);
    lua_setfield(L, -2, "ok");
    lua_pushinteger(L, g_port);
    lua_setfield(L, -2, "port");
    lua_pushstring(L, g_token);
    lua_setfield(L, -2, "token");
    String ip = WiFi.isConnected() ? WiFi.localIP().toString() : String("");
    lua_pushstring(L, ip.c_str());
    lua_setfield(L, -2, "ip");
    return 1;
}

LUA_FUNCTION(l_ota_get_token) {
    if (g_token[0] == '\0') {
        loadOrCreateToken();
    }
    lua_pushstring(L, g_token);
    return 1;
}

// @lua ez.ota.regenerate_token() -> string
// @brief Rotate the persisted dev OTA bearer token
// @description
// Generates a new 6-character token and stores it to NVS, replacing
// the old one. Any previously-issued token is invalidated immediately.
// Useful after sharing the token (e.g. with a mesh bot) and wanting
// to revoke access. The running server (if any) picks up the new
// token without restart.
// @return The newly-generated token
// @end
LUA_FUNCTION(l_ota_regenerate_token) {
    rotateAndPersistToken();
    lua_pushstring(L, g_token);
    return 1;
}

// @lua ez.ota.dev_server_stop() -> nil
// @brief Stop the dev OTA server
// @description
// Tears down the HTTP listener. If an upload is in progress it is
// aborted via Update.abort(), so the inactive partition is left in
// whatever erased state it was in — no risk to the running image.
// @end
LUA_FUNCTION(l_ota_dev_server_stop) {
    if (g_updateRunning) {
        Update.abort();
        g_updateRunning = false;
        g_lastResult = -1;
        strncpy(g_lastError, "server stopped mid-upload", MAX_ERROR_LEN - 1);
    }
    if (g_server) {
        g_server->end();
        delete g_server;
        g_server = nullptr;
        LOG("OTA", "dev server stopped");
    }
    g_token[0] = '\0';
    return 0;
}

// @lua ez.ota.dev_server_status() -> table
// @brief Inspect the dev OTA server state
// @return Table with fields:
//   - running: boolean
//   - port: integer Current port (0 when not running)
//   - token: string Current bearer token, or "" when not running
//   - ip: string Current WiFi IP, or "" if not connected
//   - in_progress: boolean True while a chunked upload is being received
//   - bytes_received: integer Bytes written for the current/last upload
//   - last_result: integer 0 = none, 1 = success, -1 = failure
//   - last_error: string Last status string (e.g. "ok 1500000 bytes")
// @end
LUA_FUNCTION(l_ota_dev_server_status) {
    lua_newtable(L);
    lua_pushboolean(L, g_server != nullptr);
    lua_setfield(L, -2, "running");
    lua_pushinteger(L, g_server ? g_port : 0);
    lua_setfield(L, -2, "port");
    lua_pushstring(L, g_server ? g_token : "");
    lua_setfield(L, -2, "token");
    String ip = WiFi.isConnected() ? WiFi.localIP().toString() : String("");
    lua_pushstring(L, ip.c_str());
    lua_setfield(L, -2, "ip");
    lua_pushboolean(L, g_updateRunning);
    lua_setfield(L, -2, "in_progress");
    lua_pushinteger(L, (lua_Integer)g_bytesReceived);
    lua_setfield(L, -2, "bytes_received");
    lua_pushinteger(L, g_lastResult);
    lua_setfield(L, -2, "last_result");
    lua_pushstring(L, g_lastError);
    lua_setfield(L, -2, "last_error");
    return 1;
}

// @lua ez.ota.running_partition() -> string
// @brief Label of the partition the device booted from
// @return "app0" or "app1"
// @end
LUA_FUNCTION(l_ota_running_partition) {
    const char* label = partitionLabelOrNil(esp_ota_get_running_partition());
    if (label) lua_pushstring(L, label);
    else lua_pushnil(L);
    return 1;
}

// @lua ez.ota.pending_partition() -> string|nil
// @brief Label of a staged update awaiting reboot, or nil
// @description
// Returns the label of an OTA image that has been written successfully
// and will be booted on the next restart. Returns nil if no update is
// pending. Useful for showing a "reboot to apply" indicator.
// @return Partition label string, or nil
// @end
LUA_FUNCTION(l_ota_pending_partition) {
    const esp_partition_t* boot = esp_ota_get_boot_partition();
    const esp_partition_t* run  = esp_ota_get_running_partition();
    if (boot && run && boot->address != run->address) {
        lua_pushstring(L, boot->label);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

// @lua ez.ota.mark_valid() -> boolean
// @brief Confirm the running image is healthy (cancels auto-rollback)
// @description
// After a successful OTA, the new image boots in the "pending verify"
// state. If the bootloader sees too many crash-reboot cycles before
// the app calls this, it auto-reverts to the previous slot. boot.lua
// should call this once the UI has come up and looks sane.
//
// Calling this on an image that's already marked valid is a no-op.
// @return true on success, false if the partition manager rejected the call
// @end
LUA_FUNCTION(l_ota_mark_valid) {
    esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
    if (err == ESP_OK) {
        LOG("OTA", "running image marked valid");
        lua_pushboolean(L, true);
    } else {
        LOG("OTA", "mark_valid failed: %d", (int)err);
        lua_pushboolean(L, false);
    }
    return 1;
}

// @lua ez.ota.rollback_and_reboot() -> boolean
// @brief Mark current image bad and reboot into the previous slot
// @description
// Forces a rollback regardless of crash-counter state. Reboots the
// device immediately on success — this function does not return when
// it works. Returns false only if the rollback request was rejected
// (e.g. there's no other valid image to fall back to).
// @end
LUA_FUNCTION(l_ota_rollback_and_reboot) {
    esp_err_t err = esp_ota_mark_app_invalid_rollback_and_reboot();
    // Only returns on failure (e.g. no other slot is bootable).
    LOG("OTA", "rollback failed: %d", (int)err);
    lua_pushboolean(L, false);
    return 1;
}

// ---------------------------------------------------------------------------
// Pull-mode OTA: download a signed firmware image over HTTPS, verify its
// SHA-256 against the manifest's expected hash, write it to flash, and
// stage it for the next reboot.
//
// Authenticity is enforced by the *caller*: the firmware-update screen
// fetches manifest.json + manifest.sig from the rolling-{main,test}
// release, verifies the Ed25519 signature against the embedded
// kOtaSigningPubkey via ez.crypto.ed25519_verify, and only then passes
// the manifest's full_bin_url + full_sha256 down to apply_full_url. We
// re-check the hash while streaming so a swapped-out asset still gets
// rejected even though we drop full TLS cert validation (setInsecure --
// cert pinning would double the flash budget for no extra security on
// top of the signature).
//
// Runs the download on a one-shot FreeRTOS task pinned to Core 0 so the
// UI loop on Core 1 stays responsive. Progress is reported through the
// ota/progress bus topic; a final phase of "end" or "error" closes the
// run. Refuses to start a second download while one is in flight.
// ---------------------------------------------------------------------------

namespace {

struct PullParams {
    String url;
    uint8_t expectedSha[32];
    bool hasExpectedSha = false;
};

volatile bool g_pullRunning = false;

bool parseHexSha(const char* hex, size_t len, uint8_t out[32]) {
    if (len != 64) return false;
    for (size_t i = 0; i < 32; ++i) {
        char c1 = hex[i * 2];
        char c2 = hex[i * 2 + 1];
        auto nibble = [](char c, uint8_t& v) {
            if (c >= '0' && c <= '9') { v = c - '0'; return true; }
            if (c >= 'a' && c <= 'f') { v = 10 + c - 'a'; return true; }
            if (c >= 'A' && c <= 'F') { v = 10 + c - 'A'; return true; }
            return false;
        };
        uint8_t hi = 0, lo = 0;
        if (!nibble(c1, hi) || !nibble(c2, lo)) return false;
        out[i] = (hi << 4) | lo;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Full-image OTA: streams firmware-full.bin (bootloader + partition table +
// app) and writes each segment to the correct flash region.
// ---------------------------------------------------------------------------

struct FullOtaState {
    // Stream position
    size_t stream_offset = 0;
    size_t total_size    = 0;

    // Bootloader buffer (PSRAM, max 32 KB)
    uint8_t* bl_buf = nullptr;
    size_t   bl_len = 0;

    // Partition table buffer (PSRAM, max 4 KB)
    uint8_t* pt_buf = nullptr;
    size_t   pt_len = 0;

    // OTA handle for app region
    esp_ota_handle_t ota_handle = 0;
    const esp_partition_t* ota_partition = nullptr;
    bool ota_began = false;

    // SHA-256 over the full stream
    mbedtls_sha256_context sha;
    bool sha_inited = false;

    // App bytes tracking
    size_t app_written = 0;
    size_t app_expected = 0;

    // Progress
    size_t last_report = 0;
    char error[80] = {0};
};

// Region boundaries in the merged binary
static constexpr size_t FULL_BL_END  = 0x8000;  // bootloader region end
static constexpr size_t FULL_PT_END  = 0x9000;  // partition table end (one 4 KB sector)
static constexpr size_t FULL_APP_OFF = 0x10000;  // app image start

static bool fullOnHeaders(void* user, int status, long content_length,
                          const http_client::HeaderPair*, size_t) {
    FullOtaState* s = (FullOtaState*)user;
    if (status != 200) {
        snprintf(s->error, sizeof(s->error), "HTTP %d", status);
        return false;
    }
    if (content_length <= (long)FULL_APP_OFF) {
        snprintf(s->error, sizeof(s->error), "too small for full image");
        return false;
    }
    s->total_size = (size_t)content_length;
    size_t app_size = content_length - FULL_APP_OFF;
    s->app_expected = app_size;

    LOG("OTA", "full image: %u bytes, app=%u", (unsigned)s->total_size, (unsigned)app_size);

    // Erase the target OTA partition upfront so we can write directly
    // via esp_partition_write. We bypass esp_ota_begin/write/end
    // because esp_ota_end's image validator rejects some valid images
    // (ESP_ERR_OTA_VALIDATE_FAILED) even when the binary is SHA-256
    // verified. Our own SHA-256 check + direct partition write +
    // esp_ota_set_boot_partition is sufficient.
    esp_err_t err = esp_partition_erase_range(s->ota_partition, 0, s->ota_partition->size);
    if (err != ESP_OK) {
        snprintf(s->error, sizeof(s->error), "partition erase: %s", esp_err_to_name(err));
        return false;
    }

    mbedtls_sha256_init(&s->sha);
    mbedtls_sha256_starts(&s->sha, 0);
    s->sha_inited = true;

    postProgress("start", 0, nullptr);
    return true;
}

static bool fullOnChunk(void* user, const uint8_t* chunk, size_t n) {
    FullOtaState* s = (FullOtaState*)user;

    mbedtls_sha256_update(&s->sha, chunk, n);

    size_t pos = 0;
    while (pos < n) {
        size_t abs_off = s->stream_offset;
        size_t remaining = n - pos;

        if (abs_off < FULL_BL_END) {
            // Bootloader region — buffer in PSRAM
            size_t take = std::min(remaining, FULL_BL_END - abs_off);
            memcpy(s->bl_buf + abs_off, chunk + pos, take);
            if (abs_off + take > s->bl_len) s->bl_len = abs_off + take;
            pos += take;
            s->stream_offset += take;
        } else if (abs_off < FULL_PT_END) {
            // Partition table — buffer in PSRAM
            size_t pt_off = abs_off - FULL_BL_END;
            size_t take = std::min(remaining, FULL_PT_END - abs_off);
            memcpy(s->pt_buf + pt_off, chunk + pos, take);
            if (pt_off + take > s->pt_len) s->pt_len = pt_off + take;
            pos += take;
            s->stream_offset += take;
        } else if (abs_off < FULL_APP_OFF) {
            // Gap between partition table and app — skip
            size_t take = std::min(remaining, FULL_APP_OFF - abs_off);
            pos += take;
            s->stream_offset += take;
        } else {
            // App region — write directly to OTA partition
            size_t part_offset = abs_off - FULL_APP_OFF;
            esp_err_t err = esp_partition_write(s->ota_partition, part_offset,
                                                chunk + pos, remaining);
            if (err != ESP_OK) {
                snprintf(s->error, sizeof(s->error), "partition write: %s",
                         esp_err_to_name(err));
                return false;
            }
            s->app_written += remaining;
            pos += remaining;
            s->stream_offset += remaining;
        }
    }

    if (s->stream_offset - s->last_report >= PROGRESS_INTERVAL) {
        postProgress("write", s->stream_offset, nullptr);
        log_panic_flush("ota_full_progress");
        s->last_report = s->stream_offset;
    }
    return true;
}

// Write a flash region only if it differs from what's already there.
// Returns ESP_OK on success (or skip), or the error code on failure.
static esp_err_t writeIfChanged(size_t flash_addr, const uint8_t* data,
                                size_t len, const char* label) {
    // Read current content
    uint8_t* current = (uint8_t*)heap_caps_malloc(len, MALLOC_CAP_SPIRAM);
    if (!current) return ESP_ERR_NO_MEM;

    esp_err_t err = spi_flash_read(flash_addr, current, len);
    if (err != ESP_OK) { free(current); return err; }

    if (memcmp(current, data, len) == 0) {
        LOG("OTA", "%s unchanged, skipping write", label);
        free(current);
        return ESP_OK;
    }
    free(current);

    LOG("OTA", "%s changed, writing %u bytes at 0x%x", label, (unsigned)len,
        (unsigned)flash_addr);

    size_t erase_size = (len + 0xFFF) & ~0xFFF;  // round up to 4 KB
    err = spi_flash_erase_range(flash_addr, erase_size);
    if (err != ESP_OK) return err;

    err = spi_flash_write(flash_addr, data, len);
    if (err != ESP_OK) return err;

    // Read-back verify
    uint8_t* verify = (uint8_t*)heap_caps_malloc(len, MALLOC_CAP_SPIRAM);
    if (!verify) return ESP_ERR_NO_MEM;
    spi_flash_read(flash_addr, verify, len);
    bool ok = memcmp(verify, data, len) == 0;
    free(verify);

    return ok ? ESP_OK : ESP_ERR_INVALID_CRC;
}

void pullFullTask(void* arg) {
    PullParams* p = (PullParams*)arg;
    FullOtaState state;

    vTaskDelay(pdMS_TO_TICKS(50));
    esp_err_t wdt_rc = esp_task_wdt_init(60, true);
    LOG("OTA", "pullFullTask entered, wdt_init(60)=%d", (int)wdt_rc);

    // Allocate PSRAM buffers
    state.bl_buf = (uint8_t*)heap_caps_calloc(1, FULL_BL_END, MALLOC_CAP_SPIRAM);
    state.pt_buf = (uint8_t*)heap_caps_calloc(1, 0x1000, MALLOC_CAP_SPIRAM);
    if (!state.bl_buf || !state.pt_buf) {
        LOG("OTA", "PSRAM alloc failed");
        g_lastResult = -1;
        strncpy(g_lastError, "PSRAM alloc failed", MAX_ERROR_LEN);
        postProgress("error", 0, "PSRAM alloc failed");
        g_pullRunning = false;
        esp_task_wdt_init(5, true);
        if (state.bl_buf) free(state.bl_buf);
        if (state.pt_buf) free(state.pt_buf);
        delete p;
        vTaskDelete(nullptr);
        return;
    }
    // Fill with 0xFF (erased flash default) so gaps in the bootloader
    // region don't write stale zeros to flash.
    memset(state.bl_buf, 0xFF, FULL_BL_END);
    memset(state.pt_buf, 0xFF, 0x1000);

    state.ota_partition = esp_ota_get_next_update_partition(nullptr);
    if (!state.ota_partition) {
        postProgress("error", 0, "no OTA partition");
        g_pullRunning = false;
        esp_task_wdt_init(5, true);
        free(state.bl_buf); free(state.pt_buf);
        delete p;
        vTaskDelete(nullptr);
        return;
    }

    auto fail = [&](const char* msg) {
        LOG("OTA", "full pull failed: %s", msg);
        if (state.sha_inited) mbedtls_sha256_free(&state.sha);
        g_lastResult = -1;
        strncpy(g_lastError, msg, MAX_ERROR_LEN - 1);
        g_lastError[MAX_ERROR_LEN - 1] = '\0';
        postProgress("error", 0, msg);
        g_pullRunning = false;
        esp_task_wdt_init(5, true);
        free(state.bl_buf); free(state.pt_buf);
        delete p;
        vTaskDelete(nullptr);
    };

    if (!WiFi.isConnected()) { fail("WiFi not connected"); return; }

    // Stream the download
    const char* hkeys[] = { "User-Agent" };
    const char* hvals[] = { "ezos-ota" };
    http_client::Request req;
    req.url           = p->url.c_str();
    req.method        = http_client::METHOD_GET;
    req.header_keys   = hkeys;
    req.header_vals   = hvals;
    req.header_count  = 1;
    req.timeout_ms    = 120000;  // full image is larger
    req.max_redirects = http_client::MAX_REDIRECTS;

    http_client::Response resp;
    http_client::fetch_streaming(req, fullOnHeaders, fullOnChunk,
                                 &state, resp);

    if (!resp.ok) {
        const char* msg = state.error[0] ? state.error
                          : (resp.error[0] ? resp.error : "fetch failed");
        http_client::response_free(resp);
        fail(msg);
        return;
    }
    http_client::response_free(resp);

    if (state.stream_offset != state.total_size) {
        fail("short read");
        return;
    }

    // Verify SHA-256
    uint8_t digest[32];
    mbedtls_sha256_finish(&state.sha, digest);
    mbedtls_sha256_free(&state.sha);
    state.sha_inited = false;

    if (p->hasExpectedSha && memcmp(digest, p->expectedSha, 32) != 0) {
        fail("sha256 mismatch");
        return;
    }

    // We wrote the app directly via esp_partition_write (not the OTA
    // API), so there's no ota_handle to close. Our SHA-256 verification
    // above guarantees the bytes on flash match the signed manifest.
    esp_err_t err;

    // 2. Write partition table (only if changed)
    if (state.pt_len > 0) {
        err = writeIfChanged(FULL_BL_END, state.pt_buf, state.pt_len, "partition table");
        if (err != ESP_OK) {
            char msg[80];
            snprintf(msg, sizeof(msg), "partition table write: %s", esp_err_to_name(err));
            fail(msg);
            return;
        }
    }

    // 3. Write bootloader LAST (only if changed — minimizes brick risk)
    if (state.bl_len > 0) {
        err = writeIfChanged(0, state.bl_buf, state.bl_len, "bootloader");
        if (err != ESP_OK) {
            char msg[80];
            snprintf(msg, sizeof(msg), "bootloader write: %s", esp_err_to_name(err));
            fail(msg);
            return;
        }
    }

    // 4. Switch the boot slot. esp_ota_set_boot_partition validates the
    //    image with esp_image_verify and rejects valid binaries with
    //    ESP_ERR_OTA_VALIDATE_FAILED on this IDF/Arduino combo, so we
    //    write otadata ourselves. Our SHA-256 against the signed
    //    manifest is already a stronger guarantee than the IDF check.
    //
    // otadata partition layout: two 4 KiB sectors, one per OTA slot.
    // Sector 0 holds the slot-0 (ota_0/app0) selector at offset 0,
    // sector 1 holds the slot-1 selector at offset 0x1000. Each
    // selector is an esp_ota_select_entry_t (32 bytes):
    //   [seq:4 LE][label:20][state:4][crc32:4]
    // The bootloader picks the slot with the higher seq whose CRC
    // validates. We only need seq + crc; the rest stays 0xFF (= "no
    // info" in IDF terms) and the bootloader treats that as a normal
    // valid app. seq=0xFFFFFFFF in flash means "blank, ignore".
    constexpr size_t OTADATA_SECTOR = 0x1000;
    const esp_partition_t* otadata_part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_OTA, NULL);
    if (!otadata_part) { fail("otadata partition not found"); return; }

    int slot = -1;
    if (strcmp(state.ota_partition->label, "app0") == 0) slot = 0;
    else if (strcmp(state.ota_partition->label, "app1") == 0) slot = 1;
    if (slot < 0) { fail("unknown OTA partition label"); return; }

    auto read_seq = [&](size_t off) -> uint32_t {
        uint8_t b[4] = {0};
        esp_partition_read(otadata_part, off, b, 4);
        return (uint32_t)b[0] | ((uint32_t)b[1] << 8)
             | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    };
    uint32_t seq0 = read_seq(0);
    uint32_t seq1 = read_seq(OTADATA_SECTOR);
    auto active = [](uint32_t s) { return s == 0xFFFFFFFF ? 0u : s; };
    uint32_t max_seq = std::max(active(seq0), active(seq1));
    uint32_t new_seq = max_seq + 1;
    // The IDF bootloader picks the boot app via `(ota_seq - 1) % ota_app_count`
    // -- not by which physical otadata sector holds the entry. On a freshly
    // flashed device both sectors are blank (0xFFFFFFFF -> treated as 0),
    // so `new_seq = 1` always selects app0; if the OTA target was app1,
    // the post-write `esp_ota_get_boot_partition` check below trips with
    // "boot partition did not switch". Nudge the sequence by one so its
    // parity matches the target slot before writing.
    if (((new_seq - 1) % 2u) != (uint32_t)slot) new_seq += 1;

    uint8_t entry[32];
    memset(entry, 0xFF, sizeof(entry));
    entry[0] = new_seq & 0xFF;
    entry[1] = (new_seq >> 8) & 0xFF;
    entry[2] = (new_seq >> 16) & 0xFF;
    entry[3] = (new_seq >> 24) & 0xFF;

    // CRC over ota_seq only (4 bytes). bootloader_common_ota_select_crc
    // calls `crc32_le(UINT32_MAX, &ota_seq, 4)` -- ESP-IDF / zlib
    // semantics: pre-invert init, process with standard reflected
    // polynomial, post-invert. For init=0xFFFFFFFF that means
    // start at 0, post-XOR with 0xFFFFFFFF.
    // (Verified empirically: seq=1 -> 0x4743989a matches the
    //  boot_app0.bin entry on flash.)
    uint32_t crc = 0;
    for (int i = 0; i < 4; i++) {
        crc ^= entry[i];
        for (int b = 0; b < 8; b++)
            crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
    crc ^= 0xFFFFFFFF;
    entry[28] = crc & 0xFF;
    entry[29] = (crc >> 8) & 0xFF;
    entry[30] = (crc >> 16) & 0xFF;
    entry[31] = (crc >> 24) & 0xFF;

    size_t sector_off = (size_t)slot * OTADATA_SECTOR;
    esp_err_t er = esp_partition_erase_range(otadata_part, sector_off, OTADATA_SECTOR);
    if (er != ESP_OK) {
        char msg[80];
        snprintf(msg, sizeof(msg), "otadata erase: %s", esp_err_to_name(er));
        fail(msg); return;
    }
    er = esp_partition_write(otadata_part, sector_off, entry, sizeof(entry));
    if (er != ESP_OK) {
        char msg[80];
        snprintf(msg, sizeof(msg), "otadata write: %s", esp_err_to_name(er));
        fail(msg); return;
    }
    LOG("OTA", "otadata written: slot=%d seq=%u", slot, (unsigned)new_seq);

    // Confirm the IDF agrees the boot slot moved. If
    // esp_ota_get_boot_partition still points at the running slot we
    // just lied to the user about activation -- bail loudly so the
    // UI shows "Update failed" instead of "Reboot to apply".
    const esp_partition_t* boot_now = esp_ota_get_boot_partition();
    if (!boot_now || boot_now->address != state.ota_partition->address) {
        fail("boot partition did not switch after otadata write");
        return;
    }

    LOG("OTA", "full OTA complete (%u bytes)", (unsigned)state.stream_offset);
    g_lastResult = 1;
    snprintf(g_lastError, MAX_ERROR_LEN, "%u bytes downloaded",
             (unsigned)state.stream_offset);
    postProgress("end", state.stream_offset, nullptr);
    g_pullRunning = false;
    esp_task_wdt_init(5, true);
    free(state.bl_buf);
    free(state.pt_buf);
    delete p;
    vTaskDelete(nullptr);
}

}  // anonymous

// @lua ez.ota.apply_full_url(url, expected_sha256_hex?) -> table
// @brief Download a full firmware image (bootloader + partitions + app) and apply it
// @description
// Like apply_url but streams firmware-full.bin which includes the bootloader
// and partition table alongside the app image. The bootloader and partition
// table are buffered in PSRAM and written to flash only after the app has
// been validated. This ensures the device can always receive OTA updates
// even when the bootloader changes between versions. Only writes flash
// regions that actually differ to minimize brick risk and flash wear.
// @param url  HTTPS URL to the firmware-full.bin
// @param expected_sha256_hex  Optional 64-char hex SHA-256 the download must match
// @return Table { ok = boolean, error?: string }
// @end
LUA_FUNCTION(l_ota_apply_full_url) {
    if (!ota_signing_configured()) {
        lua_newtable(L);
        lua_pushboolean(L, false); lua_setfield(L, -2, "ok");
        lua_pushstring(L, "signing not configured");
        lua_setfield(L, -2, "error");
        return 1;
    }
    if (g_pullRunning || g_updateRunning) {
        lua_newtable(L);
        lua_pushboolean(L, false); lua_setfield(L, -2, "ok");
        lua_pushstring(L, "busy"); lua_setfield(L, -2, "error");
        return 1;
    }
    if (!WiFi.isConnected()) {
        lua_newtable(L);
        lua_pushboolean(L, false); lua_setfield(L, -2, "ok");
        lua_pushstring(L, "WiFi not connected"); lua_setfield(L, -2, "error");
        return 1;
    }

    esp_ota_mark_app_valid_cancel_rollback();

    const char* url = luaL_checkstring(L, 1);
    PullParams* p = new PullParams();
    p->url = url;

    if (lua_gettop(L) >= 2 && !lua_isnil(L, 2)) {
        size_t hexLen = 0;
        const char* hex = luaL_checklstring(L, 2, &hexLen);
        if (!parseHexSha(hex, hexLen, p->expectedSha)) {
            delete p;
            lua_newtable(L);
            lua_pushboolean(L, false); lua_setfield(L, -2, "ok");
            lua_pushstring(L, "bad expected_sha256_hex");
            lua_setfield(L, -2, "error");
            return 1;
        }
        p->hasExpectedSha = true;
    }

    g_pullRunning = true;
    BaseType_t ok = xTaskCreatePinnedToCore(
        pullFullTask, "ota_full", 10240, p, 2, nullptr, 0);
    if (ok != pdPASS) {
        g_pullRunning = false;
        delete p;
        lua_newtable(L);
        lua_pushboolean(L, false); lua_setfield(L, -2, "ok");
        lua_pushstring(L, "task spawn failed (internal heap full)");
        lua_setfield(L, -2, "error");
        return 1;
    }

    lua_newtable(L);
    lua_pushboolean(L, true); lua_setfield(L, -2, "ok");
    return 1;
}

// @lua ez.ota.signing_pubkey() -> string|nil
// @brief Return the embedded Ed25519 OTA signing pubkey
// @description
// Returns the 32-byte Ed25519 public key the firmware was built to
// trust for OTA manifest signatures. Returns nil when the build was
// flashed without a configured key (kOtaSigningPubkey still all
// zeros) -- in that case `apply_full_url` will refuse to start.
// Use with `ez.crypto.ed25519_verify` to check a manifest signature
// before passing its URL into `apply_full_url`.
// @return 32-byte raw pubkey string, or nil when not configured
// @example
// local pub = ez.ota.signing_pubkey()
// if pub and ez.crypto.ed25519_verify(pub, manifest_text, sig) then ... end
// @end
LUA_FUNCTION(l_ota_signing_pubkey) {
    if (!ota_signing_configured()) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlstring(L, (const char*)kOtaSigningPubkey, OTA_SIGNING_PUBKEY_SIZE);
    return 1;
}

// ---------------------------------------------------------------------------

void registerBindings(lua_State* L) {
    static const luaL_Reg funcs[] = {
        {"dev_server_start",   l_ota_dev_server_start},
        {"dev_server_stop",    l_ota_dev_server_stop},
        {"dev_server_status",  l_ota_dev_server_status},
        {"get_token",          l_ota_get_token},
        {"regenerate_token",   l_ota_regenerate_token},
        {"running_partition",  l_ota_running_partition},
        {"pending_partition",  l_ota_pending_partition},
        {"mark_valid",         l_ota_mark_valid},
        {"rollback_and_reboot", l_ota_rollback_and_reboot},
        {"apply_full_url",     l_ota_apply_full_url},
        {"signing_pubkey",     l_ota_signing_pubkey},
        {nullptr, nullptr}
    };
    lua_register_module(L, "ota", funcs);
    LOG("OTA", "Bindings registered");
}

void update() {
    // AsyncWebServer doesn't need a pump; it has its own internal
    // worker task. We use this hook to drain the deferred-Lua queue:
    // the /lua handler queues a stack-allocated DeferredLua (and
    // blocks waiting on `done`); we run the Lua code on this thread,
    // fill in the response slot, and flip `done` to wake the AsyncTCP
    // worker.
    if (!g_mainQueue) return;
    DeferredLua* d = nullptr;
    while (xQueueReceive(g_mainQueue, &d, 0) == pdTRUE) {
        if (!d) continue;

        lua_State* L = LUA_STATE;
        if (!L) {
            d->status = 503;
            d->response_body = "{\"ok\":false,\"error\":\"lua not initialized\"}";
            d->done = true;
            continue;
        }
        int top = lua_gettop(L);
        String wrapped = String("return ") + d->body;
        int loadResult = luaL_loadbuffer(L, wrapped.c_str(),
            wrapped.length(), "=devhttp");
        if (loadResult != LUA_OK) {
            lua_pop(L, 1);
            loadResult = luaL_loadbuffer(L, d->body.c_str(),
                d->body.length(), "=devhttp");
        }
        if (loadResult != LUA_OK) {
            const char* err = lua_tostring(L, -1);
            JsonDocument doc;
            doc["ok"] = false;
            doc["error"] = err ? err : "load error";
            serializeJson(doc, d->response_body);
            d->status = 400;
            lua_settop(L, top);
            d->done = true;
            continue;
        }
        int callResult = lua_pcall(L, 0, LUA_MULTRET, 0);
        if (callResult != LUA_OK) {
            const char* err = lua_tostring(L, -1);
            JsonDocument doc;
            doc["ok"] = false;
            doc["error"] = err ? err : "runtime error";
            serializeJson(doc, d->response_body);
            d->status = 500;
            lua_settop(L, top);
            d->done = true;
            continue;
        }
        int nresults = lua_gettop(L) - top;
        String resultJson = "null";
        if (nresults > 0) {
            lua_getglobal(L, "ez");
            if (lua_istable(L, -1)) {
                lua_getfield(L, -1, "storage");
                if (lua_istable(L, -1)) lua_getfield(L, -1, "json_encode");
                else lua_pushnil(L);
                lua_remove(L, -2);
            } else {
                lua_pushnil(L);
            }
            if (lua_isfunction(L, -1)) {
                if (nresults == 1) {
                    lua_pushvalue(L, top + 1);
                } else {
                    lua_newtable(L);
                    for (int i = 1; i <= nresults; i++) {
                        lua_pushvalue(L, top + i);
                        lua_rawseti(L, -2, i);
                    }
                }
                if (lua_pcall(L, 1, 1, 0) == LUA_OK && lua_isstring(L, -1)) {
                    resultJson = String(lua_tostring(L, -1));
                }
                lua_pop(L, 1);
            } else {
                lua_pop(L, 1);
                resultJson = "\"<no encoder>\"";
            }
        }
        lua_settop(L, top);
        d->response_body = String("{\"ok\":true,\"result\":") + resultJson + "}";
        d->status = 200;
        d->done = true;
    }
}

void shutdown() {
    if (g_updateRunning) {
        Update.abort();
        g_updateRunning = false;
    }
    if (g_server) {
        g_server->end();
        delete g_server;
        g_server = nullptr;
    }
    if (g_mainQueue) {
        vQueueDelete(g_mainQueue);
        g_mainQueue = nullptr;
    }
}

} // namespace ota_bindings
