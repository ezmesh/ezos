#!/usr/bin/env bash
# Read the ESP-IDF coredump partition off a connected T-Deck Plus and
# decode it into a human-readable register / stack dump.
#
# Workflow:
#   1. esptool.py reads the 64 KiB coredump partition (offset 0xFF0000)
#      into a local file.
#   2. esp-coredump (a separate pip package) decodes it against the
#      built firmware ELF, producing the register dump, the stack of
#      every task, and the panic reason.
#
# Run after a panic to see *why* the device crashed, not just *that*
# it did. The on-device log only stamps the reset reason; this script
# is the post-mortem.
#
# Usage:
#   ./tools/read_coredump.sh                 # auto-detect /dev/ttyACM0
#   ./tools/read_coredump.sh /dev/ttyACM1    # explicit port
#
# Prereqs (one-time):
#   pip install esp-coredump

set -euo pipefail

PORT="${1:-/dev/ttyACM0}"
ELF="${ELF:-.pio/build/t-deck-plus/firmware.elf}"
PARTITION_OFFSET="0xFF0000"
PARTITION_SIZE="0x10000"
DUMP_FILE="${DUMP_FILE:-/tmp/tdeck_coredump.bin}"

if [[ ! -e "$PORT" ]]; then
  echo "error: $PORT not found. Plug the device in (T-Deck typically lands on /dev/ttyACM0)." >&2
  exit 1
fi
if [[ ! -e "$ELF" ]]; then
  echo "error: firmware ELF not found at $ELF. Run 'pio run' first so the symbols match the running image." >&2
  exit 1
fi

# Locate esptool. PlatformIO ships its own under ~/.platformio so we
# don't depend on a system install.
ESPTOOL=""
for candidate in \
  "$HOME/.platformio/packages/tool-esptoolpy/esptool.py" \
  "$(command -v esptool.py 2>/dev/null || true)"
do
  if [[ -n "$candidate" && -e "$candidate" ]]; then
    ESPTOOL="$candidate"; break
  fi
done
if [[ -z "$ESPTOOL" ]]; then
  echo "error: esptool.py not found. Install via 'pip install esptool' or use PlatformIO." >&2
  exit 1
fi

echo "[1/2] Reading coredump partition ($PARTITION_SIZE bytes @ $PARTITION_OFFSET) from $PORT..."
python "$ESPTOOL" --chip esp32s3 --port "$PORT" --baud 460800 \
  read_flash "$PARTITION_OFFSET" "$PARTITION_SIZE" "$DUMP_FILE"

# An unused / pristine coredump partition is all-0xFF (the erase
# state of NOR flash). The first 4 bytes are the dump's length
# field; if they're 0xFFFFFFFF there's nothing to decode.
HDR="$(xxd -l 4 -p "$DUMP_FILE")"
if [[ "$HDR" == "ffffffff" ]]; then
  echo "no coredump present (partition is empty)."
  exit 0
fi

echo "[2/2] Decoding via esp-coredump..."
if ! command -v esp-coredump >/dev/null 2>&1; then
  echo "error: esp-coredump not installed. Run 'pip install esp-coredump' and re-run." >&2
  echo "raw dump saved at: $DUMP_FILE" >&2
  exit 1
fi

esp-coredump info_corefile --core "$DUMP_FILE" --core-format raw "$ELF"
