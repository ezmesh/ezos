# tools/sharing

Host-side helpers for the ezme.sh share-URL format.

## decode_invite.py

Decode a `https://ezme.sh/#join/v1?t=...` channel invite using a
meshcore-cli node as the recipient identity. Outputs the channel name,
the passphrase, and the 16-byte AES channel key (hex), plus the exact
`meshcore-cli add_channel` command to install it.

### Setup

```
pip install cryptography
# meshcore-cli must be on $PATH (pipx install meshcore-cli)
```

### Usage

The recipient's Ed25519 private key is fetched automatically from the
node via `meshcore-cli -j -s <port> get private_key`. The sender's
Ed25519 pubkey can come from a contact name (looked up against
`meshcore-cli contacts`) or be passed directly.

```
# Look up sender by contact name
decode_invite.py "https://ezme.sh/#join/v1?t=ABC..." \
    --from-contact "Node-A2EF60"

# Or pass the sender's pubkey hex
decode_invite.py "https://ezme.sh/#join/v1?t=ABC..." \
    --from a2ef60b39e56...

# Decode AND immediately install via add_channel
decode_invite.py URL --from-contact NAME --add

# Custom serial port
decode_invite.py URL --from-contact NAME -s /dev/ttyACM2

# Skip the meshcore-cli fetch (useful for offline testing)
decode_invite.py URL --from <hex> --privkey <hex>
```

Output:

```
Channel name : DecodeTest
Passphrase   : pw-roundtrip
Channel key  : 8b8de9bdb99a57c2ed24fe53e62275a5

Add to meshcore-cli with:
  meshcore-cli -s /dev/ttyUSB0 add_channel "DecodeTest" 8b8de9bdb99a57c2ed24fe53e62275a5
```

### What it actually does

1. Pull the URL fragment, base64url-decode the token.
2. Drop the 8-byte uniqueness nonce; the rest is AES-128-ECB ciphertext.
3. Fetch the recipient's Ed25519 private seed (32 bytes) from
   meshcore-cli, derive the X25519 scalar via `SHA-512(seed)[:32]`
   with RFC 7748 clamping.
4. Convert the sender's Ed25519 public point to its X25519 Montgomery
   form via `u = (1 + y) / (1 - y) mod (2^255 - 19)`.
5. X25519 ECDH; the first 16 bytes of the 32-byte shared secret are the
   AES key (matches `Identity::calcSharedSecret` in the firmware).
6. Decrypt and parse `[name_len:1][name][pwd_len:1][password]`.
7. Derive the on-air channel key as `SHA-256(passphrase)[:16]` to match
   the firmware's `ez.crypto.derive_channel_key`.
