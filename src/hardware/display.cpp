#include "display.h"
#include <cstring>
#include <Arduino.h>
#include <SD.h>
#include <SPI.h>
#include "../fonts/FreeMono5pt7b.h"
#include "../config.h"

// Font metrics for each size (width, height measured for monospace 'M')
// All fonts are FreeMono - true monospace with UTF-8 support
static const FontMetrics FONT_METRICS[] = {
    { 6, 10, &FreeMono5pt7b },           // TINY: ~6x10 (compact UTF-8 monospace)
    { 6, 12, &fonts::FreeMono9pt7b },    // SMALL: ~6x12 (UTF-8 monospace)
    { 7, 16, &fonts::FreeMono12pt7b },   // MEDIUM: ~7x16 (default)
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

    // Keep backlight off while we clear the screen to avoid showing garbage
    _lcd.setBrightness(0);

    // Clear screen first (before turning on backlight)
    _lcd.fillScreen(Colors::BACKGROUND);
    Serial.println("Display: Screen cleared");

    // Now turn on backlight
    _lcd.setBrightness(255);
    Serial.println("Display: Backlight on");

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

    // Mark that a frame has been flushed (for text capture)
    if (_textCaptureEnabled) {
        _frameFlushed = true;
    }
}

void Display::setBrightness(uint8_t level) {
    _lcd.setBrightness(level);
}

void Display::drawText(int x, int y, const char* text, uint16_t color) {
    if (!text) return;

    // Capture text position if enabled
    if (_textCaptureEnabled && _capturedTextCount < MAX_CAPTURED_TEXTS) {
        CapturedText& ct = _capturedTexts[_capturedTextCount];
        ct.x = x;
        ct.y = y;
        ct.color = color;
        // Copy text, truncating if needed
        size_t len = strlen(text);
        if (len >= sizeof(ct.text)) {
            len = sizeof(ct.text) - 1;
        }
        memcpy(ct.text, text, len);
        ct.text[len] = '\0';
        _capturedTextCount++;
    }

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
    if (idx < 0 || idx > 3) idx = 2;  // Default to MEDIUM

    _fontSize = size;
    _fontWidth = FONT_METRICS[idx].width;
    _fontHeight = FONT_METRICS[idx].height;
    _buffer.setFont(FONT_METRICS[idx].font);
}

const char* Display::getFontSizeName(FontSize size) {
    switch (size) {
        case FontSize::TINY:   return "Tiny";
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

void Display::fillRectDithered(int x, int y, int w, int h, uint16_t color, int density) {
    // Clamp density to 0-100
    if (density <= 0) return;
    if (density >= 100) {
        fillRect(x, y, w, h, color);
        return;
    }

    // For 50% density, use simple checkerboard (fastest)
    if (density == 50) {
        for (int py = 0; py < h; py++) {
            for (int px = 0; px < w; px++) {
                if ((px + py) % 2 == 0) {
                    _buffer.drawPixel(x + px, y + py, color);
                }
            }
        }
    }
    // For 25% density, use sparser pattern
    else if (density == 25) {
        for (int py = 0; py < h; py++) {
            for (int px = 0; px < w; px++) {
                if ((px % 2 == 0) && (py % 2 == 0)) {
                    _buffer.drawPixel(x + px, y + py, color);
                }
            }
        }
    }
    // For 75% density, use denser pattern
    else if (density == 75) {
        for (int py = 0; py < h; py++) {
            for (int px = 0; px < w; px++) {
                if (!((px % 2 == 0) && (py % 2 == 0))) {
                    _buffer.drawPixel(x + px, y + py, color);
                }
            }
        }
    }
    // For other densities, use ordered dithering with 4x4 Bayer matrix
    else {
        // 4x4 Bayer matrix thresholds (0-15 scaled to 0-100)
        static const uint8_t bayer[4][4] = {
            {  0,  8,  2, 10 },
            { 12,  4, 14,  6 },
            {  3, 11,  1,  9 },
            { 15,  7, 13,  5 }
        };

        for (int py = 0; py < h; py++) {
            for (int px = 0; px < w; px++) {
                int threshold = (bayer[py % 4][px % 4] * 100) / 16;
                if (density > threshold) {
                    _buffer.drawPixel(x + px, y + py, color);
                }
            }
        }
    }
}

void Display::fillRectHLines(int x, int y, int w, int h, uint16_t color, int spacing) {
    // Fill with horizontal lines at given spacing
    // spacing=2 means every other line (50%), spacing=3 means every 3rd line (33%), etc.
    if (spacing <= 0) spacing = 1;
    if (spacing == 1) {
        fillRect(x, y, w, h, color);
        return;
    }

    for (int py = 0; py < h; py++) {
        if (py % spacing == 0) {
            _buffer.drawFastHLine(x, y + py, w, color);
        }
    }
}

void Display::fillRectVLines(int x, int y, int w, int h, uint16_t color, int spacing) {
    // Fill with vertical lines at given spacing
    // spacing=2 means every other line (50%), spacing=3 means every 3rd line (33%), etc.
    if (spacing <= 0) spacing = 1;
    if (spacing == 1) {
        fillRect(x, y, w, h, color);
        return;
    }

    for (int px = 0; px < w; px++) {
        if (px % spacing == 0) {
            _buffer.drawFastVLine(x + px, y, h, color);
        }
    }
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

void Display::drawLine(int x1, int y1, int x2, int y2, uint16_t color) {
    _buffer.drawLine(x1, y1, x2, y2, color);
}

void Display::drawCircle(int x, int y, int r, uint16_t color) {
    _buffer.drawCircle(x, y, r, color);
}

void Display::fillCircle(int x, int y, int r, uint16_t color) {
    _buffer.fillCircle(x, y, r, color);
}

void Display::drawTriangle(int x1, int y1, int x2, int y2, int x3, int y3, uint16_t color) {
    _buffer.drawTriangle(x1, y1, x2, y2, x3, y3, color);
}

void Display::fillTriangle(int x1, int y1, int x2, int y2, int x3, int y3, uint16_t color) {
    _buffer.fillTriangle(x1, y1, x2, y2, x3, y3, color);
}

void Display::drawRoundRect(int x, int y, int w, int h, int r, uint16_t color) {
    _buffer.drawRoundRect(x, y, w, h, r, color);
}

void Display::fillRoundRect(int x, int y, int w, int h, int r, uint16_t color) {
    _buffer.fillRoundRect(x, y, w, h, r, color);
}

bool Display::saveScreenshot(const char* path) {
    if (!_initialized) {
        Serial.println("[Screenshot] Display not initialized");
        return false;
    }

    // Initialize SD if needed
    SPI.begin(SD_SCLK, SD_MISO, SD_MOSI, SD_CS);
    if (!SD.begin(SD_CS)) {
        Serial.println("[Screenshot] SD card not available");
        return false;
    }

    // Create screenshots directory if it doesn't exist
    if (!SD.exists("/screenshots")) {
        SD.mkdir("/screenshots");
    }

    File file = SD.open(path, FILE_WRITE);
    if (!file) {
        Serial.printf("[Screenshot] Cannot create file: %s\n", path);
        return false;
    }

    const int width = TFT_WIDTH;
    const int height = TFT_HEIGHT;

    // BMP file uses 24-bit color (3 bytes per pixel) with 4-byte row alignment
    int rowSize = ((width * 3 + 3) / 4) * 4;  // Row size padded to 4-byte boundary
    int imageSize = rowSize * height;
    int fileSize = 54 + imageSize;  // 14 (file header) + 40 (DIB header) + pixels

    // BMP File Header (14 bytes)
    uint8_t bmpFileHeader[14] = {
        'B', 'M',                                           // Signature
        (uint8_t)(fileSize), (uint8_t)(fileSize >> 8),     // File size (bytes 2-5)
        (uint8_t)(fileSize >> 16), (uint8_t)(fileSize >> 24),
        0, 0, 0, 0,                                         // Reserved
        54, 0, 0, 0                                         // Pixel data offset (54 bytes)
    };
    file.write(bmpFileHeader, 14);

    // DIB Header (BITMAPINFOHEADER - 40 bytes)
    uint8_t bmpInfoHeader[40] = {
        40, 0, 0, 0,                                        // Header size
        (uint8_t)(width), (uint8_t)(width >> 8),           // Width
        (uint8_t)(width >> 16), (uint8_t)(width >> 24),
        (uint8_t)(height), (uint8_t)(height >> 8),         // Height
        (uint8_t)(height >> 16), (uint8_t)(height >> 24),
        1, 0,                                               // Color planes
        24, 0,                                              // Bits per pixel (24-bit)
        0, 0, 0, 0,                                         // Compression (BI_RGB)
        (uint8_t)(imageSize), (uint8_t)(imageSize >> 8),   // Image size
        (uint8_t)(imageSize >> 16), (uint8_t)(imageSize >> 24),
        0x13, 0x0B, 0, 0,                                   // X pixels per meter (2835)
        0x13, 0x0B, 0, 0,                                   // Y pixels per meter (2835)
        0, 0, 0, 0,                                         // Colors in palette
        0, 0, 0, 0                                          // Important colors
    };
    file.write(bmpInfoHeader, 40);

    // Get pointer to sprite buffer (RGB565 format)
    uint16_t* buffer = (uint16_t*)_buffer.getBuffer();
    if (!buffer) {
        Serial.println("[Screenshot] Cannot access display buffer");
        file.close();
        return false;
    }

    // Allocate row buffer for 24-bit conversion
    uint8_t* rowBuffer = (uint8_t*)malloc(rowSize);
    if (!rowBuffer) {
        Serial.println("[Screenshot] Out of memory for row buffer");
        file.close();
        return false;
    }

    // Write pixel data (BMP stores rows bottom-to-top)
    for (int y = height - 1; y >= 0; y--) {
        // Convert row from RGB565 to BGR24 (BMP uses BGR order)
        for (int x = 0; x < width; x++) {
            uint16_t pixel = buffer[y * width + x];

            // Extract RGB565 components and expand to 8-bit
            uint8_t r = ((pixel >> 11) & 0x1F) << 3;  // 5 bits -> 8 bits
            uint8_t g = ((pixel >> 5) & 0x3F) << 2;   // 6 bits -> 8 bits
            uint8_t b = (pixel & 0x1F) << 3;          // 5 bits -> 8 bits

            // Fill in the missing bits for better color accuracy
            r |= r >> 5;
            g |= g >> 6;
            b |= b >> 5;

            // BMP uses BGR order
            rowBuffer[x * 3] = b;
            rowBuffer[x * 3 + 1] = g;
            rowBuffer[x * 3 + 2] = r;
        }

        // Pad remaining bytes in row to 0
        for (int x = width * 3; x < rowSize; x++) {
            rowBuffer[x] = 0;
        }

        file.write(rowBuffer, rowSize);
    }

    free(rowBuffer);
    file.close();

    Serial.printf("[Screenshot] Saved: %s (%d bytes)\n", path, fileSize);
    return true;
}

size_t Display::getScreenshotRLE(uint8_t* buffer, size_t maxSize) {
    if (!_initialized || !buffer) {
        return 0;
    }

    // Get pointer to sprite buffer (RGB565 format)
    uint16_t* fb = (uint16_t*)_buffer.getBuffer();
    if (!fb) {
        return 0;
    }

    const int totalPixels = TFT_WIDTH * TFT_HEIGHT;
    size_t pos = 0;

    uint16_t prev = fb[0];
    uint8_t count = 1;

    for (int i = 1; i < totalPixels; i++) {
        uint16_t curr = fb[i];
        if (curr == prev && count < 255) {
            count++;
        } else {
            // Write run: [count:1][color_lo:1][color_hi:1]
            if (pos + 3 > maxSize) {
                return 0;  // Buffer overflow
            }
            buffer[pos++] = count;
            buffer[pos++] = prev & 0xFF;
            buffer[pos++] = (prev >> 8) & 0xFF;
            prev = curr;
            count = 1;
        }
    }

    // Write final run
    if (pos + 3 > maxSize) {
        return 0;
    }
    buffer[pos++] = count;
    buffer[pos++] = prev & 0xFF;
    buffer[pos++] = (prev >> 8) & 0xFF;

    return pos;
}

void Display::setTextCaptureEnabled(bool enabled) {
    _textCaptureEnabled = enabled;
    if (enabled) {
        clearCapturedText();
        _frameFlushed = false;
    }
}

void Display::clearCapturedText() {
    _capturedTextCount = 0;
}

size_t Display::getCapturedTextJSON(char* buffer, size_t maxSize) {
    if (!buffer || maxSize < 3) {
        return 0;
    }

    size_t pos = 0;
    buffer[pos++] = '[';

    for (size_t i = 0; i < _capturedTextCount && pos < maxSize - 50; i++) {
        const CapturedText& ct = _capturedTexts[i];

        if (i > 0) {
            buffer[pos++] = ',';
        }

        // Escape special characters in text for JSON
        char escapedText[128];
        size_t ej = 0;
        for (size_t j = 0; ct.text[j] && ej < sizeof(escapedText) - 2; j++) {
            char c = ct.text[j];
            if (c == '"' || c == '\\') {
                escapedText[ej++] = '\\';
            } else if (c == '\n') {
                escapedText[ej++] = '\\';
                c = 'n';
            } else if (c == '\r') {
                escapedText[ej++] = '\\';
                c = 'r';
            } else if (c == '\t') {
                escapedText[ej++] = '\\';
                c = 't';
            }
            escapedText[ej++] = c;
        }
        escapedText[ej] = '\0';

        int written = snprintf(buffer + pos, maxSize - pos,
            "{\"x\":%d,\"y\":%d,\"color\":%u,\"text\":\"%s\"}",
            ct.x, ct.y, ct.color, escapedText);

        if (written < 0 || (size_t)written >= maxSize - pos) {
            break;
        }
        pos += written;
    }

    if (pos < maxSize - 1) {
        buffer[pos++] = ']';
    }
    buffer[pos] = '\0';

    return pos;
}
