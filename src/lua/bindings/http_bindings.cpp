/**
 * @file http_bindings.cpp
 * @brief HTTP client module for Lua
 *
 * Provides async HTTP/HTTPS requests from Lua scripts. Requests run on a
 * separate FreeRTOS task (Core 0) to avoid blocking the Lua main loop.
 * All functions yield and resume the calling coroutine when complete.
 *
 * @lua ez.http
 */

#include "http_bindings.h"
#include "../../util/log.h"
#include "../async.h"
#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ESPAsyncWebServer.h>
#include <AsyncTCP.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

namespace http_bindings {

// Queue sizes
constexpr size_t REQUEST_QUEUE_SIZE = 4;
constexpr size_t RESPONSE_QUEUE_SIZE = 4;
constexpr size_t MAX_URL_LEN = 512;
constexpr size_t MAX_BODY_LEN = 32 * 1024;  // 32KB max request body
constexpr size_t MAX_RESPONSE_LEN = 128 * 1024;  // 128KB max response
constexpr size_t MAX_HEADERS = 16;
constexpr size_t MAX_HEADER_LEN = 256;

// HTTP methods
enum class Method { GET, POST, PUT, DELETE_METHOD, PATCH, HEAD };

// Request structure
struct HttpRequest {
    char url[MAX_URL_LEN];
    Method method;
    char headers[MAX_HEADERS][2][MAX_HEADER_LEN];  // [index][0=key, 1=value]
    size_t headerCount;
    char* body;
    size_t bodyLen;
    int coroRef;
    int timeout;  // milliseconds
    bool followRedirects;
};

// Response structure
struct HttpResponse {
    int coroRef;
    int statusCode;
    char* body;
    size_t bodyLen;
    char headers[MAX_HEADERS][2][MAX_HEADER_LEN];
    size_t headerCount;
    char* errorMsg;
    bool success;
};

// Module state. requestQueue/workerTask are gone -- HTTP requests
// flow through AsyncIO's queue and run on its worker thread now.
// Only the response queue is still ours, since the response delivery
// is HTTP-specific (we build a Lua table on the coroutine, not just
// return bytes the way AsyncIO file/crypto ops do).
static QueueHandle_t responseQueue = nullptr;
static lua_State* mainState = nullptr;

// ---------------------------------------------------------------------------
// Worker task -- raw HTTP/1.1 over WiFiClient.
//
// We deliberately do NOT use Arduino-ESP32's HTTPClient. That binding
// hangs in handleHeaderResponse / getString against several real
// servers we hit (Python's BaseHTTPRequestHandler being the original
// trigger); the same servers responded fine to a hand-rolled request
// over WiFiClient. The benefit of HTTPClient (parsing redirects /
// chunked / keep-alive) isn't worth the unreliability for our
// development tooling, where everyone we talk to is a small bot we
// control and a pure HTTP/1.1 + Connection: close shape is enough.
//
// Behaviour:
//   * Always sends HTTP/1.1 + Host header + Connection: close.
//   * Reads the response status + headers line by line.
//   * Body is read by one of three strategies, in order:
//       1. Content-Length: <N>     -- read exactly N bytes
//       2. Transfer-Encoding: chunked -- de-chunk on the fly
//       3. (neither)               -- read until peer closes
//   * Caps the response body at MAX_RESPONSE_LEN; truncates above.
//   * Timeout (req.timeout) covers the whole request including
//     connect, write, and read.
//
// HTTPS uses WiFiClientSecure with setInsecure() -- same convenience
// the previous binding offered for dev work. Use the bot's bearer
// token, not TLS, as the trust boundary.
// ---------------------------------------------------------------------------

static bool parseUrl(const char* url, bool& isHttps, char* host, size_t hostLen,
                     int& port, char* path, size_t pathLen) {
    if (strncmp(url, "https://", 8) == 0) {
        isHttps = true;
        url += 8;
        port = 443;
    } else if (strncmp(url, "http://", 7) == 0) {
        isHttps = false;
        url += 7;
        port = 80;
    } else {
        return false;
    }

    // host[:port] up to the first '/'
    const char* slash = strchr(url, '/');
    size_t authority_len = slash ? (size_t)(slash - url) : strlen(url);

    char authority[160];
    if (authority_len >= sizeof(authority)) return false;
    memcpy(authority, url, authority_len);
    authority[authority_len] = '\0';

    char* colon = strchr(authority, ':');
    if (colon) {
        *colon = '\0';
        port = atoi(colon + 1);
        if (port <= 0 || port > 65535) return false;
    }
    strncpy(host, authority, hostLen - 1);
    host[hostLen - 1] = '\0';

    if (slash) {
        strncpy(path, slash, pathLen - 1);
        path[pathLen - 1] = '\0';
    } else {
        path[0] = '/'; path[1] = '\0';
    }
    return true;
}

// Read one line ending in CRLF (or LF), trim the \r, drop the \n.
// Returns true on success, false on timeout or peer close.
static bool readLine(WiFiClient* client, String& out, uint32_t deadline_ms) {
    out = "";
    while (true) {
        if (client->available()) {
            int c = client->read();
            if (c < 0) return false;
            if (c == '\n') {
                if (out.length() > 0 && out[out.length() - 1] == '\r') {
                    out.remove(out.length() - 1);
                }
                return true;
            }
            out += (char)c;
            if (out.length() > 1024) return false;  // sanity cap
        } else {
            if (millis() > deadline_ms) return false;
            if (!client->connected() && !client->available()) return false;
            delay(2);
        }
    }
}

static int readBytes(WiFiClient* client, char* buf, int wanted, uint32_t deadline_ms) {
    int got = 0;
    while (got < wanted) {
        int avail = client->available();
        if (avail > 0) {
            int n = client->read((uint8_t*)buf + got, wanted - got);
            if (n > 0) got += n;
            else if (n < 0) return got;
        } else {
            if (millis() > deadline_ms) return got;
            if (!client->connected() && !client->available()) return got;
            delay(2);
        }
    }
    return got;
}

static const char* methodName(Method m) {
    switch (m) {
        case Method::GET:    return "GET";
        case Method::POST:   return "POST";
        case Method::PUT:    return "PUT";
        case Method::DELETE_METHOD: return "DELETE";
        case Method::PATCH:  return "PATCH";
        case Method::HEAD:   return "HEAD";
    }
    return "GET";
}

// One HTTP fetch run-to-completion. Called on the AsyncIO worker
// thread (Core 0) -- there is intentionally no http-specific task,
// because every extra FreeRTOS task burns scarce internal DRAM for
// its stack and we already have a perfectly capable worker.
//
// Ownership rules:
//   * l_fetch heap-allocs HttpRequest in PSRAM, hands the pointer to
//     AsyncIO::queueHttpRequest.
//   * This function frees the HttpRequest when done with it (always),
//     heap-allocs an HttpResponse, queues it on responseQueue.
//   * update() (Lua thread) reads HttpResponse and frees it.
// If sending fails (queue full), the producer frees -- there's never a
// case where the receiver doesn't take ownership of a successfully
// dequeued pointer.
static void processHttpRequest(void* requestPtr, int /*coroRef*/) {
    HttpRequest* preq = (HttpRequest*)requestPtr;
    if (!preq) return;
    HttpRequest& req = *preq;

        // Response also lives in PSRAM -- same reasoning as the request
        // alloc in l_fetch. The body is allocated separately (also PSRAM
        // when possible) and is what dominates the response footprint.
        HttpResponse* presp = (HttpResponse*)heap_caps_calloc(
            1, sizeof(HttpResponse), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!presp) presp = (HttpResponse*)calloc(1, sizeof(HttpResponse));
        if (!presp) {
            // Without a response slot we can't even report the failure;
            // best we can do is drop the request.
            if (req.body) free(req.body);
            free(preq);
            return;
        }
        HttpResponse& resp = *presp;
        resp.coroRef = req.coroRef;
        resp.success = false;

        if (WiFi.status() != WL_CONNECTED) {
            resp.errorMsg = strdup("WiFi not connected");
            xQueueSend(responseQueue, &presp, portMAX_DELAY);
            if (req.body) free(req.body);
            free(preq);
            return;
        }

        bool isHttps = false;
        char host[160] = {0};
        int  port = 0;
        char path[512] = {0};
        if (!parseUrl(req.url, isHttps, host, sizeof(host), port, path, sizeof(path))) {
            resp.errorMsg = strdup("bad URL");
            xQueueSend(responseQueue, &presp, portMAX_DELAY);
            if (req.body) free(req.body);
            free(preq);
            return;
        }

        // One client, polymorphic via the WiFiClient base. Secure
        // variant skips cert verification -- this is dev-tooling, the
        // bearer token is the trust boundary.
        WiFiClient* client = nullptr;
        if (isHttps) {
            auto* s = new WiFiClientSecure();
            s->setInsecure();
            client = s;
        } else {
            client = new WiFiClient();
        }

        uint32_t timeout = req.timeout > 0 ? (uint32_t)req.timeout : 10000;
        client->setTimeout(timeout / 1000 + 1);  // setTimeout takes seconds in this lib
        uint32_t deadline = millis() + timeout;

        if (!client->connect(host, port)) {
            resp.errorMsg = strdup("connect failed");
            delete client;
            xQueueSend(responseQueue, &presp, portMAX_DELAY);
            if (req.body) free(req.body);
            free(preq);
            return;
        }

        // Build + send the request line, headers, body.
        String headBuf = String(methodName(req.method)) + " " + path + " HTTP/1.1\r\n";
        headBuf += "Host: ";
        headBuf += host;
        if ((isHttps && port != 443) || (!isHttps && port != 80)) {
            headBuf += ":";
            headBuf += String(port);
        }
        headBuf += "\r\n";
        headBuf += "Connection: close\r\n";
        bool sawCType = false, sawCLen = false;
        for (size_t i = 0; i < req.headerCount; i++) {
            headBuf += req.headers[i][0];
            headBuf += ": ";
            headBuf += req.headers[i][1];
            headBuf += "\r\n";
            if (strcasecmp(req.headers[i][0], "Content-Type")   == 0) sawCType = true;
            if (strcasecmp(req.headers[i][0], "Content-Length") == 0) sawCLen  = true;
        }
        bool hasBody = req.body && req.bodyLen > 0 &&
                       (req.method == Method::POST  ||
                        req.method == Method::PUT   ||
                        req.method == Method::PATCH ||
                        req.method == Method::DELETE_METHOD);
        if (hasBody && !sawCLen) {
            headBuf += "Content-Length: ";
            headBuf += String((unsigned)req.bodyLen);
            headBuf += "\r\n";
        }
        if (hasBody && !sawCType) {
            headBuf += "Content-Type: application/octet-stream\r\n";
        }
        headBuf += "\r\n";

        client->print(headBuf);
        if (hasBody) {
            client->write((const uint8_t*)req.body, req.bodyLen);
        }

        // ----- Read status line ----------------------------------------
        String statusLine;
        if (!readLine(client, statusLine, deadline)) {
            resp.errorMsg = strdup("no status line");
            client->stop();
            delete client;
            xQueueSend(responseQueue, &presp, portMAX_DELAY);
            if (req.body) free(req.body);
            free(preq);
            return;
        }
        // Format: "HTTP/1.1 200 OK"
        int sp1 = statusLine.indexOf(' ');
        if (sp1 < 0) {
            resp.errorMsg = strdup("malformed status");
            client->stop(); delete client;
            xQueueSend(responseQueue, &presp, portMAX_DELAY);
            if (req.body) free(req.body);
            free(preq);
            return;
        }
        resp.statusCode = atoi(statusLine.c_str() + sp1 + 1);

        // ----- Read headers --------------------------------------------
        long contentLength = -1;
        bool chunked = false;
        resp.headerCount = 0;
        while (true) {
            String line;
            if (!readLine(client, line, deadline)) {
                resp.errorMsg = strdup("header read timeout");
                client->stop(); delete client;
                xQueueSend(responseQueue, &presp, portMAX_DELAY);
                if (req.body) free(req.body);
                free(preq);
                return;
            }
            if (line.length() == 0) break;  // end of headers
            int colon = line.indexOf(':');
            if (colon <= 0) continue;
            String key = line.substring(0, colon);
            String val = line.substring(colon + 1);
            val.trim();

            if (key.equalsIgnoreCase("Content-Length")) {
                contentLength = val.toInt();
            } else if (key.equalsIgnoreCase("Transfer-Encoding") &&
                       val.indexOf("chunked") >= 0) {
                chunked = true;
            }

            if (resp.headerCount < MAX_HEADERS) {
                strncpy(resp.headers[resp.headerCount][0], key.c_str(), MAX_HEADER_LEN - 1);
                resp.headers[resp.headerCount][0][MAX_HEADER_LEN - 1] = '\0';
                strncpy(resp.headers[resp.headerCount][1], val.c_str(), MAX_HEADER_LEN - 1);
                resp.headers[resp.headerCount][1][MAX_HEADER_LEN - 1] = '\0';
                resp.headerCount++;
            }
        }

        // ----- Read body -----------------------------------------------
        if (req.method != Method::HEAD) {
            char* body = nullptr;
            size_t bodyLen = 0;

            if (chunked) {
                // Chunked transfer: <hex-size>\r\n<bytes>\r\n... then 0\r\n\r\n
                size_t cap = 4096;
                body = (char*)ps_malloc(cap);
                if (!body) body = (char*)malloc(cap);
                while (body) {
                    String sizeLine;
                    if (!readLine(client, sizeLine, deadline)) break;
                    long chunkSize = strtol(sizeLine.c_str(), nullptr, 16);
                    if (chunkSize <= 0) break;
                    if (bodyLen + chunkSize > MAX_RESPONSE_LEN) break;
                    if (bodyLen + chunkSize + 1 > cap) {
                        size_t newCap = bodyLen + chunkSize + 1;
                        char* nb = (char*)ps_malloc(newCap);
                        if (!nb) nb = (char*)malloc(newCap);
                        if (!nb) break;
                        memcpy(nb, body, bodyLen);
                        free(body);
                        body = nb;
                        cap = newCap;
                    }
                    int got = readBytes(client, body + bodyLen, chunkSize, deadline);
                    bodyLen += got;
                    if (got < chunkSize) break;
                    String trailing;
                    readLine(client, trailing, deadline);  // consume the CRLF
                }
            } else if (contentLength > 0) {
                size_t want = (contentLength <= (long)MAX_RESPONSE_LEN)
                              ? (size_t)contentLength : MAX_RESPONSE_LEN;
                body = (char*)ps_malloc(want + 1);
                if (!body) body = (char*)malloc(want + 1);
                if (body) {
                    int got = readBytes(client, body, want, deadline);
                    bodyLen = got > 0 ? (size_t)got : 0;
                }
            } else {
                // No length header -- read until close. Grow the buffer
                // as we go, capped at MAX_RESPONSE_LEN.
                size_t cap = 4096;
                body = (char*)ps_malloc(cap);
                if (!body) body = (char*)malloc(cap);
                while (body && bodyLen < MAX_RESPONSE_LEN) {
                    if (!client->connected() && !client->available()) break;
                    if (millis() > deadline) break;
                    int avail = client->available();
                    if (avail <= 0) { delay(5); continue; }
                    if (bodyLen + 1 > cap) {
                        size_t newCap = cap * 2;
                        if (newCap > MAX_RESPONSE_LEN + 1) newCap = MAX_RESPONSE_LEN + 1;
                        char* nb = (char*)ps_malloc(newCap);
                        if (!nb) nb = (char*)malloc(newCap);
                        if (!nb) break;
                        memcpy(nb, body, bodyLen);
                        free(body);
                        body = nb;
                        cap = newCap;
                    }
                    int n = client->read((uint8_t*)body + bodyLen,
                                         (cap - 1) - bodyLen);
                    if (n > 0) bodyLen += n;
                }
            }

            if (body) {
                body[bodyLen < MAX_RESPONSE_LEN ? bodyLen : MAX_RESPONSE_LEN - 1] = '\0';
            }
            resp.body = body;
            resp.bodyLen = bodyLen;
        }
        resp.success = true;

    client->stop();
    delete client;
    if (req.body) free(req.body);
    free(preq);
    xQueueSend(responseQueue, &presp, portMAX_DELAY);
}

// Initialize HTTP module.
//
// We piggyback on the AsyncIO worker thread (Core 0) instead of
// spawning our own task. Internal DRAM is the system's tightest
// resource -- task stacks must live there, and adding even a 4 KiB
// HTTP-specific stack on top of audio/async_io/WiFi pushed the
// system over the cliff (LCD DMA descriptor allocs started failing
// with null-pointer derefs). AsyncIO has a 12 KiB stack already, so
// HTTP just queues a request and uses that thread.
//
// The only resource we still own is the response queue: it carries
// HttpResponse* pointers from the AsyncIO worker back to the Lua
// thread, where update() drains it and resumes the suspended fetch
// coroutine. Plain pointers, ~4 bytes each, no real DRAM cost.
static bool initModule() {
    if (responseQueue) return true;  // Already initialized

    responseQueue = xQueueCreate(RESPONSE_QUEUE_SIZE, sizeof(HttpResponse*));
    if (!responseQueue) {
        LOG("HTTP", "Failed to create response queue");
        return false;
    }

    AsyncIO::setHttpProcessor(processHttpRequest);

    LOG("HTTP", "Module initialized (worker shared with AsyncIO)");
    return true;
}

/**
 * @lua ez.http.fetch(url, options?) -> table
 * @brief Make an HTTP/HTTPS request
 *
 * Performs an async HTTP request. Must be called from a coroutine (use spawn()).
 * Yields until the request completes. Supports GET, POST, PUT, DELETE, PATCH, HEAD.
 *
 * @param url string URL to request (http:// or https://)
 * @param options table|nil Optional settings:
 *   - method: string HTTP method (default "GET")
 *   - headers: table Custom headers {["Header-Name"] = "value"}
 *   - body: string Request body for POST/PUT/PATCH
 *   - timeout: integer Request timeout in ms (default 10000)
 *   - follow_redirects: boolean Follow redirects (default true)
 *
 * @return table Response with fields:
 *   - ok: boolean True if request succeeded
 *   - status: integer HTTP status code (if ok)
 *   - body: string Response body (if ok)
 *   - headers: table Response headers (if ok)
 *   - error: string Error message (if not ok)
 *
 * @example
 * spawn(function()
 *     local resp = ez.http.fetch("https://api.example.com/data", {
 *         method = "POST",
 *         headers = {["Content-Type"] = "application/json"},
 *         body = '{"key": "value"}'
 *     })
 *     if resp.ok then
 *         print("Status:", resp.status)
 *         print("Body:", resp.body)
 *     else
 *         print("Error:", resp.error)
 *     end
 * end)
 */
static int l_fetch(lua_State* L) {
    if (!initModule()) {
        lua_pushnil(L);
        lua_pushstring(L, "HTTP module not initialized");
        return 2;
    }

    const char* url = luaL_checkstring(L, 1);
    if (strlen(url) >= MAX_URL_LEN) {
        lua_pushnil(L);
        lua_pushstring(L, "URL too long");
        return 2;
    }

    // Heap-alloc the request in PSRAM. It's ~8.7 KiB -- larger than
    // free internal DRAM in the typical post-boot state -- and
    // dominating the worker's stack budget would force a much bigger
    // stack alloc. PSRAM is fine here because the worker only reads
    // these fields once at the start of the request; nothing in the
    // hot path touches them.
    HttpRequest* preq = (HttpRequest*)heap_caps_calloc(
        1, sizeof(HttpRequest), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!preq) preq = (HttpRequest*)calloc(1, sizeof(HttpRequest));
    if (!preq) {
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }
    HttpRequest& req = *preq;
    strncpy(req.url, url, MAX_URL_LEN - 1);
    req.method = Method::GET;
    req.timeout = 10000;
    req.followRedirects = true;
    req.headerCount = 0;
    req.body = nullptr;
    req.bodyLen = 0;

    // Parse options table if provided
    if (lua_gettop(L) >= 2 && lua_istable(L, 2)) {
        // Method
        lua_getfield(L, 2, "method");
        if (lua_isstring(L, -1)) {
            const char* method = lua_tostring(L, -1);
            if (strcasecmp(method, "POST") == 0) req.method = Method::POST;
            else if (strcasecmp(method, "PUT") == 0) req.method = Method::PUT;
            else if (strcasecmp(method, "DELETE") == 0) req.method = Method::DELETE_METHOD;
            else if (strcasecmp(method, "PATCH") == 0) req.method = Method::PATCH;
            else if (strcasecmp(method, "HEAD") == 0) req.method = Method::HEAD;
        }
        lua_pop(L, 1);

        // Timeout
        lua_getfield(L, 2, "timeout");
        if (lua_isnumber(L, -1)) {
            req.timeout = (int)lua_tointeger(L, -1);
        }
        lua_pop(L, 1);

        // Follow redirects
        lua_getfield(L, 2, "follow_redirects");
        if (lua_isboolean(L, -1)) {
            req.followRedirects = lua_toboolean(L, -1);
        }
        lua_pop(L, 1);

        // Headers
        lua_getfield(L, 2, "headers");
        if (lua_istable(L, -1)) {
            lua_pushnil(L);
            while (lua_next(L, -2) != 0 && req.headerCount < MAX_HEADERS) {
                if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                    const char* key = lua_tostring(L, -2);
                    const char* value = lua_tostring(L, -1);
                    strncpy(req.headers[req.headerCount][0], key, MAX_HEADER_LEN - 1);
                    strncpy(req.headers[req.headerCount][1], value, MAX_HEADER_LEN - 1);
                    req.headerCount++;
                }
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);

        // Body
        lua_getfield(L, 2, "body");
        if (lua_isstring(L, -1)) {
            size_t bodyLen;
            const char* body = lua_tolstring(L, -1, &bodyLen);
            if (bodyLen > 0 && bodyLen <= MAX_BODY_LEN) {
                req.body = (char*)malloc(bodyLen);
                if (req.body) {
                    memcpy(req.body, body, bodyLen);
                    req.bodyLen = bodyLen;
                }
            }
        }
        lua_pop(L, 1);
    }

    // Store coroutine reference
    lua_pushthread(L);
    req.coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    // Hand off to the AsyncIO worker. processHttpRequest takes
    // ownership of preq from this point on.
    if (!AsyncIO::instance().queueHttpRequest(preq, req.coroRef)) {
        luaL_unref(L, LUA_REGISTRYINDEX, req.coroRef);
        if (req.body) free(req.body);
        free(preq);
        lua_pushnil(L);
        lua_pushstring(L, "Request queue full");
        return 2;
    }

    // Yield coroutine - will be resumed when response arrives
    return lua_yield(L, 0);
}

/**
 * @lua ez.http.get(url) -> table
 * @brief Convenience wrapper for GET requests
 *
 * Shorthand for ez.http.fetch(url) with GET method.
 * Must be called from a coroutine.
 *
 * @param url string URL to request
 * @return table Response (see fetch() for fields)
 *
 * @example
 * spawn(function()
 *     local resp = ez.http.get("https://api.example.com/status")
 *     if resp.ok then print(resp.body) end
 * end)
 */
static int l_get(lua_State* L) {
    // Just call fetch with GET method
    lua_settop(L, 1);  // Keep only URL
    return l_fetch(L);
}

/**
 * @lua ez.http.post(url, body, content_type?) -> table
 * @brief Make a POST request with body
 *
 * Convenience wrapper for POST requests. Sets Content-Type header automatically.
 * Must be called from a coroutine.
 *
 * @param url string URL to request
 * @param body string Request body
 * @param content_type string|nil Content-Type header (default "application/x-www-form-urlencoded")
 * @return table Response (see fetch() for fields)
 *
 * @example
 * spawn(function()
 *     local resp = ez.http.post("https://api.example.com/submit",
 *         "name=value&other=data")
 *     if resp.ok then print("Submitted!") end
 * end)
 */
static int l_post(lua_State* L) {
    const char* url = luaL_checkstring(L, 1);
    size_t bodyLen;
    const char* body = luaL_optlstring(L, 2, "", &bodyLen);
    const char* contentType = luaL_optstring(L, 3, "application/x-www-form-urlencoded");

    // Build options table
    lua_newtable(L);

    lua_pushstring(L, "POST");
    lua_setfield(L, -2, "method");

    lua_pushlstring(L, body, bodyLen);
    lua_setfield(L, -2, "body");

    // Headers subtable
    lua_newtable(L);
    lua_pushstring(L, contentType);
    lua_setfield(L, -2, "Content-Type");
    lua_setfield(L, -2, "headers");

    // Call fetch with url and options. Capture the top before the call
    // so we can return only the values fetch pushed — using lua_gettop()
    // directly would also return the original args still on the stack.
    int top_before_call = lua_gettop(L);
    lua_pushcfunction(L, l_fetch);
    lua_pushstring(L, url);
    lua_pushvalue(L, -3);  // options table
    lua_call(L, 2, LUA_MULTRET);

    return lua_gettop(L) - top_before_call;
}

/**
 * @lua ez.http.post_json(url, data) -> table
 * @brief POST a Lua table as JSON
 *
 * Encodes a Lua table to JSON and POSTs it with Content-Type: application/json.
 * Requires json_encode global function to be available.
 * Must be called from a coroutine.
 *
 * @param url string URL to request
 * @param data table Lua table to encode as JSON body
 * @return table Response (see fetch() for fields)
 *
 * @example
 * spawn(function()
 *     local resp = ez.http.post_json("https://api.example.com/users", {
 *         name = "Alice",
 *         email = "alice@example.com"
 *     })
 *     if resp.ok and resp.status == 201 then
 *         print("User created!")
 *     end
 * end)
 */
static int l_post_json(lua_State* L) {
    const char* url = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    // Convert table to JSON using json_encode global
    lua_getglobal(L, "json_encode");
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushstring(L, "json_encode not available");
        return 2;
    }
    lua_pushvalue(L, 2);
    lua_call(L, 1, 1);

    const char* jsonBody = lua_tostring(L, -1);
    if (!jsonBody) {
        lua_pushnil(L);
        lua_pushstring(L, "Failed to encode JSON");
        return 2;
    }

    // Call post with JSON content type
    return l_post(L);
}

// ---------------------------------------------------------------------------
// HTTP server (ESPAsyncWebServer wrapper)
//
// Single global server. Lua hands us one callback; every request goes
// through it, and the callback is expected to return (status_code,
// content_type, body). This matches the typical Lua web-framework
// pattern (pattern-match on uri / method inside the handler) without
// us having to expose path-registration internals.
//
// Why AsyncWebServer instead of ESP-IDF's esp_http_server: the latter
// silently stalls multi-segment responses on Arduino-ESP32 2.0.17 /
// IDF 4.4.x for this hardware. AsyncTCP runs requests through lwIP's
// raw TCP API (tcp_write + tcp_sent), bypassing the broken socket
// layer, and reliably ships the full body.
//
// Threading: AsyncWebServer fires handlers on the AsyncTCP worker
// task. Lua is single-threaded so we can't call the user's callback
// from there directly. We queue a stack-local LuaServeReq and BLOCK
// the worker until update() (Lua main thread) fills in the response.
// The AsyncTCP worker then sends the response synchronously.
//
// Bodies are passed through as Lua strings on both sides, so binary
// payloads (PNGs, archives, raw uploads) round-trip without NUL
// truncation.
// ---------------------------------------------------------------------------

static AsyncWebServer* g_serveServer = nullptr;
static int g_serverCallbackRef = LUA_NOREF;

struct LuaServeReq {
    AsyncWebServerRequest* req;
    String body;
    volatile bool done;
    int status;
    String content_type;
    String response_body;
};

static QueueHandle_t g_lua_serve_q = nullptr;

static const char* http_method_name(int m) {
    switch (m) {
        case HTTP_GET:    return "GET";
        case HTTP_POST:   return "POST";
        case HTTP_PUT:    return "PUT";
        case HTTP_DELETE: return "DELETE";
        case HTTP_PATCH:  return "PATCH";
        case HTTP_HEAD:   return "HEAD";
        default:          return "?";
    }
}

// Called from update() on the Lua main thread. Builds the request
// table, calls the user's callback, fills d->status etc, flips done.
static void dispatchLuaServeOnMain(LuaServeReq* d) {
    if (!d) return;
    auto fill_error = [&](int code, const String& msg) {
        d->status = code;
        d->content_type = "text/plain";
        d->response_body = msg;
        d->done = true;
    };
    if (g_serverCallbackRef == LUA_NOREF) { fill_error(500, "no handler"); return; }
    lua_State* L = mainState;
    if (!L)                                { fill_error(500, "no Lua"); return; }
    AsyncWebServerRequest* req = d->req;
    if (!req)                              { fill_error(500, "no request"); return; }

    lua_rawgeti(L, LUA_REGISTRYINDEX, g_serverCallbackRef);
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        fill_error(500, "handler gone");
        return;
    }

    lua_newtable(L);
    lua_pushstring(L, req->url().c_str());
    lua_setfield(L, -2, "uri");

    lua_pushstring(L, http_method_name(req->method()));
    lua_setfield(L, -2, "method");

    // Headers map. AsyncWebServer only retains headers that were
    // explicitly collected via collectHeaders() at start-up time -- we
    // collect the common set there, so this enumerates whatever's
    // available without per-name lookups.
    lua_newtable(L);
    int hdrCount = req->headers();
    for (int i = 0; i < hdrCount; i++) {
        const AsyncWebHeader* h = req->getHeader(i);
        if (!h) continue;
        lua_pushstring(L, h->value().c_str());
        lua_setfield(L, -2, h->name().c_str());
    }
    lua_setfield(L, -2, "headers");

    if (req->hasHeader("Content-Type")) {
        lua_pushstring(L, req->header("Content-Type").c_str());
        lua_setfield(L, -2, "content_type");
    }
    if (req->hasHeader("Content-Length")) {
        lua_pushinteger(L,
            (lua_Integer)strtol(req->header("Content-Length").c_str(),
                                nullptr, 10));
        lua_setfield(L, -2, "content_length");
    }

    // args = parsed query string (?k=v&k=v). AsyncWebServer parses
    // these for us into request params with isPost()==false; we
    // only surface query args here, not form fields, so user can
    // read req.body and parse if needed.
    lua_newtable(L);
    int paramCount = req->params();
    for (int i = 0; i < paramCount; i++) {
        const AsyncWebParameter* p = req->getParam(i);
        if (!p || p->isPost() || p->isFile()) continue;
        lua_pushstring(L, p->value().c_str());
        lua_setfield(L, -2, p->name().c_str());
    }
    lua_setfield(L, -2, "args");

    if (d->body.length() > 0) {
        lua_pushlstring(L, d->body.c_str(), d->body.length());
        lua_setfield(L, -2, "body");
    }

    if (lua_pcall(L, 1, 3, 0) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        fill_error(500, String("handler error: ") + (err ? err : "unknown"));
        lua_pop(L, 1);
        return;
    }
    int code = (int)lua_tointeger(L, -3);
    const char* ct = lua_tostring(L, -2);
    size_t bodyLen = 0;
    const char* body = lua_tolstring(L, -1, &bodyLen);
    if (code <= 0) code = 200;
    if (!ct) ct = "text/plain";
    d->status = code;
    d->content_type = String(ct);
    if (body && bodyLen > 0) {
        d->response_body = String();
        d->response_body.concat((const char*)body, bodyLen);
    } else {
        d->response_body = "";
    }
    lua_pop(L, 3);
    d->done = true;
}

// Body accumulator hung off AsyncWebServerRequest::_tempObject. The
// body callback streams chunks in; the completion handler reads them
// out as a single contiguous String. AsyncWebServer free()s _tempObject
// on request destruction so we don't have to track it manually.
struct ServeBodyBuf {
    size_t cap;
    size_t len;
    char data[];
};

static void serve_body_cb(AsyncWebServerRequest* req, uint8_t* data,
                          size_t len, size_t index, size_t total) {
    constexpr size_t MAX_BODY = 64 * 1024;
    if (total == 0 || total > MAX_BODY) return;
    auto* b = (ServeBodyBuf*)req->_tempObject;
    if (index == 0 || !b) {
        if (b) { free(b); req->_tempObject = nullptr; }
        b = (ServeBodyBuf*)malloc(sizeof(ServeBodyBuf) + total);
        if (!b) return;
        b->cap = total;
        b->len = 0;
        req->_tempObject = b;
    }
    if (index + len > b->cap) return;
    memcpy(b->data + index, data, len);
    if (index + len > b->len) b->len = index + len;
}

// Catch-all completion handler. Pulls the accumulated body off
// _tempObject, queues a stack LuaServeReq, blocks on the main thread
// filling it in, sends the response.
static void serve_dispatch_handler(AsyncWebServerRequest* req) {
    auto* b = (ServeBodyBuf*)req->_tempObject;

    LuaServeReq d;
    d.req = req;
    d.done = false;
    d.status = 0;
    if (b && b->len > 0) {
        d.body.concat(b->data, b->len);
    }

    LuaServeReq* p = &d;
    if (!g_lua_serve_q || xQueueSend(g_lua_serve_q, &p, 0) != pdTRUE) {
        req->send(500, "text/plain", "queue full");
        return;
    }
    // 10 s ceiling so a wedged main loop can't hold the AsyncTCP task
    // forever. /lua serve handlers are dev-only; the bound is fine.
    uint32_t deadline = millis() + 10000;
    while (!d.done && millis() < deadline) {
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    if (!d.done) {
        req->send(500, "text/plain", "main loop timeout");
        return;
    }

    int code = d.status > 0 ? d.status : 200;
    req->send(code, d.content_type, d.response_body);
}

static int l_serve_start(lua_State* L) {
    int port = (int)luaL_checkinteger(L, 1);
    if (!lua_isfunction(L, 2)) {
        return luaL_error(L, "serve_start: expected (port, handler_fn, opts?)");
    }

    if (g_serveServer) {
        g_serveServer->end();
        delete g_serveServer;
        g_serveServer = nullptr;
    }
    if (g_serverCallbackRef != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, g_serverCallbackRef);
        g_serverCallbackRef = LUA_NOREF;
    }
    if (!g_lua_serve_q) {
        g_lua_serve_q = xQueueCreate(4, sizeof(LuaServeReq*));
    }

    lua_pushvalue(L, 2);
    g_serverCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);

    g_serveServer = new AsyncWebServer(port);

    // The mathieucarbou fork retains every request header by default,
    // so we don't have to whitelist them. opts.collect_headers from
    // older callers is accepted as a no-op for backwards compat.
    (void)lua_istable(L, 3);

    g_serveServer->onRequestBody(serve_body_cb);
    g_serveServer->onNotFound(serve_dispatch_handler);

    g_serveServer->begin();
    LOG("HTTP", "serve_start listening on port %d", port);

    lua_pushboolean(L, true);
    return 1;
}

static int l_serve_update(lua_State* L) {
    if (!g_lua_serve_q) return 0;
    LuaServeReq* d = nullptr;
    while (xQueueReceive(g_lua_serve_q, &d, 0) == pdTRUE) {
        dispatchLuaServeOnMain(d);
    }
    return 0;
}

static int l_serve_stop(lua_State* L) {
    if (g_serveServer) {
        g_serveServer->end();
        delete g_serveServer;
        g_serveServer = nullptr;
    }
    if (g_serverCallbackRef != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, g_serverCallbackRef);
        g_serverCallbackRef = LUA_NOREF;
    }
    return 0;
}

void registerBindings(lua_State* L) {
    mainState = L;

    // Get or create ez table
    lua_getglobal(L, "ez");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_setglobal(L, "ez");
        lua_getglobal(L, "ez");
    }

    // Create http subtable
    lua_newtable(L);

    lua_pushcfunction(L, l_fetch);
    lua_setfield(L, -2, "fetch");

    lua_pushcfunction(L, l_get);
    lua_setfield(L, -2, "get");

    lua_pushcfunction(L, l_post);
    lua_setfield(L, -2, "post");

    lua_pushcfunction(L, l_post_json);
    lua_setfield(L, -2, "post_json");

    lua_pushcfunction(L, l_serve_start);
    lua_setfield(L, -2, "serve_start");

    lua_pushcfunction(L, l_serve_update);
    lua_setfield(L, -2, "serve_update");

    lua_pushcfunction(L, l_serve_stop);
    lua_setfield(L, -2, "serve_stop");

    lua_setfield(L, -2, "http");
    lua_pop(L, 1);  // pop ez table

    // The actual response queue + AsyncIO processor registration
    // happen lazily on the first ez.http.fetch call (initModule).
    // We don't do it eagerly here because AsyncIO::init() runs AFTER
    // registerAllModules() in lua_runtime.cpp -- AsyncIO::setHttpProcessor
    // is fine to call early (it just stores a function pointer) but
    // queueHttpRequest needs the worker queue to exist, so we let the
    // first fetch trigger setup.
    LOG("HTTP", "Bindings registered (client + server, worker shared)");
}

void update(lua_State* L) {
    // Drain Lua-callback requests from the AsyncWebServer side so the
    // Lua callback runs on this thread, not the AsyncTCP task.
    if (g_lua_serve_q) {
        LuaServeReq* d = nullptr;
        while (xQueueReceive(g_lua_serve_q, &d, 0) == pdTRUE) {
            dispatchLuaServeOnMain(d);
        }
    }

    if (!responseQueue) return;

    HttpResponse* presp = nullptr;
    while (xQueueReceive(responseQueue, &presp, 0) == pdTRUE) {
        if (!presp) continue;
        HttpResponse& resp = *presp;
        if (resp.coroRef == LUA_NOREF) {
            if (resp.body) free(resp.body);
            if (resp.errorMsg) free(resp.errorMsg);
            free(presp);
            continue;
        }

        // Get coroutine
        lua_rawgeti(L, LUA_REGISTRYINDEX, resp.coroRef);
        lua_State* co = lua_tothread(L, -1);
        lua_pop(L, 1);

        if (co) {
            // Build response table
            lua_newtable(co);

            lua_pushboolean(co, resp.success);
            lua_setfield(co, -2, "ok");

            if (resp.success) {
                lua_pushinteger(co, resp.statusCode);
                lua_setfield(co, -2, "status");

                // Body
                if (resp.body && resp.bodyLen > 0) {
                    lua_pushlstring(co, resp.body, resp.bodyLen);
                } else {
                    lua_pushstring(co, "");
                }
                lua_setfield(co, -2, "body");

                // Headers table
                lua_newtable(co);
                for (size_t i = 0; i < resp.headerCount; i++) {
                    lua_pushstring(co, resp.headers[i][1]);
                    lua_setfield(co, -2, resp.headers[i][0]);
                }
                lua_setfield(co, -2, "headers");
            } else {
                lua_pushstring(co, resp.errorMsg ? resp.errorMsg : "Unknown error");
                lua_setfield(co, -2, "error");
            }

            // Resume coroutine with response table
            int nresults = 0;
            int status = lua_resume(co, L, 1, &nresults);
            if (status != LUA_OK && status != LUA_YIELD) {
                const char* errMsg = lua_tostring(co, -1);
                LOG("HTTP", "Coroutine error: %s", errMsg ? errMsg : "unknown");
                lua_pop(co, 1);
            }
        }

        luaL_unref(L, LUA_REGISTRYINDEX, resp.coroRef);
        if (resp.body) free(resp.body);
        if (resp.errorMsg) free(resp.errorMsg);
        free(presp);
    }
}

void shutdown() {
    AsyncIO::setHttpProcessor(nullptr);
    if (responseQueue) {
        vQueueDelete(responseQueue);
        responseQueue = nullptr;
    }
    LOG("HTTP", "Shutdown complete");
}

} // namespace http_bindings
