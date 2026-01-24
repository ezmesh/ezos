#include "display.h"
#include <cstring>
#include <Arduino.h>

// Font metrics for each size (width, height measured for monospace 'M')
// FreeMono is a true monospace font
static const FontMetrics FONT_METRICS[] = {
    { 6, 12, &fonts::FreeMono9pt7b },    // SMALL: ~6x12
    { 7, 16, &fonts::FreeMono12pt7b },   // MEDIUM: ~7x16
    { 11, 24, &fonts::FreeMono18pt7b }   // LARGE: ~11x24
};

Display::Display() : _buffer(&_lcd) {
}

bool Display::init() {
    if (_initialized) {
        return true;
    }

    Serial.println("Display: Starting LCD init...");

    // Initialize the LCD
    _lcd.init();
    Serial.println("Display: LCD init done");

    // Set rotation (1 = landscape, screen right of keyboard)
    _lcd.setRotation(1);
    Serial.println("Display: Rotation set to landscape");

    // Turn on backlight
    _lcd.setBrightness(255);
    Serial.println("Display: Backlight on");

    // Clear screen
    _lcd.fillScreen(Colors::BACKGROUND);
    Serial.println("Display: Screen cleared");

    // Create sprite buffer for double-buffering (uses PSRAM if available)
    _buffer.setColorDepth(16);
    void* psram = _buffer.createSprite(TFT_WIDTH, TFT_HEIGHT);
    if (!psram) {
        Serial.println("Display: WARNING - Sprite buffer failed, using direct mode");
        // Continue anyway - will work but may flicker
    } else {
        Serial.printf("Display: Sprite buffer created (%dx%d)\n", TFT_WIDTH, TFT_HEIGHT);
    }
    _buffer.fillSprite(Colors::BACKGROUND);

    // Set default font (FreeMono - true monospace)
    setFontSize(FontSize::MEDIUM);
    _buffer.setTextSize(1);

    _initialized = true;
    Serial.println("Display: Initialization complete");
    return true;
}

void Display::clear() {
    _buffer.fillSprite(Colors::BACKGROUND);
}

void Display::flush() {
    _buffer.pushSprite(0, 0);
}

void Display::setBrightness(uint8_t level) {
    _lcd.setBrightness(level);
}

void Display::drawText(int x, int y, const char* text, uint16_t color) {
    if (!text) return;

    _buffer.setTextColor(color);
    _buffer.setCursor(x, y);
    _buffer.print(text);
}

void Display::drawTextCentered(int y, const char* text, uint16_t color) {
    if (!text) return;

    // Use textWidth() for proper UTF-8 measurement
    int tw = _buffer.textWidth(text);
    int x = (TFT_WIDTH - tw) / 2;
    drawText(x, y, text, color);
}

void Display::drawChar(int x, int y, char c, uint16_t color) {
    char str[2] = {c, '\0'};
    drawText(x, y, str, color);
}

int Display::textWidth(const char* text) {
    if (!text) return 0;
    return _buffer.textWidth(text);
}

void Display::setFontSize(FontSize size) {
    int idx = static_cast<int>(size);
    if (idx < 0 || idx > 2) idx = 1;  // Default to MEDIUM

    _fontSize = size;
    _fontWidth = FONT_METRICS[idx].width;
    _fontHeight = FONT_METRICS[idx].height;
    _buffer.setFont(FONT_METRICS[idx].font);

    Serial.printf("Display: Font set to %s (%dx%d)\n",
                  getFontSizeName(size), _fontWidth, _fontHeight);
}

const char* Display::getFontSizeName(FontSize size) {
    switch (size) {
        case FontSize::SMALL:  return "Small";
        case FontSize::MEDIUM: return "Medium";
        case FontSize::LARGE:  return "Large";
        default: return "Unknown";
    }
}

void Display::drawBoxChar(int x, int y, char boxChar, uint16_t color) {
    // Render box-drawing characters as custom graphics
    int cx = x + _fontWidth / 2;   // Center X
    int cy = y + _fontHeight / 2;  // Center Y

    switch (boxChar) {
        case BoxChars::HORIZONTAL:  // ─
            _buffer.drawFastHLine(x, cy, _fontWidth, color);
            break;

        case BoxChars::VERTICAL:  // │
            _buffer.drawFastVLine(cx, y, _fontHeight, color);
            break;

        case BoxChars::TOP_LEFT:  // ┌
            _buffer.drawFastHLine(cx, cy, _fontWidth - _fontWidth/2, color);
            _buffer.drawFastVLine(cx, cy, _fontHeight - _fontHeight/2, color);
            break;

        case BoxChars::TOP_RIGHT:  // ┐
            _buffer.drawFastHLine(x, cy, _fontWidth/2 + 1, color);
            _buffer.drawFastVLine(cx, cy, _fontHeight - _fontHeight/2, color);
            break;

        case BoxChars::BOTTOM_LEFT:  // └
            _buffer.drawFastHLine(cx, cy, _fontWidth - _fontWidth/2, color);
            _buffer.drawFastVLine(cx, y, _fontHeight/2 + 1, color);
            break;

        case BoxChars::BOTTOM_RIGHT:  // ┘
            _buffer.drawFastHLine(x, cy, _fontWidth/2 + 1, color);
            _buffer.drawFastVLine(cx, y, _fontHeight/2 + 1, color);
            break;

        case BoxChars::T_LEFT:  // ├
            _buffer.drawFastVLine(cx, y, _fontHeight, color);
            _buffer.drawFastHLine(cx, cy, _fontWidth - _fontWidth/2, color);
            break;

        case BoxChars::T_RIGHT:  // ┤
            _buffer.drawFastVLine(cx, y, _fontHeight, color);
            _buffer.drawFastHLine(x, cy, _fontWidth/2 + 1, color);
            break;

        case BoxChars::T_TOP:  // ┬
            _buffer.drawFastHLine(x, cy, _fontWidth, color);
            _buffer.drawFastVLine(cx, cy, _fontHeight - _fontHeight/2, color);
            break;

        case BoxChars::T_BOTTOM:  // ┴
            _buffer.drawFastHLine(x, cy, _fontWidth, color);
            _buffer.drawFastVLine(cx, y, _fontHeight/2 + 1, color);
            break;

        case BoxChars::CROSS:  // ┼
            _buffer.drawFastHLine(x, cy, _fontWidth, color);
            _buffer.drawFastVLine(cx, y, _fontHeight, color);
            break;
    }
}

void Display::drawBox(int x, int y, int w, int h, const char* title,
                      uint16_t borderColor, uint16_t titleColor) {
    // w and h are in character cells
    int px = x * _fontWidth;
    int py = y * _fontHeight;
    int pw = w * _fontWidth;
    int ph = h * _fontHeight;

    // Draw corners
    drawBoxChar(px, py, BoxChars::TOP_LEFT, borderColor);
    drawBoxChar(px + pw - _fontWidth, py, BoxChars::TOP_RIGHT, borderColor);
    drawBoxChar(px, py + ph - _fontHeight, BoxChars::BOTTOM_LEFT, borderColor);
    drawBoxChar(px + pw - _fontWidth, py + ph - _fontHeight, BoxChars::BOTTOM_RIGHT, borderColor);

    // Draw horizontal edges
    for (int i = 1; i < w - 1; i++) {
        drawBoxChar(px + i * _fontWidth, py, BoxChars::HORIZONTAL, borderColor);
        drawBoxChar(px + i * _fontWidth, py + ph - _fontHeight, BoxChars::HORIZONTAL, borderColor);
    }

    // Draw vertical edges
    for (int i = 1; i < h - 1; i++) {
        drawBoxChar(px, py + i * _fontHeight, BoxChars::VERTICAL, borderColor);
        drawBoxChar(px + pw - _fontWidth, py + i * _fontHeight, BoxChars::VERTICAL, borderColor);
    }

    // Draw title if provided
    if (title && strlen(title) > 0) {
        int titleLen = strlen(title);
        int titleStart = 2;  // Characters from left edge

        // Draw title with surrounding dashes
        drawBoxChar(px + _fontWidth, py, BoxChars::HORIZONTAL, borderColor);
        drawText(px + titleStart * _fontWidth, py, " ", borderColor);
        drawText(px + (titleStart + 1) * _fontWidth, py, title, titleColor);
        drawText(px + (titleStart + 1 + titleLen) * _fontWidth, py, " ", borderColor);
    }
}

void Display::drawHLine(int x, int y, int w, bool leftConnect, bool rightConnect,
                        uint16_t color) {
    int px = x * _fontWidth;
    int py = y * _fontHeight;

    // Left end
    if (leftConnect) {
        drawBoxChar(px, py, BoxChars::T_LEFT, color);
    } else {
        drawBoxChar(px, py, BoxChars::HORIZONTAL, color);
    }

    // Middle
    for (int i = 1; i < w - 1; i++) {
        drawBoxChar(px + i * _fontWidth, py, BoxChars::HORIZONTAL, color);
    }

    // Right end
    if (rightConnect) {
        drawBoxChar(px + (w - 1) * _fontWidth, py, BoxChars::T_RIGHT, color);
    } else {
        drawBoxChar(px + (w - 1) * _fontWidth, py, BoxChars::HORIZONTAL, color);
    }
}

void Display::drawList(int x, int y, int w, const char** items, int count, int selected,
                       uint16_t textColor, uint16_t selectBg, uint16_t selectFg) {
    for (int i = 0; i < count; i++) {
        int px = x * _fontWidth;
        int py = (y + i) * _fontHeight;
        int pw = w * _fontWidth;

        if (i == selected) {
            // Draw selection background
            _buffer.fillRect(px, py, pw, _fontHeight, selectBg);

            // Draw selection indicator and text
            drawText(px, py, ">", selectFg);
            drawText(px + _fontWidth * 2, py, items[i], selectFg);
        } else {
            // Draw normal item
            drawText(px + _fontWidth * 2, py, items[i], textColor);
        }
    }
}

void Display::drawProgressBar(int x, int y, int w, int h, float progress,
                              uint16_t fgColor, uint16_t bgColor) {
    // Clamp progress to 0-1 range
    if (progress < 0.0f) progress = 0.0f;
    if (progress > 1.0f) progress = 1.0f;

    // Draw background
    _buffer.fillRect(x, y, w, h, bgColor);

    // Draw filled portion
    int fillWidth = static_cast<int>(w * progress);
    if (fillWidth > 0) {
        _buffer.fillRect(x, y, fillWidth, h, fgColor);
    }
}

void Display::drawBattery(int x, int y, uint8_t percent) {
    // Battery icon: [####] style

    // Draw battery outline
    drawText(x, y, "[", Colors::BORDER);
    drawText(x + 5 * _fontWidth, y, "]", Colors::BORDER);

    // Calculate fill level (4 positions)
    int fillChars = (percent * 4) / 100;
    if (percent > 0 && fillChars == 0) fillChars = 1;  // Show at least 1 bar if not empty

    // Choose color based on level
    uint16_t color = Colors::GREEN;
    if (percent <= 20) {
        color = Colors::RED;
    } else if (percent <= 40) {
        color = Colors::YELLOW;
    }

    // Draw fill bars
    for (int i = 0; i < 4; i++) {
        if (i < fillChars) {
            drawText(x + (1 + i) * _fontWidth, y, "#", color);
        } else {
            drawText(x + (1 + i) * _fontWidth, y, "-", Colors::DARK_GRAY);
        }
    }
}

void Display::drawSignal(int x, int y, int bars) {
    // Signal indicator: ascending bars pattern
    // 4 bars maximum, increasing height

    int barWidth = 3;
    int spacing = 1;
    int maxHeight = 12;

    for (int i = 0; i < 4; i++) {
        int barHeight = (maxHeight * (i + 1)) / 4;
        int bx = x + i * (barWidth + spacing);
        int by = y + (maxHeight - barHeight);

        uint16_t color = (i < bars) ? Colors::GREEN : Colors::DARK_GRAY;
        _buffer.fillRect(bx, by, barWidth, barHeight, color);
    }
}

void Display::drawPixel(int x, int y, uint16_t color) {
    _buffer.drawPixel(x, y, color);
}

void Display::fillRect(int x, int y, int w, int h, uint16_t color) {
    _buffer.fillRect(x, y, w, h, color);
}

void Display::drawRect(int x, int y, int w, int h, uint16_t color) {
    _buffer.drawRect(x, y, w, h, color);
}

void Display::drawBitmap(int x, int y, int w, int h, const uint16_t* data) {
    if (!data) return;
    _buffer.pushImage(x, y, w, h, data);
}

void Display::drawBitmapTransparent(int x, int y, int w, int h, const uint16_t* data, uint16_t transparentColor) {
    if (!data) return;
    // Draw pixel by pixel, skipping transparent pixels
    for (int py = 0; py < h; py++) {
        for (int px = 0; px < w; px++) {
            uint16_t color = data[py * w + px];
            if (color != transparentColor) {
                _buffer.drawPixel(x + px, y + py, color);
            }
        }
    }
}
