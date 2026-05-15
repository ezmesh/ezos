#pragma once

#include <cstddef>
#include <cstdint>

// Boot profile ring buffer.
//
// Fires from setup() (Core 1, before Lua is alive) and from Lua during
// boot.lua (post-service-init marks via ez.bench.mark). Both paths drop
// into bootProfileMark which is interrupt-safe: a portMUX-protected copy
// of the name + millis() into a fixed-size array. The array is small,
// stays in internal RAM, and survives until the next reset.
//
// Out-of-space is silent: once the array is full, additional marks are
// dropped on the floor rather than evicting older entries. The first
// entries are the most valuable (they're the ones an external observer
// is trying to correlate with cold-boot symptoms), so prefer to lose
// late marks over early ones.

struct BootPhase {
    char name[32];     // 31 chars + NUL
    uint32_t millis;   // millis() at the time of the mark
};

constexpr size_t BOOT_PROFILE_CAPACITY = 64;

// Record a boot-profile marker. `name` is copied (truncated to 31 chars +
// NUL) so the caller's buffer can be transient. Safe to call from any
// task / context. Returns silently if the ring is full.
void bootProfileMark(const char* name);

// Returns the recorded boot-profile entries. `*outCount` receives the
// number of valid entries and the returned pointer is a pointer to the
// first entry. Entries are ordered by call time (entry 0 is the first
// mark). The returned pointer is into the live ring buffer -- valid for
// reading immediately, but a concurrent bootProfileMark may append more.
// Callers should treat the snapshot as a momentary view.
const BootPhase* bootProfileEntries(size_t* outCount);
