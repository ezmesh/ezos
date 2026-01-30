#pragma once

#include <Arduino.h>
#include <TinyGPS++.h>

// T-Deck Plus GPS pins (u-blox module on Grove connector)
#define GPS_TX_PIN 43
#define GPS_RX_PIN 44
#define GPS_BAUD 38400

class GPS {
public:
    static GPS& instance();

    bool init();
    void update();

    // Location data
    bool hasValidLocation() const { return _validLocation; }
    double getLatitude() const { return _latitude; }
    double getLongitude() const { return _longitude; }
    double getAltitude() const { return _altitude; }
    uint32_t getLocationAge() const;

    // Time data
    bool hasValidTime() const { return _validTime; }
    uint8_t getHour() const { return _hour; }
    uint8_t getMinute() const { return _minute; }
    uint8_t getSecond() const { return _second; }
    uint16_t getYear() const { return _year; }
    uint8_t getMonth() const { return _month; }
    uint8_t getDay() const { return _day; }
    uint32_t getTimeAge() const;

    // Movement data
    double getSpeed() const { return _speed; }  // km/h
    double getCourse() const { return _course; } // degrees

    // Satellite info
    uint32_t getSatellites() const { return _satellites; }
    double getHDOP() const { return _hdop; }

    // Status
    bool isInitialized() const { return _initialized; }
    uint32_t getCharsProcessed() const { return _gps.charsProcessed(); }
    uint32_t getSentencesWithFix() const { return _gps.sentencesWithFix(); }
    uint32_t getFailedChecksums() const { return _gps.failedChecksum(); }

    // Time sync - syncs ESP32 RTC with GPS time
    bool syncSystemTime();
    bool hasTimeSynced() const { return _timeSynced; }

private:
    GPS() = default;
    GPS(const GPS&) = delete;
    GPS& operator=(const GPS&) = delete;

    TinyGPSPlus _gps;
    HardwareSerial* _serial = nullptr;
    bool _initialized = false;

    // Cached values (updated in update())
    bool _validLocation = false;
    bool _validTime = false;
    double _latitude = 0.0;
    double _longitude = 0.0;
    double _altitude = 0.0;
    double _speed = 0.0;
    double _course = 0.0;
    uint32_t _satellites = 0;
    double _hdop = 99.9;

    uint8_t _hour = 0;
    uint8_t _minute = 0;
    uint8_t _second = 0;
    uint16_t _year = 0;
    uint8_t _month = 0;
    uint8_t _day = 0;

    uint32_t _lastLocationUpdate = 0;
    uint32_t _lastTimeUpdate = 0;
    bool _timeSynced = false;
};
