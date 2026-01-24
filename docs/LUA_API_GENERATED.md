# T-Deck OS Lua API Reference

> Auto-generated from source code

## Table of Contents

- [tdeck.audio](#audio)
- [tdeck.display](#display)
- [tdeck.keyboard](#keyboard)
- [tdeck.mesh](#mesh)
- [tdeck.radio](#radio)
- [tdeck.screen](#screen)
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

#### is_playing

```lua
tdeck.audio.is_playing() -> boolean
```

Check if audio is playing

**Returns:** true if playing

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
- `size`: Font size string: "small", "medium", or "large"

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

#### set_adaptive_scrolling

```lua
tdeck.keyboard.set_adaptive_scrolling(enabled)
```

Enable or disable adaptive scrolling

**Parameters:**
- `enabled`: true to enable, false to disable

#### set_trackball_sensitivity

```lua
tdeck.keyboard.set_trackball_sensitivity(value)
```

Set trackball sensitivity level

**Parameters:**
- `value`: Sensitivity value

## mesh

### tdeck.mesh

#### get_channel_messages

```lua
tdeck.mesh.get_channel_messages(channel) -> table
```

Get messages for a channel

**Parameters:**
- `channel`: Optional channel filter

**Returns:** Array of message tables

#### get_channels

```lua
tdeck.mesh.get_channels() -> table
```

Get list of known channels

**Returns:** Array of channel tables with name, is_joined, is_encrypted

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

**Returns:** Array of node tables with path_hash, name, rssi, snr, last_seen, hops

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

#### is_in_channel

```lua
tdeck.mesh.is_in_channel(name) -> boolean
```

Check if joined to channel

**Parameters:**
- `name`: Channel name

**Returns:** true if member of channel

#### is_initialized

```lua
tdeck.mesh.is_initialized() -> boolean
```

Check if mesh networking is initialized

**Returns:** true if mesh is ready

#### join_channel

```lua
tdeck.mesh.join_channel(name, password) -> boolean
```

Join or create a channel

**Parameters:**
- `name`: Channel name
- `password`: Optional password for encryption

**Returns:** true if successful

#### leave_channel

```lua
tdeck.mesh.leave_channel(name) -> boolean
```

Leave a channel

**Parameters:**
- `name`: Channel name to leave

**Returns:** true if successful

#### mark_channel_read

```lua
tdeck.mesh.mark_channel_read(channel)
```

Mark channel messages as read

**Parameters:**
- `channel`: Channel name

#### on_channel_message

```lua
tdeck.mesh.on_channel_message(callback)
```

Set callback for incoming channel messages

**Parameters:**
- `callback`: Function(message_table) called on new message

#### on_node_discovered

```lua
tdeck.mesh.on_node_discovered(callback)
```

Set callback for node discovery

**Parameters:**
- `callback`: Function(node_table) called when node discovered

#### send_announce

```lua
tdeck.mesh.send_announce() -> boolean
```

Broadcast node announcement

**Returns:** true if sent successfully

#### send_channel_message

```lua
tdeck.mesh.send_channel_message(channel, text) -> boolean
```

Send message to a channel

**Parameters:**
- `channel`: Channel name
- `text`: Message text

**Returns:** true if sent successfully

#### set_node_name

```lua
tdeck.mesh.set_node_name(name) -> boolean
```

Set this node's display name

**Parameters:**
- `name`: New node name

**Returns:** true if successful

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

## screen

### tdeck.screen

#### invalidate

```lua
tdeck.screen.invalidate()
```

Mark screen for redraw

#### is_empty

```lua
tdeck.screen.is_empty() -> boolean
```

Check if screen stack is empty

**Returns:** true if no screens on stack

#### pop

```lua
tdeck.screen.pop()
```

Pop current screen and return to previous

#### push

```lua
tdeck.screen.push(screen)
```

Push a new screen onto the stack

**Parameters:**
- `screen`: Screen table with render/handle_key methods

#### replace

```lua
tdeck.screen.replace(screen)
```

Replace current screen without stack growth

**Parameters:**
- `screen`: Screen table with render/handle_key methods

#### set_battery

```lua
tdeck.screen.set_battery(percent)
```

Update status bar battery indicator

**Parameters:**
- `percent`: Battery percentage (0-100)

#### set_node_count

```lua
tdeck.screen.set_node_count(count)
```

Update status bar node count

**Parameters:**
- `count`: Number of known mesh nodes

#### set_node_id

```lua
tdeck.screen.set_node_id(short_id)
```

Update status bar node ID display

**Parameters:**
- `short_id`: Short node ID string

#### set_radio

```lua
tdeck.screen.set_radio(ok, bars)
```

Update status bar radio indicator

**Parameters:**
- `ok`: true if radio is working
- `bars`: Signal strength (0-4 bars)

#### set_unread

```lua
tdeck.screen.set_unread(has_unread)
```

Update status bar unread indicator

**Parameters:**
- `has_unread`: true if there are unread messages

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

#### set_timer

```lua
tdeck.system.set_timer(ms, callback) -> integer
```

Schedule a one-shot callback

**Parameters:**
- `ms`: Delay before callback fires
- `callback`: Function to call

**Returns:** Timer ID for cancellation

#### uptime

```lua
tdeck.system.uptime() -> integer
```

Get device uptime

**Returns:** Seconds since boot
