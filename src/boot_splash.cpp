#include "boot_splash.h"
#include "generated/embedded_assets.h"
#include <Preferences.h>
#include <cstdio>
#include <cstring>

namespace boot_splash {

// Logo is the 109x31 ezOS.png drawn at 2x scale = 218x62.
constexpr int kLogoNativeW = 109;
constexpr int kLogoNativeH = 31;
constexpr float kLogoScale = 2.0f;
constexpr int kLogoW = (int)(kLogoNativeW * kLogoScale);
constexpr int kLogoH = (int)(kLogoNativeH * kLogoScale);

// Progress bar geometry, measured from the bottom of the logo.
constexpr int kBarW = 180;
constexpr int kBarH = 4;
constexpr int kBarGap = 36;  // vertical gap between logo and bar

// Colors. Background matches the rest of the boot path (black).
constexpr uint16_t kBgColor = 0x0000;            // black
constexpr uint16_t kBarBgColor = 0x2104;         // very dark gray
constexpr uint16_t kBarFgColor = 0x07E0;         // green (matches Colors::FOREGROUND)
constexpr uint16_t kVersionColor = 0x5AAB;       // dim gray-green, less prominent than logo

static int s_completed = 0;
static int s_barX = 0;
static int s_barY = 0;

// Read the user's selected OTA channel from NVS. The Lua side stores
// this as an int under the "lua_storage" namespace (see
// lua/screens/settings/firmware_update.lua); index into CHANNELS where
// 1 = "main", 2 = "test". We re-implement the lookup here in C++ so the
// splash can paint the channel suffix before Lua is up.
static const char* otaChannelLabel() {
    Preferences p;
    if (!p.begin("lua_storage", true)) {
        return "main";  // namespace not yet created -> first boot, default channel
    }
    int idx = p.getInt("ota_channel", 1);
    p.end();
    switch (idx) {
        case 2:  return "test";
        case 1:
        default: return "main";
    }
}

// Build "v<version>" or "v<version> (<channel>)" into `out`.
// The font set only covers printable ASCII, so we keep the format ASCII-only.
static void formatVersionLine(char* out, size_t outLen) {
    const char* channel = otaChannelLabel();
    if (std::strcmp(channel, "main") == 0) {
        std::snprintf(out, outLen, "v%s", EZOS_VERSION);
    } else {
        std::snprintf(out, outLen, "v%s (%s)", EZOS_VERSION, channel);
    }
}

static void drawProgress(Display* display) {
    int filled = (kBarW * s_completed) / kTotalSteps;
    if (filled > kBarW) filled = kBarW;
    // Draw the filled portion only; the background bar was drawn once
    // in show() and never gets clobbered.
    if (filled > 0) {
        display->fillRect(s_barX, s_barY, filled, kBarH, kBarFgColor);
    }
}

void show(Display* display) {
    if (!display) return;

    const int sw = display->getWidth();
    const int sh = display->getHeight();

    // Clear the framebuffer to black so the logo sits on a clean
    // background regardless of whatever junk was in memory at power-on.
    display->fillRect(0, 0, sw, sh, kBgColor);

    // Center the logo horizontally; place it slightly above center
    // vertically so the progress bar has room beneath without crowding.
    const int logoX = (sw - kLogoW) / 2;
    const int logoY = (sh - kLogoH - kBarGap - kBarH) / 2;

    // Decode the PNG straight into the display's off-screen buffer.
    // LovyanGFX's drawPng handles RGBA PNGs and respects alpha by
    // blending against whatever is already in the buffer (which we
    // just cleared to black, matching the logo's intended background).
    LGFX_Sprite& buf = display->getBuffer();
    buf.drawPng(kBootLogoPng, kBootLogoPngLen,
                logoX, logoY,
                kLogoW, kLogoH,
                0, 0,
                kLogoScale, kLogoScale);

    // Version line, centered between the logo and the progress bar.
    // Drawn before the progress bar so it shares the same kBarGap budget
    // (36 px) without nudging anything else around.
    char versionLine[48];
    formatVersionLine(versionLine, sizeof(versionLine));
    FontSize prevFont = display->getFontSize();
    display->setFontSize(FontSize::SMALL_AA);
    const int textW = display->textWidth(versionLine);
    const int textH = display->getFontHeight();
    const int textX = (sw - textW) / 2;
    const int textY = logoY + kLogoH + (kBarGap - textH) / 2;
    display->drawText(textX, textY, versionLine, kVersionColor);
    display->setFontSize(prevFont);

    // Progress bar background. Drawn once; step() only repaints the
    // filled portion so we don't have to rebuild the whole splash.
    s_barX = (sw - kBarW) / 2;
    s_barY = logoY + kLogoH + kBarGap;
    display->fillRect(s_barX, s_barY, kBarW, kBarH, kBarBgColor);

    s_completed = 0;
    drawProgress(display);
    display->flush();
}

void step(Display* display) {
    if (!display) return;
    if (s_completed >= kTotalSteps) return;
    s_completed++;
    drawProgress(display);
    display->flush();
}

}  // namespace boot_splash
