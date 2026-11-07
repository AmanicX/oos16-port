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

import subprocess
import os
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
SAFE_FASTBOOT = os.path.join(PROJECT_ROOT, "tools/safe/fastboot")

def run_fastboot(args):
    env = os.environ.copy()
    env["REAL_FASTBOOT_BIN"] = "/usr/bin/true"
    p = subprocess.run([sys.executable, SAFE_FASTBOOT] + args, capture_output=True, text=True, env=env)
    return p.returncode, p.stdout, p.stderr

def test_blocked_destructive_commands():
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
        ["snapshot-update", "cancel"]
    ]
    for cmd in banned:
        code, out, err = run_fastboot(cmd)
        assert code == 1, f"Expected {cmd} to be blocked, got {code}"
        assert "SAFETY VIOLATION" in err, f"Expected safety violation for {cmd}, got: {err}"
    print("[PASS] Destructive fastboot commands test passed.")

def test_boot_validation():
    # Non-existent file must fail
    code, out, err = run_fastboot(["boot", "nonexistent_image_file.img"])
    assert code == 1, f"Expected non-existent boot file to fail, got {code}"
    assert "does not exist" in err

    # Directory as boot target must fail
    code, out, err = run_fastboot(["boot", PROJECT_ROOT])
    assert code == 1, f"Expected directory boot target to fail, got {code}"
    assert "not a regular file" in err

    # Empty file must fail
    with tempfile.NamedTemporaryFile() as tmp:
        code, out, err = run_fastboot(["boot", tmp.name])
        assert code == 1, f"Expected empty file to fail, got {code}"
        assert "0 bytes" in err

    # Non-boot image (invalid magic) must fail
    with tempfile.NamedTemporaryFile() as tmp:
        tmp.write(b"NOT_ANDROID_MAGIC_HEADER")
        tmp.flush()
        code, out, err = run_fastboot(["boot", tmp.name])
        assert code == 1, f"Expected invalid magic to fail, got {code}"
        assert "missing valid Android boot header" in err

    print("[PASS] Boot command validation tests passed.")

def test_getvar_validation():
    # Permitted static getvars
    allowed_static = ["product", "unlocked", "current-slot", "all", "version"]
    for var in allowed_static:
        code, out, err = run_fastboot(["getvar", var])
        assert code == 0, f"Expected getvar {var} to pass validation, got {code}: {err}"
        assert "SAFETY VIOLATION" not in err

    # Permitted slotted getvars
    allowed_slotted = ["has-slot:boot", "has-slot:system", "slot-successful:a", "slot-unbootable:_b"]
    for var in allowed_slotted:
        code, out, err = run_fastboot(["getvar", var])
        assert code == 0, f"Expected slotted getvar {var} to pass validation, got {code}: {err}"
        assert "SAFETY VIOLATION" not in err

    # Rejected unapproved getvars
    rejected = [
        "some_random_var",
        "has-slot:malicious_partition",
        "slot-successful:invalid_slot",
        "product;rm -rf /",
        "partition-size:userdata"
    ]
    for var in rejected:
        code, out, err = run_fastboot(["getvar", var])
        assert code == 1, f"Expected unapproved getvar '{var}' to be blocked, got {code}"
        assert "SAFETY VIOLATION" in err

    print("[PASS] Getvar validation tests passed.")

if __name__ == "__main__":
    test_blocked_destructive_commands()
    test_boot_validation()
    test_getvar_validation()
    print("ALL FASTBOOT SAFETY WRAPPER TESTS PASSED!")
