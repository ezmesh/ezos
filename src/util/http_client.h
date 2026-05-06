#pragma once

// Outbound HTTP(S) client.
//
// One implementation, two call shapes -- buffered (collects the
// response body in memory, capped) and streaming (delivers each
// chunk via a callback while keeping no copy).
//
// Why this exists rather than Arduino-ESP32's HTTPClient: HTTPClient
// hangs in handleHeaderResponse / getString against several real
// servers we hit (Python's BaseHTTPRequestHandler being the original
// trigger; github releases via the rolling-main 302 chain were the
// most recent). The body shape we need -- HTTPS via WiFiClientSecure
// + a hand-rolled HTTP/1.1 parser + manual redirect-following + a
// real timeout -- is not large, and getting it right once and
// reusing it everywhere is preferable to two parallel HTTP code
// paths drifting out of sync.
//
// Thread / stack notes:
//   - Calls are blocking. fetch_buffered/fetch_streaming sit on the
//     calling task until the response is fully read or aborted.
//   - The body buffer (buffered mode) is heap-allocated in PSRAM;
//     so are the URL parse buffers. Internal RAM is the system's
//     tightest resource, so we keep allocation pressure off it.
//   - Stack footprint per call is small (a few hundred bytes plus
//     the WiFiClient object) -- intended to run on tasks with
//     ~5 KiB stacks (e.g. ota_pull) without trouble.

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

namespace http_client {

enum Method {
    METHOD_GET    = 0,
    METHOD_POST   = 1,
    METHOD_PUT    = 2,
    METHOD_DELETE = 3,
    METHOD_PATCH  = 4,
    METHOD_HEAD   = 5,
};

// Caps that match what the rest of the codebase historically used.
// Bumped from earlier internal constants because github releases
// emit signed redirect URLs ~900 chars long and CSP headers ~4 KiB.
constexpr size_t MAX_URL_LEN     = 2048;
constexpr size_t MAX_HEADERS     = 16;
constexpr size_t MAX_HEADER_LEN  = 1024;
constexpr size_t MAX_HOST_LEN    = 256;
constexpr int    MAX_REDIRECTS   = 5;

// One header pair as caller-owned C strings. Used both ways: caller
// supplies them as a request, helper writes them into a Response.
struct HeaderPair {
    char key[MAX_HEADER_LEN];
    char value[MAX_HEADER_LEN];
};

struct Request {
    const char* url        = nullptr;
    Method      method     = METHOD_GET;
    const uint8_t* body    = nullptr;
    size_t      body_len   = 0;
    // Caller-owned, parallel arrays of header keys / values. May be
    // null if header_count == 0. The helper does not retain
    // pointers past return.
    const char* const* header_keys = nullptr;
    const char* const* header_vals = nullptr;
    size_t      header_count   = 0;
    uint32_t    timeout_ms     = 15000;
    int         max_redirects  = MAX_REDIRECTS;
};

struct Response {
    bool   ok          = false;
    int    status      = 0;
    char   error[80]   = {0};        // empty on success
    HeaderPair* headers = nullptr;   // PSRAM array, header_count
                                     // entries; NULL when count==0
    size_t header_count = 0;
};

// Buffered mode result. body is PSRAM-allocated; caller must
// free() it. body_len is the bytes actually delivered (<= max_body
// asked for).
struct BufferedResult {
    Response response;
    uint8_t* body     = nullptr;
    size_t   body_len = 0;
};

// Per-chunk callback. Returning false aborts the body read; the
// helper will close the connection and return ok=false with an
// "aborted" error.
typedef bool (*OnChunk)(void* user, const uint8_t* chunk, size_t n);

// Optional "headers ready" callback fired after status + headers
// are parsed and *before* the body is read. Lets the caller call
// Update.begin() with a known content length, decide whether to
// keep going (return false to skip the body), etc.
typedef bool (*OnHeaders)(void* user, int status, long content_length,
                          const HeaderPair* headers, size_t header_count);

// Streaming-mode entry point. on_chunk is required; on_headers is
// optional (pass nullptr to ignore). Caller must free
// resp.headers via response_free.
void fetch_streaming(const Request& req,
                     OnHeaders on_headers,
                     OnChunk   on_chunk,
                     void*     user,
                     Response& resp);

// Buffered-mode convenience. Body is collected into a PSRAM buffer
// up to max_body bytes. Caller must free body and call
// response_free(response).
void fetch_buffered(const Request& req, size_t max_body,
                    BufferedResult& out);

// Free the headers array (and zero the count). Safe to call when
// resp.headers is already null.
void response_free(Response& resp);

}  // namespace http_client
