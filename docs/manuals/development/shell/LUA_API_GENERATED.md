# T-Deck OS Lua API Reference

> Auto-generated from source code

## Quick Reference (All Methods)

| Method | Description |
|--------|-------------|
| [`audio.beep`](#audio-beep) | Play a series of beeps (blocking) |
| [`audio.get_volume`](#audio-get_volume) | Get current volume level |
| [`audio.is_playing`](#audio-is_playing) | Check if audio is playing |
| [`audio.play_sample`](#audio-play_sample) | Play a PCM sample file from LittleFS |
| [`audio.play_tone`](#audio-play_tone) | Play a tone for specified duration |
| [`audio.set_frequency`](#audio-set_frequency) | Set playback frequency for continuous tones |
| [`audio.set_volume`](#audio-set_volume) | Set audio volume level |
| [`audio.start`](#audio-start) | Start continuous tone at current frequency |
| [`audio.stop`](#audio-stop) | Stop audio playback |
| [`bus.has_subscribers`](#bus-has_subscribers) | Check if a topic has any active subscribers |
| [`bus.pending_count`](#bus-pending_count) | Get number of messages waiting in queue |
| [`bus.post`](#bus-post) | Post a message to a topic |
| [`bus.subscribe`](#bus-subscribe) | Subscribe to a topic with a callback function |
| [`bus.unsubscribe`](#bus-unsubscribe) | Unsubscribe from a topic |
| [`crypto.aes128_ecb_decrypt`](#crypto-aes128_ecb_decrypt) | Decrypt data with AES-128-ECB |
| [`crypto.aes128_ecb_encrypt`](#crypto-aes128_ecb_encrypt) | Encrypt data with AES-128-ECB |
| [`crypto.base64_decode`](#crypto-base64_decode) | Decode base64 string to binary data |
| [`crypto.base64_encode`](#crypto-base64_encode) | Encode binary data to base64 string |
| [`crypto.bytes_to_hex`](#crypto-bytes_to_hex) | Convert binary data to hex string |
| [`crypto.channel_hash`](#crypto-channel_hash) | Compute channel hash from key (SHA256(key)[0]) |
| [`crypto.derive_channel_key`](#crypto-derive_channel_key) | Derive 16-byte channel key from password/name using SHA256 |
| [`crypto.hex_to_bytes`](#crypto-hex_to_bytes) | Convert hex string to binary data |
| [`crypto.hmac_sha256`](#crypto-hmac_sha256) | Compute HMAC-SHA256 |
| [`crypto.public_channel_key`](#crypto-public_channel_key) | Get the well-known #Public channel key |
| [`crypto.random_bytes`](#crypto-random_bytes) | Generate cryptographically secure random bytes |
| [`crypto.sha256`](#crypto-sha256) | Compute SHA-256 hash |
| [`crypto.sha512`](#crypto-sha512) | Compute SHA-512 hash |
| [`display.clear`](#display-clear) | Clear display buffer to black |
| [`display.create_sprite`](#display-create_sprite) | Create an off-screen sprite for alpha compositing |
| [`display.draw_battery`](#display-draw_battery) | Draw battery indicator icon |
| [`display.draw_bitmap`](#display-draw_bitmap) | Draw a bitmap image from raw RGB565 data |
| [`display.draw_bitmap_1bit`](#display-draw_bitmap_1bit) | Draw a 1-bit bitmap with scaling and colorization |
| [`display.draw_bitmap_transparent`](#display-draw_bitmap_transparent) | Draw a bitmap with transparency |
| [`display.draw_box`](#display-draw_box) | Draw bordered box with optional title |
| [`display.draw_char`](#display-draw_char) | Draw a single character |
| [`display.draw_circle`](#display-draw_circle) | Draw circle outline |
| [`display.draw_hline`](#display-draw_hline) | Draw horizontal line with optional connectors |
| [`display.draw_indexed_bitmap`](#display-draw_indexed_bitmap) | Draw a 3-bit indexed bitmap using a color palette |
| [`display.draw_indexed_bitmap_scaled`](#display-draw_indexed_bitmap_scaled) | Draw a scaled portion of a 3-bit indexed bitmap |
| [`display.draw_line`](#display-draw_line) | Draw a line between two points |
| [`display.draw_pixel`](#display-draw_pixel) | Draw a single pixel |
| [`display.draw_progress`](#display-draw_progress) | Draw a progress bar |
| [`display.draw_rect`](#display-draw_rect) | Draw rectangle outline |
| [`display.draw_round_rect`](#display-draw_round_rect) | Draw rounded rectangle outline |
| [`display.draw_signal`](#display-draw_signal) | Draw signal strength indicator |
| [`display.draw_text`](#display-draw_text) | Draw text at pixel coordinates |
| [`display.draw_text_bg`](#display-draw_text_bg) | Draw text with a background rectangle |
| [`display.draw_text_centered`](#display-draw_text_centered) | Draw horizontally centered text |
| [`display.draw_text_shadow`](#display-draw_text_shadow) | Draw text with a shadow offset |
| [`display.draw_triangle`](#display-draw_triangle) | Draw triangle outline |
| [`display.fill_circle`](#display-fill_circle) | Draw filled circle |
| [`display.fill_rect`](#display-fill_rect) | Fill a rectangle with color |
| [`display.fill_rect_dithered`](#display-fill_rect_dithered) | Fill a rectangle with dithered pattern (simulates transparen... |
| [`display.fill_rect_hlines`](#display-fill_rect_hlines) | Fill a rectangle with horizontal line pattern |
| [`display.fill_rect_vlines`](#display-fill_rect_vlines) | Fill a rectangle with vertical line pattern |
| [`display.fill_round_rect`](#display-fill_round_rect) | Draw filled rounded rectangle |
| [`display.fill_triangle`](#display-fill_triangle) | Draw filled triangle |
| [`display.flush`](#display-flush) | Flush buffer to physical display |
| [`display.get_cols`](#display-get_cols) | Get display columns |
| [`display.get_font_height`](#display-get_font_height) | Get font character height |
| [`display.get_font_width`](#display-get_font_width) | Get font character width |
| [`display.get_height`](#display-get_height) | Get display height |
| [`display.get_rows`](#display-get_rows) | Get display rows |
| [`display.get_width`](#display-get_width) | Get display width |
| [`display.rgb`](#display-rgb) | Convert RGB to RGB565 color value |
| [`display.save_screenshot`](#display-save_screenshot) | Save current display contents as BMP screenshot to SD card |
| [`display.set_brightness`](#display-set_brightness) | Set backlight brightness |
| [`display.set_font_size`](#display-set_font_size) | Set font size |
| [`display.text_width`](#display-text_width) | Get pixel width of text string |
| [`ez.log`](#ez-log) | Log message to serial output |
| [`gps.get_location`](#gps-get_location) | Get current GPS location |
| [`gps.get_movement`](#gps-get_movement) | Get speed and heading |
| [`gps.get_satellites`](#gps-get_satellites) | Get satellite info |
| [`gps.get_stats`](#gps-get_stats) | Get GPS parsing statistics |
| [`gps.get_time`](#gps-get_time) | Get GPS time |
| [`gps.init`](#gps-init) | Initialize the GPS module |
| [`gps.is_valid`](#gps-is_valid) | Check if GPS has a valid location fix |
| [`gps.sync_time`](#gps-sync_time) | Sync system time from GPS |
| [`gps.update`](#gps-update) | Process incoming GPS data, call from main loop |
| [`keyboard.available`](#keyboard-available) | Check if a key is waiting |
| [`keyboard.get_backlight`](#keyboard-get_backlight) | Get current keyboard backlight level |
| [`keyboard.get_mode`](#keyboard-get_mode) | Get current keyboard input mode |
| [`keyboard.get_pin_states`](#keyboard-get_pin_states) | Debug function to get raw GPIO pin states for wake detection |
| [`keyboard.get_raw_matrix_bits`](#keyboard-get_raw_matrix_bits) | Get full matrix state as 64-bit integer (raw mode) |
| [`keyboard.get_repeat_delay`](#keyboard-get_repeat_delay) | Get initial delay before key repeat starts |
| [`keyboard.get_repeat_enabled`](#keyboard-get_repeat_enabled) | Check if key repeat is enabled |
| [`keyboard.get_repeat_rate`](#keyboard-get_repeat_rate) | Get key repeat rate (interval between repeats) |
| [`keyboard.get_trackball_mode`](#keyboard-get_trackball_mode) | Get current trackball input mode |
| [`keyboard.get_trackball_sensitivity`](#keyboard-get_trackball_sensitivity) | Get trackball sensitivity level |
| [`keyboard.has_key_activity`](#keyboard-has_key_activity) | Check if keyboard interrupt pin indicates key activity |
| [`keyboard.has_trackball`](#keyboard-has_trackball) | Check if device has trackball |
| [`keyboard.is_alt_held`](#keyboard-is_alt_held) | Check if Alt is currently held |
| [`keyboard.is_ctrl_held`](#keyboard-is_ctrl_held) | Check if Ctrl is currently held |
| [`keyboard.is_fn_held`](#keyboard-is_fn_held) | Check if Fn is currently held |
| [`keyboard.is_key_pressed`](#keyboard-is_key_pressed) | Check if a specific matrix key is pressed (raw mode) |
| [`keyboard.is_shift_held`](#keyboard-is_shift_held) | Check if Shift is currently held |
| [`keyboard.read`](#keyboard-read) | Read next key event (non-blocking) |
| [`keyboard.read_blocking`](#keyboard-read_blocking) | Read key with optional timeout (blocking) |
| [`keyboard.read_raw_code`](#keyboard-read_raw_code) | Read raw key code byte directly from I2C (no translation) |
| [`keyboard.read_raw_matrix`](#keyboard-read_raw_matrix) | Read raw key matrix state (only works in raw mode) |
| [`keyboard.set_backlight`](#keyboard-set_backlight) | Set keyboard backlight brightness |
| [`keyboard.set_mode`](#keyboard-set_mode) | Set keyboard input mode |
| [`keyboard.set_repeat_delay`](#keyboard-set_repeat_delay) | Set initial delay before key repeat starts |
| [`keyboard.set_repeat_enabled`](#keyboard-set_repeat_enabled) | Enable or disable key repeat |
| [`keyboard.set_repeat_rate`](#keyboard-set_repeat_rate) | Set key repeat rate (interval between repeats) |
| [`keyboard.set_trackball_mode`](#keyboard-set_trackball_mode) | Set trackball input mode |
| [`keyboard.set_trackball_sensitivity`](#keyboard-set_trackball_sensitivity) | Set trackball sensitivity level |
| [`mesh.build_packet`](#mesh-build_packet) | Build a raw mesh packet for transmission |
| [`mesh.calc_shared_secret`](#mesh-calc_shared_secret) | Calculate ECDH shared secret with another node |
| [`mesh.clear_packet_queue`](#mesh-clear_packet_queue) | Clear all packets from the queue |
| [`mesh.clear_tx_queue`](#mesh-clear_tx_queue) | Clear all packets from transmit queue |
| [`mesh.ed25519_sign`](#mesh-ed25519_sign) | Sign data with this node's private key |
| [`mesh.ed25519_verify`](#mesh-ed25519_verify) | Verify an Ed25519 signature |
| [`mesh.enable_packet_queue`](#mesh-enable_packet_queue) | Enable or disable packet queuing for polling |
| [`mesh.get_announce_interval`](#mesh-get_announce_interval) | Get current auto-announce interval |
| [`mesh.get_node_count`](#mesh-get_node_count) | Get number of known nodes |
| [`mesh.get_node_id`](#mesh-get_node_id) | Get this node's full ID |
| [`mesh.get_node_name`](#mesh-get_node_name) | Get this node's display name |
| [`mesh.get_nodes`](#mesh-get_nodes) | Get list of discovered mesh nodes |
| [`mesh.get_path_check`](#mesh-get_path_check) | Get current path check setting |
| [`mesh.get_path_hash`](#mesh-get_path_hash) | Get this node's path hash (first byte of public key) |
| [`mesh.get_public_key`](#mesh-get_public_key) | Get this node's public key as binary string |
| [`mesh.get_public_key_hex`](#mesh-get_public_key_hex) | Get this node's public key as hex string |
| [`mesh.get_rx_count`](#mesh-get_rx_count) | Get total packets received |
| [`mesh.get_short_id`](#mesh-get_short_id) | Get this node's short ID |
| [`mesh.get_tx_count`](#mesh-get_tx_count) | Get total packets transmitted |
| [`mesh.get_tx_queue_capacity`](#mesh-get_tx_queue_capacity) | Get maximum transmit queue capacity |
| [`mesh.get_tx_queue_size`](#mesh-get_tx_queue_size) | Get number of packets waiting in transmit queue |
| [`mesh.get_tx_throttle`](#mesh-get_tx_throttle) | Get current throttle interval |
| [`mesh.has_packets`](#mesh-has_packets) | Check if packets are available in the queue |
| [`mesh.is_initialized`](#mesh-is_initialized) | Check if mesh networking is initialized |
| [`mesh.is_tx_queue_full`](#mesh-is_tx_queue_full) | Check if transmit queue is full |
| [`mesh.make_header`](#mesh-make_header) | Create a packet header byte from components |
| [`mesh.on_group_packet`](#mesh-on_group_packet) | Set callback for raw group packets (DEPRECATED - use bus.sub... |
| [`mesh.on_node_discovered`](#mesh-on_node_discovered) | Set callback for node discovery (DEPRECATED - use bus.subscr... |
| [`mesh.on_packet`](#mesh-on_packet) | Set callback for ALL incoming packets (DEPRECATED - use bus.... |
| [`mesh.packet_count`](#mesh-packet_count) | Get number of packets in queue |
| [`mesh.parse_header`](#mesh-parse_header) | Parse a packet header byte into components |
| [`mesh.pop_packet`](#mesh-pop_packet) | Get and remove the next packet from queue |
| [`mesh.queue_send`](#mesh-queue_send) | Queue packet for transmission (throttled, non-blocking) |
| [`mesh.schedule_rebroadcast`](#mesh-schedule_rebroadcast) | Schedule raw packet data for rebroadcast |
| [`mesh.send_announce`](#mesh-send_announce) | Broadcast node announcement |
| [`mesh.send_group_packet`](#mesh-send_group_packet) | Send raw encrypted group packet |
| [`mesh.send_raw`](#mesh-send_raw) | Send raw packet data directly via radio (bypasses queue, imm... |
| [`mesh.set_announce_interval`](#mesh-set_announce_interval) | Set auto-announce interval in milliseconds (0 = disabled) |
| [`mesh.set_node_name`](#mesh-set_node_name) | Set this node's display name |
| [`mesh.set_path_check`](#mesh-set_path_check) | Enable or disable path check for flood routing |
| [`mesh.set_tx_throttle`](#mesh-set_tx_throttle) | Set minimum interval between transmissions |
| [`mesh.update`](#mesh-update) | Process incoming mesh packets |
| [`radio.available`](#radio-available) | Check if data is available |
| [`radio.get_config`](#radio-get_config) | Get current radio configuration |
| [`radio.get_last_rssi`](#radio-get_last_rssi) | Get last received signal strength |
| [`radio.get_last_snr`](#radio-get_last_snr) | Get last signal-to-noise ratio |
| [`radio.is_busy`](#radio-is_busy) | Check if radio is busy |
| [`radio.is_initialized`](#radio-is_initialized) | Check if radio is initialized |
| [`radio.is_receiving`](#radio-is_receiving) | Check if in receive mode |
| [`radio.is_transmitting`](#radio-is_transmitting) | Check if currently transmitting |
| [`radio.receive`](#radio-receive) | Receive a packet |
| [`radio.send`](#radio-send) | Transmit data |
| [`radio.set_bandwidth`](#radio-set_bandwidth) | Set radio bandwidth |
| [`radio.set_coding_rate`](#radio-set_coding_rate) | Set LoRa coding rate |
| [`radio.set_frequency`](#radio-set_frequency) | Set radio frequency |
| [`radio.set_spreading_factor`](#radio-set_spreading_factor) | Set LoRa spreading factor |
| [`radio.set_sync_word`](#radio-set_sync_word) | Set sync word |
| [`radio.set_tx_power`](#radio-set_tx_power) | Set transmit power |
| [`radio.sleep`](#radio-sleep) | Put radio into sleep mode |
| [`radio.start_receive`](#radio-start_receive) | Start listening for packets |
| [`radio.wake`](#radio-wake) | Wake radio from sleep |
| [`storage.append_file`](#storage-append_file) | Append content to file |
| [`storage.clear_prefs`](#storage-clear_prefs) | Clear all preferences |
| [`storage.exists`](#storage-exists) | Check if file or directory exists |
| [`storage.file_size`](#storage-file_size) | Get file size in bytes |
| [`storage.get_flash_info`](#storage-get_flash_info) | Get flash storage info |
| [`storage.get_pref`](#storage-get_pref) | Get preference value |
| [`storage.get_sd_info`](#storage-get_sd_info) | Get SD card info |
| [`storage.is_sd_available`](#storage-is_sd_available) | Check if SD card is mounted |
| [`storage.json_decode`](#storage-json_decode) | Decode JSON string to Lua value |
| [`storage.json_encode`](#storage-json_encode) | Encode Lua value to JSON string |
| [`storage.list_dir`](#storage-list_dir) | List directory contents |
| [`storage.mkdir`](#storage-mkdir) | Create directory |
| [`storage.read_bytes`](#storage-read_bytes) | Read bytes from file at specific offset (for random access) |
| [`storage.read_file`](#storage-read_file) | Read entire file contents |
| [`storage.remove`](#storage-remove) | Delete a file |
| [`storage.remove_pref`](#storage-remove_pref) | Remove a preference |
| [`storage.rename`](#storage-rename) | Rename or move a file |
| [`storage.rmdir`](#storage-rmdir) | Remove empty directory |
| [`storage.set_pref`](#storage-set_pref) | Set preference value |
| [`storage.write_file`](#storage-write_file) | Write content to file (creates/overwrites) |
| [`system.cancel_timer`](#system-cancel_timer) | Cancel a scheduled timer |
| [`system.chip_model`](#system-chip_model) | Get ESP32 chip model name |
| [`system.cpu_freq`](#system-cpu_freq) | Get CPU frequency |
| [`system.delay`](#system-delay) | Blocking delay execution |
| [`system.gc`](#system-gc) | Force full garbage collection |
| [`system.gc_step`](#system-gc_step) | Perform incremental garbage collection |
| [`system.get_battery_percent`](#system-get_battery_percent) | Get battery charge level |
| [`system.get_battery_voltage`](#system-get_battery_voltage) | Get battery voltage |
| [`system.get_firmware_info`](#system-get_firmware_info) | Get firmware partition info |
| [`system.get_free_heap`](#system-get_free_heap) | Get free internal RAM |
| [`system.get_free_psram`](#system-get_free_psram) | Get free PSRAM |
| [`system.get_last_error`](#system-get_last_error) | Get last Lua error message |
| [`system.get_loop_delay`](#system-get_loop_delay) | Get the current main loop delay in milliseconds |
| [`system.get_lua_memory`](#system-get_lua_memory) | Get memory used by Lua runtime |
| [`system.get_time`](#system-get_time) | Get current wall clock time |
| [`system.get_time_unix`](#system-get_time_unix) | Get current Unix timestamp |
| [`system.get_timezone`](#system-get_timezone) | Get current timezone UTC offset in hours |
| [`system.get_total_heap`](#system-get_total_heap) | Get total heap size |
| [`system.get_total_psram`](#system-get_total_psram) | Get total PSRAM size |
| [`system.is_low_memory`](#system-is_low_memory) | Check if memory is critically low |
| [`system.is_sd_available`](#system-is_sd_available) | Check if SD card is available |
| [`system.is_usb_msc_active`](#system-is_usb_msc_active) | Check if USB MSC mode is active |
| [`system.millis`](#system-millis) | Returns milliseconds since boot |
| [`system.reload_scripts`](#system-reload_scripts) | Reload all Lua scripts (hot reload) |
| [`system.restart`](#system-restart) | Restart the device |
| [`system.set_interval`](#system-set_interval) | Schedule a repeating callback |
| [`system.set_loop_delay`](#system-set_loop_delay) | Set the main loop delay in milliseconds |
| [`system.set_time`](#system-set_time) | Set system clock time |
| [`system.set_time_unix`](#system-set_time_unix) | Set system clock from Unix timestamp |
| [`system.set_timer`](#system-set_timer) | Schedule a one-shot callback |
| [`system.set_timezone`](#system-set_timezone) | Set timezone using POSIX TZ string |
| [`system.start_usb_msc`](#system-start_usb_msc) | Start USB Mass Storage mode to access SD card from PC |
| [`system.stop_usb_msc`](#system-stop_usb_msc) | Stop USB Mass Storage mode |
| [`system.uptime`](#system-uptime) | Get device uptime |
| [`system.yield`](#system-yield) | Yield execution to allow C++ background tasks to run |

---

## Table of Contents

- [ez.audio](#audio)
- [ez.bus](#bus)
- [ez.crypto](#crypto)
- [ez.display](#display)
- [ez.ez](#ez)
- [ez.gps](#gps)
- [ez.keyboard](#keyboard)
- [ez.mesh](#mesh)
- [ez.radio](#radio)
- [ez.storage](#storage)
- [ez.system](#system)

## audio

### ez.audio

#### <a name="audio-beep"></a>beep

```lua
ez.audio.beep(count, frequency, on_ms, off_ms)
```

Play a series of beeps (blocking)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `count` | Number of beeps (default 1) |
| `frequency` | Tone frequency in Hz (default 1000) |
| `on_ms` | Beep duration in ms (default 100) |
| `off_ms` | Pause between beeps in ms (default 50) |

#### <a name="audio-get_volume"></a>get_volume

```lua
ez.audio.get_volume() -> integer
```

Get current volume level

**Returns:** Volume level 0-100

#### <a name="audio-is_playing"></a>is_playing

```lua
ez.audio.is_playing() -> boolean
```

Check if audio is playing

**Returns:** true if playing

#### <a name="audio-play_sample"></a>play_sample

```lua
ez.audio.play_sample(filename) -> boolean
```

Play a PCM sample file from LittleFS

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `filename` | Path to .pcm file (16-bit signed, 22050Hz mono) |

**Returns:** true if played successfully

#### <a name="audio-play_tone"></a>play_tone

```lua
ez.audio.play_tone(frequency, duration_ms) -> boolean
```

Play a tone for specified duration

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `frequency` | Frequency in Hz (20-20000) |
| `duration_ms` | Duration in milliseconds |

**Returns:** true if started successfully

#### <a name="audio-set_frequency"></a>set_frequency

```lua
ez.audio.set_frequency(frequency) -> boolean
```

Set playback frequency for continuous tones

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `frequency` | Frequency in Hz (20-20000) |

**Returns:** true if valid frequency

#### <a name="audio-set_volume"></a>set_volume

```lua
ez.audio.set_volume(level)
```

Set audio volume level

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `level` | Volume level 0-100 |

#### <a name="audio-start"></a>start

```lua
ez.audio.start()
```

Start continuous tone at current frequency

#### <a name="audio-stop"></a>stop

```lua
ez.audio.stop()
```

Stop audio playback

## bus

### ez.bus

#### <a name="bus-has_subscribers"></a>has_subscribers

```lua
ez.bus.has_subscribers(topic) -> boolean
```

Check if a topic has any active subscribers

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `topic` | Topic string to check |

**Returns:** true if one or more subscribers exist

#### <a name="bus-pending_count"></a>pending_count

```lua
ez.bus.pending_count() -> integer
```

Get number of messages waiting in queue

**Returns:** Number of pending messages

#### <a name="bus-post"></a>post

```lua
ez.bus.post(topic, data)
```

Post a message to a topic

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `topic` | Topic string to post to |
| `data` | Message data (string or table) |

#### <a name="bus-subscribe"></a>subscribe

```lua
ez.bus.subscribe(topic, callback) -> subscription_id
```

Subscribe to a topic with a callback function

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `topic` | Topic string to subscribe to |
| `callback` | Function(topic, data) called when message received |

#### <a name="bus-unsubscribe"></a>unsubscribe

```lua
ez.bus.unsubscribe(subscription_id) -> boolean
```

Unsubscribe from a topic

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `subscription_id` | ID returned from subscribe() |

**Returns:** true if subscription was found and removed

## crypto

### ez.crypto

#### <a name="crypto-aes128_ecb_decrypt"></a>aes128_ecb_decrypt

```lua
ez.crypto.aes128_ecb_decrypt(key, ciphertext) -> string
```

Decrypt data with AES-128-ECB

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `key` | 16-byte key |
| `ciphertext` | Data to decrypt (must be multiple of 16 bytes) |

**Returns:** Decrypted data as binary string (with padding zeros)

#### <a name="crypto-aes128_ecb_encrypt"></a>aes128_ecb_encrypt

```lua
ez.crypto.aes128_ecb_encrypt(key, plaintext) -> string
```

Encrypt data with AES-128-ECB

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `key` | 16-byte key |
| `plaintext` | Data to encrypt (will be zero-padded to block boundary) |

**Returns:** Encrypted data as binary string

#### <a name="crypto-base64_decode"></a>base64_decode

```lua
ez.crypto.base64_decode(encoded) -> string
```

Decode base64 string to binary data

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `encoded` | Base64 encoded string |

**Returns:** Binary string, or nil on error

#### <a name="crypto-base64_encode"></a>base64_encode

```lua
ez.crypto.base64_encode(data) -> string
```

Encode binary data to base64 string

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string to encode |

**Returns:** Base64 encoded string

#### <a name="crypto-bytes_to_hex"></a>bytes_to_hex

```lua
ez.crypto.bytes_to_hex(data) -> string
```

Convert binary data to hex string

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string |

**Returns:** Hex string (lowercase)

#### <a name="crypto-channel_hash"></a>channel_hash

```lua
ez.crypto.channel_hash(key) -> integer
```

Compute channel hash from key (SHA256(key)[0])

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `key` | 16-byte channel key |

**Returns:** Single byte hash as integer (0-255)

#### <a name="crypto-derive_channel_key"></a>derive_channel_key

```lua
ez.crypto.derive_channel_key(input) -> string
```

Derive 16-byte channel key from password/name using SHA256

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `input` | Password or channel name string |

**Returns:** 16-byte key as binary string

#### <a name="crypto-hex_to_bytes"></a>hex_to_bytes

```lua
ez.crypto.hex_to_bytes(hex) -> string
```

Convert hex string to binary data

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `hex` | Hex string (case-insensitive) |

**Returns:** Binary string, or nil on error

#### <a name="crypto-hmac_sha256"></a>hmac_sha256

```lua
ez.crypto.hmac_sha256(key, data) -> string
```

Compute HMAC-SHA256

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `key` | Binary string key |
| `data` | Binary string to authenticate |

**Returns:** 32-byte MAC as binary string

#### <a name="crypto-public_channel_key"></a>public_channel_key

```lua
ez.crypto.public_channel_key() -> string
```

Get the well-known #Public channel key

**Returns:** 16-byte key as binary string

#### <a name="crypto-random_bytes"></a>random_bytes

```lua
ez.crypto.random_bytes(count) -> string
```

Generate cryptographically secure random bytes

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `count` | Number of bytes to generate |

**Returns:** Random bytes as binary string

#### <a name="crypto-sha256"></a>sha256

```lua
ez.crypto.sha256(data) -> string
```

Compute SHA-256 hash

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string to hash |

**Returns:** 32-byte hash as binary string

#### <a name="crypto-sha512"></a>sha512

```lua
ez.crypto.sha512(data) -> string
```

Compute SHA-512 hash

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string to hash |

**Returns:** 64-byte hash as binary string

## display

### ez.display

#### <a name="display-clear"></a>clear

```lua
ez.display.clear()
```

Clear display buffer to black

#### <a name="display-create_sprite"></a>create_sprite

```lua
display.create_sprite(width, height) -> Sprite
```

Create an off-screen sprite for alpha compositing

#### <a name="display-draw_battery"></a>draw_battery

```lua
ez.display.draw_battery(x, y, percent)
```

Draw battery indicator icon

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `percent` | Battery percentage (0-100) |

#### <a name="display-draw_bitmap"></a>draw_bitmap

```lua
ez.display.draw_bitmap(x, y, width, height, data)
```

Draw a bitmap image from raw RGB565 data

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position |
| `y` | Y position |
| `width` | Bitmap width in pixels |
| `height` | Bitmap height in pixels |
| `data` | Raw RGB565 pixel data (2 bytes per pixel, big-endian) |

#### <a name="display-draw_bitmap_1bit"></a>draw_bitmap_1bit

```lua
ez.display.draw_bitmap_1bit(x, y, width, height, data, scale, color)
```

Draw a 1-bit bitmap with scaling and colorization

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position |
| `y` | Y position |
| `width` | Bitmap width in pixels (original size) |
| `height` | Bitmap height in pixels (original size) |
| `data` | Packed 1-bit data (MSB first, row by row) |
| `scale` | Scale factor (1, 2, 3, etc.) - optional, default 1 |
| `color` | RGB565 color for "on" pixels - optional, default WHITE |

#### <a name="display-draw_bitmap_transparent"></a>draw_bitmap_transparent

```lua
ez.display.draw_bitmap_transparent(x, y, width, height, data, transparent_color)
```

Draw a bitmap with transparency

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position |
| `y` | Y position |
| `width` | Bitmap width in pixels |
| `height` | Bitmap height in pixels |
| `data` | Raw RGB565 pixel data |
| `transparent_color` | RGB565 color to treat as transparent |

#### <a name="display-draw_box"></a>draw_box

```lua
ez.display.draw_box(x, y, w, h, title, border_color, title_color)
```

Draw bordered box with optional title

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in character cells |
| `y` | Y position in character cells |
| `w` | Width in character cells |
| `h` | Height in character cells |
| `title` | Optional title string |
| `border_color` | Border color (optional) |
| `title_color` | Title color (optional) |

#### <a name="display-draw_char"></a>draw_char

```lua
ez.display.draw_char(x, y, char, color)
```

Draw a single character

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `char` | Character to draw (first char of string) |
| `color` | Character color (optional) |

#### <a name="display-draw_circle"></a>draw_circle

```lua
ez.display.draw_circle(x, y, r, color)
```

Draw circle outline

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | Center X position |
| `y` | Center Y position |
| `r` | Radius |
| `color` | Circle color (optional) |

#### <a name="display-draw_hline"></a>draw_hline

```lua
ez.display.draw_hline(x, y, w, left_connect, right_connect, color)
```

Draw horizontal line with optional connectors

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in character cells |
| `y` | Y position in character cells |
| `w` | Width in character cells |
| `left_connect` | Connect to left border (optional) |
| `right_connect` | Connect to right border (optional) |
| `color` | Line color (optional) |

#### <a name="display-draw_indexed_bitmap"></a>draw_indexed_bitmap

```lua
ez.display.draw_indexed_bitmap(x, y, width, height, data, palette)
```

Draw a 3-bit indexed bitmap using a color palette

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position |
| `y` | Y position |
| `width` | Bitmap width in pixels |
| `height` | Bitmap height in pixels |
| `data` | Packed 3-bit pixel indices (8 pixels packed into 3 bytes) |
| `palette` | Table of 8 RGB565 color values |

#### <a name="display-draw_indexed_bitmap_scaled"></a>draw_indexed_bitmap_scaled

```lua
ez.display.draw_indexed_bitmap_scaled(x, y, dest_w, dest_h, data, palette, src_x, src_y, src_w, src_h)
```

Draw a scaled portion of a 3-bit indexed bitmap

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | Destination X position |
| `y` | Destination Y position |
| `dest_w` | Destination width |
| `dest_h` | Destination height |
| `data` | Packed 3-bit pixel indices (256x256 source assumed) |
| `palette` | Table of 8 RGB565 color values |
| `src_x` | Source X offset in pixels |
| `src_y` | Source Y offset in pixels |
| `src_w` | Source width to sample |
| `src_h` | Source height to sample |

#### <a name="display-draw_line"></a>draw_line

```lua
ez.display.draw_line(x1, y1, x2, y2, color)
```

Draw a line between two points

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x1` | Start X position |
| `y1` | Start Y position |
| `x2` | End X position |
| `y2` | End Y position |
| `color` | Line color (optional) |

#### <a name="display-draw_pixel"></a>draw_pixel

```lua
ez.display.draw_pixel(x, y, color)
```

Draw a single pixel

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `color` | Pixel color (optional) |

#### <a name="display-draw_progress"></a>draw_progress

```lua
ez.display.draw_progress(x, y, w, h, progress, fg_color, bg_color)
```

Draw a progress bar

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `w` | Width in pixels |
| `h` | Height in pixels |
| `progress` | Progress value (0.0 to 1.0) |
| `fg_color` | Foreground color (optional) |
| `bg_color` | Background color (optional) |

#### <a name="display-draw_rect"></a>draw_rect

```lua
ez.display.draw_rect(x, y, w, h, color)
```

Draw rectangle outline

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `w` | Width in pixels |
| `h` | Height in pixels |
| `color` | Outline color (optional) |

#### <a name="display-draw_round_rect"></a>draw_round_rect

```lua
ez.display.draw_round_rect(x, y, w, h, r, color)
```

Draw rounded rectangle outline

#### <a name="display-draw_signal"></a>draw_signal

```lua
ez.display.draw_signal(x, y, bars)
```

Draw signal strength indicator

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `bars` | Signal strength (0-4 bars) |

#### <a name="display-draw_text"></a>draw_text

```lua
ez.display.draw_text(x, y, text, color)
```

Draw text at pixel coordinates

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `text` | Text string to draw |
| `color` | Text color (optional, defaults to TEXT) |

#### <a name="display-draw_text_bg"></a>draw_text_bg

```lua
ez.display.draw_text_bg(x, y, text, fg_color, bg_color, padding)
```

Draw text with a background rectangle

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `text` | Text string to draw |
| `fg_color` | Text color |
| `bg_color` | Background color |
| `padding` | Padding around text (optional, defaults to 1) |

#### <a name="display-draw_text_centered"></a>draw_text_centered

```lua
ez.display.draw_text_centered(y, text, color)
```

Draw horizontally centered text

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `y` | Y position in pixels |
| `text` | Text string to draw |
| `color` | Text color (optional, defaults to TEXT) |

#### <a name="display-draw_text_shadow"></a>draw_text_shadow

```lua
ez.display.draw_text_shadow(x, y, text, fg_color, shadow_color, offset)
```

Draw text with a shadow offset

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `text` | Text string to draw |
| `fg_color` | Text color |
| `shadow_color` | Shadow color (optional, defaults to black) |
| `offset` | Shadow offset in pixels (optional, defaults to 1) |

#### <a name="display-draw_triangle"></a>draw_triangle

```lua
ez.display.draw_triangle(x1, y1, x2, y2, x3, y3, color)
```

Draw triangle outline

#### <a name="display-fill_circle"></a>fill_circle

```lua
ez.display.fill_circle(x, y, r, color)
```

Draw filled circle

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | Center X position |
| `y` | Center Y position |
| `r` | Radius |
| `color` | Fill color (optional) |

#### <a name="display-fill_rect"></a>fill_rect

```lua
ez.display.fill_rect(x, y, w, h, color)
```

Fill a rectangle with color

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `w` | Width in pixels |
| `h` | Height in pixels |
| `color` | Fill color (optional) |

#### <a name="display-fill_rect_dithered"></a>fill_rect_dithered

```lua
ez.display.fill_rect_dithered(x, y, w, h, color, density)
```

Fill a rectangle with dithered pattern (simulates transparency)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `w` | Width in pixels |
| `h` | Height in pixels |
| `color` | Fill color |
| `density` | Percentage of pixels filled (0-100, default 50 for checkerboard) |

#### <a name="display-fill_rect_hlines"></a>fill_rect_hlines

```lua
ez.display.fill_rect_hlines(x, y, w, h, color, spacing)
```

Fill a rectangle with horizontal line pattern

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `w` | Width in pixels |
| `h` | Height in pixels |
| `color` | Fill color |
| `spacing` | Line spacing (2 = 50%, 3 = 33%, etc., default 2) |

#### <a name="display-fill_rect_vlines"></a>fill_rect_vlines

```lua
ez.display.fill_rect_vlines(x, y, w, h, color, spacing)
```

Fill a rectangle with vertical line pattern

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `x` | X position in pixels |
| `y` | Y position in pixels |
| `w` | Width in pixels |
| `h` | Height in pixels |
| `color` | Fill color |
| `spacing` | Line spacing (2 = 50%, 3 = 33%, etc., default 2) |

#### <a name="display-fill_round_rect"></a>fill_round_rect

```lua
ez.display.fill_round_rect(x, y, w, h, r, color)
```

Draw filled rounded rectangle

#### <a name="display-fill_triangle"></a>fill_triangle

```lua
ez.display.fill_triangle(x1, y1, x2, y2, x3, y3, color)
```

Draw filled triangle

#### <a name="display-flush"></a>flush

```lua
ez.display.flush()
```

Flush buffer to physical display

#### <a name="display-get_cols"></a>get_cols

```lua
ez.display.get_cols() -> integer
```

Get display columns

**Returns:** Number of character columns

#### <a name="display-get_font_height"></a>get_font_height

```lua
ez.display.get_font_height() -> integer
```

Get font character height

**Returns:** Character height in pixels

#### <a name="display-get_font_width"></a>get_font_width

```lua
ez.display.get_font_width() -> integer
```

Get font character width

**Returns:** Character width in pixels

#### <a name="display-get_height"></a>get_height

```lua
ez.display.get_height() -> integer
```

Get display height

**Returns:** Height in pixels

#### <a name="display-get_rows"></a>get_rows

```lua
ez.display.get_rows() -> integer
```

Get display rows

**Returns:** Number of character rows

#### <a name="display-get_width"></a>get_width

```lua
ez.display.get_width() -> integer
```

Get display width

**Returns:** Width in pixels

#### <a name="display-rgb"></a>rgb

```lua
ez.display.rgb(r, g, b) -> integer
```

Convert RGB to RGB565 color value

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `r` | Red component (0-255) |
| `g` | Green component (0-255) |
| `b` | Blue component (0-255) |

**Returns:** RGB565 color value

#### <a name="display-save_screenshot"></a>save_screenshot

```lua
ez.display.save_screenshot(path) -> boolean
```

Save current display contents as BMP screenshot to SD card

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | File path on SD card (e.g., "/screenshots/screen_001.bmp") |

**Returns:** true if saved successfully, false on error

#### <a name="display-set_brightness"></a>set_brightness

```lua
ez.display.set_brightness(level)
```

Set backlight brightness

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `level` | Brightness level (0-255) |

#### <a name="display-set_font_size"></a>set_font_size

```lua
ez.display.set_font_size(size)
```

Set font size

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `size` | Font size string: "tiny", "small", "medium", or "large" |

#### <a name="display-text_width"></a>text_width

```lua
ez.display.text_width(text) -> integer
```

Get pixel width of text string

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `text` | Text string to measure |

**Returns:** Width in pixels

## ez

### ez.ez

#### <a name="ez-log"></a>log

```lua
ez.log(message)
```

Log message to serial output

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `message` | Text to log |

## gps

### ez.gps

#### <a name="gps-get_location"></a>get_location

```lua
ez.gps.get_location() -> table|nil
```

Get current GPS location

**Returns:** Table with lat, lon, alt, valid, age (ms since last fix), or nil if not initialized

#### <a name="gps-get_movement"></a>get_movement

```lua
ez.gps.get_movement() -> table|nil
```

Get speed and heading

**Returns:** Table with speed (km/h) and course (degrees), or nil if not initialized

#### <a name="gps-get_satellites"></a>get_satellites

```lua
ez.gps.get_satellites() -> table|nil
```

Get satellite info

**Returns:** Table with count and hdop (horizontal dilution of precision), or nil if not initialized

#### <a name="gps-get_stats"></a>get_stats

```lua
ez.gps.get_stats() -> table|nil
```

Get GPS parsing statistics

**Returns:** Table with chars processed, sentences with fix, failed checksums, initialized flag

#### <a name="gps-get_time"></a>get_time

```lua
ez.gps.get_time() -> table|nil
```

Get GPS time

**Returns:** Table with hour, min, sec, year, month, day, valid, synced, or nil if not initialized

#### <a name="gps-init"></a>init

```lua
ez.gps.init() -> boolean
```

Initialize the GPS module

**Returns:** true if initialization successful

#### <a name="gps-is_valid"></a>is_valid

```lua
ez.gps.is_valid() -> boolean
```

Check if GPS has a valid location fix

**Returns:** true if location is valid

#### <a name="gps-sync_time"></a>sync_time

```lua
ez.gps.sync_time() -> boolean
```

Sync system time from GPS

**Returns:** true if time was synced successfully

#### <a name="gps-update"></a>update

```lua
ez.gps.update()
```

Process incoming GPS data, call from main loop

## keyboard

### ez.keyboard

#### <a name="keyboard-available"></a>available

```lua
ez.keyboard.available() -> boolean
```

Check if a key is waiting

**Returns:** true if a key is available to read

#### <a name="keyboard-get_backlight"></a>get_backlight

```lua
ez.keyboard.get_backlight() -> integer
```

Get current keyboard backlight level

**Returns:** Backlight level (0-255, 0 = off)

#### <a name="keyboard-get_mode"></a>get_mode

```lua
ez.keyboard.get_mode() -> string
```

Get current keyboard input mode

**Returns:** "normal" or "raw"

#### <a name="keyboard-get_pin_states"></a>get_pin_states

```lua
ez.keyboard.get_pin_states() -> string
```

Debug function to get raw GPIO pin states for wake detection

**Returns:** String with pin states: "KB_INT=X TB_UP=X TB_DOWN=X TB_LEFT=X TB_RIGHT=X TB_CLICK=X"

#### <a name="keyboard-get_raw_matrix_bits"></a>get_raw_matrix_bits

```lua
ez.keyboard.get_raw_matrix_bits() -> integer
```

Get full matrix state as 64-bit integer (raw mode)

**Returns:** 49-bit value (7 cols × 7 rows), bits 0-6 = col 0, bits 7-13 = col 1, etc.

#### <a name="keyboard-get_repeat_delay"></a>get_repeat_delay

```lua
ez.keyboard.get_repeat_delay() -> integer
```

Get initial delay before key repeat starts

**Returns:** Delay in milliseconds

#### <a name="keyboard-get_repeat_enabled"></a>get_repeat_enabled

```lua
ez.keyboard.get_repeat_enabled() -> boolean
```

Check if key repeat is enabled

**Returns:** true if key repeat is enabled

#### <a name="keyboard-get_repeat_rate"></a>get_repeat_rate

```lua
ez.keyboard.get_repeat_rate() -> integer
```

Get key repeat rate (interval between repeats)

**Returns:** Rate in milliseconds

#### <a name="keyboard-get_trackball_mode"></a>get_trackball_mode

```lua
ez.keyboard.get_trackball_mode() -> string
```

Get current trackball input mode

**Returns:** "polling" or "interrupt"

#### <a name="keyboard-get_trackball_sensitivity"></a>get_trackball_sensitivity

```lua
ez.keyboard.get_trackball_sensitivity() -> integer
```

Get trackball sensitivity level

**Returns:** Sensitivity value

#### <a name="keyboard-has_key_activity"></a>has_key_activity

```lua
ez.keyboard.has_key_activity() -> boolean
```

Check if keyboard interrupt pin indicates key activity

**Returns:** true if a key press is detected via hardware interrupt pin

#### <a name="keyboard-has_trackball"></a>has_trackball

```lua
ez.keyboard.has_trackball() -> boolean
```

Check if device has trackball

**Returns:** true if trackball is available

#### <a name="keyboard-is_alt_held"></a>is_alt_held

```lua
ez.keyboard.is_alt_held() -> boolean
```

Check if Alt is currently held

**Returns:** true if Alt is held

#### <a name="keyboard-is_ctrl_held"></a>is_ctrl_held

```lua
ez.keyboard.is_ctrl_held() -> boolean
```

Check if Ctrl is currently held

**Returns:** true if Ctrl is held

#### <a name="keyboard-is_fn_held"></a>is_fn_held

```lua
ez.keyboard.is_fn_held() -> boolean
```

Check if Fn is currently held

**Returns:** true if Fn is held

#### <a name="keyboard-is_key_pressed"></a>is_key_pressed

```lua
ez.keyboard.is_key_pressed(col, row) -> boolean
```

Check if a specific matrix key is pressed (raw mode)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `col` | Column index (0-4) |
| `row` | Row index (0-6) |

**Returns:** true if key is pressed

#### <a name="keyboard-is_shift_held"></a>is_shift_held

```lua
ez.keyboard.is_shift_held() -> boolean
```

Check if Shift is currently held

**Returns:** true if Shift is held

#### <a name="keyboard-read"></a>read

```lua
ez.keyboard.read() -> table
```

Read next key event (non-blocking)

**Returns:** Key event table or nil if no key available

#### <a name="keyboard-read_blocking"></a>read_blocking

```lua
ez.keyboard.read_blocking(timeout_ms) -> table
```

Read key with optional timeout (blocking)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `timeout_ms` | Timeout in milliseconds (0 = forever) |

**Returns:** Key event table or nil on timeout

#### <a name="keyboard-read_raw_code"></a>read_raw_code

```lua
ez.keyboard.read_raw_code() -> integer|nil
```

Read raw key code byte directly from I2C (no translation)

**Returns:** Raw byte (0x00-0xFF) or nil if no key available

#### <a name="keyboard-read_raw_matrix"></a>read_raw_matrix

```lua
ez.keyboard.read_raw_matrix() -> table|nil
```

Read raw key matrix state (only works in raw mode)

**Returns:** Table of 7 bytes (one per column, 7 bits = rows), or nil on error

#### <a name="keyboard-set_backlight"></a>set_backlight

```lua
ez.keyboard.set_backlight(level)
```

Set keyboard backlight brightness

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `level` | Brightness level (0-255, 0 = off) |

#### <a name="keyboard-set_mode"></a>set_mode

```lua
ez.keyboard.set_mode(mode) -> boolean
```

Set keyboard input mode

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `mode` | "normal" or "raw" |

**Returns:** true if mode was set successfully

#### <a name="keyboard-set_repeat_delay"></a>set_repeat_delay

```lua
ez.keyboard.set_repeat_delay(delay_ms)
```

Set initial delay before key repeat starts

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `delay_ms` | Delay in milliseconds (typically 200-800) |

#### <a name="keyboard-set_repeat_enabled"></a>set_repeat_enabled

```lua
ez.keyboard.set_repeat_enabled(enabled)
```

Enable or disable key repeat

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `enabled` | true to enable, false to disable |

#### <a name="keyboard-set_repeat_rate"></a>set_repeat_rate

```lua
ez.keyboard.set_repeat_rate(rate_ms)
```

Set key repeat rate (interval between repeats)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `rate_ms` | Rate in milliseconds (typically 20-100) |

#### <a name="keyboard-set_trackball_mode"></a>set_trackball_mode

```lua
ez.keyboard.set_trackball_mode(mode)
```

Set trackball input mode

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `mode` | "polling" or "interrupt" |

#### <a name="keyboard-set_trackball_sensitivity"></a>set_trackball_sensitivity

```lua
ez.keyboard.set_trackball_sensitivity(value)
```

Set trackball sensitivity level

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `value` | Sensitivity value |

## mesh

### ez.mesh

#### <a name="mesh-build_packet"></a>build_packet

```lua
ez.mesh.build_packet(route_type, payload_type, payload, path) -> string|nil
```

Build a raw mesh packet for transmission

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `route_type` | Route type constant (FLOOD=1, DIRECT=2) |
| `payload_type` | Payload type constant (ADVERT=4, GRP_TXT=5, etc.) |
| `payload` | Binary string payload |
| `path` | Optional binary string of path hashes (default: empty) |

**Returns:** Serialized packet as binary string, or nil on error

#### <a name="mesh-calc_shared_secret"></a>calc_shared_secret

```lua
ez.mesh.calc_shared_secret(other_pub_key) -> string|nil
```

Calculate ECDH shared secret with another node

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `other_pub_key` | 32-byte Ed25519 public key of the other party |

**Returns:** 32-byte shared secret as binary string, or nil on error

#### <a name="mesh-clear_packet_queue"></a>clear_packet_queue

```lua
ez.mesh.clear_packet_queue()
```

Clear all packets from the queue

#### <a name="mesh-clear_tx_queue"></a>clear_tx_queue

```lua
ez.mesh.clear_tx_queue()
```

Clear all packets from transmit queue

#### <a name="mesh-ed25519_sign"></a>ed25519_sign

```lua
ez.mesh.ed25519_sign(data) -> signature
```

Sign data with this node's private key

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string to sign |

**Returns:** 64-byte Ed25519 signature as binary string, or nil on error

#### <a name="mesh-ed25519_verify"></a>ed25519_verify

```lua
ez.mesh.ed25519_verify(data, signature, pub_key) -> boolean
```

Verify an Ed25519 signature

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string that was signed |
| `signature` | 64-byte Ed25519 signature |
| `pub_key` | 32-byte Ed25519 public key |

**Returns:** true if signature is valid

#### <a name="mesh-enable_packet_queue"></a>enable_packet_queue

```lua
ez.mesh.enable_packet_queue(enabled)
```

Enable or disable packet queuing for polling

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `enabled` | Boolean to enable/disable |

#### <a name="mesh-get_announce_interval"></a>get_announce_interval

```lua
ez.mesh.get_announce_interval() -> integer
```

Get current auto-announce interval

**Returns:** Interval in milliseconds (0 = disabled)

#### <a name="mesh-get_node_count"></a>get_node_count

```lua
ez.mesh.get_node_count() -> integer
```

Get number of known nodes

**Returns:** Node count

#### <a name="mesh-get_node_id"></a>get_node_id

```lua
ez.mesh.get_node_id() -> string
```

Get this node's full ID

**Returns:** 6-byte hex string

#### <a name="mesh-get_node_name"></a>get_node_name

```lua
ez.mesh.get_node_name() -> string
```

Get this node's display name

**Returns:** Node name string

#### <a name="mesh-get_nodes"></a>get_nodes

```lua
ez.mesh.get_nodes() -> table
```

Get list of discovered mesh nodes

**Returns:** Array of node tables with path_hash, name, rssi, snr, last_seen, hops, pub_key_hex

#### <a name="mesh-get_path_check"></a>get_path_check

```lua
ez.mesh.get_path_check() -> boolean
```

Get current path check setting

**Returns:** true if path check is enabled

#### <a name="mesh-get_path_hash"></a>get_path_hash

```lua
ez.mesh.get_path_hash() -> integer
```

Get this node's path hash (first byte of public key)

**Returns:** Path hash as integer (0-255)

#### <a name="mesh-get_public_key"></a>get_public_key

```lua
ez.mesh.get_public_key() -> string
```

Get this node's public key as binary string

**Returns:** 32-byte Ed25519 public key

#### <a name="mesh-get_public_key_hex"></a>get_public_key_hex

```lua
ez.mesh.get_public_key_hex() -> string
```

Get this node's public key as hex string

**Returns:** 64-character hex string

#### <a name="mesh-get_rx_count"></a>get_rx_count

```lua
ez.mesh.get_rx_count() -> integer
```

Get total packets received

**Returns:** Receive count

#### <a name="mesh-get_short_id"></a>get_short_id

```lua
ez.mesh.get_short_id() -> string
```

Get this node's short ID

**Returns:** 3-byte hex string (6 chars)

#### <a name="mesh-get_tx_count"></a>get_tx_count

```lua
ez.mesh.get_tx_count() -> integer
```

Get total packets transmitted

**Returns:** Transmit count

#### <a name="mesh-get_tx_queue_capacity"></a>get_tx_queue_capacity

```lua
ez.mesh.get_tx_queue_capacity() -> integer
```

Get maximum transmit queue capacity

**Returns:** Max queue size

#### <a name="mesh-get_tx_queue_size"></a>get_tx_queue_size

```lua
ez.mesh.get_tx_queue_size() -> integer
```

Get number of packets waiting in transmit queue

**Returns:** Queue size

#### <a name="mesh-get_tx_throttle"></a>get_tx_throttle

```lua
ez.mesh.get_tx_throttle() -> integer
```

Get current throttle interval

**Returns:** Milliseconds between transmissions

#### <a name="mesh-has_packets"></a>has_packets

```lua
ez.mesh.has_packets() -> boolean
```

Check if packets are available in the queue

**Returns:** true if one or more packets are queued

#### <a name="mesh-is_initialized"></a>is_initialized

```lua
ez.mesh.is_initialized() -> boolean
```

Check if mesh networking is initialized

**Returns:** true if mesh is ready

#### <a name="mesh-is_tx_queue_full"></a>is_tx_queue_full

```lua
ez.mesh.is_tx_queue_full() -> boolean
```

Check if transmit queue is full

**Returns:** true if queue is full

#### <a name="mesh-make_header"></a>make_header

```lua
ez.mesh.make_header(route_type, payload_type, version) -> integer
```

Create a packet header byte from components

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `route_type` | Route type constant |
| `payload_type` | Payload type constant |
| `version` | Optional version (default: 0) |

**Returns:** Header byte as integer

#### <a name="mesh-on_group_packet"></a>on_group_packet

```lua
ez.mesh.on_group_packet(callback)
```

Set callback for raw group packets (DEPRECATED - use bus.subscribe("mesh/group_packet") instead)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `callback` | Function(packet_table) called with {channel_hash, data, sender_hash, rssi, snr} |

#### <a name="mesh-on_node_discovered"></a>on_node_discovered

```lua
ez.mesh.on_node_discovered(callback)
```

Set callback for node discovery (DEPRECATED - use bus.subscribe("mesh/node_discovered") instead)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `callback` | Function(node_table) called when node discovered |

#### <a name="mesh-on_packet"></a>on_packet

```lua
ez.mesh.on_packet(callback)
```

Set callback for ALL incoming packets (DEPRECATED - use bus.subscribe("mesh/packet") instead)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `callback` | Function(packet_table) returning handled, rebroadcast booleans |

#### <a name="mesh-packet_count"></a>packet_count

```lua
ez.mesh.packet_count() -> integer
```

Get number of packets in queue

**Returns:** Number of queued packets

#### <a name="mesh-parse_header"></a>parse_header

```lua
ez.mesh.parse_header(header_byte) -> route_type, payload_type, version
```

Parse a packet header byte into components

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `header_byte` | Single byte header value |

**Returns:** route_type, payload_type, version as integers

#### <a name="mesh-pop_packet"></a>pop_packet

```lua
ez.mesh.pop_packet() -> table|nil
```

Get and remove the next packet from queue

**Returns:** Packet table or nil if queue is empty

#### <a name="mesh-queue_send"></a>queue_send

```lua
ez.mesh.queue_send(data) -> boolean
```

Queue packet for transmission (throttled, non-blocking)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string of serialized packet |

**Returns:** true if queued successfully, false if queue full or error

#### <a name="mesh-schedule_rebroadcast"></a>schedule_rebroadcast

```lua
ez.mesh.schedule_rebroadcast(data)
```

Schedule raw packet data for rebroadcast

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string of raw packet bytes |

#### <a name="mesh-send_announce"></a>send_announce

```lua
ez.mesh.send_announce() -> boolean
```

Broadcast node announcement

**Returns:** true if sent successfully

#### <a name="mesh-send_group_packet"></a>send_group_packet

```lua
ez.mesh.send_group_packet(channel_hash, encrypted_data) -> boolean
```

Send raw encrypted group packet

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `channel_hash` | Single byte channel identifier |
| `encrypted_data` | Pre-encrypted payload (MAC + ciphertext) |

**Returns:** true if sent successfully

#### <a name="mesh-send_raw"></a>send_raw

```lua
ez.mesh.send_raw(data) -> boolean
```

Send raw packet data directly via radio (bypasses queue, immediate)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | Binary string of serialized packet |

**Returns:** true if sent successfully

#### <a name="mesh-set_announce_interval"></a>set_announce_interval

```lua
ez.mesh.set_announce_interval(ms)
```

Set auto-announce interval in milliseconds (0 = disabled)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `ms` | Integer - interval in milliseconds (0 to disable) |

#### <a name="mesh-set_node_name"></a>set_node_name

```lua
ez.mesh.set_node_name(name) -> boolean
```

Set this node's display name

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `name` | New node name |

**Returns:** true if successful

#### <a name="mesh-set_path_check"></a>set_path_check

```lua
ez.mesh.set_path_check(enabled)
```

Enable or disable path check for flood routing

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `enabled` | Boolean - when true, packets with our hash in path are skipped |

#### <a name="mesh-set_tx_throttle"></a>set_tx_throttle

```lua
ez.mesh.set_tx_throttle(ms)
```

Set minimum interval between transmissions

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `ms` | Milliseconds between transmissions (default 100) |

#### <a name="mesh-update"></a>update

```lua
ez.mesh.update()
```

Process incoming mesh packets

## radio

### ez.radio

#### <a name="radio-available"></a>available

```lua
ez.radio.available() -> boolean
```

Check if data is available

**Returns:** true if packet waiting

#### <a name="radio-get_config"></a>get_config

```lua
ez.radio.get_config() -> table
```

Get current radio configuration

**Returns:** Table with frequency, bandwidth, spreading_factor, etc.

#### <a name="radio-get_last_rssi"></a>get_last_rssi

```lua
ez.radio.get_last_rssi() -> number
```

Get last received signal strength

**Returns:** RSSI in dBm

#### <a name="radio-get_last_snr"></a>get_last_snr

```lua
ez.radio.get_last_snr() -> number
```

Get last signal-to-noise ratio

**Returns:** SNR in dB

#### <a name="radio-is_busy"></a>is_busy

```lua
ez.radio.is_busy() -> boolean
```

Check if radio is busy

**Returns:** true if transmitting or receiving

#### <a name="radio-is_initialized"></a>is_initialized

```lua
ez.radio.is_initialized() -> boolean
```

Check if radio is initialized

**Returns:** true if radio is ready

#### <a name="radio-is_receiving"></a>is_receiving

```lua
ez.radio.is_receiving() -> boolean
```

Check if in receive mode

**Returns:** true if listening

#### <a name="radio-is_transmitting"></a>is_transmitting

```lua
ez.radio.is_transmitting() -> boolean
```

Check if currently transmitting

**Returns:** true if transmission in progress

#### <a name="radio-receive"></a>receive

```lua
ez.radio.receive() -> string, number, number
```

Receive a packet

**Returns:** Data string, RSSI, SNR or nil if no data

#### <a name="radio-send"></a>send

```lua
ez.radio.send(data) -> string
```

Transmit data

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `data` | String or table of bytes to send |

**Returns:** Result string

#### <a name="radio-set_bandwidth"></a>set_bandwidth

```lua
ez.radio.set_bandwidth(khz) -> string
```

Set radio bandwidth

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `khz` | Bandwidth in kHz |

**Returns:** Result string

#### <a name="radio-set_coding_rate"></a>set_coding_rate

```lua
ez.radio.set_coding_rate(cr) -> string
```

Set LoRa coding rate

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `cr` | Coding rate (5-8) |

**Returns:** Result string

#### <a name="radio-set_frequency"></a>set_frequency

```lua
ez.radio.set_frequency(mhz) -> string
```

Set radio frequency

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `mhz` | Frequency in MHz |

**Returns:** Result string (ok, error_init, etc.)

#### <a name="radio-set_spreading_factor"></a>set_spreading_factor

```lua
ez.radio.set_spreading_factor(sf) -> string
```

Set LoRa spreading factor

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `sf` | Spreading factor (6-12) |

**Returns:** Result string

#### <a name="radio-set_sync_word"></a>set_sync_word

```lua
ez.radio.set_sync_word(sw) -> string
```

Set sync word

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `sw` | Sync word value |

**Returns:** Result string

#### <a name="radio-set_tx_power"></a>set_tx_power

```lua
ez.radio.set_tx_power(dbm) -> string
```

Set transmit power

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `dbm` | Power in dBm (0-22) |

**Returns:** Result string

#### <a name="radio-sleep"></a>sleep

```lua
ez.radio.sleep() -> string
```

Put radio into sleep mode

**Returns:** Result string

#### <a name="radio-start_receive"></a>start_receive

```lua
ez.radio.start_receive() -> string
```

Start listening for packets

**Returns:** Result string

#### <a name="radio-wake"></a>wake

```lua
ez.radio.wake() -> string
```

Wake radio from sleep

**Returns:** Result string

## storage

### ez.storage

#### <a name="storage-append_file"></a>append_file

```lua
ez.storage.append_file(path, content) -> boolean
```

Append content to file

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | File path |
| `content` | Content to append |

**Returns:** true if successful

#### <a name="storage-clear_prefs"></a>clear_prefs

```lua
ez.storage.clear_prefs() -> boolean
```

Clear all preferences

**Returns:** true if cleared

#### <a name="storage-exists"></a>exists

```lua
ez.storage.exists(path) -> boolean
```

Check if file or directory exists

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | Path to check |

**Returns:** true if exists

#### <a name="storage-file_size"></a>file_size

```lua
ez.storage.file_size(path) -> integer
```

Get file size in bytes

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | File path (prefix /sd/ for SD card) |

**Returns:** File size or nil with error message

#### <a name="storage-get_flash_info"></a>get_flash_info

```lua
ez.storage.get_flash_info() -> table
```

Get flash storage info

**Returns:** Table with total_bytes, used_bytes, free_bytes

#### <a name="storage-get_pref"></a>get_pref

```lua
ez.storage.get_pref(key, default) -> string
```

Get preference value

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `key` | Preference key |
| `default` | Default value if not found |

**Returns:** Stored value or default

#### <a name="storage-get_sd_info"></a>get_sd_info

```lua
ez.storage.get_sd_info() -> table
```

Get SD card info

**Returns:** Table with total_bytes, used_bytes, free_bytes or nil

#### <a name="storage-is_sd_available"></a>is_sd_available

```lua
ez.storage.is_sd_available() -> boolean
```

Check if SD card is mounted

**Returns:** true if SD card available

#### <a name="storage-json_decode"></a>json_decode

```lua
ez.storage.json_decode(json_string) -> value
```

Decode JSON string to Lua value

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `json_string` | JSON string |

**Returns:** Lua value or nil on error

#### <a name="storage-json_encode"></a>json_encode

```lua
ez.storage.json_encode(value) -> string
```

Encode Lua value to JSON string

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `value` | Lua table, string, number, boolean, or nil |

**Returns:** JSON string or nil on error

#### <a name="storage-list_dir"></a>list_dir

```lua
ez.storage.list_dir(path) -> table
```

List directory contents

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | Directory path (default "/") |

**Returns:** Array of tables with name, is_dir, size

#### <a name="storage-mkdir"></a>mkdir

```lua
ez.storage.mkdir(path) -> boolean
```

Create directory

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | Directory path |

**Returns:** true if created

#### <a name="storage-read_bytes"></a>read_bytes

```lua
ez.storage.read_bytes(path, offset, length) -> string
```

Read bytes from file at specific offset (for random access)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | File path (prefix /sd/ for SD card) |
| `offset` | Byte offset to start reading from |
| `length` | Number of bytes to read |

**Returns:** Binary data as string, or nil with error message

#### <a name="storage-read_file"></a>read_file

```lua
ez.storage.read_file(path) -> string
```

Read entire file contents

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | File path (prefix /sd/ for SD card) |

**Returns:** File content or nil, error_message

#### <a name="storage-remove"></a>remove

```lua
ez.storage.remove(path) -> boolean
```

Delete a file

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | File path to delete |

**Returns:** true if deleted

#### <a name="storage-remove_pref"></a>remove_pref

```lua
ez.storage.remove_pref(key) -> boolean
```

Remove a preference

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `key` | Preference key to remove |

**Returns:** true if removed

#### <a name="storage-rename"></a>rename

```lua
ez.storage.rename(old_path, new_path) -> boolean
```

Rename or move a file

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `old_path` | Current path |
| `new_path` | New path |

**Returns:** true if renamed

#### <a name="storage-rmdir"></a>rmdir

```lua
ez.storage.rmdir(path) -> boolean
```

Remove empty directory

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | Directory path |

**Returns:** true if removed

#### <a name="storage-set_pref"></a>set_pref

```lua
ez.storage.set_pref(key, value) -> boolean
```

Set preference value

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `key` | Preference key |
| `value` | Value to store |

**Returns:** true if saved successfully

#### <a name="storage-write_file"></a>write_file

```lua
ez.storage.write_file(path, content) -> boolean
```

Write content to file (creates/overwrites)

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `path` | File path |
| `content` | Content to write |

**Returns:** true if successful, or false with error

## system

### ez.system

#### <a name="system-cancel_timer"></a>cancel_timer

```lua
ez.system.cancel_timer(timer_id)
```

Cancel a scheduled timer

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `timer_id` | ID returned by set_timer or set_interval |

#### <a name="system-chip_model"></a>chip_model

```lua
ez.system.chip_model() -> string
```

Get ESP32 chip model name

**Returns:** Chip model string

#### <a name="system-cpu_freq"></a>cpu_freq

```lua
ez.system.cpu_freq() -> integer
```

Get CPU frequency

**Returns:** Frequency in MHz

#### <a name="system-delay"></a>delay

```lua
ez.system.delay(ms)
```

Blocking delay execution

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `ms` | Delay duration in milliseconds (max 60000) |

#### <a name="system-gc"></a>gc

```lua
ez.system.gc()
```

Force full garbage collection

#### <a name="system-gc_step"></a>gc_step

```lua
ez.system.gc_step(steps) -> integer
```

Perform incremental garbage collection

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `steps` | Number of GC steps (default 10) |

**Returns:** Result from lua_gc

#### <a name="system-get_battery_percent"></a>get_battery_percent

```lua
ez.system.get_battery_percent() -> integer
```

Get battery charge level

**Returns:** Battery percentage (0-100)

#### <a name="system-get_battery_voltage"></a>get_battery_voltage

```lua
ez.system.get_battery_voltage() -> number
```

Get battery voltage

**Returns:** Estimated battery voltage in volts

#### <a name="system-get_firmware_info"></a>get_firmware_info

```lua
ez.system.get_firmware_info() -> table
```

Get firmware partition info

**Returns:** Table with partition_size, app_size, free_bytes

#### <a name="system-get_free_heap"></a>get_free_heap

```lua
ez.system.get_free_heap() -> integer
```

Get free internal RAM

**Returns:** Free heap memory in bytes

#### <a name="system-get_free_psram"></a>get_free_psram

```lua
ez.system.get_free_psram() -> integer
```

Get free PSRAM

**Returns:** Free PSRAM in bytes

#### <a name="system-get_last_error"></a>get_last_error

```lua
ez.system.get_last_error() -> string
```

Get last Lua error message

**Returns:** Error message or nil if no error

#### <a name="system-get_loop_delay"></a>get_loop_delay

```lua
ez.system.get_loop_delay() -> integer
```

Get the current main loop delay in milliseconds

#### <a name="system-get_lua_memory"></a>get_lua_memory

```lua
ez.system.get_lua_memory() -> integer
```

Get memory used by Lua runtime

**Returns:** Memory usage in bytes

#### <a name="system-get_time"></a>get_time

```lua
ez.system.get_time() -> table|nil
```

Get current wall clock time

**Returns:** Table with hour, minute, second, or nil if time not set

#### <a name="system-get_time_unix"></a>get_time_unix

```lua
ez.system.get_time_unix() -> integer
```

Get current Unix timestamp

**Returns:** Unix timestamp (seconds since 1970-01-01), or 0 if time not set

#### <a name="system-get_timezone"></a>get_timezone

```lua
ez.system.get_timezone() -> integer
```

Get current timezone UTC offset in hours

**Returns:** UTC offset in hours

#### <a name="system-get_total_heap"></a>get_total_heap

```lua
ez.system.get_total_heap() -> integer
```

Get total heap size

**Returns:** Total heap memory in bytes

#### <a name="system-get_total_psram"></a>get_total_psram

```lua
ez.system.get_total_psram() -> integer
```

Get total PSRAM size

**Returns:** Total PSRAM in bytes

#### <a name="system-is_low_memory"></a>is_low_memory

```lua
ez.system.is_low_memory() -> boolean
```

Check if memory is critically low

**Returns:** true if less than 32KB available

#### <a name="system-is_sd_available"></a>is_sd_available

```lua
ez.system.is_sd_available() -> boolean
```

Check if SD card is available

**Returns:** true if SD card is present and accessible

#### <a name="system-is_usb_msc_active"></a>is_usb_msc_active

```lua
ez.system.is_usb_msc_active() -> boolean
```

Check if USB MSC mode is active

**Returns:** true if MSC mode is active

#### <a name="system-millis"></a>millis

```lua
ez.system.millis() -> integer
```

Returns milliseconds since boot

**Returns:** Milliseconds elapsed since device started

#### <a name="system-reload_scripts"></a>reload_scripts

```lua
ez.system.reload_scripts() -> boolean
```

Reload all Lua scripts (hot reload)

**Returns:** true if successful

#### <a name="system-restart"></a>restart

```lua
ez.system.restart()
```

Restart the device

#### <a name="system-set_interval"></a>set_interval

```lua
ez.system.set_interval(ms, callback) -> integer
```

Schedule a repeating callback

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `ms` | Interval between calls (minimum 10ms) |
| `callback` | Function to call repeatedly |

**Returns:** Timer ID for cancellation

#### <a name="system-set_loop_delay"></a>set_loop_delay

```lua
ez.system.set_loop_delay(ms)
```

Set the main loop delay in milliseconds

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `ms` | Delay in milliseconds (0-100, default 0) |

#### <a name="system-set_time"></a>set_time

```lua
ez.system.set_time(year, month, day, hour, minute, second) -> boolean
```

Set system clock time

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `year` | Full year (e.g., 2024) |
| `month` | Month (1-12) |
| `day` | Day of month (1-31) |
| `hour` | Hour (0-23) |
| `minute` | Minute (0-59) |
| `second` | Second (0-59) |

**Returns:** true if time was set successfully

#### <a name="system-set_time_unix"></a>set_time_unix

```lua
ez.system.set_time_unix(timestamp) -> boolean
```

Set system clock from Unix timestamp

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `timestamp` | Unix timestamp (seconds since 1970-01-01) |

**Returns:** true if time was set successfully

#### <a name="system-set_timer"></a>set_timer

```lua
ez.system.set_timer(ms, callback) -> integer
```

Schedule a one-shot callback

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `ms` | Delay before callback fires |
| `callback` | Function to call |

**Returns:** Timer ID for cancellation

#### <a name="system-set_timezone"></a>set_timezone

```lua
ez.system.set_timezone(tz_string) -> boolean
```

Set timezone using POSIX TZ string

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `tz_string` | POSIX timezone string (e.g., "CET-1CEST,M3.5.0,M10.5.0/3") |

**Returns:** true if timezone was set successfully

#### <a name="system-start_usb_msc"></a>start_usb_msc

```lua
ez.system.start_usb_msc() -> boolean
```

Start USB Mass Storage mode to access SD card from PC

**Returns:** true if started successfully

#### <a name="system-stop_usb_msc"></a>stop_usb_msc

```lua
ez.system.stop_usb_msc()
```

Stop USB Mass Storage mode

#### <a name="system-uptime"></a>uptime

```lua
ez.system.uptime() -> integer
```

Get device uptime

**Returns:** Seconds since boot

#### <a name="system-yield"></a>yield

```lua
ez.system.yield(ms)
```

Yield execution to allow C++ background tasks to run

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `ms` | Optional sleep time in milliseconds (default 1, max 100) |
