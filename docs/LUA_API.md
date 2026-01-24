# T-Deck OS Lua API Reference

This document describes the Lua API available in T-Deck OS for creating custom UI screens and applications.

## Table of Contents

- [tdeck.display](#tdeckdisplay) - Display drawing functions
- [tdeck.keyboard](#tdeckkeyboard) - Keyboard input
- [tdeck.screen](#tdeckscreen) - Screen navigation
- [tdeck.system](#tdecksystem) - System utilities
- [tdeck.storage](#tdeckstorage) - File and preferences storage
- [tdeck.mesh](#tdeckmesh) - MeshCore networking
- [tdeck.radio](#tdeckradio) - LoRa radio control
- [tdeck.audio](#tdeckaudio) - Audio output
- [Screen Lifecycle](#screen-lifecycle) - Creating custom screens

---

## tdeck.display

Display drawing functions. A `display` object is passed to screen `render()` methods.

### Properties (Read-only)

| Property | Type | Description |
|----------|------|-------------|
| `width` | integer | Display width in pixels (320) |
| `height` | integer | Display height in pixels (240) |
| `cols` | integer | Display columns in characters (40) |
| `rows` | integer | Display rows in characters (15) |
| `font_width` | integer | Font character width in pixels (8) |
| `font_height` | integer | Font character height in pixels (16) |
| `colors` | table | Named color constants (see below) |

### Color Constants

Access via `display.colors.*`:

- `BLACK`, `WHITE`, `RED`, `GREEN`, `BLUE`
- `CYAN`, `YELLOW`, `ORANGE`, `GRAY`
- `TEXT`, `TEXT_DIM` - Text colors
- `SELECTION` - Selection highlight
- `BORDER` - Box border color
- `DARK_GRAY` - Background elements

### Methods

#### draw_text(x, y, text, color)
Draw text at pixel coordinates.
```lua
display.draw_text(10, 20, "Hello", colors.WHITE)
```

#### draw_text_centered(y, text, color)
Draw horizontally centered text.
```lua
display.draw_text_centered(5 * display.font_height, "Centered", colors.CYAN)
```

#### draw_box(x, y, w, h, title, border_color, title_color)
Draw a bordered box with optional title. Coordinates in character cells.
```lua
display.draw_box(0, 0, display.cols, display.rows - 1, "Title", colors.CYAN, colors.WHITE)
```

#### fill_rect(x, y, w, h, color)
Fill a rectangle. Coordinates in pixels.
```lua
display.fill_rect(0, 0, 100, 50, colors.BLUE)
```

#### draw_progress(x, y, w, h, progress, fg_color, bg_color)
Draw a progress bar. `progress` is 0.0 to 1.0.
```lua
display.draw_progress(10, 50, 100, 10, 0.75, colors.GREEN, colors.DARK_GRAY)
```

#### text_width(text) -> integer
Returns the pixel width of text string.

#### rgb(r, g, b) -> integer
Convert RGB (0-255) to RGB565 color value.
```lua
local custom_color = display.rgb(255, 128, 0)
```

---

## tdeck.keyboard

Keyboard input functions. Key events are passed to screen `handle_key()` methods.

### Key Event Structure

```lua
key = {
    character = "a",      -- Printable character or nil
    special = "ENTER",    -- Special key name or nil
    shift = false,        -- Modifier states
    ctrl = false,
    alt = false,
    fn = false,
    valid = true          -- Always true for valid events
}
```

### Special Key Names

- Navigation: `"UP"`, `"DOWN"`, `"LEFT"`, `"RIGHT"`
- Actions: `"ENTER"`, `"ESCAPE"`, `"BACKSPACE"`, `"TAB"`
- Function: `"F1"` through `"F12"`

### Methods

#### available() -> boolean
Returns true if a key is waiting.

#### read() -> key_event or nil
Read next key event. Non-blocking.

#### is_shift_held() -> boolean
Check if shift is currently held.

#### is_ctrl_held() -> boolean
Check if ctrl is currently held.

---

## tdeck.screen

Screen navigation and lifecycle management.

### Methods

#### push(screen)
Push a new screen onto the stack.
```lua
local NewScreen = dofile("/scripts/ui/screens/my_screen.lua")
tdeck.screen.push(NewScreen:new())
```

#### pop()
Pop current screen and return to previous.

#### replace(screen)
Replace current screen (no stack growth).

#### invalidate()
Mark screen for redraw. Call after state changes.

#### set_battery(percent)
Update status bar battery indicator.

#### set_radio(ok, bars)
Update status bar radio indicator.

#### set_node_count(count)
Update status bar node count.

#### set_unread(has_unread)
Update status bar unread indicator.

---

## tdeck.system

System utilities, timing, and memory management.

### Timing

#### millis() -> integer
Milliseconds since boot.

#### uptime() -> integer
Seconds since boot.

#### delay(ms)
Blocking delay. Use sparingly.

#### set_timer(ms, callback) -> timer_id
Schedule one-shot callback.
```lua
tdeck.system.set_timer(1000, function()
    print("One second later!")
end)
```

#### set_interval(ms, callback) -> timer_id
Schedule repeating callback (minimum 10ms).

#### cancel_timer(timer_id)
Cancel a scheduled timer.

### System Info

#### get_battery_percent() -> integer
Battery level 0-100%.

#### get_battery_voltage() -> number
Battery voltage in volts.

#### get_free_heap() -> integer
Free internal RAM in bytes.

#### get_free_psram() -> integer
Free PSRAM in bytes.

#### get_total_heap() -> integer
Total heap size.

#### get_total_psram() -> integer
Total PSRAM size.

#### chip_model() -> string
ESP32 chip model name.

#### cpu_freq() -> integer
CPU frequency in MHz.

### Memory Management

#### gc()
Force full garbage collection.

#### gc_step(steps)
Perform incremental GC steps.

#### get_lua_memory() -> integer
Memory used by Lua runtime.

#### is_low_memory() -> boolean
True if memory is critically low.

### Miscellaneous

#### log(message)
Write to serial log.

#### restart()
Restart the device.

#### reload_scripts()
Clear script cache for hot reload.

#### get_last_error() -> string or nil
Get last Lua error message.

---

## tdeck.storage

File and preferences storage.

### File Operations

Files are stored on LittleFS (internal flash) or SD card.
Paths starting with `/sd/` access SD card.

#### read_file(path) -> string or nil
Read entire file contents.

#### write_file(path, content) -> boolean
Write content to file (creates/overwrites).

#### append_file(path, content) -> boolean
Append content to file.

#### exists(path) -> boolean
Check if file exists.

#### remove(path) -> boolean
Delete a file.

#### rename(old_path, new_path) -> boolean
Rename/move a file.

#### mkdir(path) -> boolean
Create directory.

#### rmdir(path) -> boolean
Remove empty directory.

#### list_dir(path) -> table
List directory contents.
```lua
for _, entry in ipairs(tdeck.storage.list_dir("/scripts")) do
    print(entry.name, entry.size, entry.is_dir)
end
```

### Preferences

Key-value storage persisted to flash.

#### get_pref(key, default) -> value
Get preference value.

#### set_pref(key, value) -> boolean
Set preference value.

#### remove_pref(key) -> boolean
Remove a preference.

#### clear_prefs() -> boolean
Clear all preferences.

### SD Card

#### is_sd_available() -> boolean
Check if SD card is mounted.

#### get_sd_info() -> table
Get SD card info: `{total, used, free}`.

#### get_flash_info() -> table
Get flash storage info: `{total, used, free}`.

---

## tdeck.mesh

MeshCore networking functions.

### Identity

#### is_initialized() -> boolean
Check if mesh is initialized.

#### get_node_id() -> string
Get this node's full ID.

#### get_short_id() -> string
Get short node ID (6 chars).

#### get_public_key() -> string
Get public key fingerprint.

### Nodes

#### get_nodes() -> table
Get list of discovered nodes.
```lua
for _, node in ipairs(tdeck.mesh.get_nodes()) do
    print(node.name, node.rssi, node.last_seen)
end
```

#### get_node_count() -> integer
Number of known nodes.

### Channels

#### join_channel(name, password) -> boolean
Join or create a channel. Password is optional.

#### leave_channel(name) -> boolean
Leave a channel.

#### is_in_channel(name) -> boolean
Check if joined to channel.

#### get_channels() -> table
Get list of known channels.

#### send_channel_message(channel, text) -> boolean
Send message to channel.

#### get_channel_messages(channel) -> table
Get messages for a channel.

#### mark_channel_read(channel)
Mark channel messages as read.

### Statistics

#### get_tx_count() -> integer
Total packets transmitted.

#### get_rx_count() -> integer
Total packets received.

---

## tdeck.radio

LoRa radio control.

### Status

#### is_initialized() -> boolean
Check if radio is initialized.

#### get_last_rssi() -> integer
Last received signal strength (dBm).

#### get_last_snr() -> number
Last signal-to-noise ratio (dB).

### Configuration

#### set_frequency(mhz)
Set frequency in MHz.

#### set_tx_power(dbm)
Set transmit power (0-22 dBm).

#### get_config() -> table
Get current radio configuration.

### Power Management

#### sleep()
Put radio into sleep mode.

#### wake()
Wake radio from sleep.

---

## tdeck.audio

Audio output functions.

### Methods

#### play_tone(frequency, duration_ms)
Play a tone at specified frequency.
```lua
tdeck.audio.play_tone(440, 500)  -- A4 for 500ms
```

#### stop()
Stop audio playback.

#### is_playing() -> boolean
Check if audio is playing.

#### beep()
Play short beep sound.

---

## Screen Lifecycle

Screens are Lua tables with specific methods that the system calls.

### Creating a Screen

```lua
-- my_screen.lua
local MyScreen = {
    title = "My Screen"
}

function MyScreen:new()
    local o = {
        title = self.title,
        -- your state here
    }
    setmetatable(o, {__index = MyScreen})
    return o
end

function MyScreen:on_enter()
    -- Called when screen becomes active
end

function MyScreen:on_exit()
    -- Called when screen is popped
end

function MyScreen:render(display)
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    -- Draw your content here
end

function MyScreen:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"  -- Go back
    end

    -- Handle other keys
    tdeck.screen.invalidate()  -- Request redraw if state changed

    return "continue"  -- Stay on this screen
end

return MyScreen
```

### handle_key Return Values

- `"continue"` - Stay on current screen
- `"pop"` - Pop this screen
- `"exit"` - Exit application (main menu only)

### Navigation

```lua
-- Push a new screen
local OtherScreen = dofile("/scripts/ui/screens/other.lua")
tdeck.screen.push(OtherScreen:new())

-- Request redraw after state change
self.counter = self.counter + 1
tdeck.screen.invalidate()
```

---

## Script Loading

Scripts are loaded from these locations in priority order:

1. SD Card: `/sd/scripts/`
2. Internal Flash: `/scripts/`

### Boot Process

1. System loads `/scripts/boot.lua`
2. Boot script loads theme, components, services
3. Boot script returns initial screen (usually MainMenu)

### Hot Reload

Modify scripts on SD card, then call:
```lua
tdeck.system.reload_scripts()
```

Or use the system info screen reload option.

---

## Memory Tips

- Call `tdeck.system.gc()` periodically in long-running screens
- Check `tdeck.system.is_low_memory()` before large operations
- Use `dofile()` to load screens on demand (not at startup)
- Release references to unused tables and callbacks

---

## Example: Counter Screen

```lua
local Counter = {title = "Counter"}

function Counter:new()
    return setmetatable({
        title = "Counter",
        value = 0
    }, {__index = Counter})
end

function Counter:render(display)
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    display.draw_text_centered(5 * display.font_height,
                              "Value: " .. self.value, colors.GREEN)

    display.draw_text_centered(8 * display.font_height,
                              "UP/DOWN to change", colors.TEXT_DIM)
end

function Counter:handle_key(key)
    if key.special == "UP" then
        self.value = self.value + 1
        tdeck.screen.invalidate()
    elseif key.special == "DOWN" then
        self.value = self.value - 1
        tdeck.screen.invalidate()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end
    return "continue"
end

return Counter
```
