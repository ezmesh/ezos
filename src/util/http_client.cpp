// Outbound HTTP(S) implementation. See http_client.h for rationale.

#include "http_client.h"

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiClientSecure.h>
#include <esp_heap_caps.h>
#include <string.h>
#include <stdlib.h>

namespace http_client {

// ---------------------------------------------------------------------------
// URL parsing
// ---------------------------------------------------------------------------

static bool parseUrl(const char* url, bool& isHttps,
                     char* host, size_t hostLen,
                     int& port,
                     char* path, size_t pathLen) {
    if (strncmp(url, "https://", 8) == 0) {
        isHttps = true;
        url += 8;
    } else if (strncmp(url, "http://", 7) == 0) {
        isHttps = false;
        url += 7;
    } else {
        return false;
    }
    port = isHttps ? 443 : 80;

    const char* slash = strchr(url, '/');
    size_t hostPart = slash ? (size_t)(slash - url) : strlen(url);
    if (hostPart == 0 || hostPart >= hostLen) return false;

    // host[:port] up to the first '/'
    const char* colon = (const char*)memchr(url, ':', hostPart);
    if (colon) {
        size_t hLen = colon - url;
        if (hLen >= hostLen) return false;
        memcpy(host, url, hLen);
        host[hLen] = '\0';
        port = atoi(colon + 1);
        if (port <= 0 || port > 65535) return false;
    } else {
        memcpy(host, url, hostPart);
        host[hostPart] = '\0';
    }

    if (slash) {
        size_t pLen = strlen(slash);
        if (pLen >= pathLen) return false;
        memcpy(path, slash, pLen);
        path[pLen] = '\0';
    } else {
        path[0] = '/';
        path[1] = '\0';
    }
    return true;
}

// ---------------------------------------------------------------------------
// Wire helpers
// ---------------------------------------------------------------------------

// Per-line cap for status + header lines. github's content-security-
// policy header alone is ~4.5 KiB; truncation at the previous 1 KiB
// silently broke header parsing on real servers. 8 KiB has comfortable
// margin without ballooning Arduino String's growth cost.
static constexpr size_t MAX_LINE_LEN = 8192;

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
            if (out.length() > MAX_LINE_LEN) return false;
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
        if (millis() > deadline_ms) break;
        int avail = client->available();
        if (avail <= 0) {
            if (!client->connected() && !client->available()) break;
            delay(2);
            continue;
        }
        int want = wanted - got;
        int n = client->read((uint8_t*)buf + got, want);
        if (n > 0) got += n;
    }
    return got;
}

static const char* methodName(Method m) {
    switch (m) {
        case METHOD_POST:   return "POST";
        case METHOD_PUT:    return "PUT";
        case METHOD_DELETE: return "DELETE";
        case METHOD_PATCH:  return "PATCH";
        case METHOD_HEAD:   return "HEAD";
        default:            return "GET";
    }
}

// ---------------------------------------------------------------------------
// Buffered chunk sink
// ---------------------------------------------------------------------------
//
// Implements OnChunk by appending to a heap-allocated PSRAM buffer
// up to max_body bytes. fetch_buffered uses this to provide the
// "give me the whole thing" convenience without duplicating the
// streaming code path.

struct BufferedSink {
    uint8_t* body;
    size_t   bodyLen;
    size_t   cap;
    size_t   maxBody;
};

static bool bufferedOnChunk(void* user, const uint8_t* chunk, size_t n) {
    BufferedSink* s = (BufferedSink*)user;
    if (s->bodyLen + n > s->maxBody) {
        size_t fit = s->maxBody - s->bodyLen;
        if (fit == 0) return false;
        n = fit;
    }
    if (s->bodyLen + n > s->cap) {
        size_t newCap = s->cap == 0 ? 4096 : s->cap;
        while (newCap < s->bodyLen + n) {
            newCap *= 2;
            if (newCap > s->maxBody + 1) { newCap = s->maxBody + 1; break; }
        }
        uint8_t* nb = (uint8_t*)heap_caps_malloc(newCap, MALLOC_CAP_SPIRAM);
        if (!nb) nb = (uint8_t*)malloc(newCap);
        if (!nb) return false;
        if (s->body) {
            memcpy(nb, s->body, s->bodyLen);
            free(s->body);
        }
        s->body = nb;
        s->cap  = newCap;
    }
    memcpy(s->body + s->bodyLen, chunk, n);
    s->bodyLen += n;
    return true;
}

// ---------------------------------------------------------------------------
// Header storage
// ---------------------------------------------------------------------------

static HeaderPair* allocHeaders(size_t count) {
    if (count == 0) return nullptr;
    size_t bytes = sizeof(HeaderPair) * count;
    auto* p = (HeaderPair*)heap_caps_calloc(1, bytes, MALLOC_CAP_SPIRAM);
    if (!p) p = (HeaderPair*)calloc(1, bytes);
    return p;
}

void response_free(Response& resp) {
    if (resp.headers) {
        free(resp.headers);
        resp.headers = nullptr;
    }
    resp.header_count = 0;
}

// ---------------------------------------------------------------------------
// Core: one request through to body completion (with redirect loop)
// ---------------------------------------------------------------------------

static void setError(Response& resp, const char* msg) {
    strncpy(resp.error, msg, sizeof(resp.error) - 1);
    resp.error[sizeof(resp.error) - 1] = '\0';
    resp.ok = false;
}

void fetch_streaming(const Request& req,
                     OnHeaders on_headers,
                     OnChunk   on_chunk,
                     void*     user,
                     Response& resp) {
    // Output state. Headers populated each iteration; on a
    // successful (non-redirect) response we keep them; on redirect
    // we discard and retry against the new URL.
    resp = Response{};
    if (!req.url) { setError(resp, "no url"); return; }
    if (!on_chunk) { setError(resp, "no on_chunk"); return; }
    if (WiFi.status() != WL_CONNECTED) {
        setError(resp, "WiFi not connected");
        return;
    }

    // Working buffers in PSRAM. URL/host get rewritten across
    // redirect hops; allocate once, reuse.
    char* curUrl = (char*)heap_caps_calloc(1, MAX_URL_LEN, MALLOC_CAP_SPIRAM);
    if (!curUrl) curUrl = (char*)calloc(1, MAX_URL_LEN);
    char* host = (char*)heap_caps_calloc(1, MAX_HOST_LEN, MALLOC_CAP_SPIRAM);
    if (!host) host = (char*)calloc(1, MAX_HOST_LEN);
    char* path = (char*)heap_caps_calloc(1, MAX_URL_LEN, MALLOC_CAP_SPIRAM);
    if (!path) path = (char*)calloc(1, MAX_URL_LEN);

    if (!curUrl || !host || !path) {
        setError(resp, "psram alloc failed");
        if (curUrl) free(curUrl);
        if (host)   free(host);
        if (path)   free(path);
        return;
    }
    strncpy(curUrl, req.url, MAX_URL_LEN - 1);
    curUrl[MAX_URL_LEN - 1] = '\0';

    WiFiClient* client = nullptr;
    int redirectsLeft = req.max_redirects > 0 ? req.max_redirects : 0;
    bool aborted_by_caller = false;

    while (true) {
        // Reset the response for this attempt. On a successful
        // non-redirect we keep these and exit the loop; on redirect
        // they're overwritten next iteration.
        response_free(resp);
        resp.ok      = false;
        resp.status  = 0;
        resp.error[0] = '\0';

        bool isHttps = false;
        int  port = 0;
        if (!parseUrl(curUrl, isHttps, host, MAX_HOST_LEN, port,
                      path, MAX_URL_LEN)) {
            setError(resp, "bad URL");
            goto cleanup;
        }
        Serial.printf("[hc] url parsed host=%s port=%d https=%d\n",
                      host, port, (int)isHttps);

        if (isHttps) {
            Serial.println("[hc] new WiFiClientSecure...");
            auto* s = new WiFiClientSecure();
            Serial.println("[hc] setInsecure...");
            s->setInsecure();
            client = s;
        } else {
            client = new WiFiClient();
        }

        {
            uint32_t timeout = req.timeout_ms > 0 ? req.timeout_ms : 10000;
            client->setTimeout(timeout / 1000 + 1);
            uint32_t deadline = millis() + timeout;

            Serial.printf("[hc] connecting to %s:%d (timeout=%ums)...\n",
                          host, port, (unsigned)timeout);
            if (!client->connect(host, port)) {
                Serial.println("[hc] connect FAILED");
                setError(resp, "connect failed");
                goto cleanup;
            }

            // ----- Send request line + headers + optional body ----
            String headBuf = String(methodName(req.method)) + " " + path + " HTTP/1.1\r\n";
            headBuf += "Host: ";
            headBuf += host;
            if ((isHttps && port != 443) || (!isHttps && port != 80)) {
                headBuf += ":";
                headBuf += String(port);
            }
            headBuf += "\r\nConnection: close\r\n";

            bool sawCType = false, sawCLen = false;
            for (size_t i = 0; i < req.header_count; i++) {
                if (!req.header_keys[i] || !req.header_vals[i]) continue;
                headBuf += req.header_keys[i];
                headBuf += ": ";
                headBuf += req.header_vals[i];
                headBuf += "\r\n";
                if (strcasecmp(req.header_keys[i], "Content-Type")   == 0) sawCType = true;
                if (strcasecmp(req.header_keys[i], "Content-Length") == 0) sawCLen  = true;
            }

            bool hasBody = req.body && req.body_len > 0 &&
                           (req.method == METHOD_POST  ||
                            req.method == METHOD_PUT   ||
                            req.method == METHOD_PATCH ||
                            req.method == METHOD_DELETE);
            if (hasBody && !sawCLen) {
                headBuf += "Content-Length: ";
                headBuf += String((unsigned)req.body_len);
                headBuf += "\r\n";
            }
            if (hasBody && !sawCType) {
                headBuf += "Content-Type: application/octet-stream\r\n";
            }
            headBuf += "\r\n";
            Serial.println("[hc] connected; sending request...");
            client->print(headBuf);
            if (hasBody) client->write(req.body, req.body_len);
            Serial.println("[hc] request sent; reading status...");

            // ----- Read status line --------------------------------
            String statusLine;
            if (!readLine(client, statusLine, deadline)) {
                setError(resp, "no status line");
                goto cleanup;
            }
            int sp1 = statusLine.indexOf(' ');
            if (sp1 < 0) {
                setError(resp, "malformed status");
                goto cleanup;
            }
            resp.status = atoi(statusLine.c_str() + sp1 + 1);

            // ----- Read headers ------------------------------------
            long contentLength = -1;
            bool chunked = false;
            char* locationHdr = nullptr;
            // Collect headers into a temporary PSRAM-allocated array
            // (16 entries x 2 KiB strings = 32 KiB) and copy into
            // resp.headers in one shot at the end. On-stack
            // allocation would blow every plausible task budget --
            // the AsyncIO worker has a 12 KiB stack.
            HeaderPair* tmp = (HeaderPair*)heap_caps_calloc(
                MAX_HEADERS, sizeof(HeaderPair), MALLOC_CAP_SPIRAM);
            if (!tmp) tmp = (HeaderPair*)calloc(MAX_HEADERS, sizeof(HeaderPair));
            if (!tmp) {
                setError(resp, "psram alloc failed (headers)");
                if (locationHdr) free(locationHdr);
                goto cleanup;
            }
            size_t tmpCount = 0;

            while (true) {
                String line;
                if (!readLine(client, line, deadline)) {
                    setError(resp, "header read timeout");
                    if (locationHdr) free(locationHdr);
                    free(tmp);
                    goto cleanup;
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
                } else if (key.equalsIgnoreCase("Location")) {
                    if (locationHdr) free(locationHdr);
                    locationHdr = strdup(val.c_str());
                }
                if (tmpCount < MAX_HEADERS) {
                    strncpy(tmp[tmpCount].key, key.c_str(), MAX_HEADER_LEN - 1);
                    tmp[tmpCount].key[MAX_HEADER_LEN - 1] = '\0';
                    strncpy(tmp[tmpCount].value, val.c_str(), MAX_HEADER_LEN - 1);
                    tmp[tmpCount].value[MAX_HEADER_LEN - 1] = '\0';
                    tmpCount++;
                }
            }

            // ----- Redirect handling -------------------------------
            bool is3xx = (resp.status == 301 || resp.status == 302 ||
                          resp.status == 303 || resp.status == 307 ||
                          resp.status == 308);
            if (is3xx && redirectsLeft > 0 && locationHdr &&
                strlen(locationHdr) < MAX_URL_LEN) {
                if (contentLength > 0) {
                    char dump[512];
                    long left = contentLength;
                    while (left > 0 && millis() <= deadline) {
                        int n = readBytes(client, dump,
                                          left > (long)sizeof(dump) ? sizeof(dump) : left,
                                          deadline);
                        if (n <= 0) break;
                        left -= n;
                    }
                }
                client->stop();
                delete client;
                client = nullptr;
                strncpy(curUrl, locationHdr, MAX_URL_LEN - 1);
                curUrl[MAX_URL_LEN - 1] = '\0';
                free(locationHdr);
                free(tmp);
                redirectsLeft--;
                continue;  // retry with new URL
            }
            if (locationHdr) free(locationHdr);

            // Promote tmp headers into resp.headers (PSRAM). The
            // temp array is freed unconditionally afterwards -- the
            // body loop below doesn't reference it.
            if (tmpCount > 0) {
                resp.headers = allocHeaders(tmpCount);
                if (resp.headers) {
                    memcpy(resp.headers, tmp, sizeof(HeaderPair) * tmpCount);
                    resp.header_count = tmpCount;
                }
            }
            free(tmp);
            tmp = nullptr;

            // ----- on_headers callback (optional) ------------------
            if (on_headers && req.method != METHOD_HEAD) {
                if (!on_headers(user, resp.status, contentLength,
                                resp.headers, resp.header_count)) {
                    aborted_by_caller = true;
                    setError(resp, "aborted by caller");
                    goto cleanup;
                }
            }

            // ----- Stream body to caller ---------------------------
            if (req.method != METHOD_HEAD) {
                bool ok = true;
                if (chunked) {
                    while (ok) {
                        String sizeLine;
                        if (!readLine(client, sizeLine, deadline)) { ok = false; break; }
                        long chunkSize = strtol(sizeLine.c_str(), nullptr, 16);
                        if (chunkSize <= 0) break;
                        // Read chunkSize bytes in CHUNK_BUF_LEN-sized
                        // pieces, deliver each to the user's callback.
                        constexpr int CHUNK_BUF_LEN = 2048;
                        uint8_t* cbuf = (uint8_t*)heap_caps_malloc(CHUNK_BUF_LEN, MALLOC_CAP_SPIRAM);
                        if (!cbuf) cbuf = (uint8_t*)malloc(CHUNK_BUF_LEN);
                        if (!cbuf) { ok = false; break; }
                        long left = chunkSize;
                        while (left > 0 && ok) {
                            int want = left > CHUNK_BUF_LEN ? CHUNK_BUF_LEN : left;
                            int got = readBytes(client, (char*)cbuf, want, deadline);
                            if (got <= 0) { ok = false; break; }
                            if (!on_chunk(user, cbuf, (size_t)got)) {
                                aborted_by_caller = true;
                                ok = false;
                                break;
                            }
                            left -= got;
                        }
                        free(cbuf);
                        if (!ok) break;
                        String trailing;
                        readLine(client, trailing, deadline);  // consume CRLF
                    }
                } else if (contentLength > 0) {
                    constexpr int CHUNK_BUF_LEN = 2048;
                    uint8_t* cbuf = (uint8_t*)heap_caps_malloc(CHUNK_BUF_LEN, MALLOC_CAP_SPIRAM);
                    if (!cbuf) cbuf = (uint8_t*)malloc(CHUNK_BUF_LEN);
                    if (cbuf) {
                        long left = contentLength;
                        while (left > 0 && ok) {
                            int want = left > CHUNK_BUF_LEN ? CHUNK_BUF_LEN : left;
                            int got = readBytes(client, (char*)cbuf, want, deadline);
                            if (got <= 0) { ok = false; break; }
                            if (!on_chunk(user, cbuf, (size_t)got)) {
                                aborted_by_caller = true;
                                ok = false;
                                break;
                            }
                            left -= got;
                            // Yield 1 tick (~1 ms) per chunk so IDLE
                            // can feed the task watchdog. delay(0)
                            // is `vTaskDelay(0)` -- a no-op that
                            // doesn't actually yield the CPU; on a
                            // long firmware download (~1200 chunks
                            // for 2.4 MB) we'd exhaust the 5 s
                            // task_wdt before the body finishes.
                            // 1 ms x 1200 = ~1.2 s of overhead total,
                            // negligible against a 30 s+ download.
                            vTaskDelay(1);
                        }
                        free(cbuf);
                    } else {
                        ok = false;
                    }
                } else {
                    // No length header -- read until close.
                    constexpr int CHUNK_BUF_LEN = 2048;
                    uint8_t* cbuf = (uint8_t*)heap_caps_malloc(CHUNK_BUF_LEN, MALLOC_CAP_SPIRAM);
                    if (!cbuf) cbuf = (uint8_t*)malloc(CHUNK_BUF_LEN);
                    if (cbuf) {
                        while (ok) {
                            if (!client->connected() && !client->available()) break;
                            if (millis() > deadline) { ok = false; break; }
                            int avail = client->available();
                            if (avail <= 0) { delay(5); continue; }
                            int want = avail > CHUNK_BUF_LEN ? CHUNK_BUF_LEN : avail;
                            int got = client->read(cbuf, want);
                            if (got <= 0) continue;
                            if (!on_chunk(user, cbuf, (size_t)got)) {
                                aborted_by_caller = true;
                                ok = false;
                                break;
                            }
                        }
                        free(cbuf);
                    } else {
                        ok = false;
                    }
                }
                if (!ok && !aborted_by_caller) {
                    setError(resp, "body read failed");
                    goto cleanup;
                }
                if (aborted_by_caller) {
                    setError(resp, "aborted by caller");
                    goto cleanup;
                }
            }

            resp.ok = true;
            break;  // exit redirect loop on success
        }
    }

cleanup:
    if (client) { client->stop(); delete client; }
    free(curUrl);
    free(host);
    free(path);
}

void fetch_buffered(const Request& req, size_t max_body,
                    BufferedResult& out) {
    out = BufferedResult{};
    BufferedSink sink = {nullptr, 0, 0, max_body};
    fetch_streaming(req, /*on_headers*/ nullptr, bufferedOnChunk,
                    &sink, out.response);
    out.body = sink.body;
    out.body_len = sink.bodyLen;
    if (out.body && out.body_len < (out.body == nullptr ? 0 : sink.cap)) {
        // 0-terminate for callers that treat the body as a C string.
        // Safe: bufferedOnChunk leaves room for the byte by capping
        // max_body+1 in the cap math.
        out.body[out.body_len] = '\0';
    }
}

}  // namespace http_client
