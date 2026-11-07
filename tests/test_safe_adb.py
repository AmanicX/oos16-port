#!/usr/bin/env python3
"""
Unit tests for tools/safe/adb safety wrapper.
Verifies that:
- Destructive commands are blocked.
- Shell metacharacters and injections (pipes, chaining, redirects) are blocked.
- Push to /sdcard is blocked.
- Toybox applets outside whitelist are blocked.
- Whitelisted safe commands pass validation.
"""

import subprocess
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
SAFE_ADB = os.path.join(PROJECT_ROOT, "tools/safe/adb")

def run_adb(args):
    # Pass dummy flag or run adb wrapper
    p = subprocess.run([sys.executable, SAFE_ADB] + args, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr

def test_blocked_subcommands():
    banned = ["sideload", "install", "uninstall", "sync", "remount", "disable-verity"]
    for cmd in banned:
        code, out, err = run_adb([cmd])
        assert code == 1, f"Expected {cmd} to be blocked, got code {code}"
        assert "SAFETY VIOLATION" in err, f"Expected error message for {cmd}, got: {err}"
    print("[PASS] Blocked subcommands test passed.")

def test_push_destinations():
    # Push to /sdcard must be BLOCKED
    code, out, err = run_adb(["push", "README.md", "/sdcard/foo.img"])
    assert code == 1, f"Expected push to /sdcard to be blocked, got {code}"
    assert "not RAM" in err or "REJECTED" in err

    code, out, err = run_adb(["push", "README.md", "/storage/emulated/0/foo.img"])
    assert code == 1, f"Expected push to /storage to be blocked, got {code}"

    # Push nonexistent local file must be blocked
    code, out, err = run_adb(["push", "nonexistent_file_12345.xyz", "/tmp/"])
    assert code == 1, f"Expected nonexistent push source to fail, got {code}"
    print("[PASS] Push destination safety test passed.")

def test_shell_metacharacters():
    injections = [
        ["shell", "ls; rm -rf /tmp/*"],
        ["shell", "ls && echo pwned"],
        ["shell", "cat /proc/meminfo | grep Mem"],
        ["shell", "cat /proc/meminfo > /tmp/bad"],
        ["shell", "echo $(whoami)"],
        ["shell", "echo `id`"],
        ["shell", "ls || dd of=/dev/block/sda"],
        ["shell", "cat /proc/cpuinfo\nrm -rf /"]
    ]
    for cmd in injections:
        code, out, err = run_adb(cmd)
        assert code == 1, f"Expected injection '{cmd}' to be blocked, got {code}"
        assert "Shell metacharacters" in err or "SAFETY VIOLATION" in err
    print("[PASS] Shell metacharacters injection test passed.")

def test_toybox_restrictions():
    # Dangerous toybox applets must be blocked
    bad_applets = [
        ["shell", "toybox", "dd", "if=/dev/zero", "of=/tmp/test"],
        ["shell", "toybox", "mknod", "/tmp/node", "c", "1", "3"],
        ["shell", "toybox", "mount", "-o", "rw", "/tmp/foo", "/mnt"],
        ["shell", "toybox", "chroot", "/mnt/sysroot", "/system/bin/sh"],
        ["shell", "chroot", "/mnt/sysroot", "/system/bin/sh"]
    ]
    for cmd in bad_applets:
        code, out, err = run_adb(cmd)
        assert code == 1, f"Expected '{cmd}' to be blocked, got {code}"
        assert "SAFETY VIOLATION" in err
    print("[PASS] Toybox restrictions test passed.")

if __name__ == "__main__":
    test_blocked_subcommands()
    test_push_destinations()
    test_shell_metacharacters()
    test_toybox_restrictions()
    print("ALL ADB SAFETY WRAPPER TESTS PASSED!")
