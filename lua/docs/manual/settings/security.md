# Settings -- Security

Encrypts the Ed25519 identity private key at rest behind a user
passphrase. Without encryption, anyone with USB / serial access (or
a reflash) can read the key and impersonate you on the mesh.

## Default state

The identity key lives in NVS as `privkey` (64 bytes Ed25519 seed +
derived key) and `pubkey` (32 bytes public). By default both are
stored in plaintext.

## Set passphrase

Settings -- Security -- Set passphrase opens a screen that asks for
a passphrase twice. On confirm:

1. PBKDF2-SHA256 (100 000 iterations) derives a 32-byte KEK from
   your passphrase + a 16-byte random salt.
2. AES-256-GCM encrypts the 64-byte private key under that KEK
   with a 12-byte random nonce. The 32-byte public key is bound
   into the AEAD's AAD as an identity tag, so a wrapped blob is
   tied to this device's public key.
3. The encrypted blob is written to NVS as `id_wrap`. A self-test
   decrypts the blob right back and verifies it matches the
   original before deleting the plaintext.
4. The plaintext `privkey` NVS entry is deleted.

After confirmation, the device reboots into the locked state. At
every boot from now on you'll be asked for your passphrase before
mesh starts.

## **There is no recovery if you forget the passphrase.** Picking a
phrase you can actually remember is more important than picking one
that's hard to brute-force.

## Unlock at boot

When the device boots with a wrapped key, the first screen you see
asks for your passphrase. Until you enter it:

- The status bar shows the device's normal indicators, but the
  mesh layer cannot sign messages -- no ADVERTs go out, no DMs send.
- Wrong attempts trigger exponential backoff: 1 s, 2 s, 4 s, 8 s,
  16 s, 32 s, up to 60 s. The backoff resets on a successful unlock.

There is no way to dismiss the unlock screen except by entering the
correct passphrase.

## Change passphrase

After a successful boot-time unlock, Settings -- Security gains a
"Change passphrase" entry. It asks for the current passphrase and
a new one twice; on success the wrapped blob is replaced in-place
under a fresh salt + nonce.

## Remove passphrase

Settings -- Security -- Remove passphrase undoes the wrap: enter
your current passphrase, the plaintext key is written back to NVS,
and the wrapped blob is deleted. The device returns to default
behaviour and no longer prompts at boot. The next boot is the
warning -- anyone who picks up the device can read the key again.

## What is NOT encrypted

- The 32-byte public key (it's not secret).
- Your node name, contacts, channel passwords, chat history, files
  on SD. The wrap covers only the identity private key.

If you also need at-rest encryption of message history, that is
tracked separately as a future enhancement.

## Recovery from a wrap interrupted by power loss

The wrap is two-phase: write the wrapped blob first, then delete
the plaintext. If you lose power between steps, the next boot sees
both entries in NVS and **rolls back the wrap** -- the partial
wrapped blob is deleted and the device boots normally on the
unchanged plaintext key. You can then try the wrap again. Your
identity is never silently lost to a power loss.

## Trust model notes

- The Lua terminal (Settings -- Apps -- Terminal) and the USB
  remote-control protocol can call `ez.identity.*` after unlock.
  Physical access to the device with the screen unlocked is
  outside the threat model the wrap is designed to defeat -- the
  wrap protects against an attacker who has the device but not
  the passphrase.
- The wrap key is held in RAM only after unlock; a reboot clears
  it. A panic, brownout, or power cut clears it too -- the next
  boot will require the passphrase again.
- PBKDF2-SHA256 at 100 000 iterations takes about 1 s on the
  ESP32-S3. A determined offline attacker with extracted NVS
  bytes can grind the wrapped blob on a faster machine, so a
  short passphrase ("hunter2") is not safe; pick something with
  enough entropy that the cost of a guess is meaningful.
