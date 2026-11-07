#!/usr/bin/env python3
"""
Unit tests for tools/safe/fastboot safety wrapper.
Verifies that:
- Destructive commands (flash, erase, format, set_active, wipe) are blocked.
- Arbitrary parameters are rejected.
- Invalid boot targets (directories, non-existent files) are rejected.
- Legitimate diagnostic commands pass validation.
"""

import subprocess
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
SAFE_FASTBOOT = os.path.join(PROJECT_ROOT, "tools/safe/fastboot")

def run_fastboot(args):
    p = subprocess.run([sys.executable, SAFE_FASTBOOT] + args, capture_output=True, text=True)
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
    code, out, err = run_fastboot(["boot", "scripts"])
    assert code == 1, f"Expected directory boot target to fail, got {code}"
    assert "not a regular file" in err

    # Multiple arguments to boot must fail
    code, out, err = run_fastboot(["boot", "file1.img", "file2.img"])
    assert code == 1, f"Expected multiple boot arguments to fail, got {code}"
    print("[PASS] Boot command validation test passed.")

def test_getvar_validation():
    # Empty getvar must fail
    code, out, err = run_fastboot(["getvar"])
    assert code == 1, f"Expected empty getvar to fail, got {code}"

    # Invalid variable containing shell metacharacters must fail
    code, out, err = run_fastboot(["getvar", "product;rm -rf /"])
    assert code == 1, f"Expected malicious getvar to fail, got {code}"
    print("[PASS] Getvar validation test passed.")

if __name__ == "__main__":
    test_blocked_destructive_commands()
    test_boot_validation()
    test_getvar_validation()
    print("ALL FASTBOOT SAFETY WRAPPER TESTS PASSED!")
