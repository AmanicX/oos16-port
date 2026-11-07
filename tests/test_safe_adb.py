#!/usr/bin/env python3
"""
Unit tests for tools/safe/adb safety wrapper.
Verifies that:
- Destructive commands are blocked.
- Shell metacharacters and injections (pipes, chaining, redirects) are blocked.
- Push to /sdcard, path traversal, or unapproved destination characters are blocked.
- Executable path spoofing is blocked.
- Toybox applets outside whitelist or with spoofed paths are blocked.
- State-clearing diagnostic commands (logcat -c, dmesg -c) are blocked.
- Real ADB executable validation (recursion prevention, missing binary) works.
"""

import os
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
SAFE_ADB = os.path.join(PROJECT_ROOT, "tools/safe/adb")


def run_adb(args, env_override=None):
    env = os.environ.copy()
    if env_override:
        env.update(env_override)
    p = subprocess.run([sys.executable, SAFE_ADB] + args, capture_output=True, text=True, env=env)
    return p.returncode, p.stdout, p.stderr


class TestSafeAdb(unittest.TestCase):
    def test_blocked_subcommands(self):
        banned = ["sideload", "install", "uninstall", "sync", "remount", "disable-verity"]
        for cmd in banned:
            code, out, err = run_adb([cmd])
            self.assertEqual(code, 1, f"Expected {cmd} to be blocked, got code {code}")
            self.assertIn("SAFETY VIOLATION", err, f"Expected error message for {cmd}, got: {err}")

    def test_push_destinations(self):
        # Push to /sdcard must be BLOCKED
        code, out, err = run_adb(["push", "README.md", "/sdcard/foo.img"])
        self.assertEqual(code, 1, f"Expected push to /sdcard to be blocked, got {code}")
        self.assertTrue("physical storage" in err or "REJECTED" in err)

        code, out, err = run_adb(["push", "README.md", "/storage/emulated/0/foo.img"])
        self.assertEqual(code, 1, f"Expected push to /storage to be blocked, got {code}")

        # Path traversal attempts must be BLOCKED
        traversals = [
            "/tmp/../etc/passwd",
            "/mnt/../dev/block/sda",
            "/tmp/subdir/../../sdcard",
            "../tmp/foo",
            "/tmp/./foo",
            "/mnt/foo;bar",
        ]
        for dest in traversals:
            code, out, err = run_adb(["push", "README.md", dest])
            self.assertEqual(code, 1, f"Expected traversal/invalid '{dest}' to be blocked, got {code}")
            self.assertTrue("traversal" in err or "SAFETY VIOLATION" in err or "illegal characters" in err)

        # Push nonexistent local file must be blocked
        code, out, err = run_adb(["push", "nonexistent_file_12345.xyz", "/tmp/foo.img"])
        self.assertEqual(code, 1, f"Expected nonexistent push source to fail, got {code}")

    def test_shell_metacharacters(self):
        injections = [
            ["shell", "ls; rm -rf /tmp/*"],
            ["shell", "ls && echo pwned"],
            ["shell", "cat /proc/meminfo | grep Mem"],
            ["shell", "cat /proc/meminfo > /tmp/bad"],
            ["shell", "echo $(whoami)"],
            ["shell", "echo `id`"],
            ["shell", "ls || dd of=/dev/block/sda"],
            ["shell", "cat /proc/cpuinfo\nrm -rf /"],
            ["shell", "for b in /sys/block/*; do echo $b; done"],
        ]
        for cmd in injections:
            code, out, err = run_adb(cmd)
            self.assertEqual(code, 1, f"Expected injection '{cmd}' to be blocked, got {code}")
            self.assertTrue("Shell metacharacters" in err or "SAFETY VIOLATION" in err)

    def test_executable_path_spoofing(self):
        spoofed = [
            ["shell", "/data/local/tmp/getprop"],
            ["shell", "/tmp/getprop"],
            ["shell", "/sdcard/sh"],
            ["shell", "/data/ps"],
            ["shell", "../system/bin/getprop"],
        ]
        for cmd in spoofed:
            code, out, err = run_adb(cmd)
            self.assertEqual(code, 1, f"Expected spoofed path '{cmd}' to be blocked, got {code}")
            self.assertTrue("spoofing" in err or "SAFETY VIOLATION" in err)

    def test_toybox_restrictions(self):
        bad_applets = [
            ["shell", "toybox", "dd", "if=/dev/zero", "of=/tmp/test"],
            ["shell", "toybox", "mknod", "/tmp/node", "c", "1", "3"],
            ["shell", "toybox", "mount", "-o", "rw", "/tmp/foo", "/mnt"],
            ["shell", "toybox", "chroot", "/mnt/sysroot", "/system/bin/sh"],
            ["shell", "chroot", "/mnt/sysroot", "/system/bin/sh"],
            ["shell", "toybox", "/tmp/getprop"],
        ]
        for cmd in bad_applets:
            code, out, err = run_adb(cmd)
            self.assertEqual(code, 1, f"Expected '{cmd}' to be blocked, got {code}")
            self.assertIn("SAFETY VIOLATION", err)

    def test_diagnostic_state_clearing_blocked(self):
        # logcat -c and dmesg -c clear kernel and system logs and must be BLOCKED
        clearing_cmds = [["shell", "logcat", "-c"], ["shell", "dmesg", "-c"], ["shell", "toybox", "dmesg", "-c"]]
        for cmd in clearing_cmds:
            code, out, err = run_adb(cmd)
            self.assertEqual(code, 1, f"Expected state-clearing command '{cmd}' to be blocked, got {code}")
            self.assertIn("SAFETY VIOLATION", err)

    def test_real_adb_validation(self):
        # 1. Self-reference recursion prevention (tested without test mode)
        code, out, err = run_adb(["get-state"], env_override={"REAL_ADB_BIN": SAFE_ADB})
        self.assertEqual(code, 1, "Expected recursion error when pointing REAL_ADB_BIN to wrapper itself")
        self.assertIn("infinite recursion", err)

        # 2. Arbitrary override rejected in production mode
        code, out, err = run_adb(["get-state"], env_override={"REAL_ADB_BIN": "/tmp/custom_adb"})
        self.assertEqual(code, 1, "Expected rejection of arbitrary REAL_ADB_BIN in production")
        self.assertIn("rejected in production", err)

        # 3. Non-existent binary in test mode
        code, out, err = run_adb(
            ["get-state"], env_override={"REAL_ADB_BIN": "/nonexistent/binary_xyz", "OOS16_TEST_MODE": "1"}
        )
        self.assertEqual(code, 1, "Expected error when pointing REAL_ADB_BIN to nonexistent path")
        self.assertIn("does not exist", err)

        # 4. Non-executable file in test mode
        non_exec = os.path.join(PROJECT_ROOT, "README.md")
        code, out, err = run_adb(["get-state"], env_override={"REAL_ADB_BIN": non_exec, "OOS16_TEST_MODE": "1"})
        self.assertEqual(code, 1, "Expected error when pointing REAL_ADB_BIN to non-executable file")
        self.assertIn("is not executable", err)

    def test_remote_symlink_escape_rejection(self):
        # Create temporary mock adb that simulates symlink escape detection on device
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_adb = os.path.join(tmpdir, "mock_adb")
            with open(mock_adb, "w") as f:
                f.write("""#!/bin/sh
if [ "$1" = "shell" ] && [ "$2" = "readlink" ]; then
    echo "/data/escape_target"
    exit 0
fi
exit 0
""")
            os.chmod(mock_adb, os.stat(mock_adb).st_mode | stat.S_IEXEC)
            dummy_file = os.path.join(tmpdir, "test.txt")
            with open(dummy_file, "w") as f:
                f.write("test")

            code, out, err = run_adb(
                ["push", dummy_file, "/mnt/escape_link"],
                env_override={"REAL_ADB_BIN": mock_adb, "OOS16_TEST_MODE": "1"},
            )
            self.assertEqual(code, 1, f"Expected symlink escape to be rejected, got code {code}")
            self.assertIn("symlink resolving to", err)
            self.assertIn("REJECTED", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
