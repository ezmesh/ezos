#!/usr/bin/env python3
"""
Claude WiFi chat bot for the T-Deck.

Listens on HTTP for chat messages from the device's "Claude" screen,
runs the `claude` CLI from this repo with full Read/Edit/Bash tool
access, and streams the reply BACK to the device in real time. The
system prompt baked in tells Claude how to push OTA when asked, so
requests like "add a debug log to boot.lua and push it" complete
end-to-end.

Async flow (since stream-json + per-event posting):

  1. Device POSTs /chat with { message, callback_url, callback_auth }.
  2. Bot returns 202 with { request_id } immediately.
  3. A worker thread runs `claude -p ... --output-format stream-json`,
     parses each JSONL event, and POSTs an envelope describing it to
     callback_url with callback_auth as the bearer.
  4. The device's /chat_event handler forwards the envelope to a Lua
     bus topic; the chat screen renders it incrementally.

Envelope kinds posted to callback_url:
  - {"request_id":..,"kind":"thinking","text":..}
  - {"request_id":..,"kind":"tool_use","name":..,"input":..}
  - {"request_id":..,"kind":"tool_result","is_error":..,"snippet":..}
  - {"request_id":..,"kind":"text","text":..}      (assistant text)
  - {"request_id":..,"kind":"done","text":..}      (final reply text)
  - {"request_id":..,"kind":"error","text":..}     (claude/cli failure)

Run:
    export CLAUDE_BOT_TOKEN=$(openssl rand -hex 8)
    python tools/dev/claude_wifi_bot.py

The bot prints the URL and bearer token at startup. Enter both into
Settings -> System -> Claude Bot on the device.

Conversation context is kept in memory; clear with --clear-memory or
restart the bot. Stdlib only (no Flask, no requests).
"""

import argparse
import http.client
import http.server
import json
import logging
import os
import re
import secrets
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import urlparse

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
MEMORY_PATH = Path("~/.cache/claude_wifi_bot.json").expanduser()
TOKEN_CACHE_PATH = Path("~/.cache/mesh_claude_bot.token").expanduser()  # shared with mesh bot
TOKEN_PATTERN = re.compile(r"\btoken\s*[:=]\s*([A-Z0-9]{6})\b", re.IGNORECASE)

CLAUDE_TIMEOUT = 600  # 10 min: a full edit + build + flash cycle
MAX_MEMORY_TURNS = 20
COMPACT_THRESHOLD = 30

logger = logging.getLogger("claude_wifi_bot")


# ---------------------------------------------------------------------------
# Conversation memory (mirrors mesh_claude_bot.py so multi-turn context
# survives across messages without a database)
# ---------------------------------------------------------------------------

class ConversationMemory:
    def __init__(self, path=MEMORY_PATH):
        self.path = path
        self.turns = []
        self.summary = ""
        self._lock = threading.Lock()
        self._load()

    def _load(self):
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                self.turns = data.get("turns", [])
                self.summary = data.get("summary", "")
            except (json.JSONDecodeError, OSError):
                self.turns = []
                self.summary = ""

    def _save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps({
            "turns": self.turns, "summary": self.summary,
        }))

    def add(self, role, text):
        with self._lock:
            self.turns.append({
                "role": role, "text": text, "time": int(time.time())
            })
            if len(self.turns) > COMPACT_THRESHOLD:
                self._compact_locked()
            self._save()

    def _compact_locked(self):
        # Keep the most recent MAX_MEMORY_TURNS verbatim, drop the rest.
        # Could call Claude to summarize here; for now we just trim --
        # losing very old context is preferable to paying tokens to
        # summarize on every run-away conversation.
        old = self.turns[: -MAX_MEMORY_TURNS]
        kept = self.turns[-MAX_MEMORY_TURNS:]
        if self.summary:
            self.summary += "\n[earlier]: " + " | ".join(
                t["text"][:80] for t in old
            )
        else:
            self.summary = "[earlier]: " + " | ".join(
                t["text"][:80] for t in old
            )
        self.turns = kept

    def build_context(self):
        # Format prior turns as a NARRATED recap rather than a literal
        # "User: ... / Assistant: ..." script. Claude was treating the
        # script form as a sequence to continue, hallucinating fake
        # follow-up user messages on top of its real reply. The narrated
        # form ("the user asked X, you did Y") makes the boundary clear:
        # this is history, not a template to extend.
        with self._lock:
            parts = []
            if self.summary:
                parts.append(f"Earlier summary: {self.summary}")
            for t in self.turns:
                # Trim stored text -- the recap is for context, not a
                # full transcript replay. The current message is what
                # Claude should actually respond to.
                snippet = t["text"]
                if len(snippet) > 400:
                    snippet = snippet[:400] + "..."
                if t["role"] == "user":
                    parts.append(f"- The user previously asked: {snippet}")
                else:
                    parts.append(f"- You previously replied: {snippet}")
            return "\n".join(parts)

    def clear(self):
        with self._lock:
            self.turns = []
            self.summary = ""
            try:
                self.path.unlink()
            except FileNotFoundError:
                pass


# ---------------------------------------------------------------------------
# OTA token sourcing -- mirrors the mesh bot so a `token: XXXXXX`
# update arriving over either transport is honored by both.
# ---------------------------------------------------------------------------

def current_ota_token():
    try:
        return TOKEN_CACHE_PATH.read_text().strip() or None
    except (OSError, FileNotFoundError):
        return None


def maybe_capture_token(text):
    m = TOKEN_PATTERN.search(text)
    if not m:
        return None
    new_token = m.group(1).upper()
    try:
        TOKEN_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        TOKEN_CACHE_PATH.write_text(new_token)
        logger.info(f"OTA token updated to {new_token}")
        return new_token
    except OSError as e:
        logger.warning(f"Could not write token cache: {e}")
        return None


def seed_token_cache():
    """Populate TOKEN_CACHE_PATH from MESH_OTA_TOKEN if it doesn't exist yet."""
    if TOKEN_CACHE_PATH.exists():
        return
    env = os.environ.get("MESH_OTA_TOKEN", "").strip()
    if not env:
        return
    try:
        TOKEN_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        TOKEN_CACHE_PATH.write_text(env)
    except OSError as e:
        logger.warning(f"Could not seed token cache: {e}")


# ---------------------------------------------------------------------------
# Claude invocation
# ---------------------------------------------------------------------------

def build_system_prompt(ota_host, context):
    """
    Built per-message. Two things go in here that previously belonged in
    the user prompt:
      * The recap of prior turns (so Claude sees history as a *narrated
        summary*, not a User:/Assistant: ladder it can continue).
      * Strong, directive instructions about ACTUALLY USING tools rather
        than describing them.
    """
    token = current_ota_token()

    # The directive section. Past iterations described commands and got
    # back narrated descriptions of edits ("[edits init.lua to add...]")
    # without any real Bash/Edit tool calls. The "DO NOT describe; DO IT"
    # framing below is doing the heavy lifting -- in our testing this is
    # what flips Claude from "summarize a plan" to "execute the plan".
    lines = [
        "ROLE",
        "You are this firmware repo's owner-operator, talking to the user "
        "from a chat screen on their T-Deck Plus over WiFi. Your job is "
        "to MAKE THE CHANGES they ask for and PUSH THEM VIA OTA. You have "
        "full Read/Edit/Write/Bash tool access and are running under "
        "--dangerously-skip-permissions, so no command needs approval.",
        "",
        "RULES (these are not negotiable)",
        "1. When the user requests a code change, USE the Edit/Write tools "
        "to modify files. Do NOT describe the change in prose, do NOT "
        "wrap the diff in [brackets] or pseudo-code. Make the edit.",
        "2. After editing, USE the Bash tool to run `pio run` from the "
        "project root. Verify the build succeeded (exit code 0).",
        "3. After a successful build, USE the Bash tool to run the OTA "
        "push command shown below. Verify exit code 0.",
        "4. ONLY THEN reply to the user. The reply describes WHAT YOU DID "
        "(files changed, build outcome, push outcome), not what you would "
        "do. Keep it brief -- the user is reading on a 320x240 screen.",
        "5. If a step fails, STOP and report the failure with the actual "
        "error from the tool. Do not invent fixes you didn't try.",
        "6. Never write a `User: ...` line in your reply -- you are not "
        "the user. Reply once, then stop.",
        "",
        "PROJECT",
        f"Project root: {PROJECT_ROOT} (already your cwd)",
        "Hardware: ESP32-S3 (LilyGo T-Deck Plus). C++ firmware in src/, "
        "Lua scripts in lua/. CLAUDE.md is authoritative for conventions; "
        "consult it before non-trivial edits.",
        "",
        "BUILD AND PUSH",
        "Build:    pio run",
        "Push OTA: python tools/dev/push_ota.py <ip> <token> "
        ".pio/build/t-deck-plus/firmware.bin",
        "Exit 0 from the push = firmware staged. The user must reboot to "
        "apply (a 'Firmware ready' toast appears on-device; Alt+Enter "
        "triggers the reboot).",
    ]

    if ota_host and token:
        lines += [
            "",
            "OTA TARGET (use these unless the user names a different one)",
            f"  IP:    {ota_host}",
            f"  Token: {token}",
            "If a push returns HTTP 401, the token rotated -- ask the "
            "user to send `token: XXXXXX` and try again (the bot picks "
            "the new token up automatically).",
        ]
    elif ota_host:
        lines += [
            "",
            "OTA TARGET",
            f"  IP:    {ota_host}",
            "  Token: not configured yet -- ask the user to send the "
            "token shown on the device's Dev OTA screen as `token: "
            "XXXXXX` before attempting a push.",
        ]
    else:
        lines += [
            "",
            "OTA TARGET: not configured. If the user asks for a push, "
            "ask them for the IP and token (from the device's Dev OTA "
            "screen) before attempting one.",
        ]

    if context:
        lines += [
            "",
            "EARLIER IN THIS CONVERSATION",
            context,
            "(The above is history. The user's current message is the "
            "only thing you are responding to right now.)",
        ]

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Streaming claude -> device pipeline
#
# We invoke `claude --output-format stream-json --verbose` so each event
# (thinking block, tool_use, tool_result, text chunk, final result) is
# emitted as one JSONL line on stdout. The translator below converts
# those raw events into the simpler envelope vocabulary the device
# renders. The poster sends each envelope to the device's /chat_event
# endpoint with the bearer the device handed us at request time.
# ---------------------------------------------------------------------------


def _post_envelope(callback_url, callback_auth, envelope):
    """
    Best-effort POST. We swallow most errors -- if the device drops
    one event the chat just looks slightly less complete; failing the
    whole turn over a transient network blip would be worse.
    """
    try:
        parsed = urlparse(callback_url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            return
        body = json.dumps(envelope).encode("utf-8")
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        cls = (http.client.HTTPSConnection if parsed.scheme == "https"
               else http.client.HTTPConnection)
        conn = cls(parsed.hostname, port, timeout=5)
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        headers = {
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
            "Connection": "close",
        }
        if callback_auth:
            headers["Authorization"] = callback_auth
        conn.request("POST", path, body, headers)
        resp = conn.getresponse()
        resp.read()
        conn.close()
    except (OSError, http.client.HTTPException) as e:
        logger.debug(f"chat_event post to {callback_url} failed: {e}")


def _translate_events(raw_event, request_id):
    """
    Map one raw stream-json event from the claude CLI to zero or more
    device-facing envelopes. The CLI's event vocabulary is richer than
    we want to render -- system/init events are useless to the user,
    multi-block assistant messages need to be flattened into one
    envelope per block. Anything we don't recognise gets dropped here
    rather than forwarded; the chat screen never has to know about CLI
    internals.
    """
    out = []
    etype = raw_event.get("type")

    if etype == "assistant":
        msg = raw_event.get("message", {}) or {}
        for block in msg.get("content") or []:
            btype = block.get("type")
            if btype == "text":
                txt = (block.get("text") or "").strip()
                if txt:
                    out.append({"request_id": request_id,
                                "kind": "text", "text": txt})
            elif btype == "thinking":
                txt = block.get("thinking") or block.get("text") or ""
                if txt.strip():
                    out.append({"request_id": request_id,
                                "kind": "thinking", "text": txt.strip()})
            elif btype == "tool_use":
                out.append({
                    "request_id": request_id,
                    "kind": "tool_use",
                    "name": block.get("name") or "?",
                    "input": block.get("input") or {},
                })

    elif etype == "user":
        # The CLI emits "user" events for tool_result deliveries (it's
        # framing them as the user-side of the tool call). Pull out the
        # result payload and forward as a tool_result envelope.
        msg = raw_event.get("message", {}) or {}
        for block in msg.get("content") or []:
            if block.get("type") != "tool_result":
                continue
            content = block.get("content")
            if isinstance(content, list):
                # Often a list of {type:"text", text:"..."} fragments.
                snippet = " ".join(
                    str(c.get("text", "")) for c in content
                    if isinstance(c, dict)
                ).strip()
            else:
                snippet = str(content or "").strip()
            if len(snippet) > 600:
                snippet = snippet[:600] + "..."
            out.append({
                "request_id": request_id,
                "kind": "tool_result",
                "is_error": bool(block.get("is_error")),
                "snippet": snippet,
            })

    elif etype == "result":
        # The terminal event of every successful run. Carries the final
        # consolidated assistant text -- we treat that as the canonical
        # reply for memory purposes (the streaming text envelopes the
        # device already saw add up to roughly the same thing, but
        # `result` is what the CLI considers authoritative).
        if raw_event.get("subtype") == "success":
            out.append({"request_id": request_id, "kind": "done",
                        "text": raw_event.get("result") or ""})
        else:
            out.append({"request_id": request_id, "kind": "error",
                        "text": raw_event.get("result") or "claude error"})

    # type=="system" init/etc -- intentionally ignored.
    return out


def stream_claude(message, request_id, memory, ota_host,
                  callback_url, callback_auth):
    """
    Run the claude CLI, stream events to the device, return the final
    assistant text (for memory persistence). Blocking; intended to be
    called from a worker thread.
    """
    system_prompt = build_system_prompt(ota_host, memory.build_context())

    def emit(envelope):
        if callback_url:
            _post_envelope(callback_url, callback_auth, envelope)

    try:
        proc = subprocess.Popen(
            [
                "claude", "-p", message,
                "--append-system-prompt", system_prompt,
                "--output-format", "stream-json",
                "--verbose",  # required by claude -p when stream-json
                # User explicitly asked for full bypass: this is a
                # personal dev bot running on the user's own machine
                # against their own firmware, not a public service.
                # Without this every Bash call (pio run, push_ota.py)
                # would prompt via the local CLI -- which the user
                # can't see from a chat session over WiFi.
                "--dangerously-skip-permissions",
            ],
            cwd=PROJECT_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # line-buffered so we see events as they arrive
        )
    except FileNotFoundError:
        logger.error("claude CLI not found")
        emit({"request_id": request_id, "kind": "error",
              "text": "claude CLI not installed on the host"})
        return None

    final_text = ""
    deadline = time.time() + CLAUDE_TIMEOUT

    try:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            if time.time() > deadline:
                proc.kill()
                emit({"request_id": request_id, "kind": "error",
                      "text": "claude timed out (>10 min)"})
                return None
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                # Some CLI versions interleave non-JSON status lines on
                # stdout; ignore those rather than failing the run.
                continue
            for envelope in _translate_events(event, request_id):
                emit(envelope)
                if envelope["kind"] == "done":
                    final_text = envelope.get("text") or final_text
        proc.wait(timeout=10)
    except Exception as e:
        logger.exception("stream_claude crashed")
        emit({"request_id": request_id, "kind": "error",
              "text": f"bot internal error: {e}"})
        try:
            proc.kill()
        except Exception:
            pass
        return None

    if proc.returncode != 0:
        stderr_tail = ""
        try:
            stderr_tail = (proc.stderr.read() or "").splitlines()[-1] \
                          if proc.stderr else ""
        except Exception:
            pass
        logger.error(
            f"claude rc={proc.returncode} stderr_tail={stderr_tail[:200]}")
        emit({"request_id": request_id, "kind": "error",
              "text": f"claude exited {proc.returncode}: "
                      f"{stderr_tail or 'no detail'}"})
        return None

    return final_text or None


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

class ChatHandler(http.server.BaseHTTPRequestHandler):
    # Force HTTP/1.1 in responses. Arduino-ESP32's HTTPClient hangs in
    # getString() against the BaseHTTPRequestHandler default (HTTP/1.0
    # + Connection: close) because it waits for a keep-alive frame
    # that never comes. With HTTP/1.1 + an explicit Content-Length the
    # client reads the body correctly and unblocks immediately.
    protocol_version = "HTTP/1.1"

    # Set on the server instance, read here.
    bot_token = None
    memory = None
    ota_host = None

    # Quieter logging -- the default BaseHTTPRequestHandler.log_message
    # writes to stderr for every request, which spams the terminal with
    # one line per chat turn. We log via the module logger instead.
    def log_message(self, fmt, *args):
        logger.info(f"{self.address_string()} - {fmt % args}")

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # Tell the client we're closing -- HTTP/1.1 defaults to
        # keep-alive, which would leave Arduino-ESP32's HTTPClient
        # waiting for the next request that never comes.
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _check_auth(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self._send_json(401, {"error": "missing token"})
            return False
        if auth[7:] != self.bot_token:
            self._send_json(401, {"error": "invalid token"})
            return False
        return True

    def do_GET(self):
        # /ping is unauthenticated so a host can sanity-check the bot
        # is up before configuring credentials. /chat requires auth.
        if self.path == "/ping":
            self._send_json(200, {"ok": True, "service": "claude_wifi_bot"})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self._check_auth():
            return
        if self.path != "/chat":
            self._send_json(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 64 * 1024:
            self._send_json(400, {"error": "missing or oversized body"})
            return

        try:
            raw = self.rfile.read(length).decode("utf-8")
            data = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"error": "bad JSON"})
            return

        message = (data.get("message") or "").strip()
        if not message:
            self._send_json(400, {"error": "empty message"})
            return

        # The device tells us where to send progress events. Both
        # callback_url and callback_auth come straight from the chat
        # screen, which knows its own IP and OTA bearer. If they're
        # missing we fall back to a non-streaming reply (the device
        # just sees a single 200 with the final text).
        callback_url = (data.get("callback_url") or "").strip() or None
        callback_auth = (data.get("callback_auth") or "").strip() or None

        # `token: XXX` short-circuit: update the cache and skip the
        # round trip to Claude entirely. Lets the user rotate the OTA
        # token without burning Claude tokens on a no-op.
        captured = maybe_capture_token(message)
        stripped = TOKEN_PATTERN.sub("", message).strip(" .,;-") if captured else message
        if captured and not stripped:
            self._send_json(200, {
                "reply": f"OK -- OTA token set to {captured}.",
                "request_id": "",
            })
            return

        actual = stripped if captured else message
        request_id = secrets.token_urlsafe(8)
        self.memory.add("user", actual)

        # Hand off to a worker thread and respond immediately. The
        # worker streams progress to callback_url; the device renders
        # those events incrementally on the chat screen.
        memory_ref = self.memory
        ota_host_ref = self.ota_host

        def worker():
            final = stream_claude(
                actual, request_id, memory_ref, ota_host_ref,
                callback_url, callback_auth,
            )
            if final:
                memory_ref.add("assistant", final)

        threading.Thread(target=worker, daemon=True).start()

        # 202 Accepted: we have not produced the answer yet, but we
        # have committed to producing one and the device can match
        # incoming events by request_id.
        self._send_json(202, {"request_id": request_id})


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    # Per-request thread so a long Claude call doesn't block other
    # requests (e.g. a /ping health check from another script).
    daemon_threads = True


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("CLAUDE_BOT_PORT", "8765")))
    ap.add_argument("--bind", default=os.environ.get("CLAUDE_BOT_BIND", "0.0.0.0"),
                    help="bind address (default 0.0.0.0)")
    ap.add_argument("--clear-memory", action="store_true",
                    help="wipe conversation history and exit")
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    memory = ConversationMemory()
    if args.clear_memory:
        memory.clear()
        print("Memory cleared.")
        return

    seed_token_cache()

    bot_token = os.environ.get("CLAUDE_BOT_TOKEN", "").strip()
    if not bot_token:
        bot_token = secrets.token_urlsafe(8).replace("_", "").replace("-", "")[:12].upper()

    ota_host = os.environ.get("MESH_OTA_HOST", "").strip() or None

    ChatHandler.bot_token = bot_token
    ChatHandler.memory = memory
    ChatHandler.ota_host = ota_host

    server = ThreadingHTTPServer((args.bind, args.port), ChatHandler)

    print(f"Claude WiFi bot listening on http://{args.bind}:{args.port}")
    print(f"Bearer token:  {bot_token}")
    print(f"Project root:  {PROJECT_ROOT}")
    print(f"OTA host:      {ota_host or '(not set; set MESH_OTA_HOST)'}")
    print(f"OTA token:     {current_ota_token() or '(not set; cache will pick up `token: XXX` DMs)'}")
    print()
    print("Configure on the T-Deck: Settings -> System -> Claude Bot")
    print(f"  URL:   http://<this-host-ip>:{args.port}")
    print(f"  Token: {bot_token}")
    print()
    print("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
        server.shutdown()


if __name__ == "__main__":
    main()
