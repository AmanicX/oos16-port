#!/usr/bin/env python3
"""
tests/test_watchdog.py - Verification Suite for REAL scripts/watchdog.sh Implementation.
Tests the actual Stage-1 watchdog supervisor script under dependency injection.

Covers:
1. Valid heartbeat resets countdown.
2. Repeated valid heartbeats prevent timeout.
3. Missing heartbeat triggers timeout and emergency reboot.
4. Stale heartbeat does not indefinitely reset timer (consumed on detection).
5. Empty heartbeat (touch) follows protocol.
6. Token-bearing heartbeat follows protocol.
7. Directory heartbeat target is rejected.
8. Symlink heartbeat target is rejected.
9. Cancellation flag disarms watchdog.
10. Symlink cancellation flag is rejected.
11. Expired timeout invokes configured reboot action exactly once.
12. Invalid configuration fails safely with default fallback.
"""

import unittest
import os
import sys
import stat
import time
import shutil
import tempfile
import threading
import subprocess

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WATCHDOG_SCRIPT = os.path.join(PROJECT_ROOT, "scripts/watchdog.sh")

class TestRealWatchdogImplementation(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="watchdog_test_")
        self.heartbeat_file = os.path.join(self.test_dir, "watchdog_heartbeat")
        self.cancel_file = os.path.join(self.test_dir, "watchdog_cancel")
        self.reboot_log = os.path.join(self.test_dir, "reboot_invocations.log")

        # Mock reboot executable that records all calls
        self.mock_reboot = os.path.join(self.test_dir, "mock_reboot")
        with open(self.mock_reboot, "w") as f:
            f.write(f"""#!/bin/sh
echo "REBOOT_CALLED: $@" >> "{self.reboot_log}"
exit 0
""")
        os.chmod(self.mock_reboot, stat.S_IRWXU)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_watchdog(self, env_overrides=None, timeout_sec=5):
        """Runs the real scripts/watchdog.sh with configured environment variables."""
        env = os.environ.copy()
        default_env = {
            "WATCHDOG_HEARTBEAT_FILE": self.heartbeat_file,
            "WATCHDOG_CANCEL_FILE": self.cancel_file,
            "REBOOT_BIN": self.mock_reboot,
            "WATCHDOG_TIMEOUT": "2",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "0"
        }
        env.update(default_env)
        if env_overrides:
            env.update(env_overrides)

        res = subprocess.run(["sh", WATCHDOG_SCRIPT], capture_output=True, text=True, env=env, timeout=timeout_sec)
        return res

    def test_missing_heartbeat_triggers_timeout_and_reboot(self):
        """Verify missing heartbeat causes countdown expiration and exactly one reboot call."""
        res = self.run_watchdog({"WATCHDOG_TIMEOUT": "2", "WATCHDOG_SLEEP_INTERVAL": "0.02"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Safety heartbeat lost", res.stderr)
        self.assertIn("Initiating safe emergency reboot", res.stderr)

        self.assertTrue(os.path.exists(self.reboot_log))
        with open(self.reboot_log) as f:
            lines = [l.strip() for l in f.readlines() if l.strip()]
        self.assertEqual(len(lines), 1, f"Expected 1 reboot call, got: {lines}")
        self.assertEqual(lines[0], "REBOOT_CALLED: bootloader")

    def test_valid_empty_heartbeat_touch_resets_countdown(self):
        """Verify empty file created by 'touch' is recognized, consumed, and resets timer."""
        # Create empty heartbeat file (simulating host runner touch)
        with open(self.heartbeat_file, "w") as f:
            pass
        self.assertTrue(os.path.exists(self.heartbeat_file))
        self.assertEqual(os.path.getsize(self.heartbeat_file), 0)

        # Run watchdog for 1 tick with timeout=5
        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "5",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "2"
        })
        self.assertEqual(res.returncode, 0)
        self.assertIn("Valid heartbeat received. Timer reset", res.stderr)
        # Heartbeat file must be consumed (race-safe consumption)
        self.assertFalse(os.path.exists(self.heartbeat_file))
        self.assertFalse(os.path.exists(self.reboot_log))

    def test_repeated_valid_heartbeats_prevent_timeout(self):
        """Verify continuous heartbeats prevent watchdog timeout."""
        stop_event = threading.Event()

        def heartbeat_sender():
            while not stop_event.is_set():
                try:
                    with open(self.heartbeat_file, "w") as f:
                        f.write("token")
                except OSError:
                    pass
                time.sleep(0.015)

        t = threading.Thread(target=heartbeat_sender)
        t.start()
        try:
            # Run watchdog with timeout 2, for 8 ticks (total ~0.16s)
            res = self.run_watchdog({
                "WATCHDOG_TIMEOUT": "2",
                "WATCHDOG_SLEEP_INTERVAL": "0.02",
                "WATCHDOG_MAX_TICKS": "8"
            })
            self.assertEqual(res.returncode, 0)
            self.assertIn("Reached maximum ticks (8)", res.stderr)
            self.assertFalse(os.path.exists(self.reboot_log))
        finally:
            stop_event.set()
            t.join()

    def test_stale_heartbeat_consumed_and_not_indefinitely_resetting(self):
        """Verify a single heartbeat is consumed once and does not prevent subsequent timeout."""
        # Touch heartbeat once
        with open(self.heartbeat_file, "w") as f:
            pass

        # Timeout is 2 ticks; with no new heartbeats, it must time out and reboot
        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "2",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "0"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("Valid heartbeat received", res.stderr)
        self.assertIn("Safety heartbeat lost", res.stderr)
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_token_bearing_heartbeat_accepted(self):
        """Verify non-empty token-bearing heartbeat is accepted."""
        with open(self.heartbeat_file, "w") as f:
            f.write("VALID_NONCE_TOKEN_987654321")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "5",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "2"
        })
        self.assertEqual(res.returncode, 0)
        self.assertIn("Valid heartbeat received", res.stderr)
        self.assertFalse(os.path.exists(self.heartbeat_file))

    def test_directory_heartbeat_target_rejected(self):
        """Verify directory in place of heartbeat file is rejected and timeout ensues."""
        os.makedirs(self.heartbeat_file, exist_ok=True)

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "2",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "0"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("is a directory! Rejected", res.stderr)
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_symlink_heartbeat_target_rejected(self):
        """Verify symlink pointing to heartbeat target is rejected and timeout ensues."""
        dummy_target = os.path.join(self.test_dir, "real_target")
        with open(dummy_target, "w") as f:
            f.write("target")
        os.symlink(dummy_target, self.heartbeat_file)

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "2",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "0"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("is a symlink! Rejected", res.stderr)
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_cancellation_flag_disarms_watchdog(self):
        """Verify cancel file disarms the watchdog by extending timeout."""
        with open(self.cancel_file, "w") as f:
            f.write("CANCEL")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "1",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "5"
        })
        self.assertEqual(res.returncode, 0)
        self.assertIn("Watchdog disarmed", res.stderr)
        self.assertFalse(os.path.exists(self.reboot_log))

    def test_symlink_cancellation_flag_rejected(self):
        """Verify symlink cancel file is rejected and watchdog continues monitoring."""
        dummy = os.path.join(self.test_dir, "dummy_cancel")
        with open(dummy, "w") as f:
            f.write("cancel")
        os.symlink(dummy, self.cancel_file)

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "2",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "0"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("Cancellation target", res.stderr)
        self.assertIn("is a symlink! Ignoring", res.stderr)
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_invalid_timeout_configuration_fails_safely(self):
        """Verify non-integer or negative WATCHDOG_TIMEOUT safely falls back to default 60s."""
        # Test non-integer
        res1 = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "abc_invalid",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "2"
        })
        self.assertEqual(res1.returncode, 0)
        self.assertIn("Invalid WATCHDOG_TIMEOUT 'abc_invalid'. Falling back to safe default (60s)", res1.stderr)

        # Test zero
        res2 = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "0",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "2"
        })
        self.assertEqual(res2.returncode, 0)
        self.assertIn("Non-positive WATCHDOG_TIMEOUT '0'. Falling back to safe default (60s)", res2.stderr)

if __name__ == "__main__":
    unittest.main(verbosity=2)
