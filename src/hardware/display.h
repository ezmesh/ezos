#pragma once

#include <cstdint>
#include <LovyanGFX.hpp>
#include "../config.h"

// LovyanGFX display configuration for T-Deck Plus (ST7789)
class LGFX : public lgfx::LGFX_Device {
    lgfx::Panel_ST7789 _panel_instance;
    lgfx::Bus_SPI _bus_instance;
    lgfx::Light_PWM _light_instance;

public:
    LGFX() {
        // SPI bus configuration
        {
            auto cfg = _bus_instance.config();
            cfg.spi_host = SPI2_HOST;
            cfg.spi_mode = 0;
            cfg.freq_write = 40000000;
            cfg.freq_read = 16000000;
            cfg.spi_3wire = false;
            cfg.use_lock = true;
            cfg.dma_channel = SPI_DMA_CH_AUTO;
            cfg.pin_sclk = TFT_SCLK;
            cfg.pin_mosi = TFT_MOSI;
            cfg.pin_miso = TFT_MISO;
            cfg.pin_dc = TFT_DC;
            _bus_instance.config(cfg);
            _panel_instance.setBus(&_bus_instance);
        }

        // Panel configuration for T-Deck Plus (ST7789 320x240)
        {
            auto cfg = _panel_instance.config();
            cfg.pin_cs = TFT_CS;
            cfg.pin_rst = -1;           // No hardware reset (controlled by power)
            cfg.pin_busy = -1;
            cfg.memory_width = 240;     // ST7789 native width
            cfg.memory_height = 320;    // ST7789 native height
            cfg.panel_width = 240;      // Visible width (before rotation)
            cfg.panel_height = 320;     // Visible height (before rotation)
            cfg.offset_x = 0;
            cfg.offset_y = 0;
            cfg.offset_rotation = 0;
            cfg.dummy_read_pixel = 8;
            cfg.dummy_read_bits = 1;
            cfg.readable = false;       // ST7789 read can be problematic
            cfg.invert = true;          // ST7789 needs color inversion
            cfg.rgb_order = false;      // BGR order
            cfg.dlen_16bit = false;
            cfg.bus_shared = true;      // Shared SPI with LoRa
            _panel_instance.config(cfg);
        }

        // Backlight configuration
        {
            auto cfg = _light_instance.config();
            cfg.pin_bl = TFT_BL;
            cfg.invert = false;
            cfg.freq = 1000;            // Lower frequency for stability
            cfg.pwm_channel = 7;
            _light_instance.config(cfg);
            _panel_instance.setLight(&_light_instance);
        }

        setPanel(&_panel_instance);
    }
};

// Color definitions (RGB565)
namespace Colors {
    constexpr uint16_t BLACK       = 0x0000;
    constexpr uint16_t WHITE       = 0xFFFF;
    constexpr uint16_t GREEN       = 0x07E0;
    constexpr uint16_t DARK_GREEN  = 0x03E0;
    constexpr uint16_t CYAN        = 0x07FF;
    constexpr uint16_t RED         = 0xF800;
    constexpr uint16_t YELLOW      = 0xFFE0;
    constexpr uint16_t ORANGE      = 0xFD20;
    constexpr uint16_t BLUE        = 0x001F;
    constexpr uint16_t GRAY        = 0x8410;
    constexpr uint16_t DARK_GRAY   = 0x4208;
    constexpr uint16_t LIGHT_GRAY  = 0xC618;

    // TUI theme colors
    constexpr uint16_t BACKGROUND  = BLACK;
    constexpr uint16_t FOREGROUND  = GREEN;
    constexpr uint16_t HIGHLIGHT   = CYAN;
    constexpr uint16_t BORDER      = DARK_GREEN;
    constexpr uint16_t TEXT        = GREEN;
    constexpr uint16_t TEXT_DIM    = DARK_GREEN;
    constexpr uint16_t SELECTION   = 0x0320;    // Dark cyan background
    constexpr uint16_t ERROR       = RED;
    constexpr uint16_t WARNING     = YELLOW;
    constexpr uint16_t SUCCESS     = GREEN;
}

// Forward declaration
class Display;

// Sprite class for off-screen rendering with alpha support
class Sprite {
public:
    Sprite(Display* parent);
    ~Sprite();

    // Prevent copying
    Sprite(const Sprite&) = delete;
    Sprite& operator=(const Sprite&) = delete;

    // Creation/destruction
    bool create(int width, int height);
    void destroy();
    bool isValid() const { return _valid; }

    // Properties
    int width() const { return _width; }
    int height() const { return _height; }
    void setTransparentColor(uint16_t color) { _transparentColor = color; _hasTransparent = true; }
    void clearTransparentColor() { _hasTransparent = false; }

    // Drawing operations (mirror Display API)
    void clear(uint16_t color = 0x0000);
    void drawPixel(int x, int y, uint16_t color);
    void fillRect(int x, int y, int w, int h, uint16_t color);
    void drawRect(int x, int y, int w, int h, uint16_t color);
    void drawLine(int x1, int y1, int x2, int y2, uint16_t color);
    void drawCircle(int x, int y, int r, uint16_t color);
    void fillCircle(int x, int y, int r, uint16_t color);
    void drawTriangle(int x1, int y1, int x2, int y2, int x3, int y3, uint16_t color);
    void fillTriangle(int x1, int y1, int x2, int y2, int x3, int y3, uint16_t color);
    void drawRoundRect(int x, int y, int w, int h, int r, uint16_t color);
    void fillRoundRect(int x, int y, int w, int h, int r, uint16_t color);
    void drawText(int x, int y, const char* text, uint16_t color);

    // Composite to parent display buffer
    // alpha: 0 = fully transparent, 255 = fully opaque
    void push(int x, int y, uint8_t alpha = 255);

private:
    Display* _parent;
    LGFX_Sprite _sprite;
    int _width = 0;
    int _height = 0;
    bool _valid = false;
    uint16_t _transparentColor = 0x0000;
    bool _hasTransparent = false;
};

// Font size options for TUI
enum class FontSize : uint8_t {
    TINY = 0,    // FreeMono5pt - compact (6x10), UTF-8 monospace
    SMALL = 1,   // FreeMono9pt - compact (6x12), full UTF-8
    MEDIUM = 2,  // FreeMono12pt - balanced (7x16), default
    LARGE = 3    // FreeMono18pt - easier to read (11x24)
};

// Font metrics for each size
struct FontMetrics {
    int width;
    int height;
    const lgfx::GFXfont* font;
};

// Box-drawing character mappings for TUI rendering
// These are rendered as custom graphics since most fonts don't include them
namespace BoxChars {
    constexpr char TOP_LEFT     = 0x01;  // ┌
    constexpr char TOP_RIGHT    = 0x02;  // ┐
    constexpr char BOTTOM_LEFT  = 0x03;  // └
    constexpr char BOTTOM_RIGHT = 0x04;  // ┘
    constexpr char HORIZONTAL   = 0x05;  // ─
    constexpr char VERTICAL     = 0x06;  // │
    constexpr char T_LEFT       = 0x07;  // ├
    constexpr char T_RIGHT      = 0x08;  // ┤
    constexpr char T_TOP        = 0x09;  // ┬
    constexpr char T_BOTTOM     = 0x0A;  // ┴
    constexpr char CROSS        = 0x0B;  // ┼
}

class Display {
public:
    Display();
    ~Display() = default;

    // Prevent copying
    Display(const Display&) = delete;
    Display& operator=(const Display&) = delete;

    // Initialization
    bool init();

    // Basic operations
    void clear();
    void flush();
    void setBrightness(uint8_t level);  // 0-255

    // Text rendering
    void drawText(int x, int y, const char* text, uint16_t color = Colors::TEXT);
    void drawTextCentered(int y, const char* text, uint16_t color = Colors::TEXT);
    void drawChar(int x, int y, char c, uint16_t color = Colors::TEXT);

    // Box drawing for TUI elements
    void drawBox(int x, int y, int w, int h, const char* title = nullptr,
                 uint16_t borderColor = Colors::BORDER,
                 uint16_t titleColor = Colors::HIGHLIGHT);

    // Draw a horizontal line with optional left/right connectors
    void drawHLine(int x, int y, int w, bool leftConnect = false, bool rightConnect = false,
                   uint16_t color = Colors::BORDER);

    // List rendering with selection highlight
    void drawList(int x, int y, int w, const char** items, int count, int selected,
                  uint16_t textColor = Colors::TEXT,
                  uint16_t selectBg = Colors::SELECTION,
                  uint16_t selectFg = Colors::HIGHLIGHT);

    // Progress/status bar
    void drawProgressBar(int x, int y, int w, int h, float progress,
                         uint16_t fgColor = Colors::GREEN,
                         uint16_t bgColor = Colors::DARK_GRAY);

    // Battery indicator
    void drawBattery(int x, int y, uint8_t percent);

    // Radio signal indicator
    void drawSignal(int x, int y, int bars);  // 0-4 bars

    // Pixel-level access (for custom graphics)
    void drawPixel(int x, int y, uint16_t color);
    void fillRect(int x, int y, int w, int h, uint16_t color);
    void drawRect(int x, int y, int w, int h, uint16_t color);

    // Dithered fill for simulating transparency (checkerboard pattern)
    // density: 0-100, percentage of pixels filled (50 = checkerboard)
    void fillRectDithered(int x, int y, int w, int h, uint16_t color, int density = 50);

    // Line pattern fills for simulating transparency
    // spacing: 2 = every other line (50%), 3 = every 3rd line (33%), etc.
    void fillRectHLines(int x, int y, int w, int h, uint16_t color, int spacing = 2);
    void fillRectVLines(int x, int y, int w, int h, uint16_t color, int spacing = 2);

    // Line drawing
    void drawLine(int x1, int y1, int x2, int y2, uint16_t color);

    // Circle drawing
    void drawCircle(int x, int y, int r, uint16_t color);
    void fillCircle(int x, int y, int r, uint16_t color);

    // Triangle drawing
    void drawTriangle(int x1, int y1, int x2, int y2, int x3, int y3, uint16_t color);
    void fillTriangle(int x1, int y1, int x2, int y2, int x3, int y3, uint16_t color);

    // Rounded rectangle drawing
    void drawRoundRect(int x, int y, int w, int h, int r, uint16_t color);
    void fillRoundRect(int x, int y, int w, int h, int r, uint16_t color);

    // Bitmap drawing (RGB565 format)
    void drawBitmap(int x, int y, int w, int h, const uint16_t* data);
    void drawBitmapTransparent(int x, int y, int w, int h, const uint16_t* data, uint16_t transparentColor);

    // Dimensions
    int getWidth() const { return TFT_WIDTH; }
    int getHeight() const { return TFT_HEIGHT; }
    int getCols() const { return TFT_WIDTH / _fontWidth; }
    int getRows() const { return TFT_HEIGHT / _fontHeight; }
    int getFontWidth() const { return _fontWidth; }
    int getFontHeight() const { return _fontHeight; }

    // Font configuration
    void setFontSize(FontSize size);
    FontSize getFontSize() const { return _fontSize; }
    static const char* getFontSizeName(FontSize size);

    // Text measurement (UTF-8 aware)
    int textWidth(const char* text);

    // Screenshot capture (saves current buffer to BMP file)
    bool saveScreenshot(const char* path);

    // Get RLE-compressed screenshot data for serial transfer
    // Returns size written to buffer, 0 on error
    // Format: [count:1][color_lo:1][color_hi:1] repeated
    size_t getScreenshotRLE(uint8_t* buffer, size_t maxSize);

    // Text capture for remote control
    // Enable/disable capturing text positions during rendering
    void setTextCaptureEnabled(bool enabled);
    bool isTextCaptureEnabled() const { return _textCaptureEnabled; }

    // Clear captured text (call before rendering a frame)
    void clearCapturedText();

    // Check if a frame has been flushed since capture was enabled
    bool hasFrameBeenFlushed() const { return _frameFlushed; }
    void resetFrameFlushed() { _frameFlushed = false; }

    // Get captured text as JSON array
    // Format: [{"x":0,"y":0,"text":"hello","color":65535}, ...]
    size_t getCapturedTextJSON(char* buffer, size_t maxSize);

private:
    LGFX _lcd;
    LGFX_Sprite _buffer;
    bool _initialized = false;

    // Current font settings
    FontSize _fontSize = FontSize::MEDIUM;
    int _fontWidth = 8;
    int _fontHeight = 16;

    void drawBoxChar(int x, int y, char boxChar, uint16_t color);

    // Text capture data structure
    struct CapturedText {
        int16_t x;
        int16_t y;
        uint16_t color;
        char text[64];  // Truncated to fit
    };

    // Primitive types for capture
    enum class PrimitiveType : uint8_t {
        FILL_RECT = 0,
        DRAW_RECT = 1,
        DRAW_LINE = 2,
        FILL_CIRCLE = 3,
        DRAW_CIRCLE = 4,
        FILL_TRIANGLE = 5,
        DRAW_TRIANGLE = 6,
        FILL_ROUND_RECT = 7,
        DRAW_ROUND_RECT = 8,
        DRAW_PIXEL = 9,
        DRAW_BITMAP = 10,
        DRAW_BITMAP_TRANSPARENT = 11,
    };

    // Primitive capture data structure (union for different shapes)
    struct CapturedPrimitive {
        PrimitiveType type;
        uint16_t color;  // For bitmap types, this is transparentColor (or 0 for non-transparent)
        union {
            struct { int16_t x, y, w, h; } rect;                    // FILL_RECT, DRAW_RECT, DRAW_BITMAP*
            struct { int16_t x1, y1, x2, y2; } line;                // DRAW_LINE
            struct { int16_t x, y, r; } circle;                     // FILL_CIRCLE, DRAW_CIRCLE
            struct { int16_t x1, y1, x2, y2, x3, y3; } triangle;    // FILL_TRIANGLE, DRAW_TRIANGLE
            struct { int16_t x, y, w, h, r; } roundRect;            // FILL_ROUND_RECT, DRAW_ROUND_RECT
            struct { int16_t x, y; } pixel;                         // DRAW_PIXEL
        };
    };

    // Text capture state
    bool _textCaptureEnabled = false;
    bool _frameFlushed = false;
    static constexpr size_t MAX_CAPTURED_TEXTS = 128;
    CapturedText _capturedTexts[MAX_CAPTURED_TEXTS];
    size_t _capturedTextCount = 0;

    // Primitive capture state
    bool _primitiveCaptureEnabled = false;
    static constexpr size_t MAX_CAPTURED_PRIMITIVES = 512;
    CapturedPrimitive _capturedPrimitives[MAX_CAPTURED_PRIMITIVES];
    size_t _capturedPrimitiveCount = 0;

public:
    // Primitive capture for remote control
    void setPrimitiveCaptureEnabled(bool enabled);
    bool isPrimitiveCaptureEnabled() const { return _primitiveCaptureEnabled; }
    void clearCapturedPrimitives();
    size_t getCapturedPrimitivesJSON(char* buffer, size_t maxSize);

    // Sprite support
    Sprite* createSprite(int width, int height);
    void destroySprite(Sprite* sprite);

    // Access to internal buffer (for Sprite compositing)
    LGFX_Sprite& getBuffer() { return _buffer; }
    const lgfx::GFXfont* getCurrentFont() const;
};
