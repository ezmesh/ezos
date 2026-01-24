#pragma once

// =============================================================================
// T-Deck Plus Hardware Pin Configuration
// =============================================================================

// -----------------------------------------------------------------------------
// Display (ST7789 via SPI)
// -----------------------------------------------------------------------------
#define TFT_CS          12
#define TFT_DC          11
#define TFT_MOSI        41
#define TFT_MISO        38
#define TFT_SCLK        40
#define TFT_BL          42
#define TFT_RST         -1      // No hardware reset pin

#define TFT_WIDTH       320
#define TFT_HEIGHT      240

// -----------------------------------------------------------------------------
// LoRa SX1262 (SPI, shared bus with display)
// -----------------------------------------------------------------------------
#define LORA_CS         9
#define LORA_IRQ        45
#define LORA_RST        17
#define LORA_BUSY       13
#define LORA_MOSI       41      // Shared with display
#define LORA_MISO       38
#define LORA_SCLK       40      // Shared with display

// Default LoRa settings (EU868 band)
#define LORA_FREQ_DEFAULT       869.618f  // MHz
#define LORA_BW_DEFAULT         62.5f     // kHz (narrowband)
#define LORA_SF_DEFAULT         8         // Spreading factor
#define LORA_CR_DEFAULT         8         // Coding rate (4/8)
#define LORA_SYNC_DEFAULT       0x12    // Sync word
#define LORA_POWER_DEFAULT      22      // dBm (max for SX1262)
#define LORA_PREAMBLE_DEFAULT   8       // Preamble length

// -----------------------------------------------------------------------------
// Keyboard (I2C)
// -----------------------------------------------------------------------------
#define KB_I2C_SDA      18
#define KB_I2C_SCL      8
#define KB_I2C_ADDR     0x55
#define KB_INT          46

// -----------------------------------------------------------------------------
// Trackball (GPIO pins, directly read via polling/interrupts)
// -----------------------------------------------------------------------------
#define TRACKBALL_UP        3
#define TRACKBALL_DOWN      15
#define TRACKBALL_LEFT      1
#define TRACKBALL_RIGHT     2
#define TRACKBALL_CLICK     0

// -----------------------------------------------------------------------------
// Audio (I2S Speaker + ES7210 Microphone)
// T-Deck Plus uses I2S for speaker, ES7210 codec for microphone
// -----------------------------------------------------------------------------
// Speaker I2S pins
#define I2S_BCK_PIN     7   // I2S Bit Clock (speaker)
#define I2S_WS_PIN      5   // I2S Word Select (speaker)
#define I2S_DATA_OUT    6   // I2S Data Out (speaker)

// ES7210 Microphone codec pins (separate I2S interface)
#define ES7210_MCLK     48  // Master Clock
#define ES7210_SCK      47  // Bit Clock
#define ES7210_LRCK     21  // Word Select / Frame Clock
#define ES7210_DIN      14  // Data In (from microphone)
#define ES7210_I2C_ADDR 0x40 // ES7210 I2C address

// -----------------------------------------------------------------------------
// Power Management
// -----------------------------------------------------------------------------
#define BOARD_POWERON   10
#define BATTERY_ADC     4

// Battery voltage calculation (voltage divider ratio)
#define BATTERY_DIVIDER_RATIO   2.0f
#define BATTERY_MIN_MV          3200    // Empty battery voltage (mV)
#define BATTERY_MAX_MV          4200    // Full battery voltage (mV)

// -----------------------------------------------------------------------------
// SD Card (SPI, shared bus with display)
// -----------------------------------------------------------------------------
#define SD_CS           39
#define SD_MOSI         41      // Shared with display
#define SD_MISO         38      // Shared with display
#define SD_SCLK         40      // Shared with display

// -----------------------------------------------------------------------------
// I2C Bus Configuration
// -----------------------------------------------------------------------------
#define I2C_SDA         18
#define I2C_SCL         8
#define I2C_FREQ        400000  // 400 kHz

// -----------------------------------------------------------------------------
// SPI Bus Configuration
// -----------------------------------------------------------------------------
#define SPI_MOSI        41
#define SPI_MISO        38
#define SPI_SCLK        40
#define SPI_FREQ        40000000    // 40 MHz for display

// -----------------------------------------------------------------------------
// MeshCore Protocol Defaults
// -----------------------------------------------------------------------------
#define MESHCORE_VERSION        1
#define MESHCORE_TTL_DEFAULT    3
#define MESHCORE_NODE_ID_LEN    6
#define MESHCORE_MAX_PAYLOAD    200
#define MESHCORE_PACKET_BUFFER  64      // Number of packet IDs to track for dedup
#define MESHCORE_REBROADCAST_DELAY_MIN  50   // ms
#define MESHCORE_REBROADCAST_DELAY_MAX  200  // ms

// -----------------------------------------------------------------------------
// TUI Configuration
// -----------------------------------------------------------------------------
#define TUI_FONT_WIDTH      8
#define TUI_FONT_HEIGHT     16
#define TUI_COLS            (TFT_WIDTH / TUI_FONT_WIDTH)     // 40 columns
#define TUI_ROWS            (TFT_HEIGHT / TUI_FONT_HEIGHT)   // 15 rows

// Status bar configuration
#define STATUS_BAR_HEIGHT   TUI_FONT_HEIGHT
