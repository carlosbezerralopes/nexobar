"""Offline fixtures only. Never invokes Claude or touches real user settings."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import install
import producer


NOW = datetime(2026, 10, 23, 12, tzinfo=timezone.utc)


class ProducerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nexobar-statusline-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def event(self, **limits):
        return json.dumps({"rate_limits": limits, "session_id": "private-session",
                           "account_id": "private-account", "prompt": "PRIVATE_PROMPT",
                           "api_key": "PRIVATE_SECRET"}).encode()

    def test_allowlist_percentage_zero_and_independent_windows(self):
        result = producer.receipt(self.event(seven_day={"used_percentage": 0}), NOW)
        self.assertEqual(result["windows"], [{"id": "weekly_all", "usedPercent": 0, "resetsAt": None}])
        self.assertEqual(set(result), {"schemaVersion", "provider", "capturedAt", "windows"})
        self.assertEqual(result["capturedAt"], "2026-10-23T12:00:00.000Z")
        for private in ["private-session", "private-account", "PRIVATE_PROMPT", "PRIVATE_SECRET", "account_id"]:
            self.assertNotIn(private, producer.encode(result).decode())

    def test_missing_window_erases_previous_instead_of_reusing_it(self):
        output = self.root / "out/receipt.json"
        for raw in [self.event(five_hour={"used_percentage": 31}), self.event(seven_day={"used_percentage": 17}), b"{}"]:
            producer.atomic_write(output, producer.encode(producer.receipt(raw, NOW)))
            saved = json.loads(output.read_bytes())
            self.assertEqual(saved, producer.receipt(raw, NOW))
        self.assertEqual(saved["windows"], [])

    def test_bad_values_are_never_zero_and_expired_window_disappears(self):
        for value in [None, False, True, "0", -1, 101, float("nan"), float("inf"), 10**500]:
            self.assertEqual(producer.receipt(self.event(five_hour={"used_percentage": value}), NOW)["windows"], [])
        for reset in [NOW.timestamp(), NOW.timestamp()-1, "tomorrow", True, 1, NOW.timestamp()*1000]:
            self.assertEqual(producer.receipt(self.event(five_hour={"used_percentage": 30, "resets_at": reset}), NOW)["windows"], [])
        future = NOW.timestamp() + 300
        result = producer.receipt(self.event(five_hour={"used_percentage": 30.2, "resets_at": future},
                                            spend_limit={"used_percentage": 99}), NOW)
        self.assertEqual(len(result["windows"]), 1)
        self.assertEqual(result["windows"][0]["resetsAt"], future)

    def test_atomic_bounded_private_write_and_symlink_refusal(self):
        output = self.root / "receipt.json"
        producer.atomic_write(output, b"{}")
        self.assertEqual(output.read_bytes(), b"{}")
        if os.name != "nt":
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            link = self.root / "link.json"
            link.symlink_to(output)
            with self.assertRaises(ValueError):
                producer.atomic_write(link, b"changed")
        with self.assertRaises(ValueError):
            producer.atomic_write(output, b"x" * (producer.MAX_RECEIPT + 1))
        self.assertEqual(output.read_bytes(), b"{}")
        self.assertFalse(list(self.root.glob(".nexobar-*")))

    def test_malformed_and_oversized_input_are_refused(self):
        for raw in [b"{", b"[]", b"null", b"x" * (producer.MAX_INPUT + 1)]:
            with self.assertRaises((ValueError, TypeError)):
                producer.receipt(raw, NOW)

    def test_platform_paths_are_independent(self):
        with patch.object(producer.sys, "platform", "win32"), patch.dict(os.environ, {"LOCALAPPDATA": str(self.root)}):
            self.assertEqual(producer.default_output(), self.root / "NexoBar/claude-statusline.json")
        with patch.object(producer.sys, "platform", "darwin"), patch.object(producer.Path, "home", return_value=self.root):
            self.assertEqual(producer.default_output(), self.root / "Library/Application Support/NexoBar/claude-statusline.json")

    def test_executable_only_persists_allowlisted_receipt_and_no_raw_stdin(self):
        output = self.root / "receipt.json"
        raw = self.event(five_hour={"used_percentage": 0})
        result = subprocess.run([sys.executable, producer.__file__, "--output", str(output)], input=raw,
                                capture_output=True, timeout=5, check=True)
        self.assertIn(b"5h 0%", result.stdout)
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"PRIVATE", path.read_bytes())
        subprocess.run([sys.executable, producer.__file__, "--output", str(output)], input=b"malformed",
                       capture_output=True, timeout=5, check=True)
        self.assertEqual(json.loads(output.read_bytes())["windows"], [])
        result = subprocess.run([sys.executable, producer.__file__, "--output", str(output)],
                                input=b"x" * (producer.MAX_INPUT + 1), capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(output.read_bytes())["windows"], [])

    def test_chain_preserves_exact_input_and_output_in_memory(self):
        raw = b'{"secret":"only-in-memory"}\n'
        args = [sys.executable, "-c", "import sys;sys.stdout.buffer.write(sys.stdin.buffer.read())"]
        output, code = producer.chain(raw, {"argv": args})
        self.assertEqual(output, raw)
        self.assertEqual(code, 0)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_chain_timeout_and_output_cap(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            producer.chain(b"{}", {"argv": [sys.executable, "-c", "import time;time.sleep(10)"]}, timeout=0.1)
        with self.assertRaises(ValueError):
            producer.chain(b"{}", {"argv": [sys.executable, "-c", "import sys;sys.stdout.write('x'*70000)"]})


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nexobar-installer-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.settings = self.root / "settings.json"
        self.destination = self.root / "stable-install"
        self.review = self.root / "review"
        self.original = {"model": "preserved", "hooks": {"x": "PRIVATE_OTHER_SETTING"}, "permissions": {"allow": ["Read"]}}
        self.settings.write_text(json.dumps(self.original))

    def prepare(self, chain=False, shell_executable=None):
        return install.prepare(self.settings, self.destination, self.review, sys.executable,
                               "posix", shell_executable, chain)

    def test_prepare_has_no_global_effect_or_unrelated_settings_backup(self):
        before = self.settings.read_bytes()
        plan, checksum = self.prepare()
        self.assertEqual(before, self.settings.read_bytes())
        self.assertFalse(self.destination.exists())
        self.assertEqual(checksum, install.digest(plan))
        for file in self.review.iterdir():
            self.assertNotIn(b"PRIVATE_OTHER_SETTING", file.read_bytes())
        self.assertEqual(plan["previous"], {"present": False, "value": None})

    def test_apply_and_uninstall_preserve_other_settings_even_if_changed_since_prepare(self):
        plan, checksum = self.prepare()
        changed = {**self.original, "new_setting": 10}
        self.settings.write_text(json.dumps(changed))
        receipt = install.apply(self.review / "plan.json", checksum)
        current = json.loads(self.settings.read_bytes())
        self.assertEqual(current.pop("statusLine"), plan["proposed"])
        self.assertEqual(current, changed)
        self.assertEqual(hashlib.sha256((self.destination / "producer.py").read_bytes()).hexdigest(), plan["producerSHA256"])
        changed["another_setting"] = True
        self.settings.write_text(json.dumps({**changed, "statusLine": plan["proposed"]}))
        install.uninstall(receipt)
        self.assertEqual(json.loads(self.settings.read_bytes()), changed)

    def test_existing_command_requires_explicit_chaining_and_preserves_all_fields(self):
        original_status = {"type": "command", "command": "printf 'previous'", "padding": 2, "refreshInterval": 10}
        self.settings.write_text(json.dumps({**self.original, "statusLine": original_status}))
        with self.assertRaises(ValueError):
            self.prepare()
        plan, checksum = self.prepare(chain=True, shell_executable="/bin/sh")
        self.assertEqual(plan["proposed"]["padding"], 2)
        self.assertEqual(plan["proposed"]["refreshInterval"], 10)
        self.assertEqual(plan["previous"]["value"], original_status)
        receipt = install.apply(self.review / "plan.json", checksum)
        install.uninstall(receipt)
        self.assertEqual(json.loads(self.settings.read_bytes())["statusLine"], original_status)

    def test_changed_field_digest_or_producer_cannot_be_overwritten(self):
        _, checksum = self.prepare()
        with self.assertRaises(ValueError):
            install.apply(self.review / "plan.json", "wrong-digest")
        self.settings.write_text(json.dumps({**self.original, "statusLine": {"command": "changed"}}))
        with self.assertRaises(ValueError):
            install.apply(self.review / "plan.json", checksum)
        self.settings.write_text(json.dumps(self.original))
        (self.review / "producer.py").write_text("modified")
        with self.assertRaises(ValueError):
            install.apply(self.review / "plan.json", checksum)
        self.assertFalse(self.destination.exists())

    def test_uninstall_refuses_new_user_statusline_without_losing_it(self):
        _, checksum = self.prepare()
        receipt = install.apply(self.review / "plan.json", checksum)
        changed = {**self.original, "statusLine": {"type": "command", "command": "new-user-command"}}
        self.settings.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            install.uninstall(receipt)
        self.assertEqual(json.loads(self.settings.read_bytes()), changed)

    def test_platform_quoting(self):
        self.assertEqual(install.shell_command(["C:\\Program Files\\Python\\python.exe", "D:\\a'b.py"], "posix"),
                         "'C:/Program Files/Python/python.exe' 'D:/a'\"'\"'b.py'")
        self.assertEqual(install.shell_command(["C:\\Program Files\\Python\\python.exe", "D:\\a'b.py"], "powershell"),
                         "& 'C:/Program Files/Python/python.exe' 'D:/a''b.py'")


if __name__ == "__main__":
    unittest.main()
