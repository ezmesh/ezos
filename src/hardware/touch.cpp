#include "touch.h"
#include "../config.h"

// GT911 register map (subset; see datasheet "Real-time Information" page).
//
// 0x8140 .. 0x8143 : product ID, 4 ASCII bytes ("911\0" on this part).
// 0x8144 .. 0x8145 : firmware version, little-endian u16.
// 0x814E           : status byte. bit7 = buffer ready, bits 0..3 = count.
// 0x814F + n*8     : point n (n=0..4), 8 bytes each:
//                      [track_id][x_lo][x_hi][y_lo][y_hi][size_lo][size_hi][reserved]
namespace {
    constexpr uint16_t REG_PRODUCT_ID   = 0x8140;
    constexpr uint16_t REG_FW_VERSION   = 0x8144;
    constexpr uint16_t REG_STATUS       = 0x814E;
    constexpr uint16_t REG_POINT_BASE   = 0x814F;
    constexpr size_t   POINT_STRIDE     = 8;
}

Touch* touch = nullptr;

bool Touch::readReg16(uint16_t reg, uint8_t* buf, size_t len) {
    Wire.beginTransmission(_addr);
    Wire.write((uint8_t)(reg >> 8));
    Wire.write((uint8_t)(reg & 0xFF));
    if (Wire.endTransmission(false) != 0) return false;

    size_t got = Wire.requestFrom((uint8_t)_addr, (uint8_t)len);
    if (got != len) return false;
    for (size_t i = 0; i < len; ++i) {
        if (!Wire.available()) return false;
        buf[i] = Wire.read();
    }
    return true;
}

bool Touch::writeReg16(uint16_t reg, const uint8_t* buf, size_t len) {
    Wire.beginTransmission(_addr);
    Wire.write((uint8_t)(reg >> 8));
    Wire.write((uint8_t)(reg & 0xFF));
    for (size_t i = 0; i < len; ++i) Wire.write(buf[i]);
    return Wire.endTransmission(true) == 0;
}

bool Touch::clearStatus() {
    uint8_t zero = 0x00;
    return writeReg16(REG_STATUS, &zero, 1);
}

bool Touch::init() {
    // INT is left as input -- on this board we poll. Pulling it as
    // input gives the controller's edge a defined load and avoids
    // misreading the boot-time address-select pulse.
    pinMode(TOUCH_INT, INPUT);

    // The shared Wire bus is brought up by the keyboard initialiser
    // before us; if that never ran the controller won't answer. Probe
    // the high address first (observed on real hardware) and fall
    // back to the low address so a different board revision still
    // works without a code change.
    _addr = 0;
    const uint8_t candidates[] = { TOUCH_I2C_ADDR_H, TOUCH_I2C_ADDR_L };
    for (uint8_t a : candidates) {
        Wire.beginTransmission(a);
        if (Wire.endTransmission() == 0) { _addr = a; break; }
    }
    if (_addr == 0) {
        Serial.println("Touch: GT911 not responding on I2C (tried 0x14 + 0x5D)");
        return false;
    }

    uint8_t pid[4] = {0};
    if (!readReg16(REG_PRODUCT_ID, pid, 4)) {
        Serial.printf("Touch: read product id failed at 0x%02X\n", _addr);
        return false;
    }
    memcpy(_productId, pid, 4);
    _productId[4] = 0;

    uint8_t fw[2] = {0};
    if (readReg16(REG_FW_VERSION, fw, 2)) {
        _fwVersion = (uint16_t)fw[0] | ((uint16_t)fw[1] << 8);
    }

    // Make sure the buffer-ready flag is cleared so the first read()
    // after boot sees a fresh sample rather than a stale one captured
    // during pre-boot self-test.
    clearStatus();

    Serial.printf("Touch GT911 OK -- addr=0x%02X id=\"%s\" fw=0x%04X\n",
                  _addr, _productId, _fwVersion);
    _ok = true;
    return true;
}

bool Touch::available() {
    if (!_ok) return false;
    uint8_t status = 0;
    if (!readReg16(REG_STATUS, &status, 1)) return false;
    return (status & 0x80) != 0;
}

int Touch::read(Point* out) {
    if (!_ok || out == nullptr) return -1;

    uint8_t status = 0;
    if (!readReg16(REG_STATUS, &status, 1)) return -1;
    // Bit 7 = "buffer ready". When clear the controller has no fresh
    // sample yet; return -1 so the caller skips the diff pass instead
    // of treating the missing data as "all fingers lifted" and firing
    // a spurious touch/up that would chop a continuous drag into a
    // string of rapid down/up pairs.
    if ((status & 0x80) == 0) return -1;

    int count = status & 0x0F;
    if (count > MAX_POINTS) count = MAX_POINTS;

    // Read all points in a single burst. The GT911 auto-increments the
    // address after the first byte so this is fewer round-trips than
    // 5 separate read() calls and keeps the I2C arbitration window
    // small (the keyboard polls the same bus from another task).
    if (count > 0) {
        uint8_t buf[POINT_STRIDE * MAX_POINTS] = {0};
        if (readReg16(REG_POINT_BASE, buf, POINT_STRIDE * count)) {
            for (int i = 0; i < count; ++i) {
                const uint8_t* p = buf + i * POINT_STRIDE;
                uint16_t raw_x = (uint16_t)p[1] | ((uint16_t)p[2] << 8);
                uint16_t raw_y = (uint16_t)p[3] | ((uint16_t)p[4] << 8);

                // The GT911 reports coordinates in the panel's native
                // portrait frame (240 wide x 320 tall). The display is
                // configured for landscape via LovyanGFX rotation 1
                // (90 deg clockwise), so a touch at the right edge of
                // the visible screen comes back as a high *raw_y*, not
                // a high raw_x. Apply the matching rotation here so
                // every consumer sees screen-space pixels (0..319 X,
                // 0..239 Y). If the display rotation ever becomes
                // user-configurable this will need to read from the
                // Display singleton instead of being hard-coded.
                static constexpr uint16_t PANEL_NATIVE_W = 240;
                uint16_t screen_x = raw_y;
                uint16_t screen_y = (raw_x < PANEL_NATIVE_W)
                    ? (PANEL_NATIVE_W - 1 - raw_x)
                    : 0;

                out[i].id   = p[0];
                out[i].x    = screen_x;
                out[i].y    = screen_y;
                out[i].size = (uint16_t)p[5] | ((uint16_t)p[6] << 8);
            }
        } else {
            count = 0;
        }
    }

    // Critical: clearing the status byte tells the controller it can
    // overwrite the next sample into the same registers. Skip this
    // and we'd see the same coordinates frame after frame even as the
    // user moves their finger.
    clearStatus();
    return count;
}
