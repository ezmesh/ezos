// Route mbedtls's working allocations to PSRAM.
//
// On this build the WiFi/LWIP stacks chew through DMA-capable
// internal SRAM, leaving only ~10 KiB free at runtime. mbedtls
// needs ~30-40 KiB to negotiate a TLS handshake (cipher state,
// fragment buffers, certificate parsing) and silently fails with
// "(-32512) SSL - Memory allocation failed" -- visible in
// WiFiClientSecure as a plain "connect failed". HTTPS to
// github.com (firmware update manifest fetch) hits this.
//
// Solution: install a custom calloc/free pair that pulls from
// PSRAM (we have 7+ MiB free there). MBEDTLS_PLATFORM_MEMORY is
// already enabled in the prebuilt sdkconfig, so the hook is a
// one-line registration. The hook runs from a global ctor so it's
// in place before any TLS code runs.
//
// The free side just delegates to ::free; ESP-IDF's allocator
// inspects the pointer and dispatches to the right heap, so a
// pointer minted from PSRAM is freed correctly without us having
// to track origin.

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <esp_heap_caps.h>
#include <mbedtls/platform.h>

namespace {

void* psramCalloc(size_t nmemb, size_t size) {
    size_t bytes = nmemb * size;
    // PSRAM-first; fall back to the regular heap if PSRAM is
    // exhausted or hasn't been initialized yet (early boot path
    // before psramInit -- shouldn't happen given the constructor
    // order, but defensively handled).
    void* p = heap_caps_calloc(nmemb, size, MALLOC_CAP_SPIRAM);
    if (!p) p = ::calloc(nmemb, size);
    (void)bytes;
    return p;
}

// Run as a global constructor so the hook is in place before any
// TLS handshake is attempted. Constructor order across translation
// units is undefined, but mbedtls itself is only used after the
// arduino setup() runs the WiFi stack -- well after global ctors.
struct InstallHook {
    InstallHook() {
        mbedtls_platform_set_calloc_free(psramCalloc, ::free);
    }
};
InstallHook _install;

}  // namespace
