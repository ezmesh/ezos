# MeshCore Protocol Documentation

This document describes the MeshCore mesh networking protocol as implemented by Ripple Radio devices and our ezOS firmware.

## Overview

MeshCore is a LoRa-based mesh networking protocol designed for off-grid text communication. It uses flood routing with path-based deduplication and supports both direct messages and channel-based group messaging.

---

## Packet Structure

### Header Format

```
[flags:1][path:variable][payload:variable]
```

**Flags byte:**
- Bits 0-1: Route type (0=FLOOD, 1=DIRECT, 2=RESPONSE)
- Bits 2-5: Path length (0-15 bytes)
- Bits 6-7: Payload type indicator

**Path:**
- Variable length (0-15 bytes)
- Each byte is a node's path hash
- Used for loop detection and routing

### Payload Types

| Type | Value | Description |
|------|-------|-------------|
| ADVERT | 0x00 | Node advertisement/announcement |
| TXT_MSG | 0x03 | Direct text message |
| GRP_TXT | 0x06 | Group/channel text message |
| RESPONSE | 0x08 | Response to a request |

---

## Channel System (GRP_TXT)

### Channel Key Derivation

For named channels, the 16-byte AES key is derived from the channel name:

```
key = SHA256(channel_name)[0:16]
```

**Examples:**
- `#Public` uses a well-known static key (not name-derived)
- `#test` key = `SHA256("#test")[0:16]` = `9cd8fcf22a47333b591d96a2b848b73f`
- `#xtr-test` key = `SHA256("#xtr-test")[0:16]`

### Public Channel Key

The `#Public` channel uses a well-known key shared across all MeshCore devices:

```
8b 33 87 e9 c5 cd ea 6a c9 e5 ed ba a1 15 cd 72
```

Base64: `izOH6cXN6mrJ5edbqhUNcg==`

### Channel Hash

Each channel has a 1-byte hash used to quickly identify which channel a message belongs to:

```
channel_hash = SHA256(key)[0]
```

**Known hashes:**
- `#Public` = `0x11`
- `#test` = `0xD9`

### GRP_TXT Payload Format

```
[channel_hash:1][MAC:2][ciphertext:variable]
```

**Encryption:**
- Algorithm: AES-128-ECB
- Key: 16-byte channel key
- Ciphertext is padded to 16-byte blocks

**MAC (Message Authentication Code):**
- Algorithm: HMAC-SHA256, truncated to 2 bytes
- HMAC key: 32 bytes (16-byte channel key + 16 zero bytes)
- MAC covers the plaintext payload

### Decrypted Payload Format

```
[timestamp:4][flags:1][sender_name: message\0]
```

- `timestamp`: 4-byte little-endian Unix timestamp (or uptime)
- `flags`: 1 byte (purpose TBD)
- `sender_name`: Variable length, followed by `: `
- `message`: Null-terminated string

**Example decrypted payload:**
```
AB CD EF 12 00 N o d e - 1 2 3 4 : H e l l o \0
[timestamp ] [f] [sender_name ]   [message     ]
```

---

## Node Identity

### Path Hash

Each node has a 1-byte path hash used in packet paths for loop detection:

```
path_hash = first byte of node identifier
```

Currently derived from MAC address, planned to migrate to Ed25519 public key.

### Node ID

6-byte unique identifier for each node. Currently MAC-based, planned to derive from public key hash.

---

## Routing

### Flood Routing

Default routing mode. Packets are rebroadcast by all nodes that haven't seen them.

**Loop detection:**
- Each node adds its path hash to the packet's path field before rebroadcasting
- If a node's hash is already in the path, the packet is dropped
- Maximum path length: 15 hops

### Rebroadcast Delay

To avoid collisions, nodes wait a random delay before rebroadcasting:
- Minimum: 50ms
- Maximum: 200ms

---

## What We Know (Implemented)

- [x] Packet header parsing (flags, path, payload)
- [x] Payload type identification (ADVERT, TXT_MSG, GRP_TXT, RESPONSE)
- [x] GRP_TXT decryption (AES-128-ECB)
- [x] Channel hash verification
- [x] MAC verification (HMAC-SHA256, 2-byte truncated)
- [x] Channel key derivation from name
- [x] Public channel well-known key
- [x] Path-based loop detection
- [x] Flood routing with random delay rebroadcast
- [x] Decrypted payload parsing (timestamp, flags, sender, message)

---

## What We Don't Know (TODO)

### High Priority

- [ ] **Ed25519 Signatures**: Messages may include 64-byte signatures for sender verification
  - Where is the signature in the payload?
  - What data is signed?
  - How to obtain sender's public key?

- [ ] **ADVERT Packet Format**: Node announcements
  - Full payload structure
  - Public key inclusion (32 bytes?)
  - Node name encoding
  - Capabilities/features flags

- [ ] **TXT_MSG (Direct Messages)**: Private 1-to-1 messages
  - Encryption method (asymmetric? key exchange?)
  - Addressing (how to specify recipient?)
  - Payload format

### Medium Priority

- [ ] **RESPONSE Packets**: Request/response mechanism
  - What triggers responses?
  - Payload format
  - Use cases

- [ ] **Password-Protected Channels**: Encrypted channels with password
  - Key derivation (HKDF from password?)
  - Difference from name-derived channels
  - Channel discovery/joining protocol

- [ ] **Timestamp Format**:
  - Unix timestamp or device uptime?
  - Timezone handling
  - Sync mechanism between nodes?

### Low Priority

- [ ] **ACK/Delivery Confirmation**: Does the protocol support message acknowledgment?
- [ ] **Node Discovery Protocol**: How do nodes announce themselves and discover others?
- [ ] **Message Expiry**: Do messages have a TTL or expiration?
- [ ] **Firmware Version Negotiation**: Protocol versioning?

---

## Packet Captures

### Example GRP_TXT Packet (Encrypted)

```
RX 57 bytes, RSSI:-104
Raw: 15 66 6B 18 FB A8 BE D8 EE C1 6B AF 78 CE 0A ...

Parsed:
- Flags: 0x15
  - Route type: FLOOD
  - Path length: 2
  - Payload type: GRP_TXT
- Path: [66, 6B]
- Payload:
  - Channel hash: 0xD9 (#test)
  - MAC: [18, FB]
  - Ciphertext: [A8, BE, D8, ...]
```

### Example Decrypted Message

```
Channel: #test
Sender hash: 0x66
Decrypted: "Node-1234: Hello everyone"
```

---

## References

- MeshCore source code (Ripple Radio firmware)
- Meshtastic protocol (similar but different encryption)
- LoRa modulation parameters (handled by RadioLib)

---

## Changelog

- 2026-01-24: Initial documentation based on reverse engineering
- Discovered AES-128-ECB encryption (not AES-256-CTR)
- Discovered 2-byte truncated HMAC-SHA256 MAC
- Documented channel key derivation from channel name
- Documented #Public well-known key
