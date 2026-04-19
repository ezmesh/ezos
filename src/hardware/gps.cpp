#include "gps.h"
#include <sys/time.h>
#include <stdlib.h>
#include <string.h>

GPS::GPS()
    : _gsvSatsInView(_gps, "GPGSV", 3),
      _gsaFixMode(_gps, "GPGSA", 2),
      _ggaFixQuality(_gps, "GPGGA", 6) {}

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

    // Read all available data from GPS. Track the last-byte timestamp so
    // the debug page can surface "module went silent" failures (UART
    // disconnected, module lost power, etc.) distinct from "no fix yet".
    while (_serial->available() > 0) {
        char c = _serial->read();
        _gps.encode(c);
        _lastByteTime = millis();
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
    return parseCustomInt(const_cast<TinyGPSCustom&>(_gsvSatsInView));
}

int GPS::getFixMode() const {
    return parseCustomInt(const_cast<TinyGPSCustom&>(_gsaFixMode));
}

int GPS::getFixQuality() const {
    return parseCustomInt(const_cast<TinyGPSCustom&>(_ggaFixQuality));
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
}
