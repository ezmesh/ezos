// ES7210 + I2S RX implementation. See mic.h for the contract.
//
// Board wiring (T-Deck Plus): the codec is on I2C (SDA=18, SCL=8, addr
// 0x40) and its SDOUT2 line is wired to GPIO 14 -- SDOUT1 is *not*
// connected. We therefore have to route the on-board MEMS mic's data
// through SDOUT2 to be able to read it at all.
//
// Codec config: 4-channel TDM mode (REG_SDP_INTERFACE2 = 0x02). In
// non-TDM mode MIC1/MIC2 go on SDOUT1 (unreadable on this board), but
// in TDM mode all four ADC channels are time-multiplexed onto SDOUT2
// and we can pick out the slot that carries the mic. The init
// sequence is modelled on LilyGo's own T-Deck mic example
// (Xinyuan-LilyGO/T-Deck examples/Microphone) plus the esp-adf
// ES7210 driver -- both are authoritative references for this chip.
//
// I2S RX: standard stereo (not TDM at the ESP32 side), 16-bit per
// channel. The TDM frame on the wire has 4 ADC slots per LRCK; the
// ESP32 in stereo mode only consumes 2 slots per LRCK, which halves
// the effective rate. To get the user-requested LRCK out the other
// side, we configure the I2S sample_rate at 2x and the capture task
// extracts CH0 (MIC1's slot) into a mono PCM stream. Result: caller
// asks for 16 kHz mono and gets a 16 kHz mono WAV.

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

// ES7210 register addresses we touch. Names and addresses follow
// Espressif's ESP-ADF es7210 driver (the authoritative reference for
// this codec). An earlier version of this file used hand-rolled names
// with several mis-mapped addresses (REG_ANA_PWR at 0x3F instead of
// 0x40, MIC POWER and BIAS swapped, etc.), which left the analog
// front-end in its default powered-down state and the ADC streamed
// zeros forever. If you're tempted to "clean up" these names, cross-
// check against ES7210.h in esp-adf first.
constexpr uint8_t REG_RESET           = 0x00;
constexpr uint8_t REG_CLOCK_OFF       = 0x01;  // per-channel ADC clock gating
constexpr uint8_t REG_MAINCLK         = 0x02;  // adc_div / doubler / dll
constexpr uint8_t REG_MASTER_CLK      = 0x03;  // MCLK source + SCLK division
constexpr uint8_t REG_LRCK_DIVH       = 0x04;
constexpr uint8_t REG_LRCK_DIVL       = 0x05;
constexpr uint8_t REG_POWER_DOWN      = 0x06;  // digital power-down mask
constexpr uint8_t REG_OSR             = 0x07;
constexpr uint8_t REG_MODE_CONFIG     = 0x08;  // master/slave + channels
constexpr uint8_t REG_TIME_CONTROL0   = 0x09;
constexpr uint8_t REG_TIME_CONTROL1   = 0x0A;
constexpr uint8_t REG_SDP_INTERFACE1  = 0x11;  // word length + I2S format
constexpr uint8_t REG_SDP_INTERFACE2  = 0x12;  // TDM mode
constexpr uint8_t REG_ADC34_HPF2      = 0x20;
constexpr uint8_t REG_ADC34_HPF1      = 0x21;
constexpr uint8_t REG_ADC12_HPF1      = 0x22;
constexpr uint8_t REG_ADC12_HPF2      = 0x23;
constexpr uint8_t REG_ANALOG_PWR      = 0x40;  // analog power + VMID
constexpr uint8_t REG_MIC12_BIAS      = 0x41;  // MIC1/2 bias voltage
constexpr uint8_t REG_MIC34_BIAS      = 0x42;  // MIC3/4 bias voltage
constexpr uint8_t REG_MIC1_GAIN       = 0x43;  // PGA enable (bit 4) + 4-bit gain
constexpr uint8_t REG_MIC2_GAIN       = 0x44;
constexpr uint8_t REG_MIC3_GAIN       = 0x45;
constexpr uint8_t REG_MIC4_GAIN       = 0x46;
constexpr uint8_t REG_MIC1_POWER      = 0x47;  // per-channel analog power
constexpr uint8_t REG_MIC2_POWER      = 0x48;
constexpr uint8_t REG_MIC3_POWER      = 0x49;
constexpr uint8_t REG_MIC4_POWER      = 0x4A;
constexpr uint8_t REG_MIC12_POWER     = 0x4B;  // MIC1/2 PGA + ADC power (0 = on)
constexpr uint8_t REG_MIC34_POWER     = 0x4C;

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

bool i2c_update(uint8_t reg, uint8_t mask, uint8_t val) {
    uint8_t cur = 0;
    if (!i2c_read(reg, &cur)) return false;
    uint8_t next = (cur & ~mask) | (val & mask);
    if (next == cur) return true;
    return i2c_write(reg, next);
}

// Gain selector mapping. ES7210 PGA gain register field (0x43, bits 3:0)
// is in 3 dB steps from 0 dB (0x00) to 36 dB (0x0E). We clamp into the
// usable range; values above 36 dB on this codec saturate quickly.
uint8_t pga_step_for_db(uint8_t db) {
    if (db > 36) db = 36;
    return (uint8_t)(db / 3);
}

// Full ES7210 power-on init for 16-bit, 1-channel, slave-mode capture.
// Sequence mirrors esp-adf's es7210_adc_init + mic_select + start path
// for MIC1, 16-bit I2S, fs=16 kHz, MCLK=256*fs. Every write is checked:
// if any NAKs (loose connection, bus contention with the keyboard /
// touch controller on the same I2C bus, codec held in reset), bail
// out so a partially-configured codec can't silently stream garbage.
bool codec_init(uint32_t sample_rate, uint8_t gain_db) {
    auto W = [](uint8_t reg, uint8_t val) -> bool {
        if (i2c_write(reg, val)) return true;
        Serial.printf("[Mic] codec_init: I2C write failed at reg 0x%02X\n", reg);
        return false;
    };
    auto U = [](uint8_t reg, uint8_t mask, uint8_t val) -> bool {
        if (i2c_update(reg, mask, val)) return true;
        Serial.printf("[Mic] codec_init: I2C rmw failed at reg 0x%02X\n", reg);
        return false;
    };

    // Soft reset, then bring the chip back up with all ADC clocks gated.
    if (!W(REG_RESET, 0xFF))     return false;
    delay(1);
    if (!W(REG_RESET, 0x41))     return false;
    if (!W(REG_CLOCK_OFF, 0x3F)) return false;

    // Power-on / state-machine timing.
    if (!W(REG_TIME_CONTROL0, 0x30)) return false;
    if (!W(REG_TIME_CONTROL1, 0x30)) return false;

    // HPF defaults for both ADC pairs ("quick setup" values from the
    // reference driver -- enables HPF, reasonable cutoff).
    if (!W(REG_ADC12_HPF2, 0x2A)) return false;
    if (!W(REG_ADC12_HPF1, 0x0A)) return false;
    if (!W(REG_ADC34_HPF2, 0x0A)) return false;
    if (!W(REG_ADC34_HPF1, 0x2A)) return false;

    // Slave mode: ESP32 drives MCLK / BCLK / LRCK. Bit 0 = master enable.
    if (!U(REG_MODE_CONFIG, 0x01, 0x00)) return false;

    // Analog power up + MIC bias rails. Skipping this register (it sits
    // at 0x40, NOT 0x3F) is what kept the previous version of this code
    // silent -- the analog front-end stayed in default power-down and
    // the ADC streamed zeros. 0xC3 (bit 7 set = internal regulator
    // enabled) is what LilyGo's own T-Deck example uses; esp-adf's
    // 0x43 leaves the regulator off and the codec runs dry on this
    // board even though I2C still ACKs.
    if (!W(REG_ANALOG_PWR, 0xC3)) return false;
    if (!W(REG_MIC12_BIAS, 0x70)) return false;  // 2.87 V bias for MIC1/2
    if (!W(REG_MIC34_BIAS, 0x70)) return false;

    // Clocking for 16 kHz with MCLK = 256*fs = 4.096 MHz, sourced from
    // the ESP32 I2S APLL. Values from coeff_div[] in esp-adf for
    // {mclk=4_096_000, lrck=16_000}: adc_div=1, doubler=1, dll=1,
    // osr=0x20, lrckh=1, lrckl=0 (LRCK divider = 256).
    if (!W(REG_OSR, 0x20))     return false;
    // MAINCLK: dll<<7 | doubler<<6 | adc_div. Esp-adf's coefficient
    // table uses 0xC1 (doubler ON) for {MCLK=4.096 MHz, LRCK=16 kHz}
    // but on this board that produces LRCK ~= 7.4 kHz. Clearing the
    // doubler bit (0x81) gives the correct 16 kHz LRCK.
    if (!W(REG_MAINCLK, 0x81)) return false;
    if (!W(REG_LRCK_DIVH, 0x01)) return false;
    if (!W(REG_LRCK_DIVL, 0x00)) return false;

    // Serial port: I2S format (bits[1:0]=00), 16-bit word length
    // (bits[7:5]=011). The earlier 0x30 value misread the layout as
    // a 4+4 split and ended up selecting a wider word length, which
    // bit-slipped against the I2S RX's 16-bit framing.
    if (!W(REG_SDP_INTERFACE1, 0x60)) return false;
    // TDM mode (0x02): time-multiplex all four ADCs onto SDOUT2,
    // which is the codec data pin actually wired to GPIO 14 on
    // T-Deck Plus. Non-TDM puts ADC1/2 on SDOUT1 (unconnected on
    // this board) and ADC3/4 on SDOUT2, but empirically MIC3/MIC4
    // produce no signal here, so we use TDM and pick MIC1's slot
    // out of the TDM stream in capture_task.
    if (!W(REG_SDP_INTERFACE2, 0x02)) return false;

    // Digital power up (clear power-down mask).
    if (!W(REG_POWER_DOWN, 0x00)) return false;

    // Per-channel analog power: 0x00 = fully powered.
    if (!W(REG_MIC1_POWER, 0x00)) return false;
    if (!W(REG_MIC2_POWER, 0x00)) return false;
    if (!W(REG_MIC3_POWER, 0x00)) return false;
    if (!W(REG_MIC4_POWER, 0x00)) return false;

    // Ungate all four ADC clocks so the TDM stream has every slot
    // filled.
    if (!W(REG_CLOCK_OFF, 0x00))   return false;
    if (!W(REG_MIC12_POWER, 0x00)) return false;
    if (!W(REG_MIC34_POWER, 0x00)) return false;

    // PGAs all enabled at the user-requested gain. The capture task
    // only keeps MIC1's slot but enabling the others fills the rest
    // of the TDM frame so BCLK timing stays correct.
    uint8_t gain_step = pga_step_for_db(gain_db);
    if (!W(REG_MIC1_GAIN, 0x10 | gain_step)) return false;
    if (!W(REG_MIC2_GAIN, 0x10 | gain_step)) return false;
    if (!W(REG_MIC3_GAIN, 0x10 | gain_step)) return false;
    if (!W(REG_MIC4_GAIN, 0x10 | gain_step)) return false;

    (void)sample_rate;  // clock dividers above are fixed for 16 kHz
    return true;
}

bool i2s_rx_install(uint32_t sample_rate) {
    // I2S RX config for ES7210 in TDM mode. The codec packs its ADC
    // channels onto SDOUT2 (the line wired to GPIO 14 on T-Deck Plus
    // -- SDOUT1 is unconnected, which is why non-TDM mode produced
    // all-zero recordings). We capture two TDM channels: CH0 = MIC1
    // (the on-board MEMS element) and CH1 = MIC2 (unused on this
    // board). The capture_task discards CH1 and writes CH0 as mono
    // PCM. This matches the I2S config in LilyGo's own T-Deck mic
    // example (examples/Microphone).
    i2s_config_t cfg = {};
    cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX);
    cfg.sample_rate = sample_rate;
    cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
    cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;
    cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
    cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
    cfg.dma_buf_count = 8;
    cfg.dma_buf_len = 64;
    cfg.use_apll = false;
    cfg.tx_desc_auto_clear = false;
    cfg.fixed_mclk = 0;
    cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
    cfg.bits_per_chan = I2S_BITS_PER_CHAN_16BIT;
    // Standard stereo I2S (not TDM) -- the codec is in non-TDM mode
    // driving 2 channels on SDOUT2.
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

    // De-interleave scratch: i2s_read returns 2 interleaved channels
    // (CH0 + CH1) at 16-bit each = 4 bytes per LRCK frame. We keep
    // CH0 (which carries the on-board mic signal in TDM mode) and
    // pack consecutive frames into a mono 16-bit stream.
    int16_t mono[kBufBytes / 4];

    // Discard a warm-up window before we start writing samples to the
    // file. The I2S driver pre-fills its DMA buffers with zeros in
    // i2s_zero_dma_buffer, and the codec needs a few ms to start
    // producing real samples after MCLK comes up -- without this,
    // the first ~100 ms of every recording is the zeroed DMA buffer
    // being drained, which the user hears as the start of their
    // utterance being clipped.
    size_t warmup_bytes_remaining = sess->sample_rate / 10 * 4;  // ~100 ms

    bool auto_stopped = false;
    while (!sess->stop_requested) {
        size_t bytes_read = 0;
        esp_err_t err = i2s_read(kRxPort, buf, kBufBytes, &bytes_read, pdMS_TO_TICKS(100));
        if (err == ESP_OK && bytes_read >= 4) {
            if (warmup_bytes_remaining > 0) {
                size_t drop = bytes_read < warmup_bytes_remaining ? bytes_read : warmup_bytes_remaining;
                warmup_bytes_remaining -= drop;
                if (drop == bytes_read) continue;
                // partial warm-up consumed: keep the tail of this read
                memmove(buf, buf + drop, bytes_read - drop);
                bytes_read -= drop;
            }
            int16_t* s16 = reinterpret_cast<int16_t*>(buf);
            size_t frames = bytes_read / 4;
            for (size_t f = 0; f < frames; ++f) {
                mono[f] = s16[f * 2];  // CH0
            }
            size_t mono_bytes = frames * 2;
            size_t w = sess->file.write(reinterpret_cast<uint8_t*>(mono), mono_bytes);
            sess->data_bytes += (uint32_t)w;
            if (w != mono_bytes) {
                Serial.printf("[Mic] short write: wrote %u of %u\n",
                              (unsigned)w, (unsigned)mono_bytes);
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

    // i2s_read returns 2-channel interleaved data (CH0 = MIC1, CH1 =
    // MIC2). Allocate enough space for the user-requested duration of
    // mono PCM, plus a scratch staging buffer for the raw stereo
    // stream we have to de-interleave from.
    size_t total_samples = (opts.sample_rate * duration_ms) / 1000;
    size_t total_bytes = total_samples * 2;
    int16_t* mono = (int16_t*)ps_malloc(total_bytes);
    if (!mono) {
        i2s_rx_uninstall();
        return nullptr;
    }
    uint8_t* raw = (uint8_t*)heap_caps_malloc(1024, MALLOC_CAP_DMA);
    if (!raw) {
        free(mono);
        i2s_rx_uninstall();
        return nullptr;
    }

    size_t mono_written = 0;
    while (mono_written < total_bytes) {
        size_t got = 0;
        esp_err_t err = i2s_read(kRxPort, raw, 1024, &got, pdMS_TO_TICKS(200));
        if (err != ESP_OK || got == 0) break;
        int16_t* s16 = reinterpret_cast<int16_t*>(raw);
        size_t frames = got / 4;
        for (size_t f = 0; f < frames && mono_written < total_bytes; ++f) {
            mono[mono_written / 2] = s16[f * 2];  // CH0
            mono_written += 2;
        }
    }

    free(raw);
    i2s_rx_uninstall();
    if (out_size) *out_size = mono_written;
    return mono;
}

}  // namespace mic
}  // namespace ezos
