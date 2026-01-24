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
