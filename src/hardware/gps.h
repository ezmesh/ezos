#pragma once

#include <Arduino.h>
#include <TinyGPS++.h>

// T-Deck Plus GPS pins. The on-board module is a Quectel L76K (multi-GNSS:
// GPS + Galileo + BeiDou + QZSS), wired to UART1 of the ESP32-S3.
// LilyGo's factory configuration sets the L76K to 38400 baud and
// persists it in NVRAM, so we don't reconfigure on boot.
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
    // sentence yet, so the UI can render a "-" placeholder. Each metric
    // checks both the GP- and GN-prefixed custom field — the L76K (and
    // most modern multi-GNSS receivers) emit GNxxx sentences when more
    // than one constellation is being tracked.
    int getSatsInView() const;    // GPGSV / GLGSV ... field 3 (per-constellation)
    int getFixMode() const;       // [GP|GN]GSA field 2: 1=no, 2=2D, 3=3D
    int getFixQuality() const;    // [GP|GN]GGA field 6: 0=no, 1=GPS, 2=DGPS, 4=RTK, ...

    // ms since last byte was read off the UART. UINT32_MAX if no byte
    // ever arrived. Jumps up when the module stops talking.
    uint32_t getLastByteAge() const;

    // Comma-separated list of NMEA talker IDs observed since boot
    // (e.g. "GN,GP,GL,BD"). Empty when nothing's parsed yet. Useful for
    // diagnosing why custom fields aren't matching — if the module is
    // emitting GN-prefixed sentences, GP-only listeners stay silent.
    const char* getTalkerIds() const { return _talkerIds; }

    // Send a proprietary NMEA command. The body is the part between
    // '$' and '*' — e.g. "PCAS04,7" or "PCAS06,0". This computes the
    // XOR checksum and appends "\r\n". Returns false if the GPS UART
    // isn't open. Fire-and-forget; any response shows up via
    // getLastInfoSentence(). Note that the LilyGo T-Deck Plus ships
    // with a u-blox MIA-M10Q which doesn't accept these commands —
    // use the UBX helpers below instead. This stays as a generic
    // diagnostic escape hatch.
    bool sendCommand(const char* body);

    // Most recently captured "$P..." or "$GxTXT" sentence, including
    // talker ID and checksum (e.g. "$GPTXT,01,01,02,SW=URANUS5,V5.1.0.0*1D").
    // Empty string until the module has emitted one. These are the
    // responses to $PCAS06,N queries and any other vendor-specific
    // status messages — standard fix sentences (RMC/GGA/GSV/...) are
    // intentionally not captured here.
    const char* getLastInfoSentence() const { return _lastInfoSentence; }

    // -------------------------------------------------------------------
    // UBX binary protocol (u-blox)
    // -------------------------------------------------------------------
    //
    // The MIA-M10Q on the T-Deck Plus is configured via UBX binary
    // frames, not NMEA. We feed every incoming byte through a small
    // state machine in update() that recognises the "B5 62" sync and
    // captures complete frames; everything else falls through to the
    // NMEA parser. The blocking helpers below send a frame and pump
    // update() in a tight loop until the matching response arrives or
    // the timeout expires.

    // Send a UBX frame: $sync $class $id $len_le $payload $ck_a $ck_b.
    // Fletcher-16 checksum is computed over class+id+len+payload.
    // Fire-and-forget; for ACK-bearing CFG messages, use the
    // setSignalEnabled / queryConfigKey wrappers instead.
    bool sendUbx(uint8_t cls, uint8_t id, const uint8_t* payload, uint16_t len);

    // Send UBX-MON-VER and block until the response arrives or the
    // timeout fires. Populates getSwVersion() / getHwVersion() on
    // success. Returns true if both strings are populated.
    bool queryVersion(uint32_t timeoutMs = 800);
    bool hasVersion() const { return _hasVersion; }
    const char* getSwVersion() const { return _swVersion; }
    const char* getHwVersion() const { return _hwVersion; }

    // Toggle a CFG-SIGNAL-* key (any L-typed item works). Writes to
    // RAM + BBR + Flash so the change persists across power cycles.
    // Blocks until UBX-ACK-ACK / ACK-NAK matching CFG-VALSET arrives.
    // Returns true on ACK, false on NAK or timeout.
    bool setSignalEnabled(uint32_t keyId, bool enabled, uint32_t timeoutMs = 800);

    // Read a CFG-SIGNAL-* key from the chip (Flash layer — what
    // survives a reboot). Returns 1, 0 or -1 (timeout / unknown key).
    int queryConfigKey(uint32_t keyId, uint32_t timeoutMs = 800);

    // Diagnostic accessors for the most recent UBX-ACK frame received,
    // intended for debugging the VALSET path. After a CFG send, these
    // tell you whether the chip ever answered, and with ACK or NAK.
    bool    hasAck()       const { return _hasAck; }
    uint8_t getLastAckCls() const { return _lastAckClass; }
    uint8_t getLastAckId()  const { return _lastAckId; }
    bool    getLastAckOk()  const { return _lastAckOk; }

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
    // Two sets of custom fields: one for GP-prefixed sentences (GPS-only
    // legacy receivers) and one for GN-prefixed (combined GNSS, what the
    // L76K emits when tracking multiple constellations). Whichever set
    // the module actually populates wins — the getters below pick
    // whichever has a value.
    TinyGPSCustom _gsvSatsInViewGp;
    TinyGPSCustom _gsaFixModeGp;
    TinyGPSCustom _ggaFixQualityGp;
    TinyGPSCustom _gsaFixModeGn;
    TinyGPSCustom _ggaFixQualityGn;
    HardwareSerial* _serial = nullptr;
    bool _initialized = false;

    // Talker-ID tracking. We watch the start of every NMEA sentence
    // ("$XX...") and remember which 2-letter talker codes have been
    // seen, so the diagnostics screen can show what the module is
    // actually emitting. Up to 8 distinct codes; 24 chars is enough for
    // the comma-separated list (e.g. "GN,GP,GL,GA,BD,GQ").
    char _talkerIds[24] = {0};
    uint8_t _talkerCount = 0;
    char _sentenceBuf[6] = {0};   // "$XXxxx" capture as the sentence streams in
    uint8_t _sentenceLen = 0;

    // Line-level capture for proprietary / TXT sentences. The L76K's
    // responses to $PCAS06 etc. arrive as a "$PCAS50,..." or
    // "$GPTXT,..." line; we buffer the current line as it streams
    // through and copy it to _lastInfoSentence when it terminates,
    // ignoring standard fix sentences. 96 chars covers the longest
    // PCAS responses comfortably.
    char _lineBuf[96] = {0};
    uint16_t _lineLen = 0;
    bool _lineOverflow = false;
    char _lastInfoSentence[96] = {0};

    // UBX binary frame parser. _ubxBuf holds the in-flight frame
    // (sync bytes through ck_b). _ubxIdx is the next write position;
    // 0 means "scanning for sync." Max frame size is 6 (header) +
    // 256 (max payload we care about; CFG-VALSET single key is 9) +
    // 2 (checksum) = 264, but we cap inbound payload at 256 since
    // bigger frames are likely garbage.
    static constexpr uint16_t UBX_MAX_FRAME = 264;
    uint8_t  _ubxBuf[UBX_MAX_FRAME] = {0};
    uint16_t _ubxIdx = 0;

    // MON-VER response capture
    bool _hasVersion = false;
    char _swVersion[32] = {0};   // 30 + null
    char _hwVersion[12] = {0};   // 10 + null

    // ACK tracking. _lastAckClass / _lastAckId hold the (cls,id) of
    // the message that was acknowledged; _lastAckOk is true for
    // UBX-ACK-ACK and false for UBX-ACK-NAK. The synchronous
    // wrappers clear these before sending so they only return on a
    // fresh response.
    uint8_t  _lastAckClass = 0;
    uint8_t  _lastAckId    = 0;
    bool     _lastAckOk    = false;
    bool     _hasAck       = false;

    // VALGET response capture. Caller stores the key being queried
    // here; the parser fills _valgetValue when the matching reply
    // arrives.
    uint32_t _valgetKey   = 0;
    int16_t  _valgetValue = -1;
    bool     _hasValget   = false;

    // Internal helpers
    void feedByte(uint8_t c);
    void handleUbxFrame(uint8_t cls, uint8_t id, const uint8_t* payload, uint16_t len);

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
