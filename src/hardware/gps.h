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

    // Status. All counter getters report values since the last
    // resetCounters() call, so the UI can zero the debug stats without
    // reaching into the parser.
    bool isInitialized() const { return _initialized; }
    uint32_t getCharsProcessed() const   { return _gps.charsProcessed()   - _baselineChars; }
    uint32_t getSentencesWithFix() const { return _gps.sentencesWithFix() - _baselineSentences; }
    uint32_t getFailedChecksums() const  { return _gps.failedChecksum()   - _baselineFailed; }
    uint32_t getPassedChecksums() const  { return _gps.passedChecksum()   - _baselinePassed; }

    // Extended diagnostics pulled via TinyGPSCustom from specific NMEA
    // fields. Return 0 / -1 when the module hasn't sent the relevant
    // sentence yet, so the UI can render a "-" placeholder.
    int getSatsInView() const;    // GPGSV field 3
    int getFixMode() const;       // GPGSA field 2: 1=no, 2=2D, 3=3D
    int getFixQuality() const;    // GPGGA field 6: 0=no, 1=GPS, 2=DGPS, 4=RTK, ...

    // ms since last byte was read off the UART. UINT32_MAX if no byte
    // ever arrived. Jumps up when the module stops talking.
    uint32_t getLastByteAge() const;

    // Zero the stats counters and clear cached fix state. Baselines are
    // snapshotted against the parser's running counters so we never have
    // to touch TinyGPS++ internals.
    void resetCounters();

    // Time sync - syncs ESP32 RTC with GPS time
    bool syncSystemTime();
    bool hasTimeSynced() const { return _timeSynced; }

private:
    GPS();
    GPS(const GPS&) = delete;
    GPS& operator=(const GPS&) = delete;

    TinyGPSPlus _gps;
    TinyGPSCustom _gsvSatsInView;
    TinyGPSCustom _gsaFixMode;
    TinyGPSCustom _ggaFixQuality;
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
    uint32_t _lastByteTime = 0;       // 0 = no byte seen yet
    bool _timeSynced = false;

    // Baselines subtracted from TinyGPSPlus's counters so resetCounters()
    // zeros the reported values without disturbing the parser itself.
    uint32_t _baselineChars     = 0;
    uint32_t _baselinePassed    = 0;
    uint32_t _baselineFailed    = 0;
    uint32_t _baselineSentences = 0;
};
