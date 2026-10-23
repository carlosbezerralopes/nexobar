#!/usr/bin/env python3
"""Prepare/review/apply/uninstall only Claude's statusLine field; Python 3.11+.

Default prepare has no global effects. Settings are read to extract statusLine;
only that field is saved in the plan/receipt. No session or auth file is read.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import sys

from producer import MAX_RECEIPT, atomic_write, encode

MAX_SETTINGS = 4 * 1024 * 1024


def default_destination():
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA")
        if not base:
            raise ValueError("LOCALAPPDATA unavailable")
        return Path(base) / "NexoBar/integrations/claude-statusline"
    return Path.home() / "Library/Application Support/NexoBar/integrations/claude-statusline"


def read_json(path, cap=MAX_SETTINGS):
    with Path(path).open("rb") as stream:
        data = stream.read(cap + 1)
    if len(data) > cap:
        raise ValueError("file size")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("object required")
    return value


def settings_at(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("settings symlink refused")
    return read_json(path) if path.exists() else {}


def field(root):
    return {"present": "statusLine" in root, "value": root.get("statusLine")}


def digest(value):
    return hashlib.sha256(encode(value)).hexdigest()


def shell_command(argv, shell):
    if shell == "posix":
        return shlex.join([str(a).replace("\\", "/") for a in argv])
    return "& " + " ".join("'" + str(a).replace("\\", "/").replace("'", "''") + "'" for a in argv)


def prepare(settings, destination, directory, interpreter, shell, shell_executable, chain_existing=False):
    settings, destination, directory = [Path(p).expanduser().absolute() for p in (settings, destination, directory)]
    root = settings_at(settings)
    previous = field(root)
    existing = previous["value"]
    if previous["present"]:
        if not chain_existing:
            raise ValueError("statusLine exists: review it and explicitly choose --chain-existing")
        if not isinstance(existing, dict) or existing.get("type") != "command" or not isinstance(existing.get("command"), str) or not existing["command"].strip():
            raise ValueError("existing statusLine is not a supported command; no change")
    if directory.exists() and any(directory.iterdir()):
        raise ValueError("review directory must be empty")
    if destination.exists():
        raise ValueError("installation directory already exists; uninstall/review first")
    source = Path(__file__).with_name("producer.py").read_bytes()
    proposed = copy.deepcopy(existing) if previous["present"] else {"type": "command"}
    args = [str(Path(interpreter).absolute()), str(destination / "producer.py")]
    chain_config = None
    if previous["present"]:
        if not shell_executable:
            raise ValueError("--shell-executable is required for explicit chaining")
        executable = str(Path(shell_executable).absolute())
        chain_args = [executable, "-c", existing["command"]] if shell == "posix" else [executable, "-NoProfile", "-NonInteractive", "-Command", existing["command"]]
        chain_config = {"argv": chain_args}
        if len(encode(chain_config)) > MAX_RECEIPT:
            raise ValueError("existing command exceeds chaining size limit")
        args += ["--chain-config", str(destination / "chain.json")]
    proposed["command"] = shell_command(args, shell)
    plan = {"version": 1, "settings": str(settings), "destination": str(destination),
            "previous": previous, "proposed": proposed, "chain": chain_config,
            "producerSHA256": hashlib.sha256(source).hexdigest(), "shell": shell}
    directory.mkdir(parents=True, exist_ok=True)
    atomic_write(directory / "producer.py", source, cap=MAX_SETTINGS)
    atomic_write(directory / "plan.json", encode(plan), cap=MAX_SETTINGS)
    diff = {"statusLine": {"before": previous, "after": {"present": True, "value": proposed}}}
    atomic_write(directory / "statusLine.diff.json", encode(diff), cap=MAX_SETTINGS)
    return plan, digest(plan)


def apply(plan_path, expected_digest):
    plan_path = Path(plan_path)
    plan = read_json(plan_path)
    if plan.get("version") != 1 or digest(plan) != expected_digest:
        raise ValueError("review digest differs")
    source = plan_path.with_name("producer.py").read_bytes()
    if hashlib.sha256(source).hexdigest() != plan["producerSHA256"]:
        raise ValueError("producer changed after review")
    settings = Path(plan["settings"])
    root = settings_at(settings)
    if field(root) != plan["previous"]:
        raise ValueError("statusLine changed after review; prepare again")
    destination = Path(plan["destination"])
    if destination.exists():
        raise ValueError("installation directory exists")
    destination.mkdir(parents=True, mode=0o700)
    atomic_write(destination / "producer.py", source, cap=MAX_SETTINGS)
    if plan["chain"] is not None:
        atomic_write(destination / "chain.json", encode(plan["chain"]), cap=MAX_SETTINGS)
    receipt = {"version": 1, "settings": str(settings), "previous": plan["previous"],
               "installed": plan["proposed"], "reviewDigest": expected_digest}
    atomic_write(destination / "receipt.json", encode(receipt), cap=MAX_SETTINGS)
    # Re-read immediately before merging so edits to all other settings survive.
    current = settings_at(settings)
    if field(current) != plan["previous"]:
        raise ValueError("statusLine changed during installation; settings untouched")
    current["statusLine"] = plan["proposed"]
    atomic_write(settings, encode(current), cap=MAX_SETTINGS)
    if settings_at(settings) != current:
        raise ValueError("settings readback differs; inspect before retry")
    if read_json(destination / "receipt.json") != receipt:
        raise ValueError("receipt readback differs; inspect before retry")
    return destination / "receipt.json"


def uninstall(receipt_path):
    receipt = read_json(receipt_path)
    if receipt.get("version") != 1:
        raise ValueError("receipt version")
    settings = Path(receipt["settings"])
    current = settings_at(settings)
    if field(current) != {"present": True, "value": receipt["installed"]}:
        raise ValueError("statusLine changed since installation; no change")
    previous = receipt["previous"]
    if previous["present"]:
        current["statusLine"] = previous["value"]
    else:
        current.pop("statusLine", None)
    atomic_write(settings, encode(current), cap=MAX_SETTINGS)
    if settings_at(settings) != current:
        raise ValueError("uninstall readback differs; inspect before retry")
    # Keep the narrowly scoped receipt for review; no arbitrary directory deletion.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    prep = modes.add_parser("prepare", help="dry run; writes review files only")
    prep.add_argument("--settings", type=Path, default=Path.home() / ".claude/settings.json")
    prep.add_argument("--destination", type=Path, help="default: NexoBar application data/integrations/claude-statusline")
    prep.add_argument("--directory", type=Path, required=True)
    prep.add_argument("--python", default=sys.executable)
    prep.add_argument("--shell", choices=["posix", "powershell"], default="posix" if os.name != "nt" else None,
                      help="Windows: explicitly choose posix (Git Bash) or powershell (7+)")
    prep.add_argument("--shell-executable", help="actual Git Bash/sh or PowerShell 7 path, for existing command")
    prep.add_argument("--chain-existing", action="store_true")
    run = modes.add_parser("apply", help="explicitly apply a reviewed plan")
    run.add_argument("--plan", type=Path, required=True)
    run.add_argument("--expected-digest", required=True)
    undo = modes.add_parser("uninstall", help="restore only the unchanged installed field")
    undo.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            if args.shell is None:
                raise ValueError("Windows requires explicit --shell posix or powershell")
            _, checksum = prepare(args.settings, args.destination or default_destination(), args.directory, args.python,
                                  args.shell, args.shell_executable, args.chain_existing)
            print("Prepared only. Review statusLine.diff.json and producer.py. Digest: " + checksum)
        elif args.mode == "apply":
            print("Applied; field-only receipt: " + str(apply(args.plan, args.expected_digest)))
        else:
            uninstall(args.receipt)
            print("Previous statusLine restored; other settings preserved.")
        return 0
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as error:
        # Do not echo arbitrary input/JSON errors, which may contain settings text.
        print("Refused: " + (str(error) if type(error) is ValueError else type(error).__name__), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
