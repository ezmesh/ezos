# T-Deck OS Project Guidelines

## Serial Port Access

**IMPORTANT:** Never use `stty` or interactive serial monitor commands (`pio device monitor`, `minicom`, etc.) as they block the user's interactive terminal session. The user typically has a serial monitor already open.

Instead:
- Use `pio run -t upload` to flash firmware
- Trust that the user is watching serial output in their own terminal
- If you need to see serial output for debugging, ask the user to share the relevant log lines

## Building and Flashing

```bash
# Build only
pio run

# Build and flash
pio run -t upload
```

## Project Structure

- `src/mesh/` - Mesh networking protocol (MeshCore, identity, routing, channels)
- `src/tui/` - Terminal User Interface (screens, display, theme)
- `src/hardware/` - Hardware drivers (display, keyboard, radio)

## Key Components

### Identity System (Ed25519)
- Keypairs stored in NVS (`privkey`, `pubkey`)
- Node ID derived from SHA-256 hash of public key (first 6 bytes)
- Sign/verify methods for message authentication

### Channel System
- Default channel: `#Public` (joined automatically on startup)
- Encrypted channels: password-based AES-256-GCM with HKDF key derivation
- All channel messages are signed with Ed25519

### Radio Status
- `!RF` indicator means radio failed to initialize
- Check LoRa module wiring if this appears

## MeshCore Protocol Reference

Reference implementation: https://github.com/ripplebiz/MeshCore

### Cryptographic Constants
- `PUB_KEY_SIZE`: 32 bytes (Ed25519 public key)
- `PRV_KEY_SIZE`: 64 bytes (Ed25519 private key)
- `SIGNATURE_SIZE`: 64 bytes (Ed25519 signature)
- `SEED_SIZE`: 32 bytes

### Cipher Constants
- `CIPHER_KEY_SIZE`: 16 bytes
- `CIPHER_BLOCK_SIZE`: 16 bytes
- `CIPHER_MAC_SIZE`: 2 bytes

### Packet Constants
- `MAX_PACKET_PAYLOAD`: 184 bytes
- `MAX_PATH_SIZE`: 64 bytes
- `MAX_TRANS_UNIT`: 255 bytes
- `MAX_ADVERT_DATA_SIZE`: 32 bytes
- `PATH_HASH_SIZE`: 1 byte

### Packet Header Format (1 byte)
- Bits 0-1: Route type (mask 0x03)
- Bits 2-5: Payload type (shift 2, mask 0x0F)
- Bits 6-7: Payload version (shift 6, mask 0x03)

### Route Types
- `ROUTE_TYPE_TRANSPORT_FLOOD` (0x00): Flood with transport codes
- `ROUTE_TYPE_FLOOD` (0x01): Standard flood routing
- `ROUTE_TYPE_DIRECT` (0x02): Direct with supplied path
- `ROUTE_TYPE_TRANSPORT_DIRECT` (0x03): Direct with transport codes

### ADVERT Packet Payload Format
```
[pub_key:32][timestamp:4][signature:64][app_data:variable]
```
- Offset 0: Public key (32 bytes)
- Offset 32: Timestamp (4 bytes, little-endian)
- Offset 36: Ed25519 signature (64 bytes)
- Offset 100: App data (up to 32 bytes) - contains node name and metadata

**Signature Message Format:**
The signature is computed over: `[pub_key:32][timestamp:4][app_data:variable]`

**App Data Format (Ripple apps):**
The app_data may have a type prefix byte >= 0x80 (e.g., 0x81) before the actual name string.

### Key Source Files (ripplebiz/MeshCore)
- `src/Packet.h` - Packet structure and header format
- `src/Mesh.cpp` - Packet handling including ADVERT processing
- `src/Identity.h` - Ed25519 identity class
- `src/MeshCore.h` - Main constants and definitions

## Settings Save/Restore Pattern

Settings must be both saved when changed AND restored at boot. Missing either causes settings to not persist.

### Where settings are defined
- `data/scripts/ui/screens/settings.lua` - Settings UI with definitions, defaults, and save logic

### How settings are saved
1. **In settings.lua `save_settings()`**: Write to preferences using `tdeck.storage.set_pref(key, value)`
2. **ThemeManager settings**: Saved via `ThemeManager.save()` for wallpaper, icon theme, and animation settings

### How settings are restored at boot
- `data/scripts/boot.lua` - `apply_saved_settings()` function reads preferences and applies them

### Adding a new setting
1. Add the setting definition to `settings.lua` with name, label, type, default value
2. Add save logic in `save_settings()` using `tdeck.storage.set_pref()`
3. Add restore logic in `boot.lua` `apply_saved_settings()` using `tdeck.storage.get_pref()`
4. If the setting needs immediate application when changed (not just at boot), add the API call in `save_settings()` too

### Example pattern
```lua
-- In settings.lua save_settings():
local my_setting = get_setting_value("my_setting")
tdeck.storage.set_pref("mySetting", my_setting)
tdeck.some.api_call(my_setting)  -- Apply immediately

-- In boot.lua apply_saved_settings():
local my_setting = get_pref("mySetting", default_value)
if tdeck.some and tdeck.some.api_call then
    tdeck.some.api_call(my_setting)
end
```
