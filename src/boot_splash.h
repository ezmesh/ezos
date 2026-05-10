#pragma once

#include "hardware/display.h"

// Boot-time splash screen. Drawn from C++ before Lua takes over so the
// user sees the ezOS logo + a progress bar within the first ~150 ms,
// instead of staring at a black screen for the 1-3 s of hardware init
// + Lua boot. The PNG is embedded in firmware (see scripts/embed_assets.py)
// so this works before LittleFS is mounted.
namespace boot_splash {

// Total number of init steps the progress bar tracks. Keep in sync
// with the calls to `step()` in main.cpp setup() — currently:
// keyboard, touch, settings, radio, GPS, mesh, LittleFS, Lua runtime,
// boot script. show() draws the empty bar; each step() advances it
// one notch, with the final call hitting 100% just before Lua takes
// over the screen.
constexpr int kTotalSteps = 9;

// Draw the initial splash (logo + empty progress bar) and flush.
// Safe no-op if `display` is null. Call once, immediately after
// display->init() succeeds.
void show(Display* display);

// Advance the progress bar one step and flush. The caller is
// responsible for calling this exactly kTotalSteps times across the
// init sequence.
void step(Display* display);

}  // namespace boot_splash
