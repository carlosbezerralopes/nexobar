#!/usr/bin/env python3
"""Offline publication audit, Python 3.10+, no dependencies or content excerpts.

Exit 0: no blockers (review warnings); 1: blockers; 2: input/read failure.
Writes only the explicitly requested report outside the audited directory.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


GENERATED = frozenset({".git", ".build", ".swiftpm", "build", "dist", "bin", "obj",
                       "__pycache__", "node_modules", ".venv", "venv", ".vs",
                       ".pytest_cache", ".mypy_cache", ".ruff_cache"})
SENSITIVE_NAMES = re.compile(
    r"^(?:\.env(?:\..+)?|auth\.json|credentials(?:\..+)?\.json|"
    r"client_secret.*\.json|cookies?(?:\..+)?|\.netrc|\.npmrc|id_(?:rsa|ed25519|ecdsa)|"
    r".*\.(?:pem|key|p12|pfx|keychain(?:-db)?|sqlite(?:3)?|db|session|jsonl))$", re.I)
RULES = [
    ("private-key", "block", re.compile(r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")),
    ("provider-token", "block", re.compile(
        r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|"
        r"sk-(?:ant-api\d+-|proj-|svcacct-)?[A-Za-z0-9_-]{24,}|"
        r"(?:AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,}|"
        r"AIza[A-Za-z0-9_-]{30,})\b")),
    ("jwt", "block", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("url-userinfo", "block", re.compile(r"https?://[^\s/<>\"']+:[^\s/<>\"']+@", re.I)),
    ("personal-absolute-path", "warning", re.compile(r"(?:/Users/[^/\s\"']+|/home/[^/\s\"']+|[A-Z]:\\\\?Users\\\\?[^\\\s\"']+)", re.I)),
    ("private-network-address", "warning", re.compile(r"\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b")),
    ("cloud-synced-path", "warning", re.compile(r"\bOneDrive(?:-[\w-]+)?\b", re.I)),
    ("email-address", "warning", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
]
ASSIGNMENT = re.compile(r'''(?i)(?:["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|client[_-]?secret|csrf[_-]?token)["']?)\s*[:=]\s*["']([^"'\r\n]{8,})["']''')
PLACEHOLDER = re.compile(r"(?i)(?:example|fixture|dummy|placeholder|redacted|private_secret|only-in-memory|your[-_]|test[-_]|<[^>]+>)")


def git(root: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    if result.returncode:
        raise ValueError("Git operation failed; no stderr or content copied into report")
    return result.stdout


def entropy(value: str) -> float:
    return -sum((n / len(value)) * math.log2(n / len(value))
                for n in collections.Counter(value).values())


def safe_relative(raw: str) -> str:
    path = PurePosixPath(raw.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or not path.parts or ":" in path.parts[0]:
        raise ValueError("Manifest paths must be relative and remain inside root")
    return path.as_posix()


def select(root: Path, mode: str, manifest: Path | None):
    excluded = []
    if mode == "tree":
        selected = []
        def walk_error(error):
            raise OSError("Cannot enumerate a selected directory") from error
        for base, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
            for name in sorted(dirs[:]):
                path = Path(base, name)
                if name in GENERATED:
                    excluded.append({"path":path.relative_to(root).as_posix(), "reason":"generated-directory"})
                    dirs.remove(name)
                elif path.is_symlink():
                    selected.append(path.relative_to(root).as_posix())
                    dirs.remove(name)
            selected.extend(Path(base, name).relative_to(root).as_posix() for name in files)
    elif mode == "manifest":
        if manifest is None:
            raise ValueError("--manifest required")
        selected = json.loads(manifest.read_text(encoding="utf-8"))
        if not isinstance(selected, list) or not all(isinstance(p, str) for p in selected):
            raise ValueError("Manifest must be a JSON string array")
    else:
        top = Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve()
        if not os.path.samefile(top, root):
            raise ValueError("Git root must equal --root to avoid auditing an ancestor repository")
        command = ("ls-files", "-z") if mode == "tracked" else ("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
        selected = [s.decode("utf-8") for s in git(root, *command).split(b"\0") if s]
    return sorted({safe_relative(p) for p in selected}), excluded


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--mode", choices=["tree", "tracked", "staged", "manifest"], default="tree")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root, output = args.root.resolve(), args.output.resolve()
    if not root.is_dir() or output == root or root in output.parents:
        parser.error("Root must exist; report must be outside audited root")
    report = {"schema":1, "utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "mode":args.mode, "coverage":"Selected current files only; no Git history, no archive expansion, no image OCR",
              "inventory":[], "excluded":[], "findings":[], "errors":[]}
    findings = report["findings"]
    def add(path, category, severity, line=0, fixture=False):
        findings.append({"path":path, "line":line, "category":category,
                         "severity":severity, "fixture_candidate":fixture, "value":"[REDACTED]"})
    try:
        paths, report["excluded"] = select(root, args.mode, args.manifest)
        staged_links = set()
        if args.mode == "staged":
            staged_links = {row.split(b"\t", 1)[1].decode("utf-8") for row in git(root, "ls-files", "--stage", "-z").split(b"\0") if row.startswith(b"120000 ")}
        for relative in paths:
            path = root / relative
            if relative in staged_links or path.is_symlink() or any(p.is_symlink() for p in path.parents if p != root and root in p.parents):
                add(relative, "symlink-not-followed", "block")
                report["inventory"].append({"path":relative, "kind":"symlink", "scanned":False})
                continue
            if root not in path.resolve().parents:
                raise ValueError("Selected file escapes root")
            if SENSITIVE_NAMES.match(path.name) and path.name not in {".env.example", ".env.sample"}:
                add(relative, "sensitive-file-name", "block")
            if set(PurePosixPath(relative).parts) & {".codex", ".claude", ".kiro", ".gemini"}:
                add(relative, "client-session-directory", "block")
            try:
                data = git(root, "show", ":" + relative) if args.mode == "staged" else path.read_bytes()
            except (OSError, ValueError):
                report["errors"].append({"path":relative, "category":"unreadable"})
                continue
            binary = b"\0" in data or path.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".zip", ".pdf", ".exe", ".dll"}
            record = {"path":relative, "bytes":len(data), "sha256":hashlib.sha256(data).hexdigest(), "kind":"binary" if binary else "text", "scanned":True}
            report["inventory"].append(record)
            if data.startswith((b"\xff\xfe", b"\xfe\xff")):
                text = data.decode("utf-16", errors="replace")
                record["kind"] = "text-utf16"
            elif binary:
                add(relative, "binary-manual-review", "warning")
                if path.suffix.lower() in {".zip", ".exe", ".dll", ".pfx", ".p12"}:
                    add(relative, "distribution-or-sensitive-binary", "block")
                # Still detect ASCII token/key markers embedded in binary without displaying bytes.
                text = data.decode("utf-8", errors="replace")
            else:
                try:
                    text = data.decode("utf-8-sig")
                except UnicodeDecodeError:
                    add(relative, "non-utf8-manual-review", "warning")
                    text = data.decode("utf-8", errors="replace")
            fixture_file = bool(re.search(r"(?:^|/)(?:tests?|fixtures?)(?:/|_)|Tests/", relative, re.I))
            for line_number, line in enumerate(text.splitlines(), 1):
                for category, severity, pattern in RULES:
                    for match in pattern.finditer(line):
                        if category == "private-network-address":
                            try:
                                ipaddress.ip_address(match.group())
                            except ValueError:
                                continue
                        candidate = fixture_file and category == "url-userinfo" and "user:password@" in match.group()
                        add(relative, category, "warning" if candidate else severity, line_number, candidate)
                for match in ASSIGNMENT.finditer(line):
                    value = match.group(1)
                    if len(value) >= 16 and entropy(value) >= 3.5 and re.search(r"[A-Za-z]", value) and re.search(r"[0-9]", value):
                        candidate = fixture_file and bool(PLACEHOLDER.search(value))
                        add(relative, "high-entropy-secret-assignment", "warning" if candidate else "block", line_number, candidate)
    except (OSError, ValueError, json.JSONDecodeError):
        report["errors"].append({"category":"invalid-input-or-selection", "value":"[REDACTED]"})
    report["summary"] = {"files":len(report["inventory"]), "bytes":sum(p.get("bytes",0) for p in report["inventory"]),
                         "excluded_directories":len(report["excluded"]), "blockers":sum(f["severity"] == "block" for f in findings),
                         "warnings":sum(f["severity"] == "warning" for f in findings), "errors":len(report["errors"])}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps(report["summary"], sort_keys=True))
    return 2 if report["errors"] else 1 if report["summary"]["blockers"] else 0


if __name__ == "__main__":
    sys.exit(main())
