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
#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
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

// Module state
static QueueHandle_t requestQueue = nullptr;
static QueueHandle_t responseQueue = nullptr;
static TaskHandle_t workerTask = nullptr;
static lua_State* mainState = nullptr;

// Worker task - runs HTTP requests on separate core
static void httpWorkerTask(void* param) {
    HttpRequest req;

    while (true) {
        if (xQueueReceive(requestQueue, &req, portMAX_DELAY) == pdTRUE) {
            HttpResponse resp = {};
            resp.coroRef = req.coroRef;
            resp.success = false;

            // Check WiFi connection
            if (WiFi.status() != WL_CONNECTED) {
                resp.errorMsg = strdup("WiFi not connected");
                xQueueSend(responseQueue, &resp, portMAX_DELAY);
                if (req.body) free(req.body);
                continue;
            }

            HTTPClient http;
            WiFiClientSecure* secureClient = nullptr;
            WiFiClient* client = nullptr;

            // Determine if HTTPS
            bool isHttps = strncmp(req.url, "https://", 8) == 0;

            if (isHttps) {
                secureClient = new WiFiClientSecure();
                secureClient->setInsecure();  // Skip certificate verification for now
                if (!http.begin(*secureClient, req.url)) {
                    resp.errorMsg = strdup("Failed to begin HTTPS connection");
                    delete secureClient;
                    xQueueSend(responseQueue, &resp, portMAX_DELAY);
                    if (req.body) free(req.body);
                    continue;
                }
            } else {
                client = new WiFiClient();
                if (!http.begin(*client, req.url)) {
                    resp.errorMsg = strdup("Failed to begin HTTP connection");
                    delete client;
                    xQueueSend(responseQueue, &resp, portMAX_DELAY);
                    if (req.body) free(req.body);
                    continue;
                }
            }

            // Set timeout
            http.setTimeout(req.timeout > 0 ? req.timeout : 10000);

            // Set redirect handling
            http.setFollowRedirects(req.followRedirects ? HTTPC_STRICT_FOLLOW_REDIRECTS : HTTPC_DISABLE_FOLLOW_REDIRECTS);

            // Add custom headers
            for (size_t i = 0; i < req.headerCount; i++) {
                http.addHeader(req.headers[i][0], req.headers[i][1]);
            }

            // Make request based on method
            int httpCode;
            switch (req.method) {
                case Method::GET:
                    httpCode = http.GET();
                    break;
                case Method::POST:
                    httpCode = http.POST((uint8_t*)req.body, req.bodyLen);
                    break;
                case Method::PUT:
                    httpCode = http.PUT((uint8_t*)req.body, req.bodyLen);
                    break;
                case Method::DELETE_METHOD:
                    httpCode = http.sendRequest("DELETE", (uint8_t*)req.body, req.bodyLen);
                    break;
                case Method::PATCH:
                    httpCode = http.PATCH((uint8_t*)req.body, req.bodyLen);
                    break;
                case Method::HEAD:
                    httpCode = http.sendRequest("HEAD");
                    break;
                default:
                    httpCode = http.GET();
            }

            if (httpCode > 0) {
                resp.statusCode = httpCode;
                resp.success = true;

                // Get response body (except for HEAD)
                if (req.method != Method::HEAD) {
                    String payload = http.getString();
                    if (payload.length() > 0 && payload.length() <= MAX_RESPONSE_LEN) {
                        resp.body = (char*)ps_malloc(payload.length() + 1);
                        if (!resp.body) {
                            resp.body = (char*)malloc(payload.length() + 1);
                        }
                        if (resp.body) {
                            memcpy(resp.body, payload.c_str(), payload.length());
                            resp.body[payload.length()] = '\0';
                            resp.bodyLen = payload.length();
                        }
                    }
                }

                // Collect important response headers
                const char* importantHeaders[] = {
                    "Content-Type", "Content-Length", "Location",
                    "Set-Cookie", "Cache-Control", "ETag",
                    "Last-Modified", "X-Request-Id"
                };
                resp.headerCount = 0;
                for (size_t i = 0; i < sizeof(importantHeaders)/sizeof(importantHeaders[0]) && resp.headerCount < MAX_HEADERS; i++) {
                    if (http.hasHeader(importantHeaders[i])) {
                        String value = http.header(importantHeaders[i]);
                        if (value.length() > 0) {
                            strncpy(resp.headers[resp.headerCount][0], importantHeaders[i], MAX_HEADER_LEN - 1);
                            strncpy(resp.headers[resp.headerCount][1], value.c_str(), MAX_HEADER_LEN - 1);
                            resp.headerCount++;
                        }
                    }
                }
            } else {
                // Error
                char errBuf[128];
                snprintf(errBuf, sizeof(errBuf), "HTTP error: %s", http.errorToString(httpCode).c_str());
                resp.errorMsg = strdup(errBuf);
            }

            http.end();
            if (secureClient) delete secureClient;
            if (client) delete client;
            if (req.body) free(req.body);

            xQueueSend(responseQueue, &resp, portMAX_DELAY);
        }
    }
}

// Initialize HTTP module
static bool initModule() {
    if (requestQueue != nullptr) return true;  // Already initialized

    requestQueue = xQueueCreate(REQUEST_QUEUE_SIZE, sizeof(HttpRequest));
    responseQueue = xQueueCreate(RESPONSE_QUEUE_SIZE, sizeof(HttpResponse));

    if (!requestQueue || !responseQueue) {
        LOG("HTTP", "Failed to create queues");
        return false;
    }

    // Create worker task on Core 0 (Lua runs on Core 1)
    // Stack size 32KB needed for HTTPS with WiFiClientSecure + TLS
    BaseType_t res = xTaskCreatePinnedToCore(
        httpWorkerTask, "http_worker", 32768, nullptr, 1, &workerTask, 0
    );

    if (res != pdPASS) {
        LOG("HTTP", "Failed to create worker task");
        return false;
    }

    LOG("HTTP", "Module initialized");
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

    HttpRequest req = {};
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

    // Queue the request
    if (xQueueSend(requestQueue, &req, 0) != pdTRUE) {
        luaL_unref(L, LUA_REGISTRYINDEX, req.coroRef);
        if (req.body) free(req.body);
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

    // Call fetch with url and options
    lua_pushcfunction(L, l_fetch);
    lua_pushstring(L, url);
    lua_pushvalue(L, -3);  // options table
    lua_call(L, 2, LUA_MULTRET);

    return lua_gettop(L);
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

    lua_setfield(L, -2, "http");
    lua_pop(L, 1);  // pop ez table

    LOG("HTTP", "Bindings registered");
}

void update(lua_State* L) {
    if (!responseQueue) return;

    HttpResponse resp;
    while (xQueueReceive(responseQueue, &resp, 0) == pdTRUE) {
        if (resp.coroRef == LUA_NOREF) {
            if (resp.body) free(resp.body);
            if (resp.errorMsg) free(resp.errorMsg);
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
    }
}

void shutdown() {
    if (workerTask) {
        vTaskDelete(workerTask);
        workerTask = nullptr;
    }
    if (requestQueue) {
        vQueueDelete(requestQueue);
        requestQueue = nullptr;
    }
    if (responseQueue) {
        vQueueDelete(responseQueue);
        responseQueue = nullptr;
    }
    LOG("HTTP", "Shutdown complete");
}

} // namespace http_bindings
