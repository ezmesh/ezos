#include "usb_msc.h"
#include "../config.h"
#include <SD.h>
#include <SPI.h>
#include <USB.h>
#include <USBMSC.h>

// Static members
bool SDCardUSB::_initialized = false;
bool SDCardUSB::_active = false;

// USB MSC instance (using built-in ESP32 USBMSC class)
static USBMSC msc;

// SD card info
static int32_t sdCardSectors = 0;
static int32_t sdSectorSize = 512;

// MSC callbacks
static int32_t onRead(uint32_t lba, uint32_t offset, void* buffer, uint32_t bufsize) {
    uint32_t addr = lba * sdSectorSize + offset;
    if (!SD.exists("/")) {
        return -1;
    }

    // Read directly from SD
    if (!SD.readRAW((uint8_t*)buffer, lba)) {
        return -1;
    }
    return bufsize;
}

static int32_t onWrite(uint32_t lba, uint32_t offset, uint8_t* buffer, uint32_t bufsize) {
    if (!SD.exists("/")) {
        return -1;
    }

    // Write directly to SD
    if (!SD.writeRAW((uint8_t*)buffer, lba)) {
        return -1;
    }
    return bufsize;
}

static bool onStartStop(uint8_t power_condition, bool start, bool load_eject) {
    Serial.printf("[USB MSC] StartStop: power=%d start=%d eject=%d\n",
                  power_condition, start, load_eject);
    return true;
}

bool SDCardUSB::init() {
    if (_initialized) return true;

    Serial.println("[USB MSC] Initializing SD card...");

    // Initialize SPI for SD card
    SPI.begin(SD_SCLK, SD_MISO, SD_MOSI, SD_CS);

    // Try to mount SD card
    if (!SD.begin(SD_CS)) {
        Serial.println("[USB MSC] SD card init failed - is card inserted?");
        return false;
    }

    // Get SD card info
    uint8_t cardType = SD.cardType();
    if (cardType == CARD_NONE) {
        Serial.println("[USB MSC] No SD card detected");
        return false;
    }

    const char* cardTypeName = "UNKNOWN";
    switch (cardType) {
        case CARD_MMC:  cardTypeName = "MMC"; break;
        case CARD_SD:   cardTypeName = "SD"; break;
        case CARD_SDHC: cardTypeName = "SDHC"; break;
    }
    Serial.printf("[USB MSC] Card type: %s\n", cardTypeName);

    uint64_t cardSize = SD.cardSize();
    sdCardSectors = SD.numSectors();

    if (sdCardSectors == 0) {
        Serial.println("[USB MSC] Failed to read SD card sectors");
        return false;
    }

    sdSectorSize = cardSize / sdCardSectors;
    if (sdSectorSize == 0) sdSectorSize = 512;

    Serial.printf("[USB MSC] Card size: %llu MB\n", cardSize / (1024 * 1024));
    Serial.printf("[USB MSC] Sectors: %d, Sector size: %d\n",
                  sdCardSectors, sdSectorSize);

    _initialized = true;
    return true;
}

bool SDCardUSB::start() {
    if (_active) return true;

    if (!_initialized && !init()) {
        Serial.println("[USB MSC] Failed to initialize SD card");
        return false;
    }

    Serial.println("[USB MSC] Starting MSC mode...");
    Serial.printf("[USB MSC] SD card: %d sectors, %d bytes/sector\n",
                  sdCardSectors, sdSectorSize);

    // Configure MSC
    msc.vendorID("T-Deck");
    msc.productID("MeshCore SD");
    msc.productRevision("1.0");
    msc.onRead(onRead);
    msc.onWrite(onWrite);
    msc.onStartStop(onStartStop);
    msc.mediaPresent(true);

    // Start MSC - this adds it to USB stack
    if (!msc.begin(sdCardSectors, sdSectorSize)) {
        Serial.println("[USB MSC] Failed to start MSC");
        return false;
    }

    // Note: USB.begin() may already be called for CDC serial
    // On ESP32-S3, USB is typically configured at boot
    // Calling USB.begin() again should be safe but may reinitialize
    USB.begin();

    Serial.println("[USB MSC] MSC mode active - connect USB to PC");
    Serial.println("[USB MSC] Note: Serial may disconnect when PC accesses drive");

    _active = true;
    return true;
}

void SDCardUSB::stop() {
    if (!_active) return;

    Serial.println("[USB MSC] Stopping MSC mode...");
    msc.end();
    _active = false;
}

bool SDCardUSB::isActive() {
    return _active;
}

bool SDCardUSB::isSDAvailable() {
    if (!_initialized) {
        SPI.begin(SD_SCLK, SD_MISO, SD_MOSI, SD_CS);
        return SD.begin(SD_CS);
    }
    return SD.exists("/");
}
