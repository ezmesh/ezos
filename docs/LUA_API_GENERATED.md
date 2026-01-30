# T-Deck OS Lua API Reference

> Auto-generated from source code

## Table of Contents

- [tdeck.audio](#audio)
- [tdeck.crypto](#crypto)
- [tdeck.display](#display)
- [tdeck.keyboard](#keyboard)
- [tdeck.mesh](#mesh)
- [tdeck.radio](#radio)
- [tdeck.storage](#storage)
- [tdeck.system](#system)

## audio

### tdeck.audio

#### beep

```lua
tdeck.audio.beep(count, frequency, on_ms, off_ms)
```

Play a series of beeps (blocking)

**Parameters:**
- `count`: Number of beeps (default 1)
- `frequency`: Tone frequency in Hz (default 1000)
- `on_ms`: Beep duration in ms (default 100)
- `off_ms`: Pause between beeps in ms (default 50)

#### get_volume

```lua
tdeck.audio.get_volume() -> integer
```

Get current volume level

**Returns:** Volume level 0-100

#### is_playing

```lua
tdeck.audio.is_playing() -> boolean
```

Check if audio is playing

**Returns:** true if playing

#### play_sample

```lua
tdeck.audio.play_sample(filename) -> boolean
```

Play a PCM sample file from LittleFS

**Parameters:**
- `filename`: Path to .pcm file (16-bit signed, 22050Hz mono)

**Returns:** true if played successfully

#### play_tone

```lua
tdeck.audio.play_tone(frequency, duration_ms) -> boolean
```

Play a tone for specified duration

**Parameters:**
- `frequency`: Frequency in Hz (20-20000)
- `duration_ms`: Duration in milliseconds

**Returns:** true if started successfully

#### set_frequency

```lua
tdeck.audio.set_frequency(frequency) -> boolean
```

Set playback frequency for continuous tones

**Parameters:**
- `frequency`: Frequency in Hz (20-20000)

**Returns:** true if valid frequency

#### set_volume

```lua
tdeck.audio.set_volume(level)
```

Set audio volume level

**Parameters:**
- `level`: Volume level 0-100

#### start

```lua
tdeck.audio.start()
```

Start continuous tone at current frequency

#### stop

```lua
tdeck.audio.stop()
```

Stop audio playback

## crypto

### tdeck.crypto

#### aes128_ecb_decrypt

```lua
tdeck.crypto.aes128_ecb_decrypt(key, ciphertext) -> string
```

Decrypt data with AES-128-ECB

**Parameters:**
- `key`: 16-byte key
- `ciphertext`: Data to decrypt (must be multiple of 16 bytes)

**Returns:** Decrypted data as binary string (with padding zeros)

#### aes128_ecb_encrypt

```lua
tdeck.crypto.aes128_ecb_encrypt(key, plaintext) -> string
```

Encrypt data with AES-128-ECB

**Parameters:**
- `key`: 16-byte key
- `plaintext`: Data to encrypt (will be zero-padded to block boundary)

**Returns:** Encrypted data as binary string

#### base64_decode

```lua
tdeck.crypto.base64_decode(encoded) -> string
```

Decode base64 string to binary data

**Parameters:**
- `encoded`: Base64 encoded string

**Returns:** Binary string, or nil on error

#### base64_encode

```lua
tdeck.crypto.base64_encode(data) -> string
```

Encode binary data to base64 string

**Parameters:**
- `data`: Binary string to encode

**Returns:** Base64 encoded string

#### bytes_to_hex

```lua
tdeck.crypto.bytes_to_hex(data) -> string
```

Convert binary data to hex string

**Parameters:**
- `data`: Binary string

**Returns:** Hex string (lowercase)

#### channel_hash

```lua
tdeck.crypto.channel_hash(key) -> integer
```

Compute channel hash from key (SHA256(key)[0])

**Parameters:**
- `key`: 16-byte channel key

**Returns:** Single byte hash as integer (0-255)

#### derive_channel_key

```lua
tdeck.crypto.derive_channel_key(input) -> string
```

Derive 16-byte channel key from password/name using SHA256

**Parameters:**
- `input`: Password or channel name string

**Returns:** 16-byte key as binary string

#### hex_to_bytes

```lua
tdeck.crypto.hex_to_bytes(hex) -> string
```

Convert hex string to binary data

**Parameters:**
- `hex`: Hex string (case-insensitive)

**Returns:** Binary string, or nil on error

#### hmac_sha256

```lua
tdeck.crypto.hmac_sha256(key, data) -> string
```

Compute HMAC-SHA256

**Parameters:**
- `key`: Binary string key
- `data`: Binary string to authenticate

**Returns:** 32-byte MAC as binary string

#### public_channel_key

```lua
tdeck.crypto.public_channel_key() -> string
```

Get the well-known #Public channel key

**Returns:** 16-byte key as binary string

#### random_bytes

```lua
tdeck.crypto.random_bytes(count) -> string
```

Generate cryptographically secure random bytes

**Parameters:**
- `count`: Number of bytes to generate

**Returns:** Random bytes as binary string

#### sha256

```lua
tdeck.crypto.sha256(data) -> string
```

Compute SHA-256 hash

**Parameters:**
- `data`: Binary string to hash

**Returns:** 32-byte hash as binary string

#### sha512

```lua
tdeck.crypto.sha512(data) -> string
```

Compute SHA-512 hash

**Parameters:**
- `data`: Binary string to hash

**Returns:** 64-byte hash as binary string

## display

### tdeck.display

#### clear

```lua
tdeck.display.clear()
```

Clear display buffer to black

#### draw_battery

```lua
tdeck.display.draw_battery(x, y, percent)
```

Draw battery indicator icon

**Parameters:**
- `x`: X position in pixels
- `y`: Y position in pixels
- `percent`: Battery percentage (0-100)

#### draw_bitmap

```lua
tdeck.display.draw_bitmap(x, y, width, height, data)
```

Draw a bitmap image from raw RGB565 data

**Parameters:**
- `x`: X position
- `y`: Y position
- `width`: Bitmap width in pixels
- `height`: Bitmap height in pixels
- `data`: Raw RGB565 pixel data (2 bytes per pixel, big-endian)

#### draw_bitmap_1bit

```lua
tdeck.display.draw_bitmap_1bit(x, y, width, height, data, scale, color)
```

Draw a 1-bit bitmap with scaling and colorization

**Parameters:**
- `x`: X position
- `y`: Y position
- `width`: Bitmap width in pixels (original size)
- `height`: Bitmap height in pixels (original size)
- `data`: Packed 1-bit data (MSB first, row by row)
- `scale`: Scale factor (1, 2, 3, etc.) - optional, default 1
- `color`: RGB565 color for "on" pixels - optional, default WHITE

#### draw_bitmap_transparent

```lua
tdeck.display.draw_bitmap_transparent(x, y, width, height, data, transparent_color)
```

Draw a bitmap with transparency

**Parameters:**
- `x`: X position
- `y`: Y position
- `width`: Bitmap width in pixels
- `height`: Bitmap height in pixels
- `data`: Raw RGB565 pixel data
- `transparent_color`: RGB565 color to treat as transparent

#### draw_box

```lua
tdeck.display.draw_box(x, y, w, h, title, border_color, title_color)
```

Draw bordered box with optional title

**Parameters:**
- `x`: X position in character cells
- `y`: Y position in character cells
- `w`: Width in character cells
- `h`: Height in character cells
- `title`: Optional title string
- `border_color`: Border color (optional)
- `title_color`: Title color (optional)

#### draw_char

```lua
tdeck.display.draw_char(x, y, char, color)
```

Draw a single character

**Parameters:**
- `x`: X position in pixels
- `y`: Y position in pixels
- `char`: Character to draw (first char of string)
- `color`: Character color (optional)

#### draw_circle

```lua
tdeck.display.draw_circle(x, y, r, color)
```

Draw circle outline

**Parameters:**
- `x`: Center X position
- `y`: Center Y position
- `r`: Radius
- `color`: Circle color (optional)

#### draw_hline

```lua
tdeck.display.draw_hline(x, y, w, left_connect, right_connect, color)
```

Draw horizontal line with optional connectors

**Parameters:**
- `x`: X position in character cells
- `y`: Y position in character cells
- `w`: Width in character cells
- `left_connect`: Connect to left border (optional)
- `right_connect`: Connect to right border (optional)
- `color`: Line color (optional)

#### draw_indexed_bitmap

```lua
tdeck.display.draw_indexed_bitmap(x, y, width, height, data, palette)
```

Draw a 3-bit indexed bitmap using a color palette

**Parameters:**
- `x`: X position
- `y`: Y position
- `width`: Bitmap width in pixels
- `height`: Bitmap height in pixels
- `data`: Packed 3-bit pixel indices (8 pixels packed into 3 bytes)
- `palette`: Table of 8 RGB565 color values

#### draw_line

```lua
tdeck.display.draw_line(x1, y1, x2, y2, color)
```

Draw a line between two points

**Parameters:**
- `x1`: Start X position
- `y1`: Start Y position
- `x2`: End X position
- `y2`: End Y position
- `color`: Line color (optional)

#### draw_pixel

```lua
tdeck.display.draw_pixel(x, y, color)
```

Draw a single pixel

**Parameters:**
- `x`: X position in pixels
- `y`: Y position in pixels
- `color`: Pixel color (optional)

#### draw_progress

```lua
tdeck.display.draw_progress(x, y, w, h, progress, fg_color, bg_color)
```

Draw a progress bar

**Parameters:**
- `x`: X position in pixels
- `y`: Y position in pixels
- `w`: Width in pixels
- `h`: Height in pixels
- `progress`: Progress value (0.0 to 1.0)
- `fg_color`: Foreground color (optional)
- `bg_color`: Background color (optional)

#### draw_rect

```lua
tdeck.display.draw_rect(x, y, w, h, color)
```

Draw rectangle outline

**Parameters:**
- `x`: X position in pixels
- `y`: Y position in pixels
- `w`: Width in pixels
- `h`: Height in pixels
- `color`: Outline color (optional)

#### draw_round_rect

```lua
tdeck.display.draw_round_rect(x, y, w, h, r, color)
```

Draw rounded rectangle outline

#### draw_signal

```lua
tdeck.display.draw_signal(x, y, bars)
```

Draw signal strength indicator

**Parameters:**
- `x`: X position in pixels
- `y`: Y position in pixels
- `bars`: Signal strength (0-4 bars)

#### draw_text

```lua
tdeck.display.draw_text(x, y, text, color)
```

Draw text at pixel coordinates

**Parameters:**
- `x`: X position in pixels
- `y`: Y position in pixels
- `text`: Text string to draw
- `color`: Text color (optional, defaults to TEXT)

#### draw_text_centered

```lua
tdeck.display.draw_text_centered(y, text, color)
```

Draw horizontally centered text

**Parameters:**
- `y`: Y position in pixels
- `text`: Text string to draw
- `color`: Text color (optional, defaults to TEXT)

#### draw_triangle

```lua
tdeck.display.draw_triangle(x1, y1, x2, y2, x3, y3, color)
```

Draw triangle outline

#### fill_circle

```lua
tdeck.display.fill_circle(x, y, r, color)
```

Draw filled circle

**Parameters:**
- `x`: Center X position
- `y`: Center Y position
- `r`: Radius
- `color`: Fill color (optional)

#### fill_rect

```lua
tdeck.display.fill_rect(x, y, w, h, color)
```

Fill a rectangle with color

**Parameters:**
- `x`: X position in pixels
- `y`: Y position in pixels
- `w`: Width in pixels
- `h`: Height in pixels
- `color`: Fill color (optional)

#### fill_round_rect

```lua
tdeck.display.fill_round_rect(x, y, w, h, r, color)
```

Draw filled rounded rectangle

#### fill_triangle

```lua
tdeck.display.fill_triangle(x1, y1, x2, y2, x3, y3, color)
```

Draw filled triangle

#### flush

```lua
tdeck.display.flush()
```

Flush buffer to physical display

#### get_cols

```lua
tdeck.display.get_cols() -> integer
```

Get display columns

**Returns:** Number of character columns

#### get_font_height

```lua
tdeck.display.get_font_height() -> integer
```

Get font character height

**Returns:** Character height in pixels

#### get_font_width

```lua
tdeck.display.get_font_width() -> integer
```

Get font character width

**Returns:** Character width in pixels

#### get_height

```lua
tdeck.display.get_height() -> integer
```

Get display height

**Returns:** Height in pixels

#### get_rows

```lua
tdeck.display.get_rows() -> integer
```

Get display rows

**Returns:** Number of character rows

#### get_width

```lua
tdeck.display.get_width() -> integer
```

Get display width

**Returns:** Width in pixels

#### rgb

```lua
tdeck.display.rgb(r, g, b) -> integer
```

Convert RGB to RGB565 color value

**Parameters:**
- `r`: Red component (0-255)
- `g`: Green component (0-255)
- `b`: Blue component (0-255)

**Returns:** RGB565 color value

#### set_brightness

```lua
tdeck.display.set_brightness(level)
```

Set backlight brightness

**Parameters:**
- `level`: Brightness level (0-255)

#### set_font_size

```lua
tdeck.display.set_font_size(size)
```

Set font size

**Parameters:**
- `size`: Font size string: "tiny", "small", "medium", or "large"

#### text_width

```lua
tdeck.display.text_width(text) -> integer
```

Get pixel width of text string

**Parameters:**
- `text`: Text string to measure

**Returns:** Width in pixels

## keyboard

### tdeck.keyboard

#### available

```lua
tdeck.keyboard.available() -> boolean
```

Check if a key is waiting

**Returns:** true if a key is available to read

#### get_adaptive_scrolling

```lua
tdeck.keyboard.get_adaptive_scrolling() -> boolean
```

Check if adaptive scrolling is enabled

**Returns:** true if adaptive scrolling is on

#### get_backlight

```lua
tdeck.keyboard.get_backlight() -> integer
```

Get current keyboard backlight level

**Returns:** Backlight level (0-255, 0 = off)

#### get_mode

```lua
tdeck.keyboard.get_mode() -> string
```

Get current keyboard input mode

**Returns:** "normal" or "raw"

#### get_raw_matrix_bits

```lua
tdeck.keyboard.get_raw_matrix_bits() -> integer
```

Get full matrix state as 64-bit integer (raw mode)

**Returns:** 49-bit value (7 cols × 7 rows), bits 0-6 = col 0, bits 7-13 = col 1, etc.

#### get_repeat_delay

```lua
tdeck.keyboard.get_repeat_delay() -> integer
```

Get initial delay before key repeat starts

**Returns:** Delay in milliseconds

#### get_repeat_enabled

```lua
tdeck.keyboard.get_repeat_enabled() -> boolean
```

Check if key repeat is enabled

**Returns:** true if key repeat is enabled

#### get_repeat_rate

```lua
tdeck.keyboard.get_repeat_rate() -> integer
```

Get key repeat rate (interval between repeats)

**Returns:** Rate in milliseconds

#### get_trackball_mode

```lua
tdeck.keyboard.get_trackball_mode() -> string
```

Get current trackball input mode

**Returns:** "polling" or "interrupt"

#### get_trackball_sensitivity

```lua
tdeck.keyboard.get_trackball_sensitivity() -> integer
```

Get trackball sensitivity level

**Returns:** Sensitivity value

#### has_trackball

```lua
tdeck.keyboard.has_trackball() -> boolean
```

Check if device has trackball

**Returns:** true if trackball is available

#### is_alt_held

```lua
tdeck.keyboard.is_alt_held() -> boolean
```

Check if Alt is currently held

**Returns:** true if Alt is held

#### is_ctrl_held

```lua
tdeck.keyboard.is_ctrl_held() -> boolean
```

Check if Ctrl is currently held

**Returns:** true if Ctrl is held

#### is_fn_held

```lua
tdeck.keyboard.is_fn_held() -> boolean
```

Check if Fn is currently held

**Returns:** true if Fn is held

#### is_key_pressed

```lua
tdeck.keyboard.is_key_pressed(col, row) -> boolean
```

Check if a specific matrix key is pressed (raw mode)

**Parameters:**
- `col`: Column index (0-4)
- `row`: Row index (0-6)

**Returns:** true if key is pressed

#### is_shift_held

```lua
tdeck.keyboard.is_shift_held() -> boolean
```

Check if Shift is currently held

**Returns:** true if Shift is held

#### read

```lua
tdeck.keyboard.read() -> table
```

Read next key event (non-blocking)

**Returns:** Key event table or nil if no key available

#### read_blocking

```lua
tdeck.keyboard.read_blocking(timeout_ms) -> table
```

Read key with optional timeout (blocking)

**Parameters:**
- `timeout_ms`: Timeout in milliseconds (0 = forever)

**Returns:** Key event table or nil on timeout

#### read_raw_code

```lua
tdeck.keyboard.read_raw_code() -> integer|nil
```

Read raw key code byte directly from I2C (no translation)

**Returns:** Raw byte (0x00-0xFF) or nil if no key available

#### read_raw_matrix

```lua
tdeck.keyboard.read_raw_matrix() -> table|nil
```

Read raw key matrix state (only works in raw mode)

**Returns:** Table of 7 bytes (one per column, 7 bits = rows), or nil on error

#### set_adaptive_scrolling

```lua
tdeck.keyboard.set_adaptive_scrolling(enabled)
```

Enable or disable adaptive scrolling

**Parameters:**
- `enabled`: true to enable, false to disable

#### set_backlight

```lua
tdeck.keyboard.set_backlight(level)
```

Set keyboard backlight brightness

**Parameters:**
- `level`: Brightness level (0-255, 0 = off)

#### set_mode

```lua
tdeck.keyboard.set_mode(mode) -> boolean
```

Set keyboard input mode

**Parameters:**
- `mode`: "normal" or "raw"

**Returns:** true if mode was set successfully

#### set_repeat_delay

```lua
tdeck.keyboard.set_repeat_delay(delay_ms)
```

Set initial delay before key repeat starts

**Parameters:**
- `delay_ms`: Delay in milliseconds (typically 200-800)

#### set_repeat_enabled

```lua
tdeck.keyboard.set_repeat_enabled(enabled)
```

Enable or disable key repeat

**Parameters:**
- `enabled`: true to enable, false to disable

#### set_repeat_rate

```lua
tdeck.keyboard.set_repeat_rate(rate_ms)
```

Set key repeat rate (interval between repeats)

**Parameters:**
- `rate_ms`: Rate in milliseconds (typically 20-100)

#### set_trackball_mode

```lua
tdeck.keyboard.set_trackball_mode(mode)
```

Set trackball input mode

**Parameters:**
- `mode`: "polling" or "interrupt"

#### set_trackball_sensitivity

```lua
tdeck.keyboard.set_trackball_sensitivity(value)
```

Set trackball sensitivity level

**Parameters:**
- `value`: Sensitivity value

## mesh

### tdeck.mesh

#### build_packet

```lua
tdeck.mesh.build_packet(route_type, payload_type, payload, path) -> string|nil
```

Build a raw mesh packet for transmission

**Parameters:**
- `route_type`: Route type constant (FLOOD=1, DIRECT=2)
- `payload_type`: Payload type constant (ADVERT=4, GRP_TXT=5, etc.)
- `payload`: Binary string payload
- `path`: Optional binary string of path hashes (default: empty)

**Returns:** Serialized packet as binary string, or nil on error

#### calc_shared_secret

```lua
tdeck.mesh.calc_shared_secret(other_pub_key) -> string|nil
```

Calculate ECDH shared secret with another node

**Parameters:**
- `other_pub_key`: 32-byte Ed25519 public key of the other party

**Returns:** 32-byte shared secret as binary string, or nil on error

#### clear_packet_queue

```lua
tdeck.mesh.clear_packet_queue()
```

Clear all packets from the queue

#### clear_tx_queue

```lua
tdeck.mesh.clear_tx_queue()
```

Clear all packets from transmit queue

#### ed25519_sign

```lua
tdeck.mesh.ed25519_sign(data) -> signature
```

Sign data with this node's private key

**Parameters:**
- `data`: Binary string to sign

**Returns:** 64-byte Ed25519 signature as binary string, or nil on error

#### ed25519_verify

```lua
tdeck.mesh.ed25519_verify(data, signature, pub_key) -> boolean
```

Verify an Ed25519 signature

**Parameters:**
- `data`: Binary string that was signed
- `signature`: 64-byte Ed25519 signature
- `pub_key`: 32-byte Ed25519 public key

**Returns:** true if signature is valid

#### enable_packet_queue

```lua
tdeck.mesh.enable_packet_queue(enabled)
```

Enable or disable packet queuing for polling

**Parameters:**
- `enabled`: Boolean to enable/disable

#### get_node_count

```lua
tdeck.mesh.get_node_count() -> integer
```

Get number of known nodes

**Returns:** Node count

#### get_node_id

```lua
tdeck.mesh.get_node_id() -> string
```

Get this node's full ID

**Returns:** 6-byte hex string

#### get_node_name

```lua
tdeck.mesh.get_node_name() -> string
```

Get this node's display name

**Returns:** Node name string

#### get_nodes

```lua
tdeck.mesh.get_nodes() -> table
```

Get list of discovered mesh nodes

**Returns:** Array of node tables with path_hash, name, rssi, snr, last_seen, hops, pub_key_hex

#### get_path_check

```lua
tdeck.mesh.get_path_check() -> boolean
```

Get current path check setting

**Returns:** true if path check is enabled

#### get_path_hash

```lua
tdeck.mesh.get_path_hash() -> integer
```

Get this node's path hash (first byte of public key)

**Returns:** Path hash as integer (0-255)

#### get_public_key

```lua
tdeck.mesh.get_public_key() -> string
```

Get this node's public key as binary string

**Returns:** 32-byte Ed25519 public key

#### get_public_key_hex

```lua
tdeck.mesh.get_public_key_hex() -> string
```

Get this node's public key as hex string

**Returns:** 64-character hex string

#### get_rx_count

```lua
tdeck.mesh.get_rx_count() -> integer
```

Get total packets received

**Returns:** Receive count

#### get_short_id

```lua
tdeck.mesh.get_short_id() -> string
```

Get this node's short ID

**Returns:** 3-byte hex string (6 chars)

#### get_tx_count

```lua
tdeck.mesh.get_tx_count() -> integer
```

Get total packets transmitted

**Returns:** Transmit count

#### get_tx_queue_capacity

```lua
tdeck.mesh.get_tx_queue_capacity() -> integer
```

Get maximum transmit queue capacity

**Returns:** Max queue size

#### get_tx_queue_size

```lua
tdeck.mesh.get_tx_queue_size() -> integer
```

Get number of packets waiting in transmit queue

**Returns:** Queue size

#### get_tx_throttle

```lua
tdeck.mesh.get_tx_throttle() -> integer
```

Get current throttle interval

**Returns:** Milliseconds between transmissions

#### has_packets

```lua
tdeck.mesh.has_packets() -> boolean
```

Check if packets are available in the queue

**Returns:** true if one or more packets are queued

#### is_initialized

```lua
tdeck.mesh.is_initialized() -> boolean
```

Check if mesh networking is initialized

**Returns:** true if mesh is ready

#### is_tx_queue_full

```lua
tdeck.mesh.is_tx_queue_full() -> boolean
```

Check if transmit queue is full

**Returns:** true if queue is full

#### make_header

```lua
tdeck.mesh.make_header(route_type, payload_type, version) -> integer
```

Create a packet header byte from components

**Parameters:**
- `route_type`: Route type constant
- `payload_type`: Payload type constant
- `version`: Optional version (default: 0)

**Returns:** Header byte as integer

#### on_group_packet

```lua
tdeck.mesh.on_group_packet(callback)
```

Set callback for raw group packets (before C++ decryption)

**Parameters:**
- `callback`: Function(packet_table) called with {channel_hash, data, sender_hash, rssi, snr}

#### on_node_discovered

```lua
tdeck.mesh.on_node_discovered(callback)
```

Set callback for node discovery

**Parameters:**
- `callback`: Function(node_table) called when node discovered

#### on_packet

```lua
tdeck.mesh.on_packet(callback)
```

Set callback for ALL incoming packets (called before C++ handling)

**Parameters:**
- `callback`: Function(packet_table) returning handled, rebroadcast booleans

#### packet_count

```lua
tdeck.mesh.packet_count() -> integer
```

Get number of packets in queue

**Returns:** Number of queued packets

#### parse_header

```lua
tdeck.mesh.parse_header(header_byte) -> route_type, payload_type, version
```

Parse a packet header byte into components

**Parameters:**
- `header_byte`: Single byte header value

**Returns:** route_type, payload_type, version as integers

#### pop_packet

```lua
tdeck.mesh.pop_packet() -> table|nil
```

Get and remove the next packet from queue

**Returns:** Packet table or nil if queue is empty

#### queue_send

```lua
tdeck.mesh.queue_send(data) -> boolean
```

Queue packet for transmission (throttled, non-blocking)

**Parameters:**
- `data`: Binary string of serialized packet

**Returns:** true if queued successfully, false if queue full or error

#### schedule_rebroadcast

```lua
tdeck.mesh.schedule_rebroadcast(data)
```

Schedule raw packet data for rebroadcast

**Parameters:**
- `data`: Binary string of raw packet bytes

#### send_announce

```lua
tdeck.mesh.send_announce() -> boolean
```

Broadcast node announcement

**Returns:** true if sent successfully

#### send_group_packet

```lua
tdeck.mesh.send_group_packet(channel_hash, encrypted_data) -> boolean
```

Send raw encrypted group packet

**Parameters:**
- `channel_hash`: Single byte channel identifier
- `encrypted_data`: Pre-encrypted payload (MAC + ciphertext)

**Returns:** true if sent successfully

#### send_raw

```lua
tdeck.mesh.send_raw(data) -> boolean
```

Send raw packet data directly via radio (bypasses queue, immediate)

**Parameters:**
- `data`: Binary string of serialized packet

**Returns:** true if sent successfully

#### set_node_name

```lua
tdeck.mesh.set_node_name(name) -> boolean
```

Set this node's display name

**Parameters:**
- `name`: New node name

**Returns:** true if successful

#### set_path_check

```lua
tdeck.mesh.set_path_check(enabled)
```

Enable or disable path check for flood routing

**Parameters:**
- `enabled`: Boolean - when true, packets with our hash in path are skipped

#### set_tx_throttle

```lua
tdeck.mesh.set_tx_throttle(ms)
```

Set minimum interval between transmissions

**Parameters:**
- `ms`: Milliseconds between transmissions (default 100)

#### update

```lua
tdeck.mesh.update()
```

Process incoming mesh packets

## radio

### tdeck.radio

#### available

```lua
tdeck.radio.available() -> boolean
```

Check if data is available

**Returns:** true if packet waiting

#### get_config

```lua
tdeck.radio.get_config() -> table
```

Get current radio configuration

**Returns:** Table with frequency, bandwidth, spreading_factor, etc.

#### get_last_rssi

```lua
tdeck.radio.get_last_rssi() -> number
```

Get last received signal strength

**Returns:** RSSI in dBm

#### get_last_snr

```lua
tdeck.radio.get_last_snr() -> number
```

Get last signal-to-noise ratio

**Returns:** SNR in dB

#### is_busy

```lua
tdeck.radio.is_busy() -> boolean
```

Check if radio is busy

**Returns:** true if transmitting or receiving

#### is_initialized

```lua
tdeck.radio.is_initialized() -> boolean
```

Check if radio is initialized

**Returns:** true if radio is ready

#### is_receiving

```lua
tdeck.radio.is_receiving() -> boolean
```

Check if in receive mode

**Returns:** true if listening

#### is_transmitting

```lua
tdeck.radio.is_transmitting() -> boolean
```

Check if currently transmitting

**Returns:** true if transmission in progress

#### receive

```lua
tdeck.radio.receive() -> string, number, number
```

Receive a packet

**Returns:** Data string, RSSI, SNR or nil if no data

#### send

```lua
tdeck.radio.send(data) -> string
```

Transmit data

**Parameters:**
- `data`: String or table of bytes to send

**Returns:** Result string

#### set_bandwidth

```lua
tdeck.radio.set_bandwidth(khz) -> string
```

Set radio bandwidth

**Parameters:**
- `khz`: Bandwidth in kHz

**Returns:** Result string

#### set_coding_rate

```lua
tdeck.radio.set_coding_rate(cr) -> string
```

Set LoRa coding rate

**Parameters:**
- `cr`: Coding rate (5-8)

**Returns:** Result string

#### set_frequency

```lua
tdeck.radio.set_frequency(mhz) -> string
```

Set radio frequency

**Parameters:**
- `mhz`: Frequency in MHz

**Returns:** Result string (ok, error_init, etc.)

#### set_spreading_factor

```lua
tdeck.radio.set_spreading_factor(sf) -> string
```

Set LoRa spreading factor

**Parameters:**
- `sf`: Spreading factor (6-12)

**Returns:** Result string

#### set_sync_word

```lua
tdeck.radio.set_sync_word(sw) -> string
```

Set sync word

**Parameters:**
- `sw`: Sync word value

**Returns:** Result string

#### set_tx_power

```lua
tdeck.radio.set_tx_power(dbm) -> string
```

Set transmit power

**Parameters:**
- `dbm`: Power in dBm (0-22)

**Returns:** Result string

#### sleep

```lua
tdeck.radio.sleep() -> string
```

Put radio into sleep mode

**Returns:** Result string

#### start_receive

```lua
tdeck.radio.start_receive() -> string
```

Start listening for packets

**Returns:** Result string

#### wake

```lua
tdeck.radio.wake() -> string
```

Wake radio from sleep

**Returns:** Result string

## storage

### tdeck.storage

#### append_file

```lua
tdeck.storage.append_file(path, content) -> boolean
```

Append content to file

**Parameters:**
- `path`: File path
- `content`: Content to append

**Returns:** true if successful

#### clear_prefs

```lua
tdeck.storage.clear_prefs() -> boolean
```

Clear all preferences

**Returns:** true if cleared

#### exists

```lua
tdeck.storage.exists(path) -> boolean
```

Check if file or directory exists

**Parameters:**
- `path`: Path to check

**Returns:** true if exists

#### file_size

```lua
tdeck.storage.file_size(path) -> integer
```

Get file size in bytes

**Parameters:**
- `path`: File path (prefix /sd/ for SD card)

**Returns:** File size or nil with error message

#### get_flash_info

```lua
tdeck.storage.get_flash_info() -> table
```

Get flash storage info

**Returns:** Table with total_bytes, used_bytes, free_bytes

#### get_pref

```lua
tdeck.storage.get_pref(key, default) -> string
```

Get preference value

**Parameters:**
- `key`: Preference key
- `default`: Default value if not found

**Returns:** Stored value or default

#### get_sd_info

```lua
tdeck.storage.get_sd_info() -> table
```

Get SD card info

**Returns:** Table with total_bytes, used_bytes, free_bytes or nil

#### is_sd_available

```lua
tdeck.storage.is_sd_available() -> boolean
```

Check if SD card is mounted

**Returns:** true if SD card available

#### json_decode

```lua
tdeck.storage.json_decode(json_string) -> value
```

Decode JSON string to Lua value

**Parameters:**
- `json_string`: JSON string

**Returns:** Lua value or nil on error

#### json_encode

```lua
tdeck.storage.json_encode(value) -> string
```

Encode Lua value to JSON string

**Parameters:**
- `value`: Lua table, string, number, boolean, or nil

**Returns:** JSON string or nil on error

#### list_dir

```lua
tdeck.storage.list_dir(path) -> table
```

List directory contents

**Parameters:**
- `path`: Directory path (default "/")

**Returns:** Array of tables with name, is_dir, size

#### mkdir

```lua
tdeck.storage.mkdir(path) -> boolean
```

Create directory

**Parameters:**
- `path`: Directory path

**Returns:** true if created

#### read_bytes

```lua
tdeck.storage.read_bytes(path, offset, length) -> string
```

Read bytes from file at specific offset (for random access)

**Parameters:**
- `path`: File path (prefix /sd/ for SD card)
- `offset`: Byte offset to start reading from
- `length`: Number of bytes to read

**Returns:** Binary data as string, or nil with error message

#### read_file

```lua
tdeck.storage.read_file(path) -> string
```

Read entire file contents

**Parameters:**
- `path`: File path (prefix /sd/ for SD card)

**Returns:** File content or nil, error_message

#### remove

```lua
tdeck.storage.remove(path) -> boolean
```

Delete a file

**Parameters:**
- `path`: File path to delete

**Returns:** true if deleted

#### remove_pref

```lua
tdeck.storage.remove_pref(key) -> boolean
```

Remove a preference

**Parameters:**
- `key`: Preference key to remove

**Returns:** true if removed

#### rename

```lua
tdeck.storage.rename(old_path, new_path) -> boolean
```

Rename or move a file

**Parameters:**
- `old_path`: Current path
- `new_path`: New path

**Returns:** true if renamed

#### rmdir

```lua
tdeck.storage.rmdir(path) -> boolean
```

Remove empty directory

**Parameters:**
- `path`: Directory path

**Returns:** true if removed

#### set_pref

```lua
tdeck.storage.set_pref(key, value) -> boolean
```

Set preference value

**Parameters:**
- `key`: Preference key
- `value`: Value to store

**Returns:** true if saved successfully

#### write_file

```lua
tdeck.storage.write_file(path, content) -> boolean
```

Write content to file (creates/overwrites)

**Parameters:**
- `path`: File path
- `content`: Content to write

**Returns:** true if successful, or false with error

## system

### tdeck.system

#### cancel_timer

```lua
tdeck.system.cancel_timer(timer_id)
```

Cancel a scheduled timer

**Parameters:**
- `timer_id`: ID returned by set_timer or set_interval

#### chip_model

```lua
tdeck.system.chip_model() -> string
```

Get ESP32 chip model name

**Returns:** Chip model string

#### cpu_freq

```lua
tdeck.system.cpu_freq() -> integer
```

Get CPU frequency

**Returns:** Frequency in MHz

#### delay

```lua
tdeck.system.delay(ms)
```

Blocking delay execution

**Parameters:**
- `ms`: Delay duration in milliseconds (max 60000)

#### gc

```lua
tdeck.system.gc()
```

Force full garbage collection

#### gc_step

```lua
tdeck.system.gc_step(steps) -> integer
```

Perform incremental garbage collection

**Parameters:**
- `steps`: Number of GC steps (default 10)

**Returns:** Result from lua_gc

#### get_battery_percent

```lua
tdeck.system.get_battery_percent() -> integer
```

Get battery charge level

**Returns:** Battery percentage (0-100)

#### get_battery_voltage

```lua
tdeck.system.get_battery_voltage() -> number
```

Get battery voltage

**Returns:** Estimated battery voltage in volts

#### get_firmware_info

```lua
tdeck.system.get_firmware_info() -> table
```

Get firmware partition info

**Returns:** Table with partition_size, app_size, free_bytes

#### get_free_heap

```lua
tdeck.system.get_free_heap() -> integer
```

Get free internal RAM

**Returns:** Free heap memory in bytes

#### get_free_psram

```lua
tdeck.system.get_free_psram() -> integer
```

Get free PSRAM

**Returns:** Free PSRAM in bytes

#### get_last_error

```lua
tdeck.system.get_last_error() -> string
```

Get last Lua error message

**Returns:** Error message or nil if no error

#### get_lua_memory

```lua
tdeck.system.get_lua_memory() -> integer
```

Get memory used by Lua runtime

**Returns:** Memory usage in bytes

#### get_time

```lua
tdeck.system.get_time() -> table|nil
```

Get current wall clock time

**Returns:** Table with hour, minute, second, or nil if time not set

#### get_time_unix

```lua
tdeck.system.get_time_unix() -> integer
```

Get current Unix timestamp

**Returns:** Unix timestamp (seconds since 1970-01-01), or 0 if time not set

#### get_timezone

```lua
tdeck.system.get_timezone() -> integer
```

Get current timezone UTC offset in hours

**Returns:** UTC offset in hours

#### get_total_heap

```lua
tdeck.system.get_total_heap() -> integer
```

Get total heap size

**Returns:** Total heap memory in bytes

#### get_total_psram

```lua
tdeck.system.get_total_psram() -> integer
```

Get total PSRAM size

**Returns:** Total PSRAM in bytes

#### is_low_memory

```lua
tdeck.system.is_low_memory() -> boolean
```

Check if memory is critically low

**Returns:** true if less than 32KB available

#### is_sd_available

```lua
tdeck.system.is_sd_available() -> boolean
```

Check if SD card is available

**Returns:** true if SD card is present and accessible

#### is_usb_msc_active

```lua
tdeck.system.is_usb_msc_active() -> boolean
```

Check if USB MSC mode is active

**Returns:** true if MSC mode is active

#### log

```lua
tdeck.system.log(message)
```

Log message to serial output

**Parameters:**
- `message`: Text to log

#### millis

```lua
tdeck.system.millis() -> integer
```

Returns milliseconds since boot

**Returns:** Milliseconds elapsed since device started

#### reload_scripts

```lua
tdeck.system.reload_scripts() -> boolean
```

Reload all Lua scripts (hot reload)

**Returns:** true if successful

#### restart

```lua
tdeck.system.restart()
```

Restart the device

#### set_interval

```lua
tdeck.system.set_interval(ms, callback) -> integer
```

Schedule a repeating callback

**Parameters:**
- `ms`: Interval between calls (minimum 10ms)
- `callback`: Function to call repeatedly

**Returns:** Timer ID for cancellation

#### set_time

```lua
tdeck.system.set_time(year, month, day, hour, minute, second) -> boolean
```

Set system clock time

**Parameters:**
- `year`: Full year (e.g., 2024)
- `month`: Month (1-12)
- `day`: Day of month (1-31)
- `hour`: Hour (0-23)
- `minute`: Minute (0-59)
- `second`: Second (0-59)

**Returns:** true if time was set successfully

#### set_time_unix

```lua
tdeck.system.set_time_unix(timestamp) -> boolean
```

Set system clock from Unix timestamp

**Parameters:**
- `timestamp`: Unix timestamp (seconds since 1970-01-01)

**Returns:** true if time was set successfully

#### set_timer

```lua
tdeck.system.set_timer(ms, callback) -> integer
```

Schedule a one-shot callback

**Parameters:**
- `ms`: Delay before callback fires
- `callback`: Function to call

**Returns:** Timer ID for cancellation

#### set_timezone

```lua
tdeck.system.set_timezone(tz_string) -> boolean
```

Set timezone using POSIX TZ string

**Parameters:**
- `tz_string`: POSIX timezone string (e.g., "CET-1CEST,M3.5.0,M10.5.0/3")

**Returns:** true if timezone was set successfully

#### start_usb_msc

```lua
tdeck.system.start_usb_msc() -> boolean
```

Start USB Mass Storage mode to access SD card from PC

**Returns:** true if started successfully

#### stop_usb_msc

```lua
tdeck.system.stop_usb_msc()
```

Stop USB Mass Storage mode

#### uptime

```lua
tdeck.system.uptime() -> integer
```

Get device uptime

**Returns:** Seconds since boot

#### yield

```lua
tdeck.system.yield(ms)
```

Yield execution to allow C++ background tasks to run

**Parameters:**
- `ms`: Optional sleep time in milliseconds (default 1, max 100)
