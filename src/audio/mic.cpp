// ES7210 + I2S RX implementation. See mic.h for the contract.
//
// Init sequence is derived from the ES7210 datasheet (Everest Semi
// rev 1.0). The codec is wired as I2S slave -- ESP32 supplies MCLK,
// BCLK, LRCK on I2S_NUM_1 in master mode. Only MIC1 is enabled to
// keep the data stream mono; the chip can do up to 4 channels but
// that's a follow-up.
//
// Clock plan @ 16 kHz: MCLK = 256*fs = 4.096 MHz, BCLK = 32*fs (16-bit
// stereo frame so LRCK toggles per word and we read the L slot only).
// We let the ESP32 I2S peripheral derive MCLK from the APLL so the
// codec sees a clean clock independent of the CPU PLL.

#include "mic.h"
#include "../config.h"
#include "../lua/bindings/bus_bindings.h"

#include <Arduino.h>
#include <Wire.h>
#include <SD.h>
#include <driver/i2s.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace ezos {
namespace mic {

namespace {

constexpr i2s_port_t kRxPort = I2S_NUM_1;

// ES7210 register addresses we touch. The chip has ~0x4F regs in
// total; these are the ones needed for "boot, single mic channel,
// I2S slave, 16-bit @ 16 kHz".
constexpr uint8_t REG_RESET        = 0x00;
constexpr uint8_t REG_CLK_ON       = 0x01;
constexpr uint8_t REG_MCLK_CTL     = 0x02;
constexpr uint8_t REG_MCLK_DIV     = 0x03;
constexpr uint8_t REG_LRCK_DIV_H   = 0x04;
constexpr uint8_t REG_LRCK_DIV_L   = 0x05;
constexpr uint8_t REG_OSR          = 0x07;
constexpr uint8_t REG_MODE         = 0x08;
constexpr uint8_t REG_DIGI_PWR     = 0x06;
constexpr uint8_t REG_SDP_FMT      = 0x11;
constexpr uint8_t REG_SDP_LRCK     = 0x12;
constexpr uint8_t REG_ADC_AUTOMUTE = 0x14;
constexpr uint8_t REG_ADC_DIGI_VOL = 0x15;
constexpr uint8_t REG_ANA_PWR      = 0x3F;
constexpr uint8_t REG_MIC12_PWR    = 0x41;
constexpr uint8_t REG_MIC34_PWR    = 0x42;
constexpr uint8_t REG_MIC1_GAIN    = 0x43;
constexpr uint8_t REG_MIC2_GAIN    = 0x44;
constexpr uint8_t REG_MIC1_BIAS    = 0x47;
constexpr uint8_t REG_MIC2_BIAS    = 0x48;
constexpr uint8_t REG_MIC1_PGA     = 0x4B;
constexpr uint8_t REG_MIC2_PGA     = 0x4C;

bool i2c_write(uint8_t reg, uint8_t val) {
    Wire.beginTransmission(ES7210_I2C_ADDR);
    Wire.write(reg);
    Wire.write(val);
    return Wire.endTransmission() == 0;
}

bool i2c_read(uint8_t reg, uint8_t* out) {
    Wire.beginTransmission(ES7210_I2C_ADDR);
    Wire.write(reg);
    if (Wire.endTransmission(false) != 0) return false;
    if (Wire.requestFrom((uint8_t)ES7210_I2C_ADDR, (uint8_t)1) != 1) return false;
    *out = Wire.read();
    return true;
}

// Gain selector mapping. ES7210 PGA gain register field (0x43, bits 3:0)
// is in 3 dB steps from 0 dB (0x00) to 36 dB (0x0E). We clamp into the
// usable range; values above 36 dB on this codec saturate quickly.
uint8_t pga_step_for_db(uint8_t db) {
    if (db > 36) db = 36;
    return (uint8_t)(db / 3);
}

// Full ES7210 power-on init for 16-bit, 1-channel, slave-mode capture.
// Every register write is checked. If any of them NAKs (loose connection,
// bus contention with keyboard / touch on the same I2C bus, codec held in
// reset), bail out -- a partially-configured codec captures silence or
// garbage with no surface indication of the underlying fault.
bool codec_init(uint32_t sample_rate, uint8_t gain_db) {
    auto W = [](uint8_t reg, uint8_t val) -> bool {
        if (i2c_write(reg, val)) return true;
        Serial.printf("[Mic] codec_init: I2C write failed at reg 0x%02X\n", reg);
        return false;
    };

    // Soft reset, hold ~1 ms, then clear reset.
    if (!W(REG_RESET, 0xFF)) return false;
    delay(1);
    if (!W(REG_RESET, 0x32)) return false;
    delay(1);
    if (!W(REG_RESET, 0x00)) return false;

    // Clock manager: enable MCLK/ADC clock, MCLK from MCLK pin.
    if (!W(REG_CLK_ON,   0x3F)) return false;
    // MCLK source = from external pin (we drive it from the ESP32
    // I2S peripheral), no inversion, normal divider path.
    if (!W(REG_MCLK_CTL, 0xC1)) return false;

    // Clock dividers for 16 kHz @ 256*fs MCLK.
    // OSR = 64 (default), LRCK divider = MCLK / fs = 256.
    // 256 = 0x0100 -> high=0x01, low=0x00.
    if (!W(REG_MCLK_DIV, 0x02))   return false;
    if (!W(REG_LRCK_DIV_H, 0x01)) return false;
    if (!W(REG_LRCK_DIV_L, 0x00)) return false;
    if (!W(REG_OSR, 0x20))        return false;
    // Mode: slave, normal phase.
    if (!W(REG_MODE, 0x14))       return false;
    // Digital power: enable ADC channel 1 only.
    if (!W(REG_DIGI_PWR, 0x00))   return false;

    // Serial port: I2S, 16-bit, MSB first.
    // 0x11 = [7:4 word len][3:0 fmt]. Word len 16-bit = 0b0011, fmt I2S = 0b0000.
    if (!W(REG_SDP_FMT, 0x30))    return false;
    // LRCK active high, BCLK normal phase.
    if (!W(REG_SDP_LRCK, 0x00))   return false;

    // Auto-mute disabled, digital volume = 0 dB.
    if (!W(REG_ADC_AUTOMUTE, 0x00)) return false;
    if (!W(REG_ADC_DIGI_VOL, 0xC0)) return false;  // 0xC0 = 0 dB after lookup table

    // Analog power on (full chip), enable MIC1+MIC2 PGAs and bias.
    if (!W(REG_ANA_PWR,   0x00)) return false;
    if (!W(REG_MIC12_PWR, 0x00)) return false;
    if (!W(REG_MIC34_PWR, 0xFF)) return false;  // MIC3/4 off (T-Deck has 1 mic)
    if (!W(REG_MIC1_BIAS, 0x08)) return false;  // ~2.6V bias for the MEMS element
    if (!W(REG_MIC2_BIAS, 0x08)) return false;

    uint8_t pga = pga_step_for_db(gain_db);
    if (!W(REG_MIC1_GAIN, 0x10 | pga)) return false;
    if (!W(REG_MIC2_GAIN, 0x10 | pga)) return false;
    if (!W(REG_MIC1_PGA, 0x00))        return false;
    if (!W(REG_MIC2_PGA, 0x00))        return false;

    (void)sample_rate;  // currently fixed by the dividers above
    return true;
}

bool i2s_rx_install(uint32_t sample_rate) {
    i2s_config_t cfg = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate = sample_rate,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 4,
        .dma_buf_len = 512,
        .use_apll = true,
        .tx_desc_auto_clear = false,
        .fixed_mclk = (int)(sample_rate * 256),
    };
    esp_err_t err = i2s_driver_install(kRxPort, &cfg, 0, nullptr);
    if (err != ESP_OK) {
        Serial.printf("[Mic] I2S install failed: %d\n", err);
        return false;
    }

    i2s_pin_config_t pins = {
        .mck_io_num   = ES7210_MCLK,
        .bck_io_num   = ES7210_SCK,
        .ws_io_num    = ES7210_LRCK,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num  = ES7210_DIN,
    };
    err = i2s_set_pin(kRxPort, &pins);
    if (err != ESP_OK) {
        Serial.printf("[Mic] I2S set_pin failed: %d\n", err);
        i2s_driver_uninstall(kRxPort);
        return false;
    }
    i2s_zero_dma_buffer(kRxPort);
    return true;
}

void i2s_rx_uninstall() {
    i2s_driver_uninstall(kRxPort);
}

// WAV header for 16-bit PCM mono. Sizes are placeholders -- the
// session keeps a running data-bytes counter and patches the header
// on stop.
struct WavHeader {
    char     riff[4]      = {'R','I','F','F'};
    uint32_t riff_size    = 36;
    char     wave[4]      = {'W','A','V','E'};
    char     fmt_id[4]    = {'f','m','t',' '};
    uint32_t fmt_size     = 16;
    uint16_t audio_format = 1;        // PCM
    uint16_t num_channels = 1;
    uint32_t sample_rate  = 16000;
    uint32_t byte_rate    = 32000;    // sr * ch * bytes
    uint16_t block_align  = 2;        // ch * bytes
    uint16_t bits_per_sample = 16;
    char     data_id[4]   = {'d','a','t','a'};
    uint32_t data_size    = 0;
};

}  // namespace

struct MicSession {
    File          file;
    uint32_t      sample_rate;
    uint32_t      data_bytes;
    TaskHandle_t  task;
    volatile bool stop_requested;
    volatile bool task_alive;
    SemaphoreHandle_t done_sem;
};

static MicSession* g_session = nullptr;

bool is_recording() {
    return g_session != nullptr;
}

bool probe() {
    Wire.beginTransmission(ES7210_I2C_ADDR);
    return Wire.endTransmission() == 0;
}

static void capture_task(void* arg) {
    auto* sess = static_cast<MicSession*>(arg);
    sess->task_alive = true;

    constexpr size_t kBufBytes = 1024;
    uint8_t* buf = (uint8_t*)heap_caps_malloc(kBufBytes, MALLOC_CAP_DMA);
    if (!buf) {
        Serial.println("[Mic] capture_task: buf alloc failed");
        sess->task_alive = false;
        xSemaphoreGive(sess->done_sem);
        vTaskDelete(nullptr);
        return;
    }

    bool auto_stopped = false;
    while (!sess->stop_requested) {
        size_t bytes_read = 0;
        esp_err_t err = i2s_read(kRxPort, buf, kBufBytes, &bytes_read, pdMS_TO_TICKS(100));
        if (err == ESP_OK && bytes_read > 0) {
            size_t w = sess->file.write(buf, bytes_read);
            sess->data_bytes += (uint32_t)w;
            if (w != bytes_read) {
                Serial.printf("[Mic] short write: wrote %u of %u\n",
                              (unsigned)w, (unsigned)bytes_read);
                break;
            }
        }
        // Cap individual recordings at ~5 minutes of 16k/16-bit mono.
        // Real cap is "what fits on SD" but this stops a runaway
        // session from filling the card if a screen forgets to call
        // stop_recording().
        if (sess->data_bytes > 5UL * 60 * sess->sample_rate * 2) {
            Serial.println("[Mic] hit 5-min cap, auto-stop");
            auto_stopped = true;
            break;
        }
    }

    free(buf);
    sess->task_alive = false;
    xSemaphoreGive(sess->done_sem);

    // If the task self-terminated (5-minute cap), nothing in the Lua
    // layer knows it should clean up. Post a bus event so a subscriber
    // can call ez.audio.stop_record() and finalise the WAV header,
    // close the file, uninstall I2S, and clear the binding's mirror
    // of g_session. The actual teardown all happens through the
    // existing stop_recording() path -- this just kicks it.
    if (auto_stopped) {
        MessageBus::instance().post("audio/recording_overflow", "");
    }

    vTaskDelete(nullptr);
}

MicSession* start_recording(const char* wav_path, const RecordOpts& opts) {
    if (g_session) {
        Serial.println("[Mic] start_recording: already active");
        return nullptr;
    }
    if (!probe()) {
        Serial.println("[Mic] start_recording: ES7210 not present on I2C");
        return nullptr;
    }

    if (!codec_init(opts.sample_rate, opts.gain_db)) {
        Serial.println("[Mic] codec_init failed");
        return nullptr;
    }
    if (!i2s_rx_install(opts.sample_rate)) {
        return nullptr;
    }

    auto* sess = new MicSession();
    sess->sample_rate = opts.sample_rate;
    sess->data_bytes = 0;
    sess->task = nullptr;
    sess->stop_requested = false;
    sess->task_alive = false;
    sess->done_sem = xSemaphoreCreateBinary();

    // SD.open() is mounted at /; callers pass the Lua-side
    // convention "/sd/..." so we strip the prefix the same way
    // play_wav / play_mp3 do (audio_bindings.cpp).
    const char* fs_path = wav_path;
    if (strncmp(wav_path, "/sd/", 4) == 0) fs_path = wav_path + 3;
    sess->file = SD.open(fs_path, FILE_WRITE);
    if (!sess->file) {
        Serial.printf("[Mic] failed to open %s\n", fs_path);
        vSemaphoreDelete(sess->done_sem);
        delete sess;
        i2s_rx_uninstall();
        return nullptr;
    }

    WavHeader hdr;
    hdr.sample_rate = opts.sample_rate;
    hdr.byte_rate   = opts.sample_rate * 2;
    sess->file.write(reinterpret_cast<const uint8_t*>(&hdr), sizeof(hdr));

    g_session = sess;
    if (xTaskCreatePinnedToCore(capture_task, "mic_cap", 4096, sess,
                                4, &sess->task, 1) != pdPASS) {
        Serial.println("[Mic] failed to spawn capture_task");
        sess->file.close();
        SD.remove(fs_path);
        vSemaphoreDelete(sess->done_sem);
        delete sess;
        i2s_rx_uninstall();
        g_session = nullptr;
        return nullptr;
    }
    return sess;
}

bool stop_recording(MicSession* sess, uint32_t* out_bytes_written) {
    if (!sess || sess != g_session) return false;

    sess->stop_requested = true;
    // Wait unconditionally for the capture task to finish. The task
    // wakes at most ~100 ms after stop_requested goes true (the i2s_read
    // timeout), but an in-flight SD write can stall for hundreds of ms
    // when FAT flushes. A finite timeout here used to race against
    // that: we tore down sess->file, the I2S driver, and the semaphore
    // while the task was still inside i2s_read or file.write, which
    // is undefined behaviour (use-after-free / double-free of the
    // semaphore handle). The task always signals done_sem before
    // exiting -- including on the 5-minute auto-stop path -- so this
    // wait is bounded in practice.
    xSemaphoreTake(sess->done_sem, portMAX_DELAY);

    // Patch the WAV header now that we know the final size.
    uint32_t data_size = sess->data_bytes;
    uint32_t riff_size = data_size + 36;
    sess->file.seek(4);
    sess->file.write(reinterpret_cast<const uint8_t*>(&riff_size), 4);
    sess->file.seek(40);
    sess->file.write(reinterpret_cast<const uint8_t*>(&data_size), 4);
    sess->file.flush();
    sess->file.close();

    i2s_rx_uninstall();

    if (out_bytes_written) *out_bytes_written = data_size;

    vSemaphoreDelete(sess->done_sem);
    delete sess;
    g_session = nullptr;
    return true;
}

int16_t* capture_buffer(uint32_t duration_ms, const RecordOpts& opts,
                        size_t* out_size) {
    if (g_session) {
        Serial.println("[Mic] capture_buffer: session already active");
        return nullptr;
    }
    if (!probe()) return nullptr;
    if (!codec_init(opts.sample_rate, opts.gain_db)) return nullptr;
    if (!i2s_rx_install(opts.sample_rate)) return nullptr;

    size_t total_samples = (opts.sample_rate * duration_ms) / 1000;
    size_t total_bytes = total_samples * 2;
    int16_t* buf = (int16_t*)ps_malloc(total_bytes);
    if (!buf) {
        i2s_rx_uninstall();
        return nullptr;
    }

    size_t written = 0;
    while (written < total_bytes) {
        size_t got = 0;
        size_t want = total_bytes - written;
        if (want > 1024) want = 1024;
        esp_err_t err = i2s_read(kRxPort, (uint8_t*)buf + written, want,
                                 &got, pdMS_TO_TICKS(200));
        if (err != ESP_OK || got == 0) break;
        written += got;
    }

    i2s_rx_uninstall();
    if (out_size) *out_size = written;
    return buf;
}

}  // namespace mic
}  // namespace ezos
