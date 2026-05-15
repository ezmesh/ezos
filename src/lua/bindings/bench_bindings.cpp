// ez.bench.* -- micro-benchmark + boot profiling harness used by the
// on-device test suite (tools/remote/tests/test_benchmarks.py and
// test_boot_profile.py). Same trust model as ez.debug.* -- test-only
// scaffolding, not part of the public Lua API.
//
// Scenarios are registered in a static array below. Each scenario's
// `run()` does ONE iteration; the framework wraps it in a loop, samples
// micros() before and after each call, and computes summary stats
// (min/max/mean/p50/p95) plus a full samples array for the caller.
//
// This first cut ships 4 crypto/hash scenarios. Issue #62 enumerates 12
// total; the rest (map.tile_inflate, display.draw_text, display.full_flush,
// storage.sd_read_4k, storage.sd_write_4k, mesh.packet_encode,
// async.file_read_64k, markdown.render, lua.gc_step) are deferred -- they
// have side effects or fixture requirements (SD card present, map archive
// staged, etc.) that would balloon the diff. Adding more is a one-line
// Scenario struct + a single static `run` function.

// @module ez.bench
// @brief Test-only micro-benchmark and boot profiling harness.
// @description
//   Runs registered scenarios under timing (micros()) and reports
//   min/max/mean/p50/p95 plus the raw samples. Boot profile markers are
//   recorded by bootProfileMark() in setup() and by ez.bench.mark() from
//   Lua; ez.bench.boot_profile() returns the timeline. Intended for use
//   by tools/remote/tests only -- same trust model as ez.debug.*.
// @end

#include "bench_bindings.h"
#include "../lua_bindings.h"
#include "../../boot_profile.h"

#include <Arduino.h>
#include <esp_heap_caps.h>

#include <cstdlib>
#include <cstring>

#include "mbedtls/aes.h"
#include "mbedtls/sha256.h"

#include <Ed25519.h>

extern "C" {
#include <lualib.h>
#include <lauxlib.h>
}

// ---------------------------------------------------------------------------
// Scenario fixtures (one-time setup, reused across iterations)
// ---------------------------------------------------------------------------

namespace {

// Ed25519 fixtures. Seeded lazily so device-without-mesh builds still
// produce valid keypairs without depending on global construction order.
struct Ed25519Fixture {
    bool initialized = false;
    uint8_t publicKey[32];
    uint8_t privateKey[32];  // rweather/Crypto API takes a 32-byte seed
    uint8_t message[64];
    uint8_t signature[64];
};

Ed25519Fixture g_ed25519;

void ensureEd25519Fixture() {
    if (g_ed25519.initialized) return;
    // Deterministic message so verify benchmarks always have a valid
    // signature to check (we sign it once during setup).
    for (size_t i = 0; i < sizeof(g_ed25519.message); ++i) {
        g_ed25519.message[i] = (uint8_t)(i * 7 + 1);
    }
    // Generate a dedicated keypair for the benchmark so we don't depend
    // on Identity's internal 32+32 private key layout (Identity's sign
    // API doesn't expose the raw 32-byte seed that Ed25519::sign wants).
    // Esp-random under the hood -- fine for non-replay-sensitive bench
    // fixture material.
    Ed25519::generatePrivateKey(g_ed25519.privateKey);
    Ed25519::derivePublicKey(g_ed25519.publicKey, g_ed25519.privateKey);
    Ed25519::sign(g_ed25519.signature, g_ed25519.privateKey, g_ed25519.publicKey,
                  g_ed25519.message, sizeof(g_ed25519.message));
    g_ed25519.initialized = true;
}

// AES-128-ECB fixture. 16-byte key, 256-byte ciphertext (16 blocks).
struct AesFixture {
    bool initialized = false;
    mbedtls_aes_context dec_ctx;
    uint8_t ciphertext[256];
    uint8_t plaintext[256];
};

AesFixture g_aes;

void ensureAesFixture() {
    if (g_aes.initialized) return;
    // Deterministic key + plaintext, then encrypt once so we have valid
    // ciphertext to decrypt repeatedly. The benchmark itself only
    // measures the decrypt path -- encrypt + setkey land in setup.
    uint8_t key[16];
    for (size_t i = 0; i < 16; ++i) key[i] = (uint8_t)(0xA0 + i);
    uint8_t pt[256];
    for (size_t i = 0; i < sizeof(pt); ++i) pt[i] = (uint8_t)(i & 0xFF);

    mbedtls_aes_context enc;
    mbedtls_aes_init(&enc);
    mbedtls_aes_setkey_enc(&enc, key, 128);
    for (size_t i = 0; i < sizeof(pt); i += 16) {
        mbedtls_aes_crypt_ecb(&enc, MBEDTLS_AES_ENCRYPT, pt + i, g_aes.ciphertext + i);
    }
    mbedtls_aes_free(&enc);

    mbedtls_aes_init(&g_aes.dec_ctx);
    mbedtls_aes_setkey_dec(&g_aes.dec_ctx, key, 128);
    g_aes.initialized = true;
}

// SHA-256 fixture. 1 KiB of deterministic data.
struct ShaFixture {
    bool initialized = false;
    uint8_t buffer[1024];
};

ShaFixture g_sha;

void ensureShaFixture() {
    if (g_sha.initialized) return;
    for (size_t i = 0; i < sizeof(g_sha.buffer); ++i) {
        g_sha.buffer[i] = (uint8_t)((i * 31 + 7) & 0xFF);
    }
    g_sha.initialized = true;
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

void scenario_ed25519_sign() {
    uint8_t sig[64];
    Ed25519::sign(sig, g_ed25519.privateKey, g_ed25519.publicKey,
                  g_ed25519.message, sizeof(g_ed25519.message));
    // Force the compiler to keep the sig; volatile read.
    asm volatile("" :: "r"(sig[0]));
}

void scenario_ed25519_verify() {
    bool ok = Ed25519::verify(g_ed25519.signature, g_ed25519.publicKey,
                              g_ed25519.message, sizeof(g_ed25519.message));
    asm volatile("" :: "r"(ok));
}

void scenario_aes_decrypt() {
    uint8_t out[256];
    for (size_t i = 0; i < sizeof(g_aes.ciphertext); i += 16) {
        mbedtls_aes_crypt_ecb(&g_aes.dec_ctx, MBEDTLS_AES_DECRYPT,
                              g_aes.ciphertext + i, out + i);
    }
    asm volatile("" :: "r"(out[0]));
}

void scenario_sha256_1k() {
    uint8_t hash[32];
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, g_sha.buffer, sizeof(g_sha.buffer));
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);
    asm volatile("" :: "r"(hash[0]));
}

struct Scenario {
    const char* name;
    const char* description;
    void (*setup)();
    void (*run)();
};

const Scenario kScenarios[] = {
    {"crypto.ed25519_sign",      "Ed25519 sign of a 64-byte payload",   ensureEd25519Fixture, scenario_ed25519_sign},
    {"crypto.ed25519_verify",    "Ed25519 verify of a 64-byte payload", ensureEd25519Fixture, scenario_ed25519_verify},
    {"crypto.aes_decrypt_128_ecb", "AES-128-ECB decrypt of 256 bytes",  ensureAesFixture,     scenario_aes_decrypt},
    {"crypto.sha256_1k",         "SHA-256 of a 1 KiB buffer",           ensureShaFixture,     scenario_sha256_1k},
};
const size_t kScenarioCount = sizeof(kScenarios) / sizeof(kScenarios[0]);

const Scenario* findScenario(const char* name) {
    for (size_t i = 0; i < kScenarioCount; ++i) {
        if (strcmp(kScenarios[i].name, name) == 0) return &kScenarios[i];
    }
    return nullptr;
}

// Lua-style comparator for qsort'ing samples.
int cmp_u32(const void* a, const void* b) {
    uint32_t av = *(const uint32_t*)a;
    uint32_t bv = *(const uint32_t*)b;
    if (av < bv) return -1;
    if (av > bv) return 1;
    return 0;
}

// Run a scenario `iterations` times, write summary stats and samples to
// the table on top of the Lua stack. Returns nothing (assumes a table
// is already on the stack at the top -- caller created it).
// On allocation failure, sets fields to 0 / empty.
void runScenarioToTable(lua_State* L, const Scenario& s, int iterations) {
    if (iterations < 1) iterations = 1;
    if (iterations > 1000) iterations = 1000;

    // Heap-alloc the samples buffer -- ESP-IDF stacks are tight,
    // especially for the Lua coroutine that called us. 1000 * 4 bytes =
    // 4 KiB worst case; pull it from PSRAM where the rest of Lua lives.
    uint32_t* samples = (uint32_t*)heap_caps_malloc(
        sizeof(uint32_t) * iterations,
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (samples == nullptr) {
        samples = (uint32_t*)heap_caps_malloc(sizeof(uint32_t) * iterations,
                                              MALLOC_CAP_8BIT);
    }
    if (samples == nullptr) {
        lua_pushinteger(L, 0); lua_setfield(L, -2, "min_us");
        lua_pushinteger(L, 0); lua_setfield(L, -2, "max_us");
        lua_pushinteger(L, 0); lua_setfield(L, -2, "mean_us");
        lua_pushinteger(L, 0); lua_setfield(L, -2, "p50_us");
        lua_pushinteger(L, 0); lua_setfield(L, -2, "p95_us");
        lua_pushinteger(L, 0); lua_setfield(L, -2, "iterations");
        lua_newtable(L); lua_setfield(L, -2, "samples");
        lua_pushstring(L, "alloc failed"); lua_setfield(L, -2, "error");
        return;
    }

    if (s.setup) s.setup();

    // Pre-touch the scenario once to warm caches / fixture lazy-init so
    // the first measured iteration isn't dominated by setup tail.
    s.run();

    for (int i = 0; i < iterations; ++i) {
        uint32_t t0 = micros();
        s.run();
        uint32_t t1 = micros();
        // micros() wraps every ~71 minutes; subtracting unsigned is
        // wrap-safe.
        samples[i] = t1 - t0;
    }

    // Stats. min / max / mean computed before sort to keep samples in
    // their original (chronological) order for the caller's "samples"
    // field. Then sort a copy for percentile.
    uint64_t sum = 0;
    uint32_t mn = samples[0];
    uint32_t mx = samples[0];
    for (int i = 0; i < iterations; ++i) {
        sum += samples[i];
        if (samples[i] < mn) mn = samples[i];
        if (samples[i] > mx) mx = samples[i];
    }
    uint32_t mean = (uint32_t)(sum / iterations);

    // Sort a copy for percentiles. Use a separate buffer so we can hand
    // back the original chronological array.
    uint32_t* sorted = (uint32_t*)heap_caps_malloc(
        sizeof(uint32_t) * iterations,
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (sorted == nullptr) {
        sorted = (uint32_t*)heap_caps_malloc(sizeof(uint32_t) * iterations,
                                             MALLOC_CAP_8BIT);
    }
    uint32_t p50 = mean;
    uint32_t p95 = mx;
    if (sorted != nullptr) {
        memcpy(sorted, samples, sizeof(uint32_t) * iterations);
        qsort(sorted, iterations, sizeof(uint32_t), cmp_u32);
        // Nearest-rank percentile: ceil(p/100 * N) - 1 (0-indexed).
        int idx50 = (int)(((50 * iterations) + 99) / 100) - 1;
        int idx95 = (int)(((95 * iterations) + 99) / 100) - 1;
        if (idx50 < 0) idx50 = 0;
        if (idx95 < 0) idx95 = 0;
        if (idx50 >= iterations) idx50 = iterations - 1;
        if (idx95 >= iterations) idx95 = iterations - 1;
        p50 = sorted[idx50];
        p95 = sorted[idx95];
        heap_caps_free(sorted);
    }

    lua_pushinteger(L, (lua_Integer)mn);    lua_setfield(L, -2, "min_us");
    lua_pushinteger(L, (lua_Integer)mx);    lua_setfield(L, -2, "max_us");
    lua_pushinteger(L, (lua_Integer)mean);  lua_setfield(L, -2, "mean_us");
    lua_pushinteger(L, (lua_Integer)p50);   lua_setfield(L, -2, "p50_us");
    lua_pushinteger(L, (lua_Integer)p95);   lua_setfield(L, -2, "p95_us");
    lua_pushinteger(L, (lua_Integer)iterations); lua_setfield(L, -2, "iterations");

    // samples = { ... }
    lua_newtable(L);
    for (int i = 0; i < iterations; ++i) {
        lua_pushinteger(L, (lua_Integer)samples[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "samples");

    heap_caps_free(samples);
}

}  // namespace

// ---------------------------------------------------------------------------
// Lua bindings
// ---------------------------------------------------------------------------

// @lua ez.bench.list() -> array of { name, description }
// @brief Return every registered benchmark scenario
// @description Each entry is `{ name = "<scenario>", description = "<one-line>" }`.
// Test harnesses iterate this to discover what's available without
// hard-coding the scenario list.
// @example
// for _, s in ipairs(ez.bench.list()) do
//   print(s.name, s.description)
// end
// @end
LUA_FUNCTION(l_bench_list) {
    lua_newtable(L);
    for (size_t i = 0; i < kScenarioCount; ++i) {
        lua_newtable(L);
        lua_pushstring(L, kScenarios[i].name);
        lua_setfield(L, -2, "name");
        lua_pushstring(L, kScenarios[i].description);
        lua_setfield(L, -2, "description");
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}

// @lua ez.bench.run(name, iterations?) -> { min_us, max_us, mean_us, p50_us, p95_us, samples, iterations }
// @brief Run a single scenario `iterations` times and report stats
// @description Iterations defaults to 50, clamped to [1, 1000]. Returns
// nil + "unknown scenario" on a misspelled name. `samples` is an array of
// per-iteration measurements in chronological order; percentiles are
// computed nearest-rank on a sorted copy.
// @param name  Scenario name from ez.bench.list()
// @param iterations  Number of measured runs (1..1000, default 50)
// @return Stats table, or nil + error string
// @example
// local r = ez.bench.run("crypto.sha256_1k", 100)
// print(string.format("p95=%dus mean=%dus", r.p95_us, r.mean_us))
// @end
LUA_FUNCTION(l_bench_run) {
    const char* name = luaL_checkstring(L, 1);
    int iterations = (int)luaL_optintegerdefault(L, 2, 50);
    const Scenario* s = findScenario(name);
    if (s == nullptr) {
        lua_pushnil(L);
        lua_pushfstring(L, "unknown scenario: %s", name);
        return 2;
    }
    lua_newtable(L);
    runScenarioToTable(L, *s, iterations);
    return 1;
}

// @lua ez.bench.run_all(iterations?) -> { [name] = stats, ... }
// @brief Run every registered scenario and return a name -> stats map
// @description Convenience for the test harness; equivalent to calling
// ez.bench.run(name, iterations) for each scenario.
// @param iterations  Number of measured runs per scenario (default 50)
// @return Table keyed by scenario name with per-scenario stats tables
// @example
// local all = ez.bench.run_all(50)
// for name, stats in pairs(all) do print(name, stats.p95_us) end
// @end
LUA_FUNCTION(l_bench_run_all) {
    int iterations = (int)luaL_optintegerdefault(L, 1, 50);
    lua_newtable(L);
    for (size_t i = 0; i < kScenarioCount; ++i) {
        lua_newtable(L);
        runScenarioToTable(L, kScenarios[i], iterations);
        lua_setfield(L, -2, kScenarios[i].name);
    }
    return 1;
}

// @lua ez.bench.mark(name) -> nil
// @brief Append a boot-profile marker
// @description Records the given name in the boot-profile ring buffer
// alongside the current millis(). Name is truncated to 31 chars + NUL.
// Used by lua/boot.lua to mark service-init checkpoints; available to
// other code too if you want to time something across reboot.
// @param name  Short label (truncated to 31 chars)
// @example
// ez.bench.mark("svc_contacts_done")
// @end
LUA_FUNCTION(l_bench_mark) {
    const char* name = luaL_checkstring(L, 1);
    bootProfileMark(name);
    return 0;
}

// @lua ez.bench.boot_profile() -> array of { name, millis }
// @brief Snapshot of every recorded boot-profile marker
// @description Entries are ordered by call time. The first entry is the
// earliest mark (typically `setup_start` in main.cpp). millis() values
// are uptime in milliseconds. Ring buffer is fixed at 64 entries; extras
// are silently dropped (oldest entries are the most valuable).
// @example
// for _, e in ipairs(ez.bench.boot_profile()) do
//   print(e.millis, e.name)
// end
// @end
LUA_FUNCTION(l_bench_boot_profile) {
    size_t count = 0;
    const BootPhase* entries = bootProfileEntries(&count);
    lua_newtable(L);
    for (size_t i = 0; i < count; ++i) {
        lua_newtable(L);
        lua_pushstring(L, entries[i].name);
        lua_setfield(L, -2, "name");
        lua_pushinteger(L, (lua_Integer)entries[i].millis);
        lua_setfield(L, -2, "millis");
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    return 1;
}

static const luaL_Reg bench_funcs[] = {
    {"list",         l_bench_list},
    {"run",          l_bench_run},
    {"run_all",      l_bench_run_all},
    {"mark",         l_bench_mark},
    {"boot_profile", l_bench_boot_profile},
    {nullptr, nullptr},
};

namespace bench_bindings {

void registerBindings(lua_State* L) {
    lua_register_module(L, "bench", bench_funcs);
    Serial.println("[bench_bindings] Registered ez.bench.*");
}

}  // namespace bench_bindings
