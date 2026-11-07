#!/usr/bin/env python3
"""
Unit tests for tools/safe/fastboot safety wrapper.
Verifies that:
- Destructive commands (flash, erase, format, set_active, wipe) are blocked.
- Arbitrary parameters are rejected.
- Invalid boot targets (directories, non-existent files, non-boot images) are rejected.
- Legitimate diagnostic commands pass validation.
- Strict getvar allowlist (permitted static and slotted vars vs rejected unapproved vars).
"""

import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
SAFE_FASTBOOT = os.path.join(PROJECT_ROOT, "tools/safe/fastboot")


def run_fastboot(args):
    env = os.environ.copy()
    env["REAL_FASTBOOT_BIN"] = "/usr/bin/true"
    p = subprocess.run([sys.executable, SAFE_FASTBOOT] + args, capture_output=True, text=True, env=env)
    return p.returncode, p.stdout, p.stderr


class TestSafeFastboot(unittest.TestCase):
    def test_blocked_destructive_commands(self):
        banned = [
            ["flash", "boot", "boot.img"],
            ["flash", "recovery", "recovery.img"],
            ["erase", "userdata"],
            ["format", "userdata"],
            ["set_active", "a"],
            ["set_active", "b"],
            ["-w"],
            ["--wipe"],
            ["oem", "unlock"],
            ["flashing", "unlock"],
            ["snapshot-update", "cancel"],
        ]
        for cmd in banned:
            code, out, err = run_fastboot(cmd)
            self.assertEqual(code, 1, f"Expected {cmd} to be blocked, got {code}")
            self.assertIn("SAFETY VIOLATION", err, f"Expected safety violation for {cmd}, got: {err}")

    def test_boot_validation(self):
        # Non-existent file must fail
        code, out, err = run_fastboot(["boot", "nonexistent_image_file.img"])
        self.assertEqual(code, 1, f"Expected non-existent boot file to fail, got {code}")
        self.assertIn("does not exist", err)

        # Directory as boot target must fail
        code, out, err = run_fastboot(["boot", PROJECT_ROOT])
        self.assertEqual(code, 1, f"Expected directory boot target to fail, got {code}")
        self.assertIn("not a regular file", err)

        # Empty file must fail
        with tempfile.NamedTemporaryFile() as tmp:
            code, out, err = run_fastboot(["boot", tmp.name])
            self.assertEqual(code, 1, f"Expected empty file to fail, got {code}")
            self.assertIn("0 bytes", err)

        # Non-boot image (invalid magic) must fail
        with tempfile.NamedTemporaryFile() as tmp:
            tmp.write(b"NOT_ANDROID_MAGIC_HEADER")
            tmp.flush()
            code, out, err = run_fastboot(["boot", tmp.name])
            self.assertEqual(code, 1, f"Expected invalid magic to fail, got {code}")
            self.assertIn("missing valid Android boot header", err)

    def test_getvar_validation(self):
        # Permitted static getvars
        allowed_static = ["product", "unlocked", "current-slot", "all", "version"]
        for var in allowed_static:
            code, out, err = run_fastboot(["getvar", var])
            self.assertEqual(code, 0, f"Expected getvar {var} to pass validation, got {code}: {err}")
            self.assertNotIn("SAFETY VIOLATION", err)

        # Permitted slotted getvars
        allowed_slotted = ["has-slot:boot", "has-slot:system", "slot-successful:a", "slot-unbootable:_b"]
        for var in allowed_slotted:
            code, out, err = run_fastboot(["getvar", var])
            self.assertEqual(code, 0, f"Expected slotted getvar {var} to pass validation, got {code}: {err}")
            self.assertNotIn("SAFETY VIOLATION", err)

        # Rejected unapproved getvars
        rejected = [
            "some_random_var",
            "has-slot:malicious_partition",
            "slot-successful:invalid_slot",
            "product;rm -rf /",
            "partition-size:userdata",
        ]
        for var in rejected:
            code, out, err = run_fastboot(["getvar", var])
            self.assertEqual(code, 1, f"Expected unapproved getvar '{var}' to be blocked, got {code}")
            self.assertIn("SAFETY VIOLATION", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
