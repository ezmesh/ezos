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

// Function table for ez.audio
static const luaL_Reg audio_funcs[] = {
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
