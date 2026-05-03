#!/usr/bin/env python3
"""
Claude AI mesh chat bot

Listens for private messages on a MeshCore node and responds using Claude.
Messages are kept short for LoRa mesh bandwidth constraints.

Usage:
    python mesh_claude_bot.py /dev/ttyUSB0 --contact Node-D309F5

Requires:
    - meshcore Python library (from meshcore-cli pipx venv)
    - claude CLI tool (claude -p)
"""

import asyncio
import argparse
import json
import logging
import os
import subprocess
import sys
import time

# Use the meshcore library from the pipx venv
PIPX_VENV = os.path.expanduser(
    "~/.local/pipx/venvs/meshcore-cli/lib/python3.11/site-packages"
)
if os.path.isdir(PIPX_VENV):
    sys.path.insert(0, PIPX_VENV)

from meshcore import MeshCore
from meshcore.events import EventType

logger = logging.getLogger("mesh_claude_bot")

# Mesh message size limit (inner plaintext, minus 5 bytes header)
MAX_MSG_LEN = 160

MEMORY_PATH = os.path.expanduser("~/.cache/mesh_claude_bot.json")
MAX_MEMORY_TURNS = 20  # Keep last N exchanges before compacting
COMPACT_THRESHOLD = 30  # Compact when exceeding this many turns

# Persistent cache for the OTA bearer token. Updated three ways:
#   1. MESH_OTA_TOKEN env var seeds it on first run if missing
#   2. The user can edit this file directly
#   3. Inbound DM matching `token: XXXXXX` updates it (so they can
#      send a new token over mesh after pressing "Regenerate" on the
#      device's Dev OTA screen).
TOKEN_CACHE_PATH = os.path.expanduser("~/.cache/mesh_claude_bot.token")
import re as _re
TOKEN_PATTERN = _re.compile(r"\btoken\s*[:=]\s*([A-Z0-9]{6})\b", _re.IGNORECASE)


class ConversationMemory:
    """Persistent conversation memory with auto-compacting."""

    def __init__(self, path=MEMORY_PATH):
        self.path = path
        self.turns = []
        self.summary = ""
        self._load()

    def _load(self):
        if os.path.exists(self.path):
            try:
                with open(self.path) as f:
                    data = json.load(f)
                self.turns = data.get("turns", [])
                self.summary = data.get("summary", "")
            except (json.JSONDecodeError, KeyError):
                self.turns = []
                self.summary = ""

    def _save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w") as f:
            json.dump({"turns": self.turns, "summary": self.summary}, f)

    def add(self, role, text):
        self.turns.append({"role": role, "text": text, "time": int(time.time())})
        if len(self.turns) > COMPACT_THRESHOLD:
            self._compact()
        self._save()

    def _compact(self):
        """Summarize old turns using Claude, keep recent ones."""
        old_turns = self.turns[: -MAX_MEMORY_TURNS]
        recent = self.turns[-MAX_MEMORY_TURNS:]

        # Build text of old turns for summarization
        old_text = ""
        for t in old_turns:
            role = "Human" if t["role"] == "user" else "Bot"
            old_text += f"{role}: {t['text']}\n"

        if old_text:
            prompt = (
                f"Summarize this conversation history in 2-3 sentences. "
                f"Focus on key topics, preferences, and context that would be "
                f"useful for continuing the conversation:\n\n"
                f"{self.summary}\n{old_text}"
            )
            try:
                result = subprocess.run(
                    ["claude", "-p", prompt],
                    capture_output=True, text=True, timeout=30,
                )
                if result.returncode == 0 and result.stdout.strip():
                    self.summary = result.stdout.strip()
            except Exception as e:
                logger.warning(f"Compact failed: {e}")

        self.turns = recent
        logger.info(f"Compacted memory: {len(old_turns)} turns summarized")

    def build_context(self):
        """Build context string for Claude prompt."""
        parts = []
        if self.summary:
            parts.append(f"Previous conversation summary: {self.summary}")
        for t in self.turns[-10:]:
            role = "Human" if t["role"] == "user" else "You"
            parts.append(f"{role}: {t['text']}")
        return "\n".join(parts)


class MeshClaudeBot:
    def __init__(self, port, baudrate, contact_filter=None, debug=False,
                 project_root=None):
        self.port = port
        self.baudrate = baudrate
        self.contact_filter = contact_filter
        self.debug = debug
        self.mc = None
        self.memory = ConversationMemory()
        self.target_pubkey = None
        self._processing = asyncio.Lock()
        self._seen_msgs = {}  # (sender, text) -> timestamp for dedup
        self._dedup_window = 60  # ignore duplicate messages within this many seconds

        # Project root the bot operates against. Defaults to the repo
        # this script lives in -- the typical run is
        # "python tools/mesh_claude_bot.py ..." from the project root.
        # Claude is invoked with this as its working directory so its
        # Read/Edit/Bash tools see the firmware source tree.
        self.project_root = project_root or os.path.dirname(
            os.path.dirname(os.path.abspath(__file__))
        )

        # OTA target wired into Claude's system prompt so it can push
        # firmware without asking. The token is read fresh on every
        # message via _current_ota_token(), so a "token: XXX" DM (or
        # an external edit of TOKEN_CACHE_PATH) propagates without a
        # bot restart.
        self.ota_host = os.environ.get("MESH_OTA_HOST", "").strip() or None
        self._seed_token_cache()

    def _seed_token_cache(self):
        """Populate the token cache from MESH_OTA_TOKEN if the file is missing."""
        if os.path.exists(TOKEN_CACHE_PATH):
            return
        env_token = os.environ.get("MESH_OTA_TOKEN", "").strip()
        if not env_token:
            return
        try:
            os.makedirs(os.path.dirname(TOKEN_CACHE_PATH), exist_ok=True)
            with open(TOKEN_CACHE_PATH, "w") as f:
                f.write(env_token)
        except OSError as e:
            logger.warning(f"Could not seed token cache: {e}")

    def _current_ota_token(self):
        """Read the latest token from disk on every call.

        Reading per-message means the user can rotate the token (via
        the device's "Regenerate token" button + a follow-up `token:
        XXXXXX` DM, or a direct file edit) without having to bounce
        the bot.
        """
        try:
            with open(TOKEN_CACHE_PATH) as f:
                t = f.read().strip()
            return t or None
        except (OSError, FileNotFoundError):
            return None

    def _maybe_capture_token(self, text):
        """If the message contains `token: XXX`, persist it. Returns the captured token, or None."""
        m = TOKEN_PATTERN.search(text)
        if not m:
            return None
        new_token = m.group(1).upper()
        try:
            os.makedirs(os.path.dirname(TOKEN_CACHE_PATH), exist_ok=True)
            with open(TOKEN_CACHE_PATH, "w") as f:
                f.write(new_token)
            logger.info(f"OTA token updated to {new_token}")
            return new_token
        except OSError as e:
            logger.warning(f"Could not write token cache: {e}")
            return None

    async def start(self):
        logger.info(f"Connecting to {self.port}...")
        self.mc = await MeshCore.create_serial(
            self.port, self.baudrate, debug=self.debug, default_timeout=10
        )

        # Fetch contacts to resolve names
        logger.info("Fetching contacts...")
        await self.mc.commands.get_contacts()
        await asyncio.sleep(2)

        # Find target contact by name
        if self.contact_filter:
            for key, contact in self.mc._contacts.items():
                name = contact.get("adv_name", "") or contact.get("name", "")
                if self.contact_filter.lower() in name.lower():
                    self.target_pubkey = contact.get("public_key", key)
                    logger.info(
                        f"Target contact: {name} ({self.target_pubkey[:12]}...)"
                    )
                    break
            if not self.target_pubkey:
                logger.warning(
                    f"Contact '{self.contact_filter}' not found, "
                    f"will respond to all DMs"
                )

        # Subscribe to incoming DMs before starting fetch so we don't miss events
        self.mc.subscribe(EventType.CONTACT_MSG_RECV, self._on_message)

        # Start message fetching (triggers initial get_msg and listens for MESSAGES_WAITING)
        await self.mc.start_auto_message_fetching()
        logger.info("Listening for messages...")

        # Poll for messages periodically as a fallback in case
        # MESSAGES_WAITING events aren't delivered by the device
        try:
            while True:
                await asyncio.sleep(5)
                try:
                    await self.mc.commands.get_msg()
                except Exception:
                    pass
        except asyncio.CancelledError:
            pass

    async def _on_message(self, event):
        msg = event.payload
        sender_prefix = msg.get("pubkey_prefix", "")
        text = msg.get("text", "").strip()

        if not text:
            return

        # Filter by target contact if set
        if self.target_pubkey and not self.target_pubkey.lower().startswith(
            sender_prefix.lower()
        ):
            logger.debug(f"Ignoring message from {sender_prefix}: {text}")
            return

        # Deduplicate: skip if we've seen this exact message recently
        now = time.time()
        dedup_key = (sender_prefix.lower(), text.lower())
        last_seen = self._seen_msgs.get(dedup_key, 0)
        if now - last_seen < self._dedup_window:
            logger.debug(f"Skipping duplicate: {text}")
            return
        self._seen_msgs[dedup_key] = now

        # Prune old dedup entries
        cutoff = now - self._dedup_window * 2
        self._seen_msgs = {
            k: v for k, v in self._seen_msgs.items() if v > cutoff
        }

        logger.info(f"<< {sender_prefix[:8]}: {text}")

        # Only process one message at a time — drop messages that arrive
        # while we're already generating a response
        if self._processing.locked():
            logger.info(f"   (busy, skipping)")
            return

        async with self._processing:
            # Token rotation handshake: if the message contains
            # `token: XXXXXX`, capture it before invoking Claude so
            # the new value flows into the system prompt below.
            captured = self._maybe_capture_token(text)
            if captured:
                await self._reply(f"Updated OTA token to {captured}.")
                # Don't run Claude on what is effectively a config DM
                # unless the user added other content beyond the token
                # update. Most "token:" messages are just the rotation
                # itself.
                stripped = TOKEN_PATTERN.sub("", text).strip(" .,;-")
                if not stripped:
                    return
                text = stripped  # let Claude see whatever else they wrote

            # Add to memory
            self.memory.add("user", text)

            # Acknowledge receipt before kicking off Claude -- firmware
            # work (read repo, edit, build, flash) routinely takes a
            # minute or more, and the user should know we're on it
            # rather than wondering if the DM got eaten.
            await self._reply("Working on it...")

            # Ask Claude with full repo + OTA tool access
            response = await asyncio.get_event_loop().run_in_executor(
                None, self._ask_claude, text
            )

            if not response:
                response = "(no response)"

            # Truncate for mesh
            if len(response) > MAX_MSG_LEN:
                response = response[: MAX_MSG_LEN - 3] + "..."

            # Add response to memory
            self.memory.add("assistant", response)

            logger.info(f">> {response}")

            # Send reply
            dest = self.target_pubkey or sender_prefix
            try:
                await self.mc.commands.send_msg(dest, response)
                logger.info("   (sent)")
            except Exception as e:
                logger.error(f"   Send failed: {e}")

    async def _reply(self, text):
        """Send a DM back to the target contact, truncating to mesh size."""
        if not self.target_pubkey:
            logger.warning(f"No target pubkey, can't reply: {text}")
            return
        if len(text) > MAX_MSG_LEN:
            text = text[: MAX_MSG_LEN - 3] + "..."
        try:
            await self.mc.commands.send_msg(self.target_pubkey, text)
            logger.info(f">> {text}")
        except Exception as e:
            logger.error(f"   Send failed: {e}")

    # -----------------------------------------------------------------
    # Claude invocation
    #
    # We shell out to the `claude` CLI in -p (print) mode, with the
    # project root as cwd so its built-in Read/Edit/Bash tools see the
    # firmware source tree. The system prompt tells Claude where the
    # OTA push script is and (when configured) the target IP + token,
    # so requests like "add a debug log to boot.lua and push it" work
    # end-to-end -- Claude edits the file, runs `pio run`, runs
    # push_ota.py, and replies with a short status.
    #
    # Memory continues to track turns so multi-message conversations
    # ("rename that variable to FOO instead") stay coherent across DMs.
    # -----------------------------------------------------------------

    def _build_system_prompt(self):
        """Compose the system prompt that tells Claude what it can do.

        Re-built per call so the OTA token reflects whatever's on disk
        right now (rotated via the device's regenerate button + a
        `token: XXX` DM).
        """
        token = self._current_ota_token()
        lines = [
            "You are a firmware engineer's assistant operating over a LoRa "
            "mesh DM channel. The user is on a T-Deck Plus and chats with "
            "you to make changes to *this* firmware repo.",
            "",
            f"Project root: {self.project_root} (your cwd)",
            "Target hardware: ESP32-S3 (LilyGo T-Deck Plus). C++ firmware "
            "with Lua scripts for UI under lua/. CLAUDE.md in the project "
            "root is authoritative -- read it first when making changes.",
            "",
            "Build:   pio run",
            "Flash via OTA over WiFi:",
            "  python tools/dev/push_ota.py <ip> <token> "
            ".pio/build/t-deck-plus/firmware.bin",
            "  push_ota.py exit code 0 = success; the device must be "
            "rebooted to apply (the user can press Alt+Enter on the "
            "'Firmware ready' toast).",
        ]

        if self.ota_host and token:
            lines += [
                "",
                f"Default OTA target: {self.ota_host}",
                f"OTA bearer token:   {token}",
                "Use these unless the user names a different target. "
                "The token is persistent on the device (survives "
                "reboots) but the user can rotate it from "
                "Settings -> System -> Dev OTA -> 'Regenerate token'. "
                "If a push returns HTTP 401, ask the user to send the "
                "new token as `token: XXXXXX` -- the bot picks it up "
                "automatically and your next push will use it.",
            ]
        elif self.ota_host:
            lines += [
                "",
                f"Default OTA host: {self.ota_host}",
                "OTA token is not configured. Ask the user to send "
                "the token shown on the device as `token: XXXXXX` "
                "before attempting a push.",
            ]
        else:
            lines += [
                "",
                "No OTA target is configured. Ask the user for the IP "
                "and token (shown on the device's Dev OTA screen).",
            ]

        lines += [
            "",
            "Mesh constraint: every reply you make is sent verbatim as "
            f"a single LoRa DM. Hard limit: {MAX_MSG_LEN} characters. "
            "No markdown, no preamble, no bullet lists. State the result "
            "and any next step the user needs to take. If something "
            "failed, say what failed in one sentence.",
        ]
        return "\n".join(lines)

    def _ask_claude(self, message):
        context = self.memory.build_context()

        # The user's actual message is appended after any prior memory
        # so Claude can resolve references like "make it 5 instead".
        # The "Respond in <=NN chars" reminder is repeated here on top
        # of the system prompt because the system prompt only sets
        # behavioral guardrails -- the per-message reminder makes the
        # truncation hit reliably.
        prompt_parts = []
        if context:
            prompt_parts.append(f"Recent conversation:\n{context}\n")
        prompt_parts.append(f"User: {message}")
        prompt_parts.append(
            f"\nRespond in <={MAX_MSG_LEN} characters, plain text only."
        )
        user_prompt = "\n".join(prompt_parts)

        try:
            result = subprocess.run(
                [
                    "claude", "-p", user_prompt,
                    "--append-system-prompt", self._build_system_prompt(),
                    "--permission-mode", "acceptEdits",
                ],
                cwd=self.project_root,
                capture_output=True,
                text=True,
                timeout=600,  # firmware build + flash can take ~1-2 min
            )
            if result.returncode == 0:
                return result.stdout.strip()
            logger.error(f"Claude rc={result.returncode}, stderr={result.stderr}")
            return f"Error (rc={result.returncode}): " + (
                result.stderr.strip().splitlines()[-1][:120]
                if result.stderr else "no detail"
            )
        except subprocess.TimeoutExpired:
            logger.error("Claude timed out")
            return "Timed out (>10 min). Try a smaller change."
        except FileNotFoundError:
            logger.error("claude CLI not found")
            return "Error: claude CLI not installed on the host."


def main():
    parser = argparse.ArgumentParser(description="Claude AI mesh chat bot")
    parser.add_argument("port", help="Serial port (e.g., /dev/ttyUSB0)")
    parser.add_argument(
        "-b", "--baudrate", type=int, default=115200, help="Baudrate (default: 115200)"
    )
    parser.add_argument(
        "-c",
        "--contact",
        help="Only respond to this contact name (partial match)",
    )
    parser.add_argument(
        "--debug", action="store_true", help="Enable debug logging"
    )
    parser.add_argument(
        "--clear-memory", action="store_true", help="Clear conversation memory"
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    if args.clear_memory:
        if os.path.exists(MEMORY_PATH):
            os.remove(MEMORY_PATH)
            print("Memory cleared.")
        return

    bot = MeshClaudeBot(
        args.port, args.baudrate, contact_filter=args.contact, debug=args.debug
    )

    try:
        asyncio.run(bot.start())
    except KeyboardInterrupt:
        print("\nBot stopped.")


if __name__ == "__main__":
    main()
