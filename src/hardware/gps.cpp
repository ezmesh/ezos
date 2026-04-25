#include "gps.h"
#include <sys/time.h>
#include <stdlib.h>
#include <string.h>

GPS::GPS()
    : _gsvSatsInViewGp(_gps, "GPGSV", 3),
      _gsaFixModeGp(_gps, "GPGSA", 2),
      _ggaFixQualityGp(_gps, "GPGGA", 6),
      _gsaFixModeGn(_gps, "GNGSA", 2),
      _ggaFixQualityGn(_gps, "GNGGA", 6) {}

GPS& GPS::instance() {
    static GPS inst;
    return inst;
}

bool GPS::init() {
    if (_initialized) return true;

    // Use Serial1 for GPS (TX=43, RX=44)
    _serial = &Serial1;
    _serial->begin(GPS_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);

    // Give GPS module time to start
    delay(100);

    _initialized = true;
    Serial.println("[GPS] Initialized on Serial1 (TX=43, RX=44) at 38400 baud");

    return true;
}

void GPS::update() {
    if (!_initialized || !_serial) return;

    // Read all available data from GPS. Each byte goes through
    // feedByte(), which routes UBX binary frames into the UBX state
    // machine and everything else through the NMEA pipeline.
    while (_serial->available() > 0) {
        uint8_t b = (uint8_t)_serial->read();
        _lastByteTime = millis();
        feedByte(b);
    }

    // Update cached location if valid
    if (_gps.location.isValid() && _gps.location.isUpdated()) {
        _validLocation = true;
        _latitude = _gps.location.lat();
        _longitude = _gps.location.lng();
        _lastLocationUpdate = millis();
    }

    // Update altitude
    if (_gps.altitude.isValid() && _gps.altitude.isUpdated()) {
        _altitude = _gps.altitude.meters();
    }

    // Update speed and course
    if (_gps.speed.isValid()) {
        _speed = _gps.speed.kmph();
    }
    if (_gps.course.isValid()) {
        _course = _gps.course.deg();
    }

    // Update satellite info
    if (_gps.satellites.isValid()) {
        _satellites = _gps.satellites.value();
    }
    if (_gps.hdop.isValid()) {
        _hdop = _gps.hdop.hdop();
    }

    // Update time if valid. TinyGPS++ flags its own zero-initialised
    // date (year 2000, month/day 0) as `isValid() == true` after the
    // first partial sentence it sees, so we also require a plausible
    // year before accepting the fields — otherwise callers see
    // `time.valid` true with obviously-nonsense values.
    if (_gps.time.isValid() && _gps.date.isValid() && _gps.time.isUpdated()
            && _gps.date.year() >= 2024) {
        _validTime = true;
        _hour = _gps.time.hour();
        _minute = _gps.time.minute();
        _second = _gps.time.second();
        _year = _gps.date.year();
        _month = _gps.date.month();
        _day = _gps.date.day();
        _lastTimeUpdate = millis();

        // Auto-sync system time on first real time reading. The year
        // check above already ensured the data is plausible.
        if (!_timeSynced) {
            syncSystemTime();
        }
    }
}

uint32_t GPS::getLocationAge() const {
    if (!_validLocation) return UINT32_MAX;
    return millis() - _lastLocationUpdate;
}

uint32_t GPS::getTimeAge() const {
    if (!_validTime) return UINT32_MAX;
    return millis() - _lastTimeUpdate;
}

bool GPS::syncSystemTime() {
    if (!_validTime || _year < 2024) {
        return false;
    }

    // GPS provides UTC time. Convert to Unix timestamp.
    // Use a simple calculation instead of mktime() to avoid timezone complications.
    // Days from 1970-01-01 to the GPS date
    int days = 0;
    for (int y = 1970; y < _year; y++) {
        days += (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 366 : 365;
    }
    static const int daysBeforeMonth[] = {0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};
    days += daysBeforeMonth[_month - 1] + _day - 1;
    // Leap day adjustment for current year
    if (_month > 2 && (_year % 4 == 0 && (_year % 100 != 0 || _year % 400 == 0))) {
        days++;
    }

    time_t timestamp = (time_t)days * 86400 + _hour * 3600 + _minute * 60 + _second;

    // Set system time (this is UTC)
    struct timeval tv;
    tv.tv_sec = timestamp;
    tv.tv_usec = 0;
    settimeofday(&tv, nullptr);

    // Force timezone recalculation with current TZ setting
    tzset();

    _timeSynced = true;
    Serial.printf("[GPS] System time synced: %04d-%02d-%02d %02d:%02d:%02d UTC\n",
                  _year, _month, _day, _hour, _minute, _second);

    return true;
}

// Parse a positive decimal integer out of a TinyGPSCustom field buffer.
// Returns -1 when the field hasn't been populated yet. Custom fields
// store their value as a C string; empty string means "no sentence of
// that type parsed yet."
// NOTE: TinyGPSCustom::value() is non-const (it clears an internal
// `updated` flag as a side effect), so we accept a non-const ref. The
// caller-facing wrappers are still declared const because mutating that
// flag doesn't change any observable state.
static int parseCustomInt(TinyGPSCustom& field) {
    const char* v = field.value();
    if (!v || !*v) return -1;
    return atoi(v);
}

int GPS::getSatsInView() const {
    // GSV is per-constellation (GPGSV, GLGSV, BDGSV, GAGSV) so the GP
    // listener only sees the GPS count. For a multi-GNSS module that's
    // still useful as "GPS satellites in view"; we pick this rather
    // than summing constellations to keep the existing semantics.
    return parseCustomInt(const_cast<TinyGPSCustom&>(_gsvSatsInViewGp));
}

int GPS::getFixMode() const {
    int v = parseCustomInt(const_cast<TinyGPSCustom&>(_gsaFixModeGn));
    if (v >= 0) return v;
    return parseCustomInt(const_cast<TinyGPSCustom&>(_gsaFixModeGp));
}

int GPS::getFixQuality() const {
    int v = parseCustomInt(const_cast<TinyGPSCustom&>(_ggaFixQualityGn));
    if (v >= 0) return v;
    return parseCustomInt(const_cast<TinyGPSCustom&>(_ggaFixQualityGp));
}

uint32_t GPS::getLastByteAge() const {
    if (_lastByteTime == 0) return UINT32_MAX;
    return millis() - _lastByteTime;
}

void GPS::resetCounters() {
    // Snapshot the parser's running totals — all subsequent get*() calls
    // return the delta, so the UI sees counters at zero.
    _baselineChars     = _gps.charsProcessed();
    _baselinePassed    = _gps.passedChecksum();
    _baselineFailed    = _gps.failedChecksum();
    _baselineSentences = _gps.sentencesWithFix();

    // Forget the cached fix so stale lat/lon / sat counts don't linger
    // until the next NMEA sentence arrives.
    _validLocation = false;
    _validTime     = false;
    _latitude = _longitude = _altitude = 0.0;
    _speed = _course = 0.0;
    _satellites = 0;
    _hdop = 99.9;
    _hour = _minute = _second = 0;
    _month = _day = 0;
    _year = 0;
    _lastLocationUpdate = 0;
    _lastTimeUpdate = 0;
    _lastByteTime = 0;
    // _timeSynced intentionally preserved: the system RTC is still set
    // from whatever fix we had, and letting it re-sync on the next fix
    // is harmless.

    // Talker IDs we've sniffed are diagnostic-only; clearing them on
    // reset gives a clean view of "which talkers showed up since the
    // last reset" rather than "since boot".
    _talkerIds[0] = 0;
    _talkerCount  = 0;
    _sentenceLen  = 0;

    // Drop the captured info sentence too, so a stale firmware-version
    // string doesn't make it look like the chip just answered.
    _lastInfoSentence[0] = 0;
    _lineLen     = 0;
    _lineOverflow = false;

    // UBX state is left intact. _hasVersion / _hasAck / _hasValget
    // are response flags that the synchronous wrappers manage
    // themselves; clearing them here would race with an in-flight
    // query. The mid-frame buffer (_ubxIdx) is also untouched —
    // breaking a frame in half is worse than leaving it to finish.
}

void GPS::feedByte(uint8_t b) {
    // -----------------------------------------------------------------
    // UBX binary state machine. _ubxIdx tracks how many bytes of the
    // current frame have been collected; 0 means "scanning for sync."
    // We resync on any unexpected byte, and route bytes that aren't
    // part of a UBX frame through the NMEA path below.
    // -----------------------------------------------------------------
    if (_ubxIdx > 0) {
        _ubxBuf[_ubxIdx++] = b;
        if (_ubxIdx == 2) {
            if (b != 0x62) {
                // False sync — drop the leading 0xB5 and feed this
                // byte through the NMEA pipeline as if nothing
                // happened. (NMEA never starts with 0xB5 anyway.)
                _ubxIdx = 0;
                // Fall through to NMEA handling below.
            } else {
                return;
            }
        } else if (_ubxIdx >= 6) {
            uint16_t len = (uint16_t)_ubxBuf[4] | ((uint16_t)_ubxBuf[5] << 8);
            uint16_t total = 6u + len + 2u;  // header + payload + ck
            if (total > UBX_MAX_FRAME) {
                // Implausibly large frame — likely corruption. Resync.
                _ubxIdx = 0;
            } else if (_ubxIdx == total) {
                // Frame complete. Verify Fletcher-16 over [class .. payload].
                uint8_t ckA = 0, ckB = 0;
                for (uint16_t i = 2; i < 6 + len; i++) {
                    ckA += _ubxBuf[i];
                    ckB += ckA;
                }
                if (ckA == _ubxBuf[6 + len] && ckB == _ubxBuf[7 + len]) {
                    handleUbxFrame(_ubxBuf[2], _ubxBuf[3], &_ubxBuf[6], len);
                }
                _ubxIdx = 0;
            }
            return;
        } else {
            return;
        }
    }
    if (b == 0xB5) {
        _ubxBuf[0] = b;
        _ubxIdx = 1;
        return;
    }

    // -----------------------------------------------------------------
    // NMEA path. Two parallel state machines feed off the same byte:
    // (a) the line buffer that captures whole proprietary / TXT
    //     sentences for diagnostics; (b) the talker-ID sniffer that
    //     records every "$XX" prefix encountered. The byte is also
    //     fed to TinyGPS++ for fix-sentence parsing.
    // -----------------------------------------------------------------
    char c = (char)b;
    _gps.encode(c);

    // Line buffer
    if (c == '$') {
        _lineLen = 0;
        _lineOverflow = false;
        _lineBuf[_lineLen++] = c;
    } else if (_lineLen > 0) {
        if (c == '\r' || c == '\n') {
            _lineBuf[_lineLen < sizeof(_lineBuf) ? _lineLen : sizeof(_lineBuf) - 1] = 0;
            bool keep = false;
            if (_lineLen >= 6 && !_lineOverflow) {
                if (_lineBuf[1] == 'P') {
                    keep = true;
                } else if (_lineBuf[3] == 'T' && _lineBuf[4] == 'X'
                                              && _lineBuf[5] == 'T') {
                    keep = true;
                }
            }
            if (keep) {
                strncpy(_lastInfoSentence, _lineBuf, sizeof(_lastInfoSentence) - 1);
                _lastInfoSentence[sizeof(_lastInfoSentence) - 1] = 0;
            }
            _lineLen = 0;
            _lineOverflow = false;
        } else if (_lineLen < sizeof(_lineBuf) - 1) {
            _lineBuf[_lineLen++] = c;
        } else {
            _lineOverflow = true;
        }
    }

    // Talker-ID sniffer
    if (c == '$') {
        _sentenceLen = 1;
        _sentenceBuf[0] = '$';
    } else if (_sentenceLen > 0 && _sentenceLen < 3) {
        _sentenceBuf[_sentenceLen++] = c;
        if (_sentenceLen == 3) {
            char code[2] = { _sentenceBuf[1], _sentenceBuf[2] };
            bool valid = (code[0] >= 'A' && code[0] <= 'Z')
                      && (code[1] >= 'A' && code[1] <= 'Z');
            bool seen = false;
            for (uint8_t i = 0; i < _talkerCount; i++) {
                if (_talkerIds[i*3] == code[0] && _talkerIds[i*3+1] == code[1]) {
                    seen = true;
                    break;
                }
            }
            if (valid && !seen && _talkerCount < 8) {
                if (_talkerCount > 0) {
                    _talkerIds[_talkerCount*3 - 1] = ',';
                }
                _talkerIds[_talkerCount*3]     = code[0];
                _talkerIds[_talkerCount*3 + 1] = code[1];
                _talkerIds[_talkerCount*3 + 2] = 0;
                _talkerCount++;
            }
        }
    }
}

void GPS::handleUbxFrame(uint8_t cls, uint8_t id, const uint8_t* payload, uint16_t len) {
    // ACK class: payload is [acked_class, acked_id]. id 0x01 is ACK,
    // 0x00 is NAK. We just remember the most recent one — synchronous
    // wrappers clear _hasAck before sending and poll until we set it.
    if (cls == 0x05 && len == 2 && (id == 0x00 || id == 0x01)) {
        _lastAckClass = payload[0];
        _lastAckId    = payload[1];
        _lastAckOk    = (id == 0x01);
        _hasAck       = true;
        return;
    }
    // MON-VER: 30B sw + 10B hw, both null-terminated, plus optional
    // 30B extension blocks we ignore.
    if (cls == 0x0A && id == 0x04 && len >= 40) {
        memcpy(_swVersion, payload, 30);
        _swVersion[30] = 0;
        memcpy(_hwVersion, payload + 30, 10);
        _hwVersion[10] = 0;
        _hasVersion = true;
        return;
    }
    // CFG-VALGET response. For our single-key queries the payload is
    // [version:1][layer:1][position:2][keyId:4][value:1].
    if (cls == 0x06 && id == 0x8B && len >= 9) {
        uint32_t key = (uint32_t)payload[4]
                     | ((uint32_t)payload[5] << 8)
                     | ((uint32_t)payload[6] << 16)
                     | ((uint32_t)payload[7] << 24);
        if (key == _valgetKey) {
            _valgetValue = payload[8];
            _hasValget   = true;
        }
        return;
    }
}

bool GPS::sendUbx(uint8_t cls, uint8_t id, const uint8_t* payload, uint16_t len) {
    if (!_initialized || !_serial) return false;
    uint8_t header[6] = {
        0xB5, 0x62, cls, id,
        (uint8_t)(len & 0xFF),
        (uint8_t)((len >> 8) & 0xFF)
    };
    uint8_t ckA = 0, ckB = 0;
    for (uint8_t i = 2; i < 6; i++) { ckA += header[i]; ckB += ckA; }
    for (uint16_t i = 0; i < len; i++) { ckA += payload[i]; ckB += ckA; }
    uint8_t ck[2] = { ckA, ckB };

    _serial->write(header, 6);
    if (len > 0 && payload) _serial->write(payload, len);
    _serial->write(ck, 2);
    _serial->flush();
    return true;
}

bool GPS::queryVersion(uint32_t timeoutMs) {
    _hasVersion = false;
    if (!sendUbx(0x0A, 0x04, nullptr, 0)) return false;
    uint32_t deadline = millis() + timeoutMs;
    while ((int32_t)(millis() - deadline) < 0) {
        update();
        if (_hasVersion) return true;
    }
    return false;
}

bool GPS::setSignalEnabled(uint32_t keyId, bool enabled, uint32_t timeoutMs) {
    // VALSET payload: version(0), layers, reserved(2), keyId(4 LE), value(1).
    //
    // We write to RAM (current session) + BBR (battery-backed RAM,
    // survives short power blips and the kept-alive backup). We
    // intentionally skip the Flash layer (bit 2): on the ROM-based
    // M10Q variant LilyGo ships, Flash isn't user-writable and a
    // VALSET that asks for it gets NAK'd outright. BBR is enough
    // for persistence across normal warm boots; on full power loss
    // without VBAT, settings revert to the defaults the chip's ROM
    // built-in firmware provides — which is fine, the host re-applies
    // user prefs on boot anyway.
    uint8_t payload[9] = {
        0x00,
        0x03,
        0x00, 0x00,
        (uint8_t)(keyId & 0xFF),
        (uint8_t)((keyId >> 8) & 0xFF),
        (uint8_t)((keyId >> 16) & 0xFF),
        (uint8_t)((keyId >> 24) & 0xFF),
        (uint8_t)(enabled ? 1 : 0)
    };
    _hasAck = false;
    _lastAckClass = _lastAckId = 0;
    _lastAckOk = false;
    if (!sendUbx(0x06, 0x8A, payload, sizeof(payload))) return false;
    uint32_t deadline = millis() + timeoutMs;
    while ((int32_t)(millis() - deadline) < 0) {
        update();
        if (_hasAck && _lastAckClass == 0x06 && _lastAckId == 0x8A) {
            return _lastAckOk;
        }
    }
    return false;
}

int GPS::queryConfigKey(uint32_t keyId, uint32_t timeoutMs) {
    // VALGET payload: version(0), layer(0=RAM/current), position(2), keyId(4).
    uint8_t payload[8] = {
        0x00,
        0x00,
        0x00, 0x00,
        (uint8_t)(keyId & 0xFF),
        (uint8_t)((keyId >> 8) & 0xFF),
        (uint8_t)((keyId >> 16) & 0xFF),
        (uint8_t)((keyId >> 24) & 0xFF)
    };
    _valgetKey   = keyId;
    _valgetValue = -1;
    _hasValget   = false;
    if (!sendUbx(0x06, 0x8B, payload, sizeof(payload))) return -1;
    uint32_t deadline = millis() + timeoutMs;
    while ((int32_t)(millis() - deadline) < 0) {
        update();
        if (_hasValget) return _valgetValue;
    }
    return -1;
}

bool GPS::sendCommand(const char* body) {
    if (!_initialized || !_serial || !body) return false;
    // NMEA checksum is XOR over every byte between '$' and '*',
    // exclusive. We assemble the full "$<body>*<HH>\r\n" string in one
    // buffer and write it with a single `_serial->write()` so the
    // module sees the sentence atomically — some firmware variants
    // are picky if bytes arrive in fragmented USB-CDC bursts.
    uint8_t cksum = 0;
    for (const char* p = body; *p; p++) cksum ^= (uint8_t)*p;
    char buf[96];
    int n = snprintf(buf, sizeof(buf), "$%s*%02X\r\n", body, cksum);
    if (n <= 0 || n >= (int)sizeof(buf)) return false;
    _serial->write(reinterpret_cast<const uint8_t*>(buf), (size_t)n);
    _serial->flush();
    return true;
}
