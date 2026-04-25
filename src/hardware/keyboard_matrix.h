#pragma once

#include <cstdint>

// T-Deck / T-Deck Plus keyboard matrix layout.
//
// The I2C keyboard (ESP32-C3 at 0x55) supports a "raw matrix" mode where
// each read returns 5 bytes, one per column, with bit `row` set when
// (col, row) is pressed. This header pairs each matrix position with the
// character or special action it produces, so the host-side driver can
// do its own edge detection and modifier handling instead of relying on
// the upstream firmware's edge-triggered single-byte path (which emits
// no release events and no hold state).
//
// Source: upstream Keyboard_ESP32C3.ino, extracted 2026-04-18. Plus and
// original T-Deck share this firmware — keymap is identical.

namespace kb_matrix {

static constexpr uint8_t COLS = 5;
static constexpr uint8_t ROWS = 7;

// Base layer (no modifier).
// 0 == position is either empty or a modifier/special key — handled below.
static const char BASE[COLS][ROWS] = {
    {'q', 'w',   0, 'a',   0, ' ',   0},
    {'e', 's', 'd', 'p', 'x', 'z',   0},
    {'r', 'g', 't',   0, 'v', 'c', 'f'},
    {'u', 'h', 'y',   0, 'b', 'n', 'j'},
    {'o', 'l', 'i',   0, '$', 'm', 'k'},
};

// Symbol layer (active while Sym at (0,2) is held).
static const char SYM[COLS][ROWS] = {
    {'#', '1',   0, '*',   0,   0, '0'},
    {'2', '4', '5', '@', '8', '7',   0},
    {'3', '/', '(',   0, '?', '9', '6'},
    {'_', ':', ')',   0, '!', ',', ';'},
    {'+', '"', '-',   0,   0, '.','\''},
};

// Modifier / layer-toggle positions.
static constexpr uint8_t SYM_COL    = 0, SYM_ROW    = 2;
static constexpr uint8_t ALT_COL    = 0, ALT_ROW    = 4;
static constexpr uint8_t SHIFT1_COL = 1, SHIFT1_ROW = 6;
static constexpr uint8_t SHIFT2_COL = 2, SHIFT2_ROW = 3;

// Non-character keys (emit SpecialKey events).
static constexpr uint8_t ENTER_COL     = 3, ENTER_ROW     = 3;
static constexpr uint8_t BACKSPACE_COL = 4, BACKSPACE_ROW = 3;

inline bool isModifierPosition(uint8_t col, uint8_t row) {
    return (col == SYM_COL    && row == SYM_ROW)
        || (col == ALT_COL    && row == ALT_ROW)
        || (col == SHIFT1_COL && row == SHIFT1_ROW)
        || (col == SHIFT2_COL && row == SHIFT2_ROW);
}

} // namespace kb_matrix
