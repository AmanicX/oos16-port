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
        self.device_heartbeat_file = os.path.join(self.test_dir, "stage2_heartbeat")
        self.ack_file = os.path.join(self.test_dir, "stage1_ack")
        self.done_file = os.path.join(self.test_dir, "stage2_done")
        self.cancel_file = os.path.join(self.test_dir, "watchdog_cancel")
        self.state_file = os.path.join(self.test_dir, "watchdog_state")
        self.reboot_log = os.path.join(self.test_dir, "reboot_invocations.log")

        # Mock reboot executable that records all calls
        self.mock_reboot = os.path.join(self.test_dir, "mock_reboot")
        with open(self.mock_reboot, "w") as f:
            f.write(f"""#!/bin/sh
echo "REBOOT_CALLED: $@" >> "{self.reboot_log}"
exit 0
""")
        os.chmod(self.mock_reboot, stat.S_IRWXU)

        # Mock getprop executable
        self.mock_getprop = os.path.join(self.test_dir, "mock_getprop")
        with open(self.mock_getprop, "w") as f:
            f.write("""#!/bin/sh
if [ "$1" = "sys.boot_completed" ]; then
    cat "$GETPROP_BOOT_STATUS_FILE" 2>/dev/null || echo "0"
    exit 0
fi
echo ""
exit 0
""")
        os.chmod(self.mock_getprop, stat.S_IRWXU)
        self.boot_status_file = os.path.join(self.test_dir, "boot_status")

        # Setup mock sysfs and blockdev for storage inventory
        self.mock_sys_block = os.path.join(self.test_dir, "sys_block")
        self.mock_dev_block = os.path.join(self.test_dir, "dev_block")
        self.bin_dir = os.path.join(self.test_dir, "bin")
        os.makedirs(self.mock_sys_block, exist_ok=True)
        os.makedirs(self.mock_dev_block, exist_ok=True)
        os.makedirs(self.bin_dir, exist_ok=True)

        # Mock blockdev binary
        self.mock_blockdev = os.path.join(self.bin_dir, "blockdev")
        with open(self.mock_blockdev, "w") as f:
            f.write("""#!/bin/sh
if [ "$1" = "--getro" ]; then
    if [ "${BLOCKDEV_FAIL:-0}" = "1" ]; then
        exit 1
    fi
    if [ -n "${BLOCKDEV_FAIL_DEV:-}" ] && [ "$2" = "$BLOCKDEV_FAIL_DEV" ]; then
        echo "0"
        exit 0
    fi
    echo "${BLOCKDEV_RO_VAL:-1}"
    exit 0
elif [ "$1" = "--setro" ]; then
    if [ "${BLOCKDEV_SETRO_FAIL:-0}" = "1" ]; then
        exit 1
    fi
    if [ -n "${BLOCKDEV_SETRO_FAIL_DEV:-}" ] && [ "$2" = "$BLOCKDEV_SETRO_FAIL_DEV" ]; then
        exit 1
    fi
    exit 0
fi
exit 0
""")
        os.chmod(self.mock_blockdev, stat.S_IRWXU)

        # Mock mknod binary recording invocations and checking strict operands
        self.mock_mknod = os.path.join(self.bin_dir, "mknod")
        self.mknod_log = os.path.join(self.test_dir, "mknod_invocations.log")
        with open(self.mock_mknod, "w") as f:
            f.write(f"""#!/bin/sh
echo "$@" >> "{self.mknod_log}"
if [ "${{MKNOD_FAIL:-0}}" = "1" ]; then
    echo "mknod: permission denied or I/O error" >&2
    exit 1
fi
if [ "$#" -lt 4 ] || [ -z "$4" ]; then
    echo "mknod: missing operand: requires device type, major and minor" >&2
    exit 1
fi
# Emulate block device node creation as regular file in test isolation
touch "$1"
exit 0
""")
        os.chmod(self.mock_mknod, stat.S_IRWXU)

        # Mock stat binary
        self.mock_stat = os.path.join(self.bin_dir, "stat")
        self.stat_log = os.path.join(self.test_dir, "stat_invocations.log")
        with open(self.mock_stat, "w") as f:
            f.write(f"""#!/bin/sh
echo "$@" >> "{self.stat_log}"
if [ "${{STAT_FAIL:-0}}" = "1" ]; then
    echo "stat: cannot stat: I/O error" >&2
    exit 1
fi
if [ -n "${{STAT_RAW_OUTPUT+x}}" ]; then
    echo "${{STAT_RAW_OUTPUT}}"
    exit 0
fi
node="$4"
bname=$(basename "$node")
dev_file="{self.mock_sys_block}/$bname/dev"
if [ ! -f "$dev_file" ]; then
    dev_file="{self.mock_sys_block}/sda/$bname/dev"
fi
if [ -f "$dev_file" ]; then
    mm=$(cat "$dev_file" 2>/dev/null | tr -d '[:space:]')
    maj="${{mm%%:*}}"
    min="${{mm##*:}}"
    hex_maj=$(printf "%x" "$maj" 2>/dev/null || echo "$maj")
    hex_min=$(printf "%x" "$min" 2>/dev/null || echo "$min")
    echo "$hex_maj:$hex_min"
    exit 0
fi
echo "8:0"
exit 0
""")
        os.chmod(self.mock_stat, stat.S_IRWXU)

        # Default valid disk sda
        self.sda_sys = os.path.join(self.mock_sys_block, "sda")
        os.makedirs(self.sda_sys, exist_ok=True)
        with open(os.path.join(self.sda_sys, "device"), "w") as f:
            f.write("mock_hw\n")
        with open(os.path.join(self.sda_sys, "dev"), "w") as f:
            f.write("8:0\n")

        self.sda_node = os.path.join(self.mock_dev_block, "sda")
        with open(self.sda_node, "w") as f:
            f.write("")

        self.mnt_dir = os.path.join(self.test_dir, "mnt_dir")
        self.tmp_dir = os.path.join(self.test_dir, "tmp_dir")
        os.makedirs(self.mnt_dir, exist_ok=True)
        os.makedirs(self.tmp_dir, exist_ok=True)
        self.inv_file_mnt = os.path.join(self.mnt_dir, "physical_storage_inventory_mnt")
        self.inv_file_tmp = os.path.join(self.tmp_dir, "physical_storage_inventory_tmp")
        self.inv_file = self.inv_file_mnt
        initial_inv = f"/dev/block/sda:8:0:{self.sda_sys}\n"
        with open(self.inv_file_mnt, "w") as f:
            f.write(initial_inv)
        with open(self.inv_file_tmp, "w") as f:
            f.write(initial_inv)

    def sync_inventories(self):
        """Keep test mnt and tmp inventories synchronized if modified."""
        if os.path.exists(self.inv_file_mnt):
            shutil.copy2(self.inv_file_mnt, self.inv_file_tmp)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_watchdog(self, env_overrides=None, timeout_sec=5):
        """Runs the real scripts/watchdog.sh with configured environment variables."""
        env = os.environ.copy()
        default_env = {
            "WATCHDOG_HEARTBEAT_FILE": self.heartbeat_file,
            "WATCHDOG_DEVICE_HEARTBEAT_FILE": self.device_heartbeat_file,
            "WATCHDOG_ACK_FILE": self.ack_file,
            "WATCHDOG_DONE_FILE": self.done_file,
            "WATCHDOG_CANCEL_FILE": self.cancel_file,
            "WATCHDOG_STATE_FILE": self.state_file,
            "WATCHDOG_INVENTORY_FILE": self.inv_file_mnt,
            "WATCHDOG_INVENTORY_FILE_TMP": self.inv_file_tmp,
            "SYS_BLOCK_DIR": self.mock_sys_block,
            "DEV_BLOCK_DIR": self.mock_dev_block,
            "WATCHDOG_TEST_MODE": "1",
            "PATH": f"{self.bin_dir}:" + env.get("PATH", ""),
            "REBOOT_BIN": self.mock_reboot,
            "GETPROP_BIN": self.mock_getprop,
            "GETPROP_BOOT_STATUS_FILE": self.boot_status_file,
            "STAT_BIN": self.mock_stat,
            "WATCHDOG_TIMEOUT": "2",
            "WATCHDOG_STAGE2_TIMEOUT": "4",
            "WATCHDOG_HEALTH_TIMEOUT": "4",
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
                time.sleep(0.005)

        t = threading.Thread(target=heartbeat_sender)
        t.start()
        try:
            # Run watchdog with timeout 5, for 10 ticks (total ~0.20s).
            # Without heartbeats, it would timeout and reboot at tick 5.
            # Continuous heartbeats reset countdown every tick, surviving all 10 ticks.
            res = self.run_watchdog({
                "WATCHDOG_TIMEOUT": "5",
                "WATCHDOG_SLEEP_INTERVAL": "0.02",
                "WATCHDOG_MAX_TICKS": "10"
            })
            self.assertEqual(res.returncode, 0)
            self.assertIn("Reached maximum ticks (10)", res.stderr)
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

    def test_stage1_ack_transitions_to_stage2_running(self):
        """Verify presence of stage1_ack transitions state to STAGE2_RUNNING and resets timer."""
        with open(self.ack_file, "w") as f:
            f.write("ack")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "1",
            "WATCHDOG_STAGE2_TIMEOUT": "5",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "3"
        })
        self.assertEqual(res.returncode, 0)
        self.assertIn("Transitioned to STAGE2_RUNNING", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STAGE2_RUNNING")

    def test_device_heartbeat_accepted_in_stage2(self):
        """Verify device-side heartbeat in stage 2 resets timer without conflict."""
        with open(self.ack_file, "w") as f:
            f.write("ack")
        with open(self.device_heartbeat_file, "w") as f:
            f.write("device_ping")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "1",
            "WATCHDOG_STAGE2_TIMEOUT": "5",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "3"
        })
        self.assertEqual(res.returncode, 0)
        self.assertIn("Heartbeat received during Stage-2 bringup", res.stderr)
        self.assertFalse(os.path.exists(self.device_heartbeat_file))

    def test_stage2_done_transitions_to_health_monitor(self):
        """Verify stage2_done marker transitions state to HEALTH_MONITOR."""
        with open(self.ack_file, "w") as f:
            f.write("ack")
        with open(self.done_file, "w") as f:
            f.write("done")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "1",
            "WATCHDOG_STAGE2_TIMEOUT": "2",
            "WATCHDOG_HEALTH_TIMEOUT": "5",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "4"
        })
        self.assertEqual(res.returncode, 0)
        self.assertIn("Transitioned to HEALTH_MONITOR", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "HEALTH_MONITOR")

    def test_health_monitor_detects_boot_completed(self):
        """Verify health monitor exits cleanly with code 0 when sys.boot_completed=1."""
        with open(self.ack_file, "w") as f:
            f.write("ack")
        with open(self.done_file, "w") as f:
            f.write("done")
        with open(self.boot_status_file, "w") as f:
            f.write("1\n")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "1",
            "WATCHDOG_STAGE2_TIMEOUT": "2",
            "WATCHDOG_HEALTH_TIMEOUT": "5",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "10"
        })
        self.assertEqual(res.returncode, 0)
        self.assertIn("Android boot completed successfully (sys.boot_completed=1)", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "BOOT_COMPLETED")

    def test_health_monitor_timeout_triggers_reboot(self):
        """Verify timeout in health monitor triggers safe emergency reboot."""
        with open(self.ack_file, "w") as f:
            f.write("ack")
        with open(self.done_file, "w") as f:
            f.write("done")
        with open(self.boot_status_file, "w") as f:
            f.write("0\n")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "2",
            "WATCHDOG_STAGE2_TIMEOUT": "3",
            "WATCHDOG_HEALTH_TIMEOUT": "1",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "0"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("State at failure: HEALTH_MONITOR", res.stderr)
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_delayed_android_boot_completion_success(self):
        """Verify watchdog waits for delayed sys.boot_completed=1 and exits cleanly."""
        with open(self.ack_file, "w") as f:
            f.write("ack")
        with open(self.done_file, "w") as f:
            f.write("done")
        with open(self.boot_status_file, "w") as f:
            f.write("0\n")

        # Background thread that flips property to "1" after 20ms
        def delayed_flip():
            time.sleep(0.02)
            with open(self.boot_status_file, "w") as f:
                f.write("1\n")

        t = threading.Thread(target=delayed_flip)
        t.start()
        try:
            # Stage 2 done transitions immediately to HEALTH_MONITOR.
            # Timeout is 50 ticks (1000ms), giving robust margin against runner CPU scheduling latency.
            res = self.run_watchdog({
                "WATCHDOG_TIMEOUT": "5",
                "WATCHDOG_STAGE2_TIMEOUT": "5",
                "WATCHDOG_HEALTH_TIMEOUT": "50",
                "WATCHDOG_SLEEP_INTERVAL": "0.02",
                "WATCHDOG_MAX_TICKS": "50"
            })
            self.assertEqual(res.returncode, 0)
            self.assertIn("Android boot completed successfully (sys.boot_completed=1)", res.stderr)
            with open(self.state_file) as f:
                self.assertEqual(f.read().strip(), "BOOT_COMPLETED")
        finally:
            t.join()

    def test_property_service_failure_triggers_reboot(self):
        """Verify property-service empty or failed responses do not cause false success."""
        with open(self.ack_file, "w") as f:
            f.write("ack")
        with open(self.done_file, "w") as f:
            f.write("done")
        with open(self.boot_status_file, "w") as f:
            f.write("FAILED_PROP_READ\n")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "2",
            "WATCHDOG_STAGE2_TIMEOUT": "2",
            "WATCHDOG_HEALTH_TIMEOUT": "1",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "0"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("State at failure: HEALTH_MONITOR", res.stderr)
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_symlink_stage1_ack_and_stage2_done_rejected(self):
        """Verify symlink ack and done markers are rejected without state transition."""
        dummy = os.path.join(self.test_dir, "dummy_target")
        with open(dummy, "w") as f:
            f.write("data")
        os.symlink(dummy, self.ack_file)

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "5",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "2"
        })
        self.assertIn("Acknowledgement file", res.stderr)
        self.assertIn("is a symlink! Ignoring", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STAGE1_WAIT")

    def test_adb_disconnect_stops_heartbeat_and_reboots(self):
        """Verify simulating ADB disconnection (heartbeats stop) triggers timeout and reboot."""
        # Touch heartbeat once, then disconnect (no more heartbeats)
        with open(self.heartbeat_file, "w") as f:
            f.write("ping")

        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "1",
            "WATCHDOG_SLEEP_INTERVAL": "0.02",
            "WATCHDOG_MAX_TICKS": "0"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("Safety heartbeat lost", res.stderr)
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_invalid_and_boundary_configuration_values(self):
        """Verify that malformed, negative, out-of-range, or zero configuration parameters are safely normalized."""
        res = self.run_watchdog({
            "WATCHDOG_STAGE2_TIMEOUT": "-50",
            "WATCHDOG_HEALTH_TIMEOUT": "999999",
            "WATCHDOG_SLEEP_INTERVAL": "0",
            "WATCHDOG_MAX_TICKS": "1",
        }, timeout_sec=3)
        self.assertIn("WATCHDOG_STAGE2_TIMEOUT '-50'", res.stderr)
        self.assertIn("[WATCHDOG WARN] WATCHDOG_HEALTH_TIMEOUT '999999' exceeds maximum", res.stderr)
        self.assertIn("[WATCHDOG WARN] Zero WATCHDOG_SLEEP_INTERVAL '0' prohibited", res.stderr)

    def test_malformed_sleep_interval_multiple_decimals(self):
        """Verify multiple decimal points in sleep interval are rejected."""
        res = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "1",
            "WATCHDOG_SLEEP_INTERVAL": "1.2.3",
            "WATCHDOG_MAX_TICKS": "1"
        }, timeout_sec=2)
        self.assertIn("multiple decimal points", res.stderr)

    def test_watchdog_numeric_grammar_and_boundaries(self):
        """
        Verify specific boundary and invalid values requested by safety audit:
        '.', '.5', '1.', '0.001', '0', '60', '60.1', '999999999999999999999999', negative values, empty.
        """
        cases = [
            (".", "leading decimal point prohibited"),
            (".5", "leading decimal point prohibited"),
            ("1.", "trailing decimal point prohibited"),
            ("0", "Zero WATCHDOG_SLEEP_INTERVAL '0' prohibited"),
            ("0.0", "Zero WATCHDOG_SLEEP_INTERVAL '0.0' prohibited"),
            ("60.1", "exceeds maximum"),
            ("-5", "Invalid non-numeric"),
            ("", "Invalid non-numeric"),
            ("1.2.3.4", "multiple decimal points"),
        ]
        for val, expected_err in cases:
            res = self.run_watchdog({
                "WATCHDOG_SLEEP_INTERVAL": val,
                "WATCHDOG_MAX_TICKS": "1"
            }, timeout_sec=2)
            self.assertIn(expected_err, res.stderr, f"Failed for WATCHDOG_SLEEP_INTERVAL='{val}'")

        # Test valid boundaries: 0.001 and 60 must NOT log a warning
        for val in ["0.001", "60", "0.5", "1"]:
            res = self.run_watchdog({
                "WATCHDOG_SLEEP_INTERVAL": val,
                "WATCHDOG_MAX_TICKS": "1"
            }, timeout_sec=2)
            self.assertNotIn("WATCHDOG_SLEEP_INTERVAL", res.stderr, f"Unexpected warning for valid '{val}'")

        # Test overflow on integer timeout: 999999999999999999999999
        res_overflow = self.run_watchdog({
            "WATCHDOG_TIMEOUT": "999999999999999999999999",
            "WATCHDOG_MAX_TICKS": "1"
        }, timeout_sec=2)
        self.assertIn("exceeds maximum (86400s)", res_overflow.stderr)

    # --------------------------------------------------------------------------
    # Priority 1: Storage Safety Fail-Closed Watchdog Tests
    # --------------------------------------------------------------------------
    def test_watchdog_missing_inventory_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION and reboot when inventory file is missing."""
        if os.path.exists(self.inv_file):
            os.remove(self.inv_file)
        res = self.run_watchdog({"WATCHDOG_INVENTORY_FILE": os.path.join(self.test_dir, "nonexistent_inv")})
        self.assertEqual(res.returncode, 1)
        self.assertIn("[WATCHDOG FATAL] Storage safety violation: Physical storage inventory missing", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_watchdog_empty_inventory_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION and reboot when inventory is 0 bytes."""
        with open(self.inv_file_mnt, "w") as f:
            pass
        with open(self.inv_file_tmp, "w") as f:
            pass
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("is empty (0 bytes)", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")
        self.assertTrue(os.path.exists(self.reboot_log))

    def test_watchdog_unreadable_inventory_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION when inventory file is unreadable."""
        os.chmod(self.inv_file_mnt, 0o000)
        try:
            res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
            self.assertEqual(res.returncode, 1)
            self.assertIn("is not readable", res.stderr)
            with open(self.state_file) as f:
                self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")
        finally:
            os.chmod(self.inv_file_mnt, 0o644)

    def test_watchdog_malformed_inventory_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION on malformed inventory entries."""
        with open(self.inv_file_mnt, "w") as f:
            f.write("/dev/block/sda:8:0\n")  # Missing 4th field
        self.sync_inventories()
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Malformed inventory entry", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_missing_block_node_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION when a declared device node does not exist."""
        os.remove(self.sda_node)
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Block device node '/dev/block/sda' does not exist", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_disappearing_sysfs_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION if a physical device disappears from sysfs."""
        shutil.rmtree(self.sda_sys)
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("disappeared or does not exist", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_major_minor_mismatch_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION if sysfs major:minor changes or mismatches."""
        with open(os.path.join(self.sda_sys, "dev"), "w") as f:
            f.write("8:99\n")  # Expected 8:0
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Major:minor mismatch for '/dev/block/sda' (8:99 != 8:0)", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_blockdev_getro_failure_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION if blockdev fails (NO fallback to 1)."""
        res = self.run_watchdog({"BLOCKDEV_FAIL": "1", "WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("blockdev --getro failed on '/dev/block/sda'", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_blockdev_getro_zero_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION if blockdev reports ro=0."""
        res = self.run_watchdog({"BLOCKDEV_RO_VAL": "0", "WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("is NOT read-only (ro=0, expected 1)", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_duplicate_inventory_entry_triggers_storage_violation(self):
        """Verify watchdog triggers STORAGE_VIOLATION on duplicate records in inventory."""
        with open(self.inv_file_mnt, "a") as f:
            f.write(f"/dev/block/sda:8:0:{self.sda_sys}\n")
        self.sync_inventories()
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Duplicate device '/dev/block/sda' found in inventory", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_writable_mount_triggers_storage_violation(self):
        """Verify watchdog detects writable physical mount in mounts file and halts."""
        mounts_file = os.path.join(self.test_dir, "test_mounts")
        with open(mounts_file, "w") as f:
            f.write("/dev/block/sda1 /data ext4 rw,seclabel 0 0\n")
        res = self.run_watchdog({"PROC_MOUNTS_FILE": mounts_file, "WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Detected writable physical mount", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_newly_appearing_partition_locked_and_recorded(self):
        """Verify watchdog detects newly appearing partition in sysfs, creates node via mknod, locks it, and appends to inventory."""
        sda1_sys = os.path.join(self.sda_sys, "sda1")
        os.makedirs(sda1_sys, exist_ok=True)
        with open(os.path.join(sda1_sys, "dev"), "w") as f:
            f.write("8:1\n")
        sda1_node = os.path.join(self.mock_dev_block, "sda1")
        if os.path.exists(sda1_node):
            os.remove(sda1_node)

        with open(self.heartbeat_file, "w") as f:
            f.write("pet")

        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("Detected newly appearing physical partition: /dev/block/sda1", res.stderr)
        self.assertIn("Locked newly appearing partition read-only: /dev/block/sda1 (ro=1)", res.stderr)
        with open(self.inv_file_mnt) as f:
            content_mnt = f.read()
        with open(self.inv_file_tmp) as f:
            content_tmp = f.read()
        self.assertEqual(content_mnt, content_tmp)
        self.assertIn("/dev/block/sda1:8:1:", content_mnt)
        self.assertTrue(os.path.exists(sda1_node))

    def test_watchdog_newly_appearing_partition_mknod_arg_construction(self):
        """
        Verify exact argument construction passed to mknod for newly appearing partition.
        Catches regression where $pmin was used instead of $p_min (empty minor number).
        """
        sda2_sys = os.path.join(self.sda_sys, "sda2")
        os.makedirs(sda2_sys, exist_ok=True)
        with open(os.path.join(sda2_sys, "dev"), "w") as f:
            f.write("8:2\n")
        sda2_node = os.path.join(self.mock_dev_block, "sda2")
        if os.path.exists(sda2_node):
            os.remove(sda2_node)

        with open(self.heartbeat_file, "w") as f:
            f.write("pet")

        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertTrue(os.path.exists(self.mknod_log), "mknod was not invoked")
        with open(self.mknod_log) as f:
            mknod_invocations = f.read().splitlines()

        matching = [l for l in mknod_invocations if "sda2" in l]
        self.assertTrue(len(matching) > 0, f"No mknod invocation found for sda2 in {mknod_invocations}")
        # Validate exact 4 arguments: <node> b <major> <minor>
        args = matching[0].split()
        self.assertEqual(len(args), 4, f"mknod invoked with invalid argument count: {args}")
        self.assertTrue(args[0].endswith("sda2"))
        self.assertEqual(args[1], "b")
        self.assertEqual(args[2], "8")
        self.assertEqual(args[3], "2", "Minor number must be '2' (not empty, caught $pmin regression)")

    def test_watchdog_newly_appearing_disk_created_locked_and_appended(self):
        """Verify watchdog detects newly appearing whole disk, creates node, locks ro=1, and appends to inventory."""
        sdb_sys = os.path.join(self.mock_sys_block, "sdb")
        os.makedirs(sdb_sys, exist_ok=True)
        with open(os.path.join(sdb_sys, "device"), "w") as f:
            f.write("mock_hw\n")
        with open(os.path.join(sdb_sys, "dev"), "w") as f:
            f.write("8:16\n")
        sdb_node = os.path.join(self.mock_dev_block, "sdb")
        if os.path.exists(sdb_node):
            os.remove(sdb_node)

        with open(self.heartbeat_file, "w") as f:
            f.write("pet")

        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("Detected newly appearing physical disk: /dev/block/sdb", res.stderr)
        self.assertIn("Locked newly appearing disk read-only: /dev/block/sdb (ro=1)", res.stderr)
        with open(self.inv_file_mnt) as f:
            content_mnt = f.read()
        with open(self.inv_file_tmp) as f:
            content_tmp = f.read()
        self.assertEqual(content_mnt, content_tmp)
        self.assertIn("/dev/block/sdb:8:16:", content_mnt)

    def test_watchdog_newly_appearing_partition_mknod_failure_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION when mknod fails for a newly appearing partition."""
        sda3_sys = os.path.join(self.sda_sys, "sda3")
        os.makedirs(sda3_sys, exist_ok=True)
        with open(os.path.join(sda3_sys, "dev"), "w") as f:
            f.write("8:3\n")
        sda3_node = os.path.join(self.mock_dev_block, "sda3")
        if os.path.exists(sda3_node):
            os.remove(sda3_node)

        res = self.run_watchdog({"MKNOD_FAIL": "1", "WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("mknod failed for newly appearing partition '/dev/block/sda3'", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_newly_appearing_partition_failed_blockdev_setro_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION when blockdev --setro fails on newly appearing partition."""
        sda4_sys = os.path.join(self.sda_sys, "sda4")
        os.makedirs(sda4_sys, exist_ok=True)
        with open(os.path.join(sda4_sys, "dev"), "w") as f:
            f.write("8:4\n")
        sda4_node = os.path.join(self.mock_dev_block, "sda4")

        res = self.run_watchdog({
            "BLOCKDEV_SETRO_FAIL_DEV": sda4_node,
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("Failed to execute blockdev --setro on newly appearing partition", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_newly_appearing_partition_failed_blockdev_getro_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION when blockdev --getro fails or is not 1 on new partition."""
        sda5_sys = os.path.join(self.sda_sys, "sda5")
        os.makedirs(sda5_sys, exist_ok=True)
        with open(os.path.join(sda5_sys, "dev"), "w") as f:
            f.write("8:5\n")
        sda5_node = os.path.join(self.mock_dev_block, "sda5")

        res = self.run_watchdog({
            "BLOCKDEV_FAIL_DEV": sda5_node,
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("could not be locked read-only (ro=0, expected 1)", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_newly_appearing_partition_malformed_dev_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION when newly appearing partition has malformed sysfs dev."""
        sda6_sys = os.path.join(self.sda_sys, "sda6")
        os.makedirs(sda6_sys, exist_ok=True)
        with open(os.path.join(sda6_sys, "dev"), "w") as f:
            f.write("invalid_dev\n")

        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("has malformed dev file", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_newly_appearing_partition_inventory_append_failure_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION if inventory append fails."""
        sda7_sys = os.path.join(self.sda_sys, "sda7")
        os.makedirs(sda7_sys, exist_ok=True)
        with open(os.path.join(sda7_sys, "dev"), "w") as f:
            f.write("8:7\n")

        # Make directory in place of inv_file_mnt to cause update failure
        os.remove(self.inv_file_mnt)
        os.makedirs(self.inv_file_mnt, exist_ok=True)

        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    # --------------------------------------------------------------------------
    # Priority 3: Inventory Synchronization Regression Tests
    # --------------------------------------------------------------------------
    def test_watchdog_new_disk_updates_both_inventories(self):
        """Verify newly appearing disk updates both /mnt and /tmp inventory copies."""
        sdb_sys = os.path.join(self.mock_sys_block, "sdb")
        os.makedirs(sdb_sys, exist_ok=True)
        with open(os.path.join(sdb_sys, "device"), "w") as f:
            f.write("mock_hw\n")
        with open(os.path.join(sdb_sys, "dev"), "w") as f:
            f.write("8:16\n")
        sdb_node = os.path.join(self.mock_dev_block, "sdb")
        if os.path.exists(sdb_node):
            os.remove(sdb_node)

        with open(self.heartbeat_file, "w") as f:
            f.write("pet")

        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 0, f"Watchdog failed: {res.stderr}")
        with open(self.inv_file_mnt) as f:
            content_mnt = f.read()
        with open(self.inv_file_tmp) as f:
            content_tmp = f.read()
        self.assertIn("/dev/block/sdb:8:16:", content_mnt)
        self.assertIn("/dev/block/sdb:8:16:", content_tmp)
        self.assertEqual(content_mnt, content_tmp)

    def test_watchdog_new_partition_updates_both_inventories(self):
        """Verify newly appearing partition updates both /mnt and /tmp inventory copies."""
        sda1_sys = os.path.join(self.sda_sys, "sda1")
        os.makedirs(sda1_sys, exist_ok=True)
        with open(os.path.join(sda1_sys, "dev"), "w") as f:
            f.write("8:1\n")
        sda1_node = os.path.join(self.mock_dev_block, "sda1")
        if os.path.exists(sda1_node):
            os.remove(sda1_node)

        with open(self.heartbeat_file, "w") as f:
            f.write("pet")

        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 0, f"Watchdog failed: {res.stderr}")
        with open(self.inv_file_mnt) as f:
            content_mnt = f.read()
        with open(self.inv_file_tmp) as f:
            content_tmp = f.read()
        self.assertIn("/dev/block/sda1:8:1:", content_mnt)
        self.assertIn("/dev/block/sda1:8:1:", content_tmp)
        self.assertEqual(content_mnt, content_tmp)

    def test_watchdog_both_files_remain_byte_identical_after_update(self):
        """Verify both inventory files remain byte-identical after discovery and locking."""
        sda1_sys = os.path.join(self.sda_sys, "sda1")
        os.makedirs(sda1_sys, exist_ok=True)
        with open(os.path.join(sda1_sys, "dev"), "w") as f:
            f.write("8:1\n")
        with open(self.heartbeat_file, "w") as f:
            f.write("pet")

        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 0)
        with open(self.inv_file_mnt, "rb") as f1, open(self.inv_file_tmp, "rb") as f2:
            self.assertEqual(f1.read(), f2.read())

    def test_watchdog_missing_mnt_inventory_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION when /mnt inventory copy is missing."""
        os.remove(self.inv_file_mnt)
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Physical storage inventory missing at", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_missing_tmp_inventory_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION when /tmp inventory copy is missing."""
        os.remove(self.inv_file_tmp)
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Physical storage inventory missing at", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_initial_inventory_mismatch_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION when initial /mnt and /tmp copies mismatch."""
        with open(self.inv_file_tmp, "a") as f:
            f.write("/dev/block/mismatch:8:99:/sys/block/mismatch\n")
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("Initial physical storage inventory byte-identity mismatch", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_failure_copying_staging_file_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION if copying staging file fails."""
        sda1_sys = os.path.join(self.sda_sys, "sda1")
        os.makedirs(sda1_sys, exist_ok=True)
        with open(os.path.join(sda1_sys, "dev"), "w") as f:
            f.write("8:1\n")
        # Make staging directory read-only to prevent staging file creation
        os.chmod(self.mnt_dir, 0o555)
        try:
            res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
            self.assertEqual(res.returncode, 1)
            self.assertIn("Failed to copy", res.stderr)
            with open(self.state_file) as f:
                self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")
        finally:
            os.chmod(self.mnt_dir, 0o755)

    def test_watchdog_failure_appending_record_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION if record append fails."""
        sda1_sys = os.path.join(self.sda_sys, "sda1")
        os.makedirs(sda1_sys, exist_ok=True)
        with open(os.path.join(sda1_sys, "dev"), "w") as f:
            f.write("8:1\n")
        # Replace tmp inventory with directory so staging copy/append fails
        os.remove(self.inv_file_tmp)
        os.makedirs(self.inv_file_tmp, exist_ok=True)
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_failure_publishing_staged_file_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION if publication rename fails."""
        sda1_sys = os.path.join(self.sda_sys, "sda1")
        os.makedirs(sda1_sys, exist_ok=True)
        with open(os.path.join(sda1_sys, "dev"), "w") as f:
            f.write("8:1\n")
        # Target inventory replaced by non-empty directory prevents mv -f
        os.remove(self.inv_file_tmp)
        os.makedirs(self.inv_file_tmp, exist_ok=True)
        with open(os.path.join(self.inv_file_tmp, "blocker"), "w") as f:
            f.write("blocker\n")
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_final_byte_identity_mismatch_fails_closed(self):
        """Verify watchdog triggers STORAGE_VIOLATION if final published inventories mismatch."""
        with open(self.inv_file_mnt, "w") as f:
            f.write(f"/dev/block/sda:8:0:{self.sda_sys}\n")
        with open(self.inv_file_tmp, "w") as f:
            f.write(f"/dev/block/sda:8:0:{self.sda_sys}\n/dev/block/sdb:8:16:{self.sda_sys}\n")
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIn("byte-identity mismatch", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_duplicate_record_insertion_rejected(self):
        """Verify duplicate record insertion is rejected fail-closed."""
        res = self.run_watchdog({"WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res.returncode, 0)
        with open(self.inv_file_mnt) as f:
            lines = f.read().splitlines()
        sda_lines = [l for l in lines if l.startswith("/dev/block/sda:")]
        self.assertEqual(len(sda_lines), 1, "Duplicate sda record found in inventory!")

    # --------------------------------------------------------------------------
    # Priority 3: Block-Node Identity Verification Regression Tests
    # --------------------------------------------------------------------------
    def test_watchdog_correct_hex_major_minor_conversion_passes(self):
        """Verify correct hexadecimal major/minor conversion (e.g. 8:10 hex -> 8:16 dec) passes."""
        with open(os.path.join(self.sda_sys, "dev"), "w") as f:
            f.write("8:16\n")
        with open(self.inv_file_mnt, "w") as f:
            f.write(f"/dev/block/sda:8:16:{self.sda_sys}\n")
        self.sync_inventories()
        with open(self.heartbeat_file, "w") as f:
            f.write("pet")
        res = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_RAW_OUTPUT": "8:10",  # 0x10 hex == 16 decimal
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")

    def test_watchdog_correct_device_identity_passes(self):
        """Verify matching device identity passes verification."""
        with open(self.heartbeat_file, "w") as f:
            f.write("pet")
        with open(os.path.join(self.sda_sys, "dev"), "w") as f:
            f.write("8:1\n")
        with open(self.inv_file_mnt, "w") as f:
            f.write(f"/dev/block/sda:8:1:{self.sda_sys}\n")
        self.sync_inventories()
        res_pass = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_RAW_OUTPUT": "8:1",
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res_pass.returncode, 0, f"Failed: {res_pass.stderr}")

    def test_watchdog_incorrect_major_fails_closed(self):
        """Verify incorrect major number in stat output triggers STORAGE_VIOLATION."""
        res = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_RAW_OUTPUT": "9:0",  # expected 8:0
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("does not match sysfs", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_incorrect_minor_fails_closed(self):
        """Verify incorrect minor number in stat output triggers STORAGE_VIOLATION."""
        res = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_RAW_OUTPUT": "8:99",  # expected 8:0
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("does not match sysfs", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_malformed_stat_output_fails_closed(self):
        """Verify malformed stat output (missing colon or non-hex) triggers STORAGE_VIOLATION."""
        res = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_RAW_OUTPUT": "invalid_stat_string",
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("Malformed stat output", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_empty_stat_output_fails_closed(self):
        """Verify empty stat output triggers STORAGE_VIOLATION."""
        res = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_RAW_OUTPUT": "",
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("Empty stat output", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_both_stat_implementations_unavailable_fails_closed(self):
        """Verify absence of any stat binary triggers STORAGE_VIOLATION."""
        no_stat_dir = os.path.join(self.test_dir, "no_stat_bin")
        os.makedirs(no_stat_dir, exist_ok=True)
        sh_path = shutil.which("sh") or "/bin/sh"
        os.symlink(sh_path, os.path.join(no_stat_dir, "sh"))
        for tool in ["rm", "mv", "cp", "cat", "echo", "grep", "tr", "cut", "sed", "wc", "basename", "dirname", "printf", "cmp", "blockdev"]:
            tool_path = shutil.which(tool)
            if tool_path:
                os.symlink(tool_path, os.path.join(no_stat_dir, tool))
        res = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_BIN": "/nonexistent/stat_binary",
            "PATH": no_stat_dir,
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("No stat binary available", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_stat_exits_nonzero_fails_closed(self):
        """Verify non-zero stat exit code triggers STORAGE_VIOLATION."""
        res = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_FAIL": "1",
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("stat -L -c '%t:%T' failed on block node", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_zero_identity_rejected_for_physical_devices(self):
        """Verify unexpected zero device identity (0:0) triggers STORAGE_VIOLATION."""
        res = self.run_watchdog({
            "WATCHDOG_TEST_VERIFY_STAT": "1",
            "STAT_RAW_OUTPUT": "0:0",
            "WATCHDOG_MAX_TICKS": "1"
        })
        self.assertEqual(res.returncode, 1)
        self.assertIn("Unexpected zero device identity (0:0)", res.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")

    def test_watchdog_test_mode_regular_files_supported_without_weakening_production(self):
        """Verify regular file mocks pass in test mode but fail closed in production mode."""
        # 1. Test mode = 1: regular file mock passes
        with open(self.heartbeat_file, "w") as f:
            f.write("pet")
        res_test = self.run_watchdog({"WATCHDOG_TEST_MODE": "1", "WATCHDOG_MAX_TICKS": "1"})
        self.assertEqual(res_test.returncode, 0, f"Failed in test mode: {res_test.stderr}")

        # 2. Production mode (WATCHDOG_TEST_MODE = 0): regular file mock is rejected fail-closed
        res_prod = self.run_watchdog({
            "WATCHDOG_TEST_MODE": "0",
            "WATCHDOG_MAX_TICKS": "1",
            "WATCHDOG_INVENTORY_MNT": self.inv_file_mnt,
            "WATCHDOG_INVENTORY_TMP": self.inv_file_tmp
        })
        self.assertEqual(res_prod.returncode, 1)
        self.assertIn("is NOT a block device", res_prod.stderr)
        with open(self.state_file) as f:
            self.assertEqual(f.read().strip(), "STORAGE_VIOLATION")


if __name__ == "__main__":
    unittest.main(verbosity=2)
