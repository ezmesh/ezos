// Onboard microphone capture for T-Deck Plus.
//
// The T-Deck Plus routes a MEMS mic through an Everest ES7210 ADC codec.
// The codec is I2C-controlled on the same bus as the keyboard / touch
// controller (SDA=GPIO18, SCL=GPIO8, address 0x40) and clocks an I2S
// stream out on a separate set of pins (MCLK=48, BCLK=47, LRCK=21,
// DIN=14, on I2S_NUM_1) so the speaker on I2S_NUM_0 keeps working
// untouched.
//
// API is intentionally narrow: start_recording() opens a WAV on the SD
// card and primes a background task that pumps I2S RX -> file. Caller
// gets a `MicSession*` handle back; stop_recording() finalises the WAV
// (RIFF/data chunk sizes) and tears the task down. capture_buffer() is
// for short clips that fit comfortably in RAM -- it returns the raw
// little-endian PCM as a Lua string without ever touching the SD.
//
// Why a background task instead of pumping I2S inline: SD writes can
// stall for tens of milliseconds when the FAT layer flushes, and we
// don't want the Lua main loop to block on that. The task lives in
// PSRAM-friendly heap and exits as soon as stop_recording fires.

#pragma once

#include <stdint.h>
#include <stddef.h>

namespace ezos {
namespace mic {

struct RecordOpts {
    uint32_t sample_rate;   // Hz, e.g. 16000
    uint8_t  bits;          // 16 only for now
    uint8_t  gain_db;       // 0..36 mic PGA gain
};

// Opaque to callers; defined in mic.cpp.
struct MicSession;

// Probe the codec over I2C. Safe to call before recording -- returns
// true if the ES7210 ACKs at its expected address, false otherwise
// (e.g. unpopulated board, wiring fault).
bool probe();

// Start streaming PCM to `wav_path`. Path is a real filesystem path
// (e.g. "/recordings/clip.wav" on the SD card mount). Returns the
// session handle on success, nullptr if anything failed (I2C nack,
// I2S install error, file open error). On nullptr return, no resources
// are left held -- safe to retry.
MicSession* start_recording(const char* wav_path, const RecordOpts& opts);

// Stop streaming and finalise the WAV header. After this returns the
// session handle is no longer valid. `out_bytes_written` (optional)
// gets the number of PCM bytes actually committed.
bool stop_recording(MicSession* session, uint32_t* out_bytes_written = nullptr);

// True while a session is active.
bool is_recording();

// Capture `duration_ms` of mono PCM into a freshly-allocated buffer.
// On success returns a malloc'd buffer (caller frees) and writes the
// size in bytes into *out_size. Returns nullptr on error.
int16_t* capture_buffer(uint32_t duration_ms, const RecordOpts& opts,
                        size_t* out_size);

}  // namespace mic
}  // namespace ezos
