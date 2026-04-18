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
    def __init__(self, port, baudrate, contact_filter=None, debug=False):
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
            # Add to memory
            self.memory.add("user", text)

            # Ask Claude
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

    def _ask_claude(self, message):
        context = self.memory.build_context()

        prompt = (
            f"You are a helpful assistant chatting over a LoRa mesh network. "
            f"Keep ALL responses under {MAX_MSG_LEN} characters — this is a hard limit, "
            f"not a suggestion. Be concise, direct, and conversational. "
            f"No markdown, no bullet points, no headers. Just plain text.\n\n"
        )
        if context:
            prompt += f"Conversation so far:\n{context}\n\n"
        prompt += f"Human: {message}\n\nRespond concisely:"

        try:
            result = subprocess.run(
                ["claude", "-p", prompt],
                capture_output=True,
                text=True,
                timeout=60,
            )
            if result.returncode == 0:
                return result.stdout.strip()
            else:
                logger.error(f"Claude error: {result.stderr}")
                return None
        except subprocess.TimeoutExpired:
            logger.error("Claude timed out")
            return "Sorry, thinking took too long."
        except FileNotFoundError:
            logger.error("claude CLI not found")
            return "Error: claude not installed"


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
