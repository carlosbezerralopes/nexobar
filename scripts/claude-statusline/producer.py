#!/usr/bin/env python3
"""Claude statusLine stdin -> quota-only NexoBar receipt. Python 3.11+, stdlib.

Never invokes Claude, authenticates, or persists the input. Missing windows replace
previous windows. The timestamp dates delivery by the CLI, not a remote request.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading

MAX_INPUT = 1024 * 1024
MAX_RECEIPT = 16 * 1024
MAX_CHAIN_OUTPUT = 64 * 1024
RESET_RANGE = (1_000_000_000, 4_102_444_800)


def default_output():
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA")
        if not base:
            raise ValueError("LOCALAPPDATA unavailable")
        return Path(base) / "NexoBar" / "claude-statusline.json"
    return Path.home() / "Library/Application Support/NexoBar/claude-statusline.json"


def number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def receipt(raw, now=None):
    now = now or datetime.now(timezone.utc)
    if len(raw) > MAX_INPUT:
        raise ValueError("input size")
    root = json.loads(raw)
    if not isinstance(root, dict):
        raise ValueError("input object")
    limits = root.get("rate_limits")
    limits = limits if isinstance(limits, dict) else {}
    windows = []
    for source, identifier in [("five_hour", "session"), ("seven_day", "weekly_all")]:
        row = limits.get(source)
        if not isinstance(row, dict):
            continue
        used = row.get("used_percentage")
        if not number(used) or not 0 <= used <= 100:
            continue
        reset = row.get("resets_at")
        if reset is not None:
            if not number(reset) or not RESET_RANGE[0] <= reset <= RESET_RANGE[1]:
                continue
            if reset <= now.timestamp():
                continue
        windows.append({"id": identifier, "usedPercent": used, "resetsAt": reset})
    return {"schemaVersion": 1, "provider": "claude",
            "capturedAt": now.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "windows": windows}


def atomic_write(path, data, cap=MAX_RECEIPT):
    if len(data) > cap:
        raise ValueError("output size")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError("symlink destination")
    fd, name = tempfile.mkstemp(prefix=".nexobar-", dir=path.parent)
    try:
        if os.name != "nt":
            os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode()


def chain(raw, config, timeout=2.0):
    """Forward original stdin/output only in RAM; bound time and output together."""
    args = config["argv"]
    if not isinstance(args, list) or not args or not all(isinstance(a, str) for a in args):
        raise ValueError("chain command")
    flags = {"start_new_session": True} if os.name != "nt" else {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, **flags)
    output = bytearray()
    overflow = threading.Event()

    def receive():
        while True:
            chunk = process.stdout.read(4096)
            if not chunk:
                return
            if len(output) + len(chunk) > MAX_CHAIN_OUTPUT:
                overflow.set()
                process.kill()
                return
            output.extend(chunk)

    def send():
        try:
            process.stdin.write(raw)
            process.stdin.close()
        except (BrokenPipeError, OSError):
            pass

    reader = threading.Thread(target=receive, daemon=True)
    writer = threading.Thread(target=send, daemon=True)
    reader.start()
    writer.start()
    try:
        process.wait(timeout=timeout)
        reader.join(timeout=max(0.01, timeout))
        if reader.is_alive() or overflow.is_set():
            raise ValueError("chain output")
        return bytes(output), process.returncode
    finally:
        # Reap descendants even if the shell exits before a child closes stdout.
        if os.name != "nt":
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        elif process.poll() is None:
            # taskkill is the Windows process-tree primitive; stdin contains no data.
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        if process.poll() is None:
            process.kill()
        process.wait()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--chain-config", type=Path)
    args = parser.parse_args(argv)
    raw = sys.stdin.buffer.read(MAX_INPUT + 1)
    result = None
    try:
        result = receipt(raw)
        atomic_write(args.output or default_output(), encode(result))
    except (OSError, ValueError, TypeError, RecursionError):
        # A malformed event cannot keep a previously valid receipt looking current.
        try:
            atomic_write(args.output or default_output(), encode(receipt(b"{}")))
        except (OSError, ValueError):
            pass
    if len(raw) > MAX_INPUT:
        return 1
    if args.chain_config:
        try:
            with args.chain_config.open("rb") as stream:
                config = json.loads(stream.read(MAX_RECEIPT + 1))
            output, code = chain(raw, config)
            sys.stdout.buffer.write(output)
            return code if code >= 0 else 1
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            return 1
    if result is not None:
        parts = [("5h" if w["id"] == "session" else "7d") + f' {w["usedPercent"]:g}%'
                 for w in result["windows"]]
        print("Claude · " + (" · ".join(parts) if parts else "cotas indisponíveis"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
