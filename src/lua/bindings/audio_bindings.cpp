// ez.audio module bindings
// Provides audio/tone generation functions using I2S

#include "../lua_bindings.h"
#include "../../config.h"
#include <Arduino.h>
#include <driver/i2s.h>
#include <cmath>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <LittleFS.h>
#include <SD.h>
#include "MP3DecoderHelix.h"

// @module ez.audio
// @brief Audio synthesis and playback via I2S DAC
// @description
// Plays audio through the T-Deck speaker via I2S. Supports multiple formats:
// WAV files (PCM, 8/16-bit, mono/stereo), MP3 files (decoded with Helix), and
// raw PCM samples. Also provides tone synthesis for beeps and alerts. Use
// play() for automatic format detection, or play_wav()/play_mp3() directly.
// Audio output is mono at 44100Hz with volume control.
// @end

// I2S configuration
static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr int SAMPLE_RATE = 44100;
static constexpr int SAMPLE_RATE_PCM = 22050;  // PCM files are at 22050Hz
static constexpr int AMPLITUDE = 16000;

// Audio state
static TaskHandle_t audioTaskHandle = nullptr;
static volatile bool audioRunning = false;
static volatile uint32_t audioFrequency = 440;
static volatile bool i2sInitialized = false;
static volatile uint32_t toneEndTime = 0;
static volatile bool toneHasDuration = false;
static volatile uint8_t audioVolume = 100;  // 0-100 volume level

static bool initI2S() {
    if (i2sInitialized) return true;

    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
        .sample_rate = SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = 256,
        .use_apll = false,
        .tx_desc_auto_clear = true,
        .fixed_mclk = 0
    };

    i2s_pin_config_t pin_config = {
        .bck_io_num = I2S_BCK_PIN,
        .ws_io_num = I2S_WS_PIN,
        .data_out_num = I2S_DATA_OUT,
        .data_in_num = I2S_PIN_NO_CHANGE
    };

    esp_err_t err = i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
    if (err != ESP_OK) {
        Serial.printf("[Audio] I2S driver install failed: %d\n", err);
        return false;
    }

    err = i2s_set_pin(I2S_PORT, &pin_config);
    if (err != ESP_OK) {
        Serial.printf("[Audio] I2S set pin failed: %d\n", err);
        i2s_driver_uninstall(I2S_PORT);
        return false;
    }

    i2sInitialized = true;
    return true;
}

// Background audio generation task
static void audioTask(void* param) {
    float phase = 0;
    int16_t samples[256];

    while (true) {
        // Check if timed tone should end
        if (toneHasDuration && audioRunning && millis() >= toneEndTime) {
            audioRunning = false;
            toneHasDuration = false;
        }

        if (audioRunning) {
            uint32_t freq = audioFrequency;
            float phaseIncrement = 2.0f * M_PI * freq / SAMPLE_RATE;
            float volumeScale = audioVolume / 100.0f;

            for (int i = 0; i < 256; i++) {
                samples[i] = (int16_t)(AMPLITUDE * volumeScale * sinf(phase));
                phase += phaseIncrement;
                if (phase >= 2.0f * M_PI) {
                    phase -= 2.0f * M_PI;
                }
            }

            size_t bytes_written;
            i2s_write(I2S_PORT, samples, sizeof(samples), &bytes_written, portMAX_DELAY);
        } else {
            vTaskDelay(10 / portTICK_PERIOD_MS);
        }
    }
}

static void ensureAudioTask() {
    if (!initI2S()) return;

    if (audioTaskHandle == nullptr) {
        xTaskCreatePinnedToCore(
            audioTask,
            "lua_audio",
            4096,
            nullptr,
            5,
            &audioTaskHandle,
            1
        );
    }
}

static void stopAudio() {
    audioRunning = false;
    toneHasDuration = false;

    if (i2sInitialized) {
        int16_t silence[256] = {0};
        size_t bytes_written;
        i2s_write(I2S_PORT, silence, sizeof(silence), &bytes_written, 10);
    }
}

// @lua ez.audio.play_tone(frequency, duration_ms) -> boolean
// @brief Play a tone for specified duration
// @description Plays a sine wave tone at the given frequency. The tone plays in
// the background and stops automatically after the duration. Non-blocking, so
// your code continues while the tone plays. Use is_playing() to check status.
// @param frequency Frequency in Hz (20-20000)
// @param duration_ms Duration in milliseconds
// @return true if started successfully
// @example
// -- Play a 440Hz (A4) beep for half a second
// ez.audio.play_tone(440, 500)
// -- Play a higher alert tone
// ez.audio.play_tone(880, 200)
// @end
LUA_FUNCTION(l_audio_play_tone) {
    LUA_CHECK_ARGC(L, 2);
    int frequency = luaL_checkinteger(L, 1);
    int duration = luaL_checkinteger(L, 2);

    if (frequency < 20 || frequency > 20000) {
        lua_pushboolean(L, false);
        return 1;
    }

    ensureAudioTask();

    audioFrequency = frequency;
    toneEndTime = millis() + duration;
    toneHasDuration = true;
    audioRunning = true;

    lua_pushboolean(L, true);
    return 1;
}

// @lua ez.audio.stop()
// @brief Stop audio playback
// @description Immediately stops any playing tone or sample. Also clears any
// pending timed duration, so the audio won't resume.
// @example
// ez.audio.start()  -- Start continuous tone
// ez.system.delay(1000)
// ez.audio.stop()   -- Stop after 1 second
// @end
LUA_FUNCTION(l_audio_stop) {
    stopAudio();
    return 0;
}

// @lua ez.audio.is_playing() -> boolean
// @brief Check if audio is playing
// @description Returns true if a tone or sample is currently playing. Useful for
// waiting until audio completes before starting another sound.
// @return true if playing
// @example
// ez.audio.play_tone(440, 500)
// while ez.audio.is_playing() do
//     ez.system.delay(10)
// end
// print("Tone finished!")
// @end
LUA_FUNCTION(l_audio_is_playing) {
    lua_pushboolean(L, audioRunning);
    return 1;
}

// @lua ez.audio.beep(count, frequency, on_ms, off_ms)
// @brief Play a series of beeps (blocking)
// @description Plays one or more beeps with configurable timing. This function
// blocks until all beeps complete. Good for alerts and notifications. Parameters
// are constrained to safe ranges (count: 1-10, frequency: 100-5000Hz, timing: 10-500ms).
// @param count Number of beeps (default 1)
// @param frequency Tone frequency in Hz (default 1000)
// @param on_ms Beep duration in ms (default 100)
// @param off_ms Pause between beeps in ms (default 50)
// @example
// ez.audio.beep()           -- Single default beep
// ez.audio.beep(2)          -- Two beeps
// ez.audio.beep(3, 2000)    -- Three high-pitched beeps
// ez.audio.beep(1, 500, 200, 0)  -- One low 200ms beep
// @end
LUA_FUNCTION(l_audio_beep) {
    int count = luaL_optintegerdefault(L, 1, 1);
    int frequency = luaL_optintegerdefault(L, 2, 1000);
    int onMs = luaL_optintegerdefault(L, 3, 100);
    int offMs = luaL_optintegerdefault(L, 4, 50);

    count = constrain(count, 1, 10);
    frequency = constrain(frequency, 100, 5000);
    onMs = constrain(onMs, 10, 500);
    offMs = constrain(offMs, 10, 500);

    ensureAudioTask();

    for (int i = 0; i < count; i++) {
        audioFrequency = frequency;
        audioRunning = true;
        delay(onMs);
        audioRunning = false;
        if (i < count - 1) {
            delay(offMs);
        }
    }

    // Ensure silence at end
    stopAudio();

    return 0;
}

// @lua ez.audio.set_frequency(frequency) -> boolean
// @brief Set playback frequency for continuous tones
// @description Changes the frequency of the tone generator. If a tone is already
// playing, the frequency changes immediately (smooth transition). Combine with
// start() and stop() for custom tone patterns.
// @param frequency Frequency in Hz (20-20000)
// @return true if valid frequency
// @example
// ez.audio.start()
// for freq = 200, 800, 50 do
//     ez.audio.set_frequency(freq)
//     ez.system.delay(50)
// end
// ez.audio.stop()
// @end
LUA_FUNCTION(l_audio_set_frequency) {
    LUA_CHECK_ARGC(L, 1);
    int frequency = luaL_checkinteger(L, 1);

    if (frequency < 20 || frequency > 20000) {
        lua_pushboolean(L, false);
        return 1;
    }

    audioFrequency = frequency;
    lua_pushboolean(L, true);
    return 1;
}

// @lua ez.audio.start()
// @brief Start continuous tone at current frequency
// @description Starts playing a continuous tone at the current frequency (set via
// set_frequency, default 440Hz). The tone plays until stop() is called. Use this
// with set_frequency() for custom sound effects like sirens or sweeps.
// @example
// ez.audio.set_frequency(1000)
// ez.audio.start()
// -- Tone plays continuously until stopped
// ez.system.delay(2000)
// ez.audio.stop()
// @end
LUA_FUNCTION(l_audio_start) {
    ensureAudioTask();
    toneHasDuration = false;
    audioRunning = true;
    return 0;
}

// @lua ez.audio.set_volume(level)
// @brief Set audio volume level
// @description Sets the master volume for all audio output. Affects both tones
// and samples. The setting persists until changed. Volume 0 is silent, 100 is max.
// @param level Volume level 0-100
// @example
// ez.audio.set_volume(50)  -- Half volume
// ez.audio.beep()
// ez.audio.set_volume(100) -- Full volume
// @end
LUA_FUNCTION(l_audio_set_volume) {
    LUA_CHECK_ARGC(L, 1);
    int level = luaL_checkinteger(L, 1);
    audioVolume = constrain(level, 0, 100);
    return 0;
}

// @lua ez.audio.get_volume() -> integer
// @brief Get current volume level
// @description Returns the current master volume setting. Use this to save/restore
// volume levels or display the current volume in a settings screen.
// @return Volume level 0-100
// @example
// local vol = ez.audio.get_volume()
// print("Current volume:", vol .. "%")
// @end
LUA_FUNCTION(l_audio_get_volume) {
    lua_pushinteger(L, audioVolume);
    return 1;
}

// @lua ez.audio.play_sample(filename) -> boolean
// @brief Play a PCM sample file from LittleFS
// @description Plays a raw PCM audio file from the /sounds/ directory. Files must be
// 16-bit signed, 22050Hz mono format (.pcm extension). The function blocks until
// playback completes. Use for sound effects, alerts, or short audio clips. Convert
// audio files using: ffmpeg -i input.wav -f s16le -ar 22050 -ac 1 output.pcm
// @param filename Path to .pcm file (relative to /sounds/, extension optional)
// @return true if played successfully, false if file not found
// @example
// -- Play a notification sound
// ez.audio.play_sample("notify")
// -- Play with full path
// ez.audio.play_sample("alerts/warning.pcm")
// @end
LUA_FUNCTION(l_audio_play_sample) {
    LUA_CHECK_ARGC(L, 1);
    const char* filename = luaL_checkstring(L, 1);

    if (!initI2S()) {
        lua_pushboolean(L, false);
        return 1;
    }

    // Stop any running audio first
    audioRunning = false;

    // Build full path
    String path = "/sounds/";
    path += filename;
    if (!path.endsWith(".pcm")) {
        path += ".pcm";
    }

    // Open file
    File file = LittleFS.open(path, "r");
    if (!file) {
        Serial.printf("[Audio] Failed to open: %s\n", path.c_str());
        lua_pushboolean(L, false);
        return 1;
    }

    size_t fileSize = file.size();
    size_t numSamples = fileSize / 2;  // 16-bit samples

    // Read and play in chunks, upsampling 2x (22050 -> 44100)
    int16_t readBuf[128];
    int16_t playBuf[256];  // 2x for upsampling
    float volumeScale = audioVolume / 100.0f;

    while (file.available()) {
        size_t bytesRead = file.read((uint8_t*)readBuf, sizeof(readBuf));
        size_t samplesRead = bytesRead / 2;

        // Upsample 2x and apply volume
        for (size_t i = 0; i < samplesRead; i++) {
            int16_t sample = (int16_t)(readBuf[i] * volumeScale);
            playBuf[i * 2] = sample;
            playBuf[i * 2 + 1] = sample;  // Duplicate for 2x upsampling
        }

        // Write to I2S
        size_t bytesWritten;
        i2s_write(I2S_PORT, playBuf, samplesRead * 4, &bytesWritten, portMAX_DELAY);
    }

    file.close();

    // Write silence to flush
    int16_t silence[256] = {0};
    size_t bytesWritten;
    i2s_write(I2S_PORT, silence, sizeof(silence), &bytesWritten, 10);

    lua_pushboolean(L, true);
    return 1;
}

// WAV header structure
struct WavHeader {
    char riff[4];           // "RIFF"
    uint32_t fileSize;      // File size - 8
    char wave[4];           // "WAVE"
    char fmt[4];            // "fmt "
    uint32_t fmtSize;       // Format chunk size (16 for PCM)
    uint16_t audioFormat;   // 1 = PCM
    uint16_t numChannels;   // 1 = mono, 2 = stereo
    uint32_t sampleRate;    // Sample rate in Hz
    uint32_t byteRate;      // Bytes per second
    uint16_t blockAlign;    // Bytes per sample frame
    uint16_t bitsPerSample; // Bits per sample
};

// Parse WAV file header and find data chunk
static bool parseWavHeader(File& file, WavHeader& header, uint32_t& dataSize) {
    // Read RIFF header
    if (file.read((uint8_t*)&header, sizeof(WavHeader)) != sizeof(WavHeader)) {
        return false;
    }

    // Verify RIFF/WAVE signature
    if (memcmp(header.riff, "RIFF", 4) != 0 || memcmp(header.wave, "WAVE", 4) != 0) {
        Serial.println("[Audio] Invalid WAV: missing RIFF/WAVE");
        return false;
    }

    // Verify fmt chunk
    if (memcmp(header.fmt, "fmt ", 4) != 0) {
        Serial.println("[Audio] Invalid WAV: missing fmt chunk");
        return false;
    }

    // Only support PCM format
    if (header.audioFormat != 1) {
        Serial.printf("[Audio] Unsupported WAV format: %d (only PCM supported)\n", header.audioFormat);
        return false;
    }

    // Only support 8 or 16 bit samples
    if (header.bitsPerSample != 8 && header.bitsPerSample != 16) {
        Serial.printf("[Audio] Unsupported bits per sample: %d\n", header.bitsPerSample);
        return false;
    }

    // Skip any extra format bytes
    if (header.fmtSize > 16) {
        file.seek(file.position() + header.fmtSize - 16);
    }

    // Find data chunk
    char chunkId[4];
    uint32_t chunkSize;
    while (file.available()) {
        if (file.read((uint8_t*)chunkId, 4) != 4) return false;
        if (file.read((uint8_t*)&chunkSize, 4) != 4) return false;

        if (memcmp(chunkId, "data", 4) == 0) {
            dataSize = chunkSize;
            return true;
        }
        // Skip unknown chunks
        file.seek(file.position() + chunkSize);
    }

    Serial.println("[Audio] Invalid WAV: no data chunk found");
    return false;
}

// @lua ez.audio.play_wav(filename) -> boolean
// @brief Play a WAV audio file
// @description Plays a WAV file from the /sounds/ directory or SD card. Supports
// PCM format with 8 or 16 bit samples, mono or stereo, at any sample rate (resampled
// to 44100Hz). This function blocks until playback completes. WAV is ideal for
// short sound effects and UI feedback.
// @param filename Path to .wav file (relative to /sounds/ for LittleFS, or full path starting with /sd/ for SD card)
// @return true if played successfully, false on error
// @example
// -- Play from internal storage
// ez.audio.play_wav("click.wav")
// -- Play from SD card
// ez.audio.play_wav("/sd/music/song.wav")
// @end
LUA_FUNCTION(l_audio_play_wav) {
    LUA_CHECK_ARGC(L, 1);
    const char* filename = luaL_checkstring(L, 1);

    if (!initI2S()) {
        lua_pushboolean(L, false);
        return 1;
    }

    // Stop any running audio
    audioRunning = false;

    // Determine file source (SD card or LittleFS)
    File file;
    bool useSD = (strncmp(filename, "/sd/", 4) == 0);

    if (useSD) {
        file = SD.open(filename + 3);  // Skip "/sd" prefix
    } else {
        String path = "/sounds/";
        path += filename;
        file = LittleFS.open(path, "r");
    }

    if (!file) {
        Serial.printf("[Audio] Failed to open WAV: %s\n", filename);
        lua_pushboolean(L, false);
        return 1;
    }

    // Parse WAV header
    WavHeader header;
    uint32_t dataSize;
    if (!parseWavHeader(file, header, dataSize)) {
        file.close();
        lua_pushboolean(L, false);
        return 1;
    }

    Serial.printf("[Audio] WAV: %dHz, %d-bit, %s, %u bytes\n",
                  header.sampleRate, header.bitsPerSample,
                  header.numChannels == 1 ? "mono" : "stereo", dataSize);

    // Calculate resampling ratio
    float resampleRatio = (float)SAMPLE_RATE / header.sampleRate;
    float volumeScale = audioVolume / 100.0f;
    bool is16bit = (header.bitsPerSample == 16);
    bool isStereo = (header.numChannels == 2);
    int bytesPerSample = (header.bitsPerSample / 8) * header.numChannels;

    // Buffers for reading and playback
    uint8_t readBuf[512];
    int16_t playBuf[512];

    float srcPos = 0;  // Position in source samples
    int16_t prevSample = 0;
    size_t bytesRemaining = dataSize;

    while (bytesRemaining > 0) {
        size_t toRead = min((size_t)sizeof(readBuf), bytesRemaining);
        size_t bytesRead = file.read(readBuf, toRead);
        if (bytesRead == 0) break;
        bytesRemaining -= bytesRead;

        int srcSamples = bytesRead / bytesPerSample;
        int playPos = 0;

        // Resample and convert to 16-bit mono
        while (srcPos < srcSamples && playPos < 512) {
            int srcIdx = (int)srcPos;
            int16_t sample;

            if (is16bit) {
                int16_t* src16 = (int16_t*)readBuf;
                if (isStereo) {
                    // Mix stereo to mono
                    sample = (src16[srcIdx * 2] + src16[srcIdx * 2 + 1]) / 2;
                } else {
                    sample = src16[srcIdx];
                }
            } else {
                // Convert 8-bit unsigned to 16-bit signed
                uint8_t* src8 = readBuf;
                if (isStereo) {
                    int mono = ((int)src8[srcIdx * 2] + src8[srcIdx * 2 + 1]) / 2;
                    sample = (mono - 128) << 8;
                } else {
                    sample = (src8[srcIdx] - 128) << 8;
                }
            }

            playBuf[playPos++] = (int16_t)(sample * volumeScale);
            srcPos += 1.0f / resampleRatio;
        }

        // Adjust source position for next chunk
        srcPos -= srcSamples;

        // Write to I2S
        if (playPos > 0) {
            size_t bytesWritten;
            i2s_write(I2S_PORT, playBuf, playPos * sizeof(int16_t), &bytesWritten, portMAX_DELAY);
        }
    }

    file.close();

    // Flush with silence
    int16_t silence[256] = {0};
    size_t bytesWritten;
    i2s_write(I2S_PORT, silence, sizeof(silence), &bytesWritten, 10);

    lua_pushboolean(L, true);
    return 1;
}

// MP3 decoder state
static libhelix::MP3DecoderHelix* mp3Decoder = nullptr;
static volatile bool mp3Playing = false;
static File mp3File;

// Preloaded audio sample storage
struct PreloadedSample {
    int16_t* samples;
    size_t sampleCount;
    uint32_t sampleRate;
    bool valid;
};

// Maximum preloaded samples
static constexpr size_t MAX_PRELOADED = 8;
static PreloadedSample preloadedSamples[MAX_PRELOADED] = {0};

// Find a free preload slot or return -1
static int findFreePreloadSlot() {
    for (int i = 0; i < MAX_PRELOADED; i++) {
        if (!preloadedSamples[i].valid) return i;
    }
    return -1;
}

// Free a preloaded sample
static void freePreloadedSample(int index) {
    if (index >= 0 && index < MAX_PRELOADED && preloadedSamples[index].valid) {
        if (preloadedSamples[index].samples) {
            free(preloadedSamples[index].samples);
            preloadedSamples[index].samples = nullptr;
        }
        preloadedSamples[index].valid = false;
    }
}

// Callback for decoded MP3 samples (MP3FrameInfo is in global namespace from mp3dec.h)
static void mp3DataCallback(MP3FrameInfo& info, short* pcm_buffer, size_t len, void* ref) {
    if (!mp3Playing || len == 0) return;

    float volumeScale = audioVolume / 100.0f;

    // Resample if needed (MP3 can be 44100, 22050, etc.)
    if (info.samprate == SAMPLE_RATE && info.nChans == 1) {
        // Direct playback - just apply volume
        int16_t* scaledBuf = (int16_t*)ps_malloc(len * sizeof(int16_t));
        if (scaledBuf) {
            for (size_t i = 0; i < len; i++) {
                scaledBuf[i] = (int16_t)(pcm_buffer[i] * volumeScale);
            }
            size_t bytesWritten;
            i2s_write(I2S_PORT, scaledBuf, len * sizeof(int16_t), &bytesWritten, portMAX_DELAY);
            free(scaledBuf);
        }
    } else {
        // Resample and/or mix to mono
        float resampleRatio = (float)SAMPLE_RATE / info.samprate;
        int16_t playBuf[1024];
        int playPos = 0;

        size_t srcSamples = len / info.nChans;

        for (float srcPos = 0; srcPos < srcSamples && playPos < 1024; srcPos += 1.0f / resampleRatio) {
            int srcIdx = (int)srcPos;
            int16_t sample;

            if (info.nChans == 2) {
                // Mix stereo to mono
                sample = (pcm_buffer[srcIdx * 2] + pcm_buffer[srcIdx * 2 + 1]) / 2;
            } else {
                sample = pcm_buffer[srcIdx];
            }

            playBuf[playPos++] = (int16_t)(sample * volumeScale);
        }

        if (playPos > 0) {
            size_t bytesWritten;
            i2s_write(I2S_PORT, playBuf, playPos * sizeof(int16_t), &bytesWritten, portMAX_DELAY);
        }
    }
}

// @lua ez.audio.play_mp3(filename) -> boolean
// @brief Play an MP3 audio file
// @description Plays an MP3 file from the /sounds/ directory or SD card. Supports
// any valid MP3 file (MPEG Layer 3). Audio is decoded in real-time using the Helix
// decoder. This function blocks until playback completes. MP3 is ideal for longer
// audio clips and music due to its compression.
// @param filename Path to .mp3 file (relative to /sounds/ for LittleFS, or full path starting with /sd/ for SD card)
// @return true if played successfully, false on error
// @example
// -- Play from internal storage
// ez.audio.play_mp3("startup.mp3")
// -- Play from SD card
// ez.audio.play_mp3("/sd/music/song.mp3")
// @end
LUA_FUNCTION(l_audio_play_mp3) {
    LUA_CHECK_ARGC(L, 1);
    const char* filename = luaL_checkstring(L, 1);

    if (!initI2S()) {
        lua_pushboolean(L, false);
        return 1;
    }

    // Stop any running audio
    audioRunning = false;
    mp3Playing = false;

    // Determine file source
    bool useSD = (strncmp(filename, "/sd/", 4) == 0);

    if (useSD) {
        mp3File = SD.open(filename + 3);
    } else {
        String path = "/sounds/";
        path += filename;
        mp3File = LittleFS.open(path, "r");
    }

    if (!mp3File) {
        Serial.printf("[Audio] Failed to open MP3: %s\n", filename);
        lua_pushboolean(L, false);
        return 1;
    }

    Serial.printf("[Audio] Playing MP3: %s (%u bytes)\n", filename, mp3File.size());

    // Create decoder if needed
    if (!mp3Decoder) {
        mp3Decoder = new libhelix::MP3DecoderHelix();
        mp3Decoder->setDataCallback(mp3DataCallback);
    }

    mp3Decoder->begin();
    mp3Playing = true;

    // Read and decode file in chunks
    uint8_t readBuf[1024];
    while (mp3File.available() && mp3Playing) {
        size_t bytesRead = mp3File.read(readBuf, sizeof(readBuf));
        if (bytesRead > 0) {
            mp3Decoder->write(readBuf, bytesRead);
        }
        // Allow other tasks to run
        vTaskDelay(1);
    }

    mp3Decoder->end();
    mp3File.close();
    mp3Playing = false;

    // Flush with silence
    int16_t silence[256] = {0};
    size_t bytesWritten;
    i2s_write(I2S_PORT, silence, sizeof(silence), &bytesWritten, 10);

    lua_pushboolean(L, true);
    return 1;
}

// @lua ez.audio.play(filename) -> boolean
// @brief Play an audio file (auto-detects format)
// @description Plays an audio file, automatically detecting the format from the
// file extension. Supports .wav, .mp3, and .pcm formats. Files are loaded from
// the /sounds/ directory (LittleFS) by default, or from SD card if the path starts
// with /sd/. This is the recommended function for playing audio files.
// @param filename Path to audio file (.wav, .mp3, or .pcm)
// @return true if played successfully, false on error
// @example
// -- Play different formats
// ez.audio.play("click.wav")
// ez.audio.play("notify.mp3")
// ez.audio.play("beep.pcm")
// -- Play from SD card
// ez.audio.play("/sd/sounds/music.mp3")
// @end
LUA_FUNCTION(l_audio_play) {
    LUA_CHECK_ARGC(L, 1);
    const char* filename = luaL_checkstring(L, 1);

    // Detect format from extension
    size_t len = strlen(filename);
    if (len < 4) {
        Serial.printf("[Audio] Invalid filename: %s\n", filename);
        lua_pushboolean(L, false);
        return 1;
    }

    const char* ext = filename + len - 4;

    if (strcasecmp(ext, ".wav") == 0) {
        return l_audio_play_wav(L);
    } else if (strcasecmp(ext, ".mp3") == 0) {
        return l_audio_play_mp3(L);
    } else if (strcasecmp(ext, ".pcm") == 0) {
        return l_audio_play_sample(L);
    } else {
        Serial.printf("[Audio] Unknown format: %s\n", ext);
        lua_pushboolean(L, false);
        return 1;
    }
}

// @lua ez.audio.preload(filename) -> integer | nil
// @brief Preload an audio file into memory for instant playback
// @description Loads a WAV or PCM file entirely into PSRAM for zero-latency playback.
// Returns a handle (integer) that can be passed to play_preloaded(). Useful for
// UI feedback sounds and game audio where latency matters. Maximum 8 preloaded
// sounds at once. Call unload() when the sound is no longer needed.
// @param filename Path to .wav or .pcm file
// @return Handle (1-8) on success, nil on error (file not found, memory full, or too many preloaded)
// @example
// -- Preload UI sounds at startup
// local click = ez.audio.preload("click.wav")
// local beep = ez.audio.preload("beep.wav")
// -- Later, play with zero latency
// ez.audio.play_preloaded(click)
// @end
LUA_FUNCTION(l_audio_preload) {
    LUA_CHECK_ARGC(L, 1);
    const char* filename = luaL_checkstring(L, 1);

    int slot = findFreePreloadSlot();
    if (slot < 0) {
        Serial.println("[Audio] Preload failed: all slots full");
        lua_pushnil(L);
        return 1;
    }

    // Determine file source and format
    bool useSD = (strncmp(filename, "/sd/", 4) == 0);
    File file;

    if (useSD) {
        file = SD.open(filename + 3);
    } else {
        String path = "/sounds/";
        path += filename;
        file = LittleFS.open(path, "r");
    }

    if (!file) {
        Serial.printf("[Audio] Preload failed: cannot open %s\n", filename);
        lua_pushnil(L);
        return 1;
    }

    size_t len = strlen(filename);
    bool isWav = (len >= 4 && strcasecmp(filename + len - 4, ".wav") == 0);

    PreloadedSample& sample = preloadedSamples[slot];
    sample.sampleRate = isWav ? SAMPLE_RATE : SAMPLE_RATE_PCM;

    if (isWav) {
        // Parse WAV header
        WavHeader header;
        uint32_t dataSize;
        if (!parseWavHeader(file, header, dataSize)) {
            file.close();
            lua_pushnil(L);
            return 1;
        }

        sample.sampleRate = header.sampleRate;
        size_t numSamples = dataSize / (header.bitsPerSample / 8) / header.numChannels;

        // Allocate in PSRAM
        sample.samples = (int16_t*)ps_malloc(numSamples * sizeof(int16_t));
        if (!sample.samples) {
            Serial.println("[Audio] Preload failed: out of memory");
            file.close();
            lua_pushnil(L);
            return 1;
        }

        // Read and convert to 16-bit mono
        bool is16bit = (header.bitsPerSample == 16);
        bool isStereo = (header.numChannels == 2);
        int bytesPerFrame = (header.bitsPerSample / 8) * header.numChannels;
        uint8_t readBuf[512];
        size_t pos = 0;

        while (file.available() && pos < numSamples) {
            size_t toRead = min((size_t)sizeof(readBuf), dataSize);
            size_t bytesRead = file.read(readBuf, toRead);
            size_t frames = bytesRead / bytesPerFrame;

            for (size_t i = 0; i < frames && pos < numSamples; i++) {
                int16_t s;
                if (is16bit) {
                    int16_t* src16 = (int16_t*)&readBuf[i * bytesPerFrame];
                    s = isStereo ? (src16[0] + src16[1]) / 2 : src16[0];
                } else {
                    uint8_t* src8 = &readBuf[i * bytesPerFrame];
                    int mono = isStereo ? ((int)src8[0] + src8[1]) / 2 : src8[0];
                    s = (mono - 128) << 8;
                }
                sample.samples[pos++] = s;
            }
        }

        sample.sampleCount = pos;
    } else {
        // Raw PCM: 16-bit mono at 22050Hz
        size_t fileSize = file.size();
        sample.sampleCount = fileSize / 2;
        sample.samples = (int16_t*)ps_malloc(sample.sampleCount * sizeof(int16_t));

        if (!sample.samples) {
            Serial.println("[Audio] Preload failed: out of memory");
            file.close();
            lua_pushnil(L);
            return 1;
        }

        file.read((uint8_t*)sample.samples, fileSize);
    }

    file.close();
    sample.valid = true;

    Serial.printf("[Audio] Preloaded %s: %zu samples at %u Hz (slot %d)\n",
                  filename, sample.sampleCount, sample.sampleRate, slot + 1);

    lua_pushinteger(L, slot + 1);  // 1-indexed for Lua
    return 1;
}

// @lua ez.audio.play_preloaded(handle) -> boolean
// @brief Play a preloaded audio sample
// @description Plays an audio sample that was previously loaded with preload().
// This has minimal latency since the audio data is already in memory. The function
// blocks until playback completes. For non-blocking playback, see start_preloaded().
// @param handle Handle returned by preload()
// @return true if played, false if invalid handle
// @example
// local click = ez.audio.preload("click.wav")
// -- Play instantly when button is pressed
// ez.audio.play_preloaded(click)
// @end
LUA_FUNCTION(l_audio_play_preloaded) {
    LUA_CHECK_ARGC(L, 1);
    int handle = luaL_checkinteger(L, 1);
    int slot = handle - 1;  // Convert from 1-indexed

    if (slot < 0 || slot >= MAX_PRELOADED || !preloadedSamples[slot].valid) {
        lua_pushboolean(L, false);
        return 1;
    }

    if (!initI2S()) {
        lua_pushboolean(L, false);
        return 1;
    }

    // Stop any running audio
    audioRunning = false;

    PreloadedSample& sample = preloadedSamples[slot];
    float volumeScale = audioVolume / 100.0f;
    float resampleRatio = (float)SAMPLE_RATE / sample.sampleRate;

    int16_t playBuf[512];
    size_t srcPos = 0;
    float srcFrac = 0;

    while (srcPos < sample.sampleCount) {
        int playPos = 0;

        while (srcPos < sample.sampleCount && playPos < 512) {
            playBuf[playPos++] = (int16_t)(sample.samples[srcPos] * volumeScale);

            srcFrac += 1.0f / resampleRatio;
            if (srcFrac >= 1.0f) {
                srcPos++;
                srcFrac -= 1.0f;
            } else if (resampleRatio >= 1.0f) {
                // Upsampling: repeat sample
            } else {
                srcPos++;
            }
        }

        if (playPos > 0) {
            size_t bytesWritten;
            i2s_write(I2S_PORT, playBuf, playPos * sizeof(int16_t), &bytesWritten, portMAX_DELAY);
        }
    }

    // Flush with silence
    int16_t silence[256] = {0};
    size_t bytesWritten;
    i2s_write(I2S_PORT, silence, sizeof(silence), &bytesWritten, 10);

    lua_pushboolean(L, true);
    return 1;
}

// @lua ez.audio.unload(handle)
// @brief Free a preloaded audio sample
// @description Releases the memory used by a preloaded sample. Call this when
// the sound is no longer needed to free PSRAM for other uses. After unloading,
// the handle is invalid and cannot be played.
// @param handle Handle returned by preload()
// @example
// local click = ez.audio.preload("click.wav")
// -- ... use it ...
// ez.audio.unload(click)  -- Free memory
// @end
LUA_FUNCTION(l_audio_unload) {
    LUA_CHECK_ARGC(L, 1);
    int handle = luaL_checkinteger(L, 1);
    int slot = handle - 1;

    if (slot >= 0 && slot < MAX_PRELOADED) {
        freePreloadedSample(slot);
    }
    return 0;
}

// Function table for ez.audio
static const luaL_Reg audio_funcs[] = {
    {"play",          l_audio_play},
    {"preload",       l_audio_preload},
    {"play_preloaded", l_audio_play_preloaded},
    {"unload",        l_audio_unload},
    {"play_wav",      l_audio_play_wav},
    {"play_mp3",      l_audio_play_mp3},
    {"play_tone",     l_audio_play_tone},
    {"play_sample",   l_audio_play_sample},
    {"stop",          l_audio_stop},
    {"is_playing",    l_audio_is_playing},
    {"beep",          l_audio_beep},
    {"set_frequency", l_audio_set_frequency},
    {"start",         l_audio_start},
    {"set_volume",    l_audio_set_volume},
    {"get_volume",    l_audio_get_volume},
    {nullptr, nullptr}
};

// Register the audio module
void registerAudioModule(lua_State* L) {
    lua_register_module(L, "audio", audio_funcs);
    Serial.println("[LuaRuntime] Registered ez.audio");
}
