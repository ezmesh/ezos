# ezOS Security Audit (2026)

Audit performed: 2026-05-15
Auditor: Claude (autopilot)
Scope: codebase-wide pass per issue #23 (P0 chore)

This is a structured, static-only first pass. It walks the six categories
listed in #23, calls out concrete defects (file:line) with severity, and
documents the threat model items we explicitly accept by design. Each
finding has a paragraph-scale fix suggestion and a one-paragraph regression
test sketch so a follow-up issue can lift the test text verbatim.

## Summary

Severity counts:

- P0 (remote, unauthenticated RCE / persistent compromise): 0
- P1 (remote DoS or info disclosure): 4
- P2 (local, requires unusual config, or hardening with concrete impact): 5
- P3 (defense-in-depth / hardening): 3

Top three findings:

1. **F-01 — Unbounded `_nodes` vector in `MeshCore`.** A peer can flood
   unique-pubkey ADVERTs and grow the in-memory node table without limit;
   only the *persist* layer caps at 64/128. Eventual heap exhaustion or
   wedged Lua callbacks on a busy mesh (P1, remote DoS).
2. **F-02 — DM replay accepted once the peer sends any other message.**
   AES-128-ECB has no nonce; an attacker who captures a ciphertext can
   replay it indefinitely. The DM service's dedup compares against the
   last entry by `(text, timestamp)`; once a different message arrives
   it displaces the captured plaintext, and the next replay is accepted
   as a fresh message regardless of wall-clock elapsed time (P1, remote
   message injection).
3. **F-03 — Unsanitized sender names + text in GRP_TXT path.** Inner
   relay sender names are ASCII-checked, but the outer `sender_name`
   field and the message text itself are not. Garbage bytes paint as
   `[]` boxes on the on-device font; a NUL truncates rendered output
   and could mask appended content (P2, display poisoning).

## Findings

### F-01 — Unbounded `MeshCore::_nodes` vector  [severity: P1] [status: open]

**Location:** `src/mesh/meshcore.cpp:580` (and the vector declared in
`src/mesh/meshcore.h:136`)
**Category:** mesh-protocol

**Description:** `MeshCore::updateNode()` calls
`_nodes.push_back(node);` with no size cap when a new path-hash is
seen. The `NodeStore` caps writes to 128 (SD) / 64 (NVS), but those
limits only apply at *save* time; the in-memory vector grows without
bound. `getNodes()` iterates it every UI frame on the node browser /
map view.

```cpp
// src/mesh/meshcore.cpp:579
    _nodes.push_back(node);
    markDirty();
```

**Exploit sketch:** A malicious peer (or a tester with `ez_remote`)
sends valid-signed ADVERTs with a fresh Ed25519 keypair each second.
Each unique pubkey lands as a new `NodeInfo` entry (~88 bytes after
alignment) plus persisted-cache churn; after ~3000 entries the device
is hundreds of KB into the heap on a board with ~300 KB internal
RAM. Even without OOM, every `get_nodes()` Lua call iterates and
allocates a fresh table, stalling the UI loop.

**Suggested fix:** Apply the same eviction policy `NodeStore::serialize`
uses (oldest-by-`lastSeen`) inline in `updateNode()` when
`_nodes.size() >= kInMemoryCap`. Suggest `kInMemoryCap = 128` to match
the SD persist cap so steady-state behaviour doesn't change. Eviction
should clear the slot's `hasPublicKey` so the X25519 cache in
`direct_messages.lua` doesn't keep a dangling reference.

**Replay test:** `tools/remote/tests/e2e/test_mesh_node_flood.py`. From
`meshcore-cli` on `/dev/ttyUSB0`, generate 200 distinct Ed25519
keypairs and emit a signed ADVERT for each. Assert via
`ez_remote -e "return #ez.mesh.get_nodes()"` that the count plateaus at
the cap and does not grow further.

---

### F-02 — DM replay accepted once the peer sends any other message  [severity: P1] [status: open]

**Location:** `lua/services/direct_messages.lua:392-435` (constant
`RECV_DEDUP_WINDOW_S = 60` and `store_message` dedup)
**Category:** mesh-protocol

**Description:** AES-128-ECB has no nonce; the inner plaintext
`[timestamp:4 LE][flags:1][text:N]` is identical for every replay of a
captured ciphertext. The DM service's dedup logic merges only when
`text` matches a recent entry AND
`msg.timestamp - last.timestamp <= RECV_DEDUP_WINDOW_S` (60 s).
**Both timestamps are static inner-plaintext values set by the
original sender** — they are baked into the captured ciphertext and
never change between replays.

```lua
-- lua/services/direct_messages.lua:427-431
        if last and not last.is_self
                and last.text == msg.text
                and (msg.timestamp or 0) - (last.timestamp or 0) <= RECV_DEDUP_WINDOW_S then
            last.count = (last.count or 1) + 1
            last.timestamp = msg.timestamp
```

Replaying the same captured ciphertext after a quiet period produces
`msg.timestamp - last.timestamp = 0` (same packet, same inner
timestamp), so the dedup test passes and the replay merges into the
last entry. The MAC check passes (it's the original sender's MAC),
the ECDH key is unchanged, and the decrypted plaintext is
byte-identical to the original.

The dedup only fails to suppress a replay when `last.text != msg.text`
— i.e. the peer has sent **any other DM** between the original
delivery and the replay, displacing the captured plaintext from the
"last entry" slot. At that point the replay is accepted as fresh
regardless of wall-clock elapsed time, because the comparison is
against the new last entry, not the original. Wall-clock elapsed time
plays no role; the exploit window opens the moment the peer sends a
different message.

**Exploit sketch:** Attacker records a victim's DM. The attacker
waits until the peer has sent any other message to the victim
(observable on the air as a fresh TXT_MSG to the same dest_hash),
then re-transmits the captured packet. The replay shows up as a
brand-new message in the victim's DM thread with the original
timestamp. ACK retries are not needed; the attacker just resends the
on-air bytes. Repeating the trick requires another intervening peer
message before each subsequent replay.

**Suggested fix:** Maintain a per-pubkey replay window keyed on the
ciphertext bytes (or the 2-byte MAC + first 8 bytes of ciphertext as a
cheaper key). Reject any packet whose key has been seen in the last
`REPLAY_WINDOW_MS` (suggest 24 h, ring-buffered to bound RAM at
~256 entries per peer). The right primitive is a small LRU; the
existing `pending_ciphertexts` table is a poor fit because it gates on
"sender unknown", not "we already processed this exact ciphertext".

**Replay test:** `tools/remote/tests/e2e/test_dm_replay.py`. Capture a
DM from `meshcore-cli` (intercepting `radio/raw_rx` is the cleanest
path on the test rig), wait 120 s, retransmit verbatim. Assert
`require('services.direct_messages').get_history(pub_hex)` count did
not increment on the second send.

---

### F-03 — GRP_TXT sender_name and text not ASCII-sanitized  [severity: P2] [status: open]

**Location:** `lua/services/channels.lua:454-462` (outer parse) and
`lua/services/channels.lua:497-512` (text + sender_name flow into
`store_message` without sanitization)
**Category:** mesh-protocol

**Description:** The decrypted GRP_TXT plaintext is parsed as
`[timestamp:4][type:1][sendername: text]`. Only the *inner* (room
server relay) sender name is checked for printable ASCII
(`channels.lua:478-485`). The outer `sender_name` and the `text` field
flow directly into `store_message`, which persists to history and
hands the strings to the chat bubble renderer (`draw_text`). Built-in
bitmap fonts only cover 0x20..0x7E; everything else renders as `[]`.
A NUL byte in `sender_name` will not truncate Lua strings, but a NUL
in `text` will hit `c_str()` boundaries in several display paths
(notification toast title sanitization documented in CLAUDE.md is the
exception, not the rule).

**Exploit sketch:** Anyone on the `#Public` channel (no auth — it's
the well-known key) sends a GRP_TXT whose plaintext is
`"<ASCII control bytes>: <text>"`. Every receiver displays a row of
`[]` glyph boxes in their chat history; the row is persisted to NVS
and survives reboot.

**Suggested fix:** Add an `is_printable_ascii(s)` helper at the top of
`channels.lua` (the `channels.lua:478-485` inline loop is the right
shape) and run sender_name + text + content through it before the
relay-detection block at line 470 and again before `store_message`.
Replace non-printable bytes with `?` so the byte count stays the same
(important for upstream uniqueness keys). Apply the same fix to the
DM path (`direct_messages.lua` `plaintext:sub(6)` text).

**Replay test:** `tools/remote/tests/e2e/test_channel_name_inject.py`.
Send a `#Public` packet with `sender_name = "\x01\x02\x03BAD"` and
assert the rendered text via `ez_remote --text` contains `?` not raw
control bytes, and that `get_history("#Public")[end].sender_name`
matches the sanitized form.

---

### F-04 — Unbounded `_pendingRebroadcasts` queue  [severity: P2] [status: open]

**Location:** `src/mesh/meshcore.cpp:450, 480` (push paths) and
`src/mesh/meshcore.h:167` (declaration)
**Category:** mesh-protocol

**Description:** `MeshCore::scheduleRebroadcast` and
`scheduleRawRebroadcast` both `_pendingRebroadcasts.push_back(rb);`
without checking the queue depth. Each entry is
`MeshPacket::MAX_SIZE` (~256 bytes). The radio drains entries one at
a time, throttled by the LoRa queue; a flood faster than the drain
rate piles up packets.

**Exploit sketch:** A neighbouring node sends ~30 FLOOD packets per
second with distinct path-hashes (so our dedup `isInPath` doesn't
catch them) and unique payloads. Each becomes a pending rebroadcast.
LoRa at SF7BW250 drains ~3-4 packets/sec for a 200-byte payload, so
the queue grows by ~26 packets/sec, ~6.5 KB/sec. Within a minute the
queue is ~400 KB — past the internal heap. PSRAM may absorb it, but
`std::vector` reallocs cause TX stalls anyway.

**Suggested fix:** Cap at `kMaxPendingRebroadcasts = 32` (matches the
packet-queue cap in `mesh_bindings.cpp:115`). On overflow, drop the
*new* packet — keeping older entries lets the flood-detection logic
in the path-hash check still mark us as having seen the packet, so we
don't replay it later.

**Replay test:** `tools/remote/tests/e2e/test_rebroadcast_flood.py`.
Have `meshcore-cli` emit 100 unique-path FLOOD packets in 5 seconds.
Assert via
`ez_remote -e "return ez.mesh.get_tx_count(), ez.mesh.get_rx_count()"`
that TX count plateaus near 32 (cap) while RX continues to climb.
Also assert free heap (from `ez.system.free_heap()`) stays within
±50 KB of baseline.

---

### F-05 — `apply_full_url` SHA-256 verification is optional at the binding  [severity: P2] [status: open]

**Location:** `src/lua/bindings/ota_bindings.cpp:1196` and
`src/lua/bindings/ota_bindings.cpp:1352-1391`
**Category:** update-path

**Description:** `l_ota_apply_full_url` accepts an optional
`expected_sha256_hex` argument. When omitted, `p->hasExpectedSha`
stays `false` and the post-download verification at
`ota_bindings.cpp:1196` is skipped entirely:

```cpp
    if (p->hasExpectedSha && memcmp(digest, p->expectedSha, 32) != 0) {
        fail("sha256 mismatch");
        return;
    }
```

The current caller (`lua/screens/settings/firmware_update.lua`) always
passes a hash (verified via Ed25519 over the signed manifest), so this
is latent. But the binding does not enforce; a future Lua caller (or a
terminal-REPL user) can pass just the URL and the device will flash
whatever the TLS-insecure stream delivers. The matching Ed25519
verification lives in Lua, not in C++, so a one-line Lua bug bypasses
firmware authenticity.

**Exploit sketch:** Not exploitable today (no caller invokes the
binding without a hash), but a regression in `firmware_update.lua`
that drops the hash argument would silently turn the OTA flow into
"flash whatever you can reach over HTTPS." The C++ side should not
make signed-update bypass a single-line Lua bug away.

**Suggested fix:** Make `expected_sha256_hex` mandatory in
`l_ota_apply_full_url` — `luaL_checkstring` it (not `lua_isnil`-gated)
and `parseHexSha` always. Return `{ok=false, error="sha required"}`
otherwise. Alternative: require both `expected_sha256` *and* a signed
`manifest_blob + manifest_sig` so the C++ side re-verifies the chain
before starting the download. Less work, same outcome: make
authenticity a property of the binding, not a property of the caller.

**Replay test:** `tools/remote/tests/test_ota_binding.py`. Call
`ez.ota.apply_full_url("https://example.com/firmware.bin")` (no sha)
via `ez_remote -e` and assert the response table has
`ok = false, error ~= nil`. Also verify a hash-mismatch case still
fails via the existing flow.

---

### F-06 — `mesh/packet` bus topic surfaces unauthenticated bytes to all subscribers  [severity: P2] [status: open]

**Location:** `src/lua/bindings/mesh_bindings.cpp:122-153`
**Category:** mesh-protocol

**Description:** `postPacketToBus` fires for every received packet
*before* any signature / MAC verification. ADVERTs that fail
`Identity::verify` at `meshcore.cpp:311` still land on the bus
(`handleAdvertPacket` doesn't gate the `_onNode` / bus path on sig
validity — see line 393-401: `if (!sigValid) { ... } // Still add the
node`). Lua subscribers (e.g. signal_test, custom_packets) operating
on these payloads can be made to act on attacker-chosen bytes.

```cpp
// src/mesh/meshcore.cpp:393-401
    if (!sigValid) {
        MESH_LOG("ADVERT from %02X: %s [%s] (sig INVALID)\n", pathHash, name, roleStr);
        // Still add the node but could mark as unverified in the future
    } else {
        MESH_LOG("ADVERT from %02X: %s [%s] (verified)\n", pathHash, name, roleStr);
    }
    // Update node info with role, ADVERT timestamp, and location
    updateNode(...);
```

**Exploit sketch:** Attacker sends an ADVERT with a junk signature.
The signature check fails, but `updateNode` still runs, the node lands
in the table with attacker-chosen name + role + GPS, and the
`mesh/packet` bus subscribers see the packet. Downstream code that
treats `route_type=ADVERT` payloads as authenticated is wrong but not
visibly so. Today, no downstream code depends on this distinction —
the risk is forward.

**Suggested fix:** Add a `sig_valid` boolean to `NodeInfo` and to the
`mesh/packet` bus payload. Lua consumers (signal_test, the map / node
browser) can then choose to display "unverified" indicators or skip.
Marking rather than dropping unsigned ADVERTs preserves
interoperability with older MeshCore firmware that doesn't sign
ADVERTs and avoids partitioning the network on a forward-compatible
field. (Ed25519 verification itself is clock-independent —
`Identity::verify` takes only `(publicKey, message, signature)` — so
this is purely a compatibility argument, not a time-sync one.)

**Replay test:**
`tools/remote/tests/e2e/test_advert_unsigned.py`. Send a malformed
(bad signature) ADVERT and assert the node lands with
`sig_valid=false` in `ez.mesh.get_nodes()`.

---

### F-07 — Path-traversal not blocked in storage bindings  [severity: P2] [status: open]

**Location:** `src/lua/bindings/storage_bindings.cpp:80-120`
(`getFSType`) and every `LUA_FUNCTION` that calls it.
**Category:** storage

**Description:** `getFSType` does prefix matching (`/sd/`, `/fs/`,
`/img/`) but does not normalize `..` segments or NUL bytes. `/sd/../`
or `/fs/../../etc/passwd` passes the prefix check and the underlying
FATFS / LittleFS may or may not honor traversal. LittleFS rejects `..`
internally; FAT-on-SD does not. So `/sd/foo/../../bar.txt` on FAT
resolves to `/bar.txt`. Combined with `file_transfer` writing to a
user-armed directory, a peer who chose a name with embedded `..`
slips through `basename(name)` (which strips slashes but accepts dots)
and lands the file outside `armed_dir`.

Wait — `basename(path)` is `(path or ""):match("([^/]+)$")` which
returns the last `/`-separated component. So `foo/../bar` becomes
`bar`. NUL is not stripped, but Lua strings carry it through to
`write_file`'s C boundary, where `c_str()` truncates. The realistic
risk reduces to: NUL-in-name truncation can produce ambiguous
filenames. The `..` risk applies if a future caller skips
`basename()`.

**Exploit sketch:** Limited today by `basename()` in
`file_transfer.lua:377`. Risk is forward: any new code that passes a
peer- or network-derived path directly to `ez.storage.write_file`
without `basename()` would be able to write to anywhere on the
filesystem.

**Suggested fix:** In `getFSType`, after picking the mount, scan the
adjusted path for `..` components and NUL bytes; reject (`FSType::INVALID`)
on either. Cheap: one pass with `strstr(adjusted, "/..")`,
`strstr(adjusted, "../")`, `strcmp(adjusted, "..")`, plus a `memchr`
NUL scan. Document the contract in `// @lua` annotations.

**Replay test:**
`tools/remote/tests/test_storage_traversal.py`. Call
`ez.storage.write_file("/sd/../foo.txt", "x")` and assert `false +
error`. Same for `/sd/sub/../../bar` and `"/sd/foo\0bar.txt"`.

---

### F-08 — Channel passwords + WiFi creds stored in plaintext NVS  [severity: P2] [status: wont-fix-by-design]

**Location:** `lua/services/channels.lua:165` and
`src/lua/bindings/wifi_bindings.cpp` (WiFi creds via
`Preferences.putString`)
**Category:** storage

**Description:** Channel passwords are concatenated into a `|`-joined
string and stored as a single NVS `joined_channels` string. WiFi
credentials are stored in NVS via `Preferences`. NVS encryption is
disabled on this build. Anyone with physical access (USB cable +
esptool) reads the partition trivially.

**Exploit sketch:** Attacker steals device, dumps flash via esptool,
extracts NVS namespace `lua_storage` and `meshcore`, recovers channel
passwords, WiFi SSID + password, the device's Ed25519 private key,
and the contact list. Device identity is now spoofable.

**Suggested fix:** Document as a deliberate threat-model choice (see
"Threat model" below). NVS encryption requires flash encryption +
NVS-encrypt partition + provisioned eFuse keys; the OTA flow would
need to migrate. Out of scope for this audit's PR; flag for a
separate platform-level decision.

**Replay test:** N/A — by-design.

---

### F-09 — Crypto bindings leak heap on Lua error (longjmp through `new[]`)  [severity: P3] [status: open]

**Location:** `src/lua/bindings/crypto_bindings.cpp:178-232`
(`aes128_ecb_encrypt`), `:248-300` (`aes128_ecb_decrypt`), `:484-493`
(`bytes_to_hex`), `:558-584` (`base64_encode`), and parallel patterns
in `display_bindings.cpp` allocations
**Category:** binding-boundary

**Description:** Several bindings allocate via `new[]`, push a Lua
string with `lua_pushlstring`, then `delete[]`. `lua_pushlstring`
copies into Lua-owned memory but **can longjmp on OOM** (it calls
into the Lua memory allocator). When it does, the `delete[]` is
skipped and the heap leaks. The pattern repeats across the binding
layer; under normal conditions it's never hit, but a low-memory
device that hits this path enough times turns a memory pressure
condition into terminal heap loss.

```cpp
// src/lua/bindings/crypto_bindings.cpp:224-231
    mbedtls_aes_free(&ctx);
    delete[] padded;

    lua_pushlstring(L, reinterpret_cast<char*>(output), paddedLen);
    delete[] output;   // <-- skipped on longjmp
    return 1;
```

**Exploit sketch:** Not directly exploitable, but a stuck-low-heap
device that the user keeps poking (terminal REPL, repeated map
loads) leaks each call until the device wedges.

**Suggested fix:** Wrap `new[]` in a small RAII helper or switch to
`std::unique_ptr<uint8_t[]>`. Push the Lua string before `delete[]`
runs *as the last step before return*. Better: push first, then let
the RAII destructor handle cleanup automatically.

**Replay test:** Not feasible without OOM injection. Doc-only fix
note: include this as part of a binding-style audit pass alongside
`new[]` → `unique_ptr` refactor.

---

### F-10 — `_pendingRebroadcasts` size and `_nodes` size unrecorded in stats  [severity: P3] [status: open]

**Location:** `src/mesh/meshcore.cpp` (no telemetry exported)
**Category:** mesh-protocol

**Description:** There's no Lua-side visibility into the rebroadcast
queue depth or the in-memory node count *relative* to caps. Without
this, a tester can't tell whether F-01 / F-04 mitigations are working
in the field. The `tx_count` / `rx_count` counters exist; queue
depths do not.

**Suggested fix:** Add `ez.mesh.queue_depth() -> { rebroadcast, nodes }`
once F-01 / F-04 land. Surface on a hidden Settings → Diagnostics page
or in `ez.system.stats()`.

**Replay test:** Folded into F-01 / F-04.

---

### F-11 — `serve_body_cb` `index + len` could overflow  [severity: P3] [status: open]

**Location:** `src/lua/bindings/http_bindings.cpp:660`
**Category:** network

**Description:** `if (index + len > b->cap) return;` uses `size_t`
arithmetic. AsyncTCP normally enforces sane bounds, but the binding
shouldn't trust the caller of its own callback. With `index ==
SIZE_MAX - 50` and `len == 100`, `index + len` wraps below `cap` and
the subsequent `memcpy(b->data + index, ...)` writes past the
allocation.

**Suggested fix:** Check `len > b->cap || index > b->cap - len`
instead. Same fix in the matching `memcpy(b->data + index, ...)` line.

**Replay test:** Cannot induce via the AsyncWebServer API in our
control path; static-analysis fix only. Document in code.

---

### F-12 — DM `pending_ciphertexts` could be force-promoted via contact-add  [severity: P3] [status: open]

**Location:** `lua/services/direct_messages.lua:856-866`
**Category:** mesh-protocol

**Description:** `stash_pending` holds 32 ciphertexts (`PENDING_MAX`)
keyed by `src_hash` (1 byte). On `contacts/changed`, every stashed
entry is re-tried against the newly added contact's pubkey. The
`src_hash` is 1 byte, so 1-in-256 hash collision lets an attacker's
old ciphertext "decrypt" against a freshly added contact's pubkey if
the 2-byte MAC also matches by coincidence — combined,
~1-in-2^24 per stashed-entry / contact-add pair.

This is a random-coincidence ceiling, not an attacker-grindable one.
The MAC is HMAC-SHA256 keyed with the X25519 shared secret between
the receiver and the supposed sender; the attacker does not possess
that key and cannot iterate trials against the verifier. A captured
packet's MAC, checked against any *other* contact's shared secret, is
effectively a random 2-byte token from the verifier's perspective.
Stashing more ciphertexts or replaying the same one repeatedly does
not improve the attacker's odds against a given new contact — only
the number of distinct (stashed entry, newly added contact) pairs
does. The risk is "occasionally a garbage entry pops into a new
contact thread on first add", not "an attacker can target a victim".

**Suggested fix:** Once F-02 lands (per-pubkey replay window), the
`pending_ciphertexts` flow can also gate on "have we seen this MAC
before for this peer". Treat as folded into F-02.

**Replay test:** Folded into F-02.

---

## Category status

- **C++ Lua-binding boundary:** 2 findings filed (F-05, F-09).
  `LUA_STATE` pattern is correctly used at the audited call sites
  (mesh_bindings packet callback line 168; `display_bindings` /
  `system_bindings` timer paths). `LUA_CHECK_ARGC` is used at most
  bindings reviewed; missing on `l_crypto_ed25519_verify` (line 637)
  but its `luaL_checklstring` calls cover length safety. `memcpy`
  sinks in `mesh_bindings.cpp:1004-1008` are gated by
  `MAX_PACKET_PAYLOAD` / `MAX_PATH_SIZE`. Integer-overflow risk
  flagged at `display_bindings.cpp:1038` (`width * height * 2`) — only
  triggers on huge negative-after-overflow values that subsequently
  fail the `dataLen` check; bordering on hardening, not filed.
- **Mesh protocol attack surface:** 5 findings filed (F-01, F-02,
  F-03, F-04, F-06). The 1-byte src_hash / dest_hash is used only as
  a fast filter and the pubkey is re-checked downstream (DM
  `build_candidates` flow at `direct_messages.lua:756`), so the
  protocol-level concern is OK. 6-byte node-ID collision (2^24 work)
  is acknowledged in CLAUDE.md and the codebase treats short IDs as
  hints; the pubkey is the credential. Path-hash poisoning is mostly
  irrelevant because `isInPath` only suppresses our *own* rebroadcast.
  ADVERT signature is verified, but unsigned ADVERTs still mutate
  node table (F-06).
- **File / storage:** 2 findings filed (F-07, F-08). NVS 15-char key
  limit collision is mitigated by `set_pref` logging+rejecting keys
  > 15 chars at `storage_bindings.cpp:932-938`. USB MSC is opt-in via
  `ez.system.start_usb_msc()` and not auto-started — OK.
  `save_screenshot` and `ez.docs.read` accept Lua-controlled paths,
  but Lua is privileged (firmware-shipped scripts only); accept by
  design.
- **Network:** 1 finding filed (F-11). HTTP serve cap is 64 KB at
  `http_bindings.cpp:649` and request body is 32 KB at
  `http_bindings.cpp:43`. Slowloris depends on AsyncWebServer's
  built-in timeouts; tolerable for a device that exposes the server
  only behind user opt-in. Outbound HTTP without TLS is opt-in (Lua
  passes the URL); plain HTTP is currently used by the dev-mode
  `ota.dev_server_*` only. WiFi creds in unencrypted NVS — see F-08.
- **Lua surface:** 0 findings filed. The terminal REPL, `_G.hot_reload`,
  and remote-control USB are all in the documented threat model:
  physical access = game over, embedded Lua = privileged. The
  `clean_hot_reload` boot pass at `lua/boot.lua:64-81` keeps SD/LittleFS
  scripts from outliving a reboot, which closes the most obvious
  persistence path. Reviewed against the spec; OK.
- **Update path:** 1 finding filed (F-05). The Ed25519 verification
  flow in `firmware_update.lua:147` correctly checks the manifest
  signature against `ez.ota.signing_pubkey()` (non-zero per
  `src/ota_pubkey.cpp:12`), cross-checks `manifest.tag` against the
  selected channel, and passes both URL and SHA-256 down. The
  binding-level optional-hash is the one weak link.

## Threat model (documented-by-design)

- **Physical access compromises the device.** USB cable + esptool
  reads the entire flash, including the NVS partitions that hold
  the Ed25519 private key, channel passwords, WiFi credentials, and
  the contact list. NVS encryption is off and enabling it requires
  a platform-level migration (eFuse provisioning, OTA reflash). We
  accept this for now and document it explicitly. F-08 belongs to
  this bucket.
- **Lua scripts are privileged.** The runtime treats every Lua file
  the firmware ships with as trusted: it can call any binding,
  write any path, drive the radio, start an AP, etc. The
  threat-model boundary is the *embedded scripts*, not the Lua
  language itself. The terminal REPL
  (`lua/screens/tools/terminal.lua`) gives an on-device user a Lua
  prompt, but that requires already-have-the-device.
- **Remote control USB is part of the trust boundary.** The protocol
  in `src/remote/` lets a host machine on USB read framebuffers,
  inject keys, write files, and execute arbitrary Lua. This is the
  development trust model; anyone with a USB cable was already
  privileged before they could use it.
- **6-byte node IDs are display hints, not credentials.** The 2^24
  collision work is acknowledged. Authentication always falls
  through to the 32-byte Ed25519 pubkey; the 1-byte path-hash is a
  routing filter only, the 6-byte short ID is for the UI only.
- **The `#Public` channel is unauthenticated by design.** The
  well-known key (`crypto_bindings.cpp:456-460`) means anyone can
  read or write to `#Public`. Treat it as untrusted radio noise;
  any sanitization fix (F-03) is about display correctness, not
  about authenticating the sender.
- **mbedTLS side channels are out of scope.** We trust upstream.
- **Post-quantum migration is out of scope.** Ed25519 + X25519 are
  classical-secure; the radio link's ~100-byte payload is not the
  right place to bolt on a kyber/dilithium layer.

## Follow-up checklist

Ordered by severity then by category for easy issue-creation:

- [ ] F-01 — Unbounded `MeshCore::_nodes` vector (P1)
- [ ] F-02 — DM replay accepted once the peer sends any other message (P1)
- [ ] F-03 — GRP_TXT sender_name and text not ASCII-sanitized (P2)
- [ ] F-04 — Unbounded `_pendingRebroadcasts` queue (P2)
- [ ] F-05 — `apply_full_url` SHA-256 verification is optional at the binding (P2)
- [ ] F-06 — `mesh/packet` bus surfaces unauthenticated ADVERTs (P2)
- [ ] F-07 — Path-traversal not blocked in storage bindings (P2)
- [ ] F-08 — Channel passwords + WiFi creds in plaintext NVS (P2, by-design)
- [ ] F-09 — Crypto bindings leak heap on Lua-error longjmp (P3)
- [ ] F-10 — Mesh queue/table depths not exported (P3)
- [ ] F-11 — `serve_body_cb` `index + len` overflow risk (P3)
- [ ] F-12 — DM `pending_ciphertexts` promotion via contact-add (P3, folds into F-02)

## Out of scope (per the issue)

- Hardware attacks (chip-level glitching, side-channel, fault injection)
- mbedTLS side-channels (trusted upstream)
- Post-quantum migration (not relevant at this scale)
