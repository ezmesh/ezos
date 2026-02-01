#include "gps.h"
#include <sys/time.h>
#include <stdlib.h>
#include <string.h>

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

    // Read all available data from GPS
    while (_serial->available() > 0) {
        char c = _serial->read();
        _gps.encode(c);
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

    // Update time if valid
    if (_gps.time.isValid() && _gps.date.isValid() && _gps.time.isUpdated()) {
        _validTime = true;
        _hour = _gps.time.hour();
        _minute = _gps.time.minute();
        _second = _gps.time.second();
        _year = _gps.date.year();
        _month = _gps.date.month();
        _day = _gps.date.day();
        _lastTimeUpdate = millis();

        // Auto-sync system time on first valid fix
        if (!_timeSynced && _year >= 2024) {
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
