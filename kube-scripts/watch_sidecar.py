#!/usr/bin/env python3
"""Observer sidecar for a sudo-letta agent pod.

Three jobs in one process (threads):

1. PROCESS MONITOR — poll /proc every ``poll_interval_sec``; shared PID
   namespace (``shareProcessNamespace: true``) exposes the agent container's
   processes (the pause container is PID 1). Appends ``process_state`` events
   on idle<->active transitions ("letta activity" = cmdline references letta).
2. CAPTURE — tail-follow every
   ``/home/node/.letta/lc-local-backend/conversations/*/messages.jsonl`` with
   persisted byte-offset watermarks (``<log_dir>/state.json``); normalize each
   message into events appended to ``<log_dir>/events.jsonl``.
   A file that shrinks (recreate/rotation) resets its watermark. Only complete
   lines are parsed (partial trailing line is buffered).
3. HTTP TAP — stdlib http.server (threaded) on WATCH_PORT (default 8000):

       GET /healthz     -> 200 OK
       GET /status       -> JSON snapshot
       GET /ps           -> JSON list of non-self processes
       GET /events?n=100 -> last N event lines verbatim (JSONL)
       GET /stream       -> live chunked tail of NEW events (flush per event)

Event schema — one JSON object per line in ``<log_dir>/events.jsonl``:

  common:  {"ts": <epoch float>, "conversation": "<decoded conv id>", "event": "<type>"}
  types:   "user" {text} | "thinking" {text} | "assistant" {text}
           "tool_call" {name, args} | "tool_result" {text, truncated, full_bytes}
           "session" {id, cwd} | "process_state" {state, processes}

Config: /etc/watch-config/config.json if present; env WATCH_PORT / AGENT_NAME /
DEPLOY_NAME override config. Defaults: log_dir /home/node/.letta/watch, poll 2s.
Writes ONLY under log_dir. stdlib only.
"""

import base64
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── Config ────────────────────────────────────────────────────────────────

DEFAULTS = {
    "agent_name": "",
    "deploy_name": "",
    "watch_port": 8000,
    "poll_interval_sec": 2,
    "log_dir": "/home/node/.letta/watch",
    "result_truncate_bytes": 4096,
    "capture": True,
}

CONV_ROOT = "/home/node/.letta/lc-local-backend/conversations"
SETTINGS_JSON = "/home/node/.letta/settings.json"
SETTINGS_KEY = "local:/home/node/.letta/lc-local-backend"

CONFIG = dict(DEFAULTS)
STATE = {
    "started": time.time(),
    "events_logged": 0,
    "last_event_ts": None,
    "current_conversation": None,
    "agent_container_up": False,
    "active": False,
    "last_process_state": None,  # "active" | "idle"
}
_LOCK = threading.Lock()  # guards events.jsonl appends + STATE counters


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open("/etc/watch-config/config.json") as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    if os.environ.get("WATCH_PORT"):
        try:
            cfg["watch_port"] = int(os.environ["WATCH_PORT"])
        except ValueError:
            pass
    if os.environ.get("AGENT_NAME"):
        cfg["agent_name"] = os.environ["AGENT_NAME"]
    if os.environ.get("DEPLOY_NAME"):
        cfg["deploy_name"] = os.environ["DEPLOY_NAME"]
    if os.environ.get("WATCH_LOG_DIR"):
        cfg["log_dir"] = os.environ["WATCH_LOG_DIR"]
    CONFIG.clear()
    CONFIG.update(cfg)


def events_path():
    return os.path.join(CONFIG["log_dir"], "events.jsonl")


def state_path():
    return os.path.join(CONFIG["log_dir"], "state.json")


def ensure_log_dir():
    try:
        os.makedirs(CONFIG["log_dir"], exist_ok=True)
    except OSError:
        pass  # unit tests monkeypatch paths; capture is best-effort


def append_event(event):
    """Append one event dict to events.jsonl; update STATE counters."""
    line = json.dumps(event, ensure_ascii=False)
    with _LOCK:
        ensure_log_dir()
        with open(events_path(), "a") as f:
            f.write(line + "\n")
        STATE["events_logged"] += 1
        STATE["last_event_ts"] = event.get("ts")


# ── Message-store capture ─────────────────────────────────────────────────

def load_watermarks():
    try:
        with open(state_path()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_watermarks(wm):
    tmp = state_path() + ".tmp"
    with open(tmp, "w") as f:
        json.dump(wm, f)
    os.replace(tmp, state_path())


def decode_conv_dir(dirname):
    """'Y29udmVyc...' -> 'conversation:local-conv-11' (best-effort)."""
    try:
        return base64.b64decode(dirname + "=" * (-len(dirname) % 4)).decode()
    except Exception:
        return dirname


def normalize_record(record, conversation):
    """Turn one messages.jsonl record into a list of events (may be empty).

    Record shapes (verified against a live pod):
      {"type":"session","version":N,"id":...,"timestamp":...,"cwd":...}
      {"type":"message","id":...,"timestamp":...,
       "message":{"role": user|assistant|toolResult, "content": [blocks...]}}
    """
    out = []
    ts = time.time()
    common = {"ts": ts, "conversation": conversation}
    if record.get("type") == "session":
        out.append(dict(common, event="session",
                        id=record.get("id"), cwd=record.get("cwd")))
        return out
    if record.get("type") != "message":
        return out
    msg = record.get("message") or {}
    role = msg.get("role")
    content = msg.get("content")
    if not isinstance(content, list):
        content = []
    if role == "user":
        for blk in content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                text = blk.get("text", "")
                is_reminder = "<system-reminder>" in text
                out.append(dict(common, event="user",
                                text=text, reminder=is_reminder))
    elif role == "assistant":
        for blk in content:
            if not isinstance(blk, dict):
                continue
            btype = blk.get("type")
            if btype == "thinking":
                out.append(dict(common, event="thinking",
                                text=blk.get("thinking", "")))
            elif btype == "toolCall":
                out.append(dict(common, event="tool_call",
                                name=blk.get("name"), args=blk.get("arguments")))
            elif btype == "text":
                out.append(dict(common, event="assistant",
                                text=blk.get("text", "")))
    elif role == "toolResult":
        for blk in content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                text = blk.get("text", "")
                full = len(text.encode("utf-8", "replace"))
                limit = int(CONFIG["result_truncate_bytes"])
                trunc = False
                if full > limit:
                    text = text.encode("utf-8", "replace")[:limit].decode(
                        "utf-8", "replace")
                    trunc = True
                out.append(dict(common, event="tool_result",
                                text=text, truncated=trunc, full_bytes=full))
    return out


def scan_conversation_files():
    """Map messages.jsonl path -> decoded conversation id."""
    found = {}
    try:
        entries = os.listdir(CONV_ROOT)
    except OSError:
        return found
    for d in entries:
        p = os.path.join(CONV_ROOT, d, "messages.jsonl")
        if os.path.isfile(p):
            found[p] = decode_conv_dir(d)
    return found


def capture_once(watermarks):
    """One tail-follow pass over every messages.jsonl; returns changed watermark dict."""
    changed = {}
    for path, conv in scan_conversation_files().items():
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        off = int(watermarks.get(path, 0))
        if size < off:
            off = 0  # file shrunk: recreate/rotation -> reset watermark
        if size == off:
            continue
        buf = b""
        try:
            with open(path, "rb") as f:
                f.seek(off)
                buf = f.read()
        except OSError:
            continue
        new_off = off + len(buf)
        if buf.endswith(b"\n"):
            complete, buf = buf, b""
        else:
            idx = buf.rfind(b"\n")
            if idx == -1:
                continue  # only a partial line so far; keep watermark, wait
            complete, buf = buf[: idx + 1], b""
            new_off = off + len(complete)
        for raw in complete.splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            for ev in normalize_record(rec, conv):
                append_event(ev)
        changed[path] = new_off
    return changed


def update_current_conversation():
    """Best-effort: read settings.json -> pinned conversationId."""
    try:
        with open(SETTINGS_JSON) as f:
            st = json.load(f)
        STATE["current_conversation"] = st["sessionsByServer"][SETTINGS_KEY][
            "conversationId"]
    except (OSError, ValueError, KeyError, TypeError):
        pass


def capture_loop():
    watermarks = load_watermarks()
    while True:
        changed = capture_once(watermarks)
        if changed:
            watermarks.update(changed)
            save_watermarks(watermarks)
        update_current_conversation()
        time.sleep(0.5)


# ── Process monitor ───────────────────────────────────────────────────────

def _read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def self_pid_tree():
    """Set of pids in our own tree (we + our threads + children)."""
    me = os.getpid()
    tree = {me}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        ppid = _read_file("/proc/%s/stat" % entry).split(")")[-1].split()[1]
        try:
            if int(ppid) in tree:
                tree.add(int(entry))
        except (IndexError, ValueError):
            pass
    return tree


def poll_processes():
    """Return (agent_up, letta_procs, all_procs) from one /proc scan."""
    mine = self_pid_tree()
    agent_up = False
    letta_procs = []
    all_procs = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid in mine:
            continue
        if pid == 1:
            continue  # pause container
        cmdline = _read_file("/proc/%s/cmdline" % entry).replace("\0", " ").strip()
        stat = _read_file("/proc/%s/stat" % entry)
        try:
            ppid = int(stat.split(")")[-1].split()[1])
        except (IndexError, ValueError):
            ppid = 0
        try:
            with open("/proc/%s/status" % entry) as f:
                uid = int(next(l for l in f if l.startswith("Uid:")).split()[1])
        except (OSError, StopIteration, ValueError):
            uid = -1
        try:
            age = time.time() - os.path.getmtime("/proc/%s" % entry)
        except OSError:
            age = 0.0
        if not cmdline:
            # kernel threads shouldn't appear in a container, but be safe
            continue
        agent_up = True
        proc = {"pid": pid, "ppid": ppid, "uid": uid,
                "age_s": round(age, 1), "cmdline": cmdline[:300]}
        all_procs.append(proc)
        if "letta" in cmdline.lower():
            letta_procs.append(proc)
    return agent_up, letta_procs, all_procs


def monitor_loop():
    interval = float(CONFIG["poll_interval_sec"])
    while True:
        agent_up, letta_procs, all_procs = poll_processes()
        STATE["agent_container_up"] = agent_up
        active = bool(letta_procs)
        STATE["active"] = active
        state_str = "active" if active else "idle"
        if state_str != STATE["last_process_state"]:
            STATE["last_process_state"] = state_str
            append_event({
                "ts": time.time(),
                "conversation": STATE["current_conversation"] or "",
                "event": "process_state",
                "state": state_str,
                "processes": [{"pid": p["pid"], "cmdline": p["cmdline"]}
                              for p in letta_procs],
            })
        time.sleep(interval)


# ── HTTP tap ──────────────────────────────────────────────────────────────

class TapHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "letta-watch/1.0"

    def log_message(self, fmt, *args):  # quiet
        pass

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, obj):
        self._send(200, json.dumps(obj, indent=2), "application/json")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._send(200, "OK\n")
        elif path == "/status":
            self._send_json({
                "agent": CONFIG["agent_name"],
                "deploy": CONFIG["deploy_name"],
                "uptime_s": round(time.time() - STATE["started"], 1),
                "agent_container_up": STATE["agent_container_up"],
                "active": STATE["active"],
                "current_conversation": STATE["current_conversation"],
                "last_event_ts": STATE["last_event_ts"],
                "events_logged": STATE["events_logged"],
                "watch_port": CONFIG["watch_port"],
            })
        elif path == "/ps":
            _, _, procs = poll_processes()
            self._send_json(procs)
        elif path == "/events":
            n = 100
            if "?" in self.path:
                for pair in self.path.split("?", 1)[1].split("&"):
                    if pair.startswith("n="):
                        try:
                            n = int(pair[2:])
                        except ValueError:
                            pass
            try:
                with open(events_path()) as f:
                    lines = f.readlines()
            except OSError:
                lines = []
            self._send(200, "".join(lines[-n:]), "application/x-ndjson")
        elif path == "/stream":
            self.stream()
        else:
            self._send(404, "not found\n")

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            with open(events_path()) as f:
                f.seek(0, 2)  # only NEW events
                while True:
                    line = f.readline()
                    if line:
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(line), line.encode()))
                        self.wfile.flush()
                    else:
                        time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def http_server():
    srv = ThreadingHTTPServer(("0.0.0.0", int(CONFIG["watch_port"])), TapHandler)
    srv.daemon_threads = True
    srv.serve_forever()


# ── Main ─────────────────────────────────────────────────────────────────

def main():
    load_config()
    os.makedirs(CONFIG["log_dir"], exist_ok=True)
    threads = [
        threading.Thread(target=capture_loop, daemon=True),
        threading.Thread(target=monitor_loop, daemon=True),
        threading.Thread(target=http_server, daemon=True),
    ]
    for t in threads:
        t.start()
    # keep the main thread alive; if a worker dies, exit so k3s restarts us
    while True:
        if not all(t.is_alive() for t in threads):
            raise SystemExit("worker thread died")
        time.sleep(5)


if __name__ == "__main__":
    main()
