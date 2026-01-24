// tdeck.audio module bindings
// Provides audio/tone generation functions using I2S

#include "../lua_bindings.h"
#include "../../config.h"
#include <Arduino.h>
#include <driver/i2s.h>
#include <cmath>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

// I2S configuration
static constexpr i2s_port_t I2S_PORT = I2S_NUM_0;
static constexpr int SAMPLE_RATE = 44100;
static constexpr int AMPLITUDE = 16000;

// Audio state
static TaskHandle_t audioTaskHandle = nullptr;
static volatile bool audioRunning = false;
static volatile uint32_t audioFrequency = 440;
static volatile bool i2sInitialized = false;
static volatile uint32_t toneEndTime = 0;
static volatile bool toneHasDuration = false;

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

            for (int i = 0; i < 256; i++) {
                samples[i] = (int16_t)(AMPLITUDE * sinf(phase));
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

// @lua tdeck.audio.play_tone(frequency, duration_ms) -> boolean
// @brief Play a tone for specified duration
// @param frequency Frequency in Hz (20-20000)
// @param duration_ms Duration in milliseconds
// @return true if started successfully
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

// @lua tdeck.audio.stop()
// @brief Stop audio playback
LUA_FUNCTION(l_audio_stop) {
    stopAudio();
    return 0;
}

// @lua tdeck.audio.is_playing() -> boolean
// @brief Check if audio is playing
// @return true if playing
LUA_FUNCTION(l_audio_is_playing) {
    lua_pushboolean(L, audioRunning);
    return 1;
}

// @lua tdeck.audio.beep(count, frequency, on_ms, off_ms)
// @brief Play a series of beeps (blocking)
// @param count Number of beeps (default 1)
// @param frequency Tone frequency in Hz (default 1000)
// @param on_ms Beep duration in ms (default 100)
// @param off_ms Pause between beeps in ms (default 50)
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

// @lua tdeck.audio.set_frequency(frequency) -> boolean
// @brief Set playback frequency for continuous tones
// @param frequency Frequency in Hz (20-20000)
// @return true if valid frequency
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

// @lua tdeck.audio.start()
// @brief Start continuous tone at current frequency
LUA_FUNCTION(l_audio_start) {
    ensureAudioTask();
    toneHasDuration = false;
    audioRunning = true;
    return 0;
}

// Function table for tdeck.audio
static const luaL_Reg audio_funcs[] = {
    {"play_tone",     l_audio_play_tone},
    {"stop",          l_audio_stop},
    {"is_playing",    l_audio_is_playing},
    {"beep",          l_audio_beep},
    {"set_frequency", l_audio_set_frequency},
    {"start",         l_audio_start},
    {nullptr, nullptr}
};

// Register the audio module
void registerAudioModule(lua_State* L) {
    lua_register_module(L, "audio", audio_funcs);
    Serial.println("[LuaRuntime] Registered tdeck.audio");
}
