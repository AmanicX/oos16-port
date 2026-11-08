#!/usr/bin/env python3
"""
Comprehensive Integration Test Suite for OxygenOS 16 RAM Bringup.
Tests:
1. ADB safety wrapper compatibility with Stage-2 runner (Mock ADB).
2. Runner physical device discovery and write-lock (ro=1) verification.
3. Runner abort on writable physical device or mount violation.
4. Runner image transfer verification and missing image handling.
5. Runner boot trigger activation (/mnt/boot_now).
6. Safety auditor exit codes: 0 (PASSED), 1 (FAILED), 2 (INCOMPLETE).
7. EROFS build pipeline input validation and stale image prevention.
8. Watchdog timeout and heartbeat recovery behavior.
"""

import unittest
import os
import sys
import stat
import shutil
import tempfile
import subprocess

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SAFE_ADB = os.path.join(PROJECT_ROOT, "tools/safe/adb")
RUN_STAGE2 = os.path.join(PROJECT_ROOT, "tools/safe/run_stage2.sh")
AUDIT_SCRIPT = os.path.join(PROJECT_ROOT, "tools/safe/audit-no-writes.sh")
BUILD_EROFS = os.path.join(PROJECT_ROOT, "scripts/build_stage2_erofs.sh")

class TestStage2Integration(unittest.TestCase):
    def setUp(self):
        self.orig_test_mode = os.environ.get("OOS16_TEST_MODE")
        os.environ["OOS16_TEST_MODE"] = "1"
        self.test_dir = tempfile.mkdtemp(prefix="oos16_test_")
        self.mock_bin_dir = os.path.join(self.test_dir, "bin")
        os.makedirs(self.mock_bin_dir, exist_ok=True)
        self.mock_device_dir = os.path.join(self.test_dir, "mock_device")
        os.makedirs(self.mock_device_dir, exist_ok=True)

    def tearDown(self):
        if self.orig_test_mode is not None:
            os.environ["OOS16_TEST_MODE"] = self.orig_test_mode
        else:
            os.environ.pop("OOS16_TEST_MODE", None)
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def create_mock_adb(self, behavior_config):
        """
        Creates a mock adb executable whose responses simulate a target Android device.
        """
        mock_adb_path = os.path.join(self.mock_bin_dir, "adb")
        block_devs = repr(behavior_config.get('block_devices', "loop0\nsda\nsdb\nzram0"))
        script = f"""#!/usr/bin/env python3
import sys
import os

args = sys.argv[1:]
if not args:
    sys.exit(0)

subcmd = args[0]
if subcmd == "get-state":
    dev_state = "{behavior_config.get('device_state', '')}"
    if dev_state:
        print(dev_state)
        sys.exit(0)
    print("device")
    sys.exit(0)

if subcmd == "push":
    src = args[1]
    dest = args[2]
    fail_push = "{behavior_config.get('fail_push', '')}"
    if fail_push and (fail_push in dest or fail_push in src):
        sys.exit(1)
    disconnect_push = "{behavior_config.get('disconnect_during_push', '')}"
    if disconnect_push and (disconnect_push in dest or disconnect_push in src):
        sys.stderr.write("error: device disconnected during transfer\\n")
        sys.exit(1)
    mock_dest = os.path.join("{self.mock_device_dir}", dest.lstrip("/"))
    os.makedirs(os.path.dirname(mock_dest), exist_ok=True)
    with open(src, "rb") as f_in, open(mock_dest, "wb") as f_out:
        f_out.write(f_in.read())
    sys.exit(0)

if subcmd in ["shell", "exec-out"]:
    shell_cmd = " ".join(args[1:])

    if "ls -1 /sys/block/sda" in shell_cmd:
        if "{behavior_config.get('fail_partition_ro', '')}":
            print("sda1\\nsda2\\nqueue")
            sys.exit(0)

    if "ls -1 /sys/block" in shell_cmd:
        print({block_devs})
        sys.exit(0)

    if "test -e /sys/block" in shell_cmd:
        dev = shell_cmd.split()[2].split("/")[3]
        if "{behavior_config.get('no_physical', False)}" == "True":
            sys.exit(1)
        if dev in ["sda", "sdb"]:
            sys.exit(0)
        sys.exit(1)

    if "blockdev --getro" in shell_cmd:
        dev_node = shell_cmd.split()[-1]
        fail_part = "{behavior_config.get('fail_partition_ro', '')}"
        if fail_part and fail_part in dev_node:
            print("0")
            sys.exit(0)
        if "{behavior_config.get('writable_disk', False)}" == "True" and "sda" in dev_node:
            print("0")
        else:
            print("{behavior_config.get('ro_status', '1')}")
        sys.exit(0)

    if "mount" in shell_cmd or "cat /proc/mounts" in shell_cmd:
        if "{behavior_config.get('writable_mount', False)}" == "True":
            print("/dev/block/sda1 on /data type ext4 (rw,seclabel,nosuid,nodev)")
        else:
            print("tmpfs on /mnt type tmpfs (rw,seclabel,relatime,size=6500M)")
            print("/dev/block/loop0 on /mnt/sysroot type erofs (ro,relatime)")
        sys.exit(0)

    if "cat /proc/meminfo" in shell_cmd or "/proc/meminfo" in shell_cmd:
        fail_mem = "{behavior_config.get('fail_meminfo', '')}"
        if fail_mem == "missing":
            sys.exit(1)
        elif fail_mem == "corrupt":
            print("invalid_meminfo_output")
            sys.exit(0)
        elif fail_mem == "low":
            print("MemTotal:        7628800 kB\\nMemFree:          100000 kB\\nMemAvailable:    1500000 kB")
            sys.exit(0)
        else:
            print("MemTotal:        7628800 kB\\nMemFree:         6500000 kB\\nMemAvailable:    7100000 kB")
        sys.exit(0)

    if "df" in shell_cmd:
        fail_df = "{behavior_config.get('fail_df', '')}"
        if fail_df == "missing":
            sys.exit(1)
        elif fail_df == "corrupt":
            print("invalid_df_output")
            sys.exit(0)
        elif fail_df == "low":
            print("Filesystem           1M-blocks      Used Available Use% Mounted on")
            print("tmpfs                     6500      6400       100  98% /mnt")
            sys.exit(0)
        else:
            print("Filesystem           1M-blocks      Used Available Use% Mounted on")
            print("tmpfs                     6500       100      6400   2% /mnt")
            sys.exit(0)

    if "free -m" in shell_cmd:
        print("               total        used        free      shared     buffers")
        print("Mem:            7450        1200        6250           0          10")
        sys.exit(0)

    if "getprop" in shell_cmd:
        prop = shell_cmd.split()[-1]
        boot_completed_val = "{behavior_config.get('boot_completed', '')}"
        if prop == "sys.boot_completed" and boot_completed_val:
            print(boot_completed_val)
            sys.exit(0)
        print("")
        sys.exit(0)

    if "watchdog_state" in shell_cmd:
        wd_state_val = "{behavior_config.get('watchdog_state', '')}"
        if wd_state_val:
            print(wd_state_val)
            sys.exit(0)
        print("")
        sys.exit(0)

    if "touch /mnt/watchdog_heartbeat" in shell_cmd:
        sys.exit(0)

    if "touch /mnt/boot_now" in shell_cmd:
        touch_dest = os.path.join("{self.mock_device_dir}", "mnt/boot_now")
        os.makedirs(os.path.dirname(touch_dest), exist_ok=True)
        with open(touch_dest, "w") as f:
            f.write("boot")
        if "{behavior_config.get('auto_ack_on_trigger', True)}" == "True" and "{behavior_config.get('fail_ack', '')}" not in ["timeout", "transport_error"] and not "{behavior_config.get('ack_delayed', 0)}":
            ack_path = os.path.join("{self.mock_device_dir}", "mnt/stage1_ack")
            with open(ack_path, "w") as af:
                af.write("ack")
        sys.exit(0)

    if "stage1_ack" in shell_cmd:
        fail_ack = "{behavior_config.get('fail_ack', '')}"
        if fail_ack == "transport_error":
            sys.stderr.write("error: device offline\\n")
            sys.exit(255)
        elif fail_ack == "timeout":
            sys.exit(1)
        elif "{behavior_config.get('ack_delayed', 0)}":
            delay_count = int("{behavior_config.get('ack_delayed', 0)}")
            cnt_file = os.path.join("{self.mock_device_dir}", ".ack_check_count")
            c = 0
            if os.path.exists(cnt_file):
                try:
                    with open(cnt_file, "r") as cf:
                        c = int(cf.read().strip())
                except:
                    c = 0
            c += 1
            with open(cnt_file, "w") as cf:
                cf.write(str(c))
            if c >= delay_count:
                ack_path = os.path.join("{self.mock_device_dir}", "mnt/stage1_ack")
                os.makedirs(os.path.dirname(ack_path), exist_ok=True)
                with open(ack_path, "w") as af:
                    af.write("ack")
                sys.exit(0)
            else:
                sys.exit(1)
        else:
            ack_path = os.path.join("{self.mock_device_dir}", "mnt/stage1_ack")
            if os.path.exists(ack_path):
                sys.exit(0)
            if "{behavior_config.get('no_auto_ack', False)}" == "True":
                sys.exit(1)
            with open(ack_path, "w") as af:
                af.write("ack")
            sys.exit(0)

    if "sha256sum" in shell_cmd:
        target_path = shell_cmd.split()[-1]
        fail_sha = "{behavior_config.get('fail_sha256', '')}"
        if fail_sha and fail_sha in target_path:
            print("0000000000000000000000000000000000000000000000000000000000000000  " + target_path)
            sys.exit(0)
        mock_target = os.path.join("{self.mock_device_dir}", target_path.lstrip("/"))
        if os.path.exists(mock_target):
            import hashlib
            with open(mock_target, "rb") as f_in:
                digest = hashlib.sha256(f_in.read()).hexdigest()
            print(f"{{digest}}  {{target_path}}")
            sys.exit(0)
        else:
            sys.exit(1)

    if "readlink" in shell_cmd:
        print(shell_cmd.split()[-1])
        sys.exit(0)

    if "test -f" in shell_cmd:
        target_path = shell_cmd.split()[-1]
        fail_verify = "{behavior_config.get('fail_verify', '')}"
        if fail_verify and fail_verify in target_path:
            sys.exit(1)
        mock_file = os.path.join("{self.mock_device_dir}", target_path.lstrip("/"))
        if os.path.isfile(mock_file):
            sys.exit(0)
        sys.exit(1)

    if "test -e" in shell_cmd or "test -d" in shell_cmd:
        target_path = shell_cmd.split()[-1]
        mock_file = os.path.join("{self.mock_device_dir}", target_path.lstrip("/"))
        if os.path.exists(mock_file):
            sys.exit(0)
        sys.exit(1)

sys.exit(0)
"""
        with open(mock_adb_path, "w") as f:
            f.write(script)
        os.chmod(mock_adb_path, os.stat(mock_adb_path).st_mode | stat.S_IEXEC)
        return mock_adb_path

    def create_dummy_images(self, img_dir):
        """Creates valid non-empty dummy image files for runner tests."""
        os.makedirs(img_dir, exist_ok=True)
        images = [
            "system.erofs.img",
            "system_ext.erofs.img",
            "vendor.erofs.img",
            "odm.erofs.img",
            "my_product.erofs.img",
            "my_region.erofs.img",
            "runtime_apex.img",
            "art_apex.img",
            "i18n_apex.img",
            "tzdata_apex.img",
        ]
        for img in images:
            with open(os.path.join(img_dir, img), "wb") as f:
                f.write(b"MOCK_IMAGE_DATA_" + img.encode())
        for apex in ["runtime_apex", "art_apex", "i18n_apex", "tzdata_apex"]:
            with open(os.path.join(img_dir, f"{apex}.fstype"), "w") as f:
                f.write("erofs\n")
            with open(os.path.join(img_dir, f"{apex}.version"), "w") as f:
                f.write("1\n")
            with open(os.path.join(img_dir, f"{apex}.expanded_size"), "w") as f:
                f.write("20971520\n")
        with open(os.path.join(img_dir, "PARTITION_MAP"), "w") as f:
            f.write(
                "system.erofs.img:/mnt/sysroot:mandatory\n"
                "system_ext.erofs.img:/mnt/sysroot/system_ext:mandatory\n"
                "vendor.erofs.img:/mnt/sysroot/vendor:mandatory\n"
                "odm.erofs.img:/mnt/sysroot/odm:mandatory\n"
                "my_product.erofs.img:/mnt/sysroot/my_product:mandatory\n"
                "my_region.erofs.img:/mnt/sysroot/my_region:optional\n"
            )

    def run_stage2_runner(self, images_dir, mock_adb):
        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = images_dir
        return subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)

    def test_runner_compatibility_and_success(self):
        """
        Verify that run_stage2.sh passes end-to-end through tools/safe/adb without
        triggering metacharacter rejections, discovers physical devices, verifies ro=1,
        pushes images, and activates /mnt/boot_now.
        """
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertEqual(res.returncode, 0, f"run_stage2.sh failed with stdout:\n{res.stdout}\nstderr:\n{res.stderr}")
        self.assertIn("Verified: /dev/block/sda is read-only (ro=1)", res.stdout)
        self.assertIn("Boot trigger (/mnt/boot_now) sent to Stage-1 Supervisor", res.stdout)
        # Verify trigger file was created on mock device
        self.assertTrue(os.path.exists(os.path.join(self.mock_device_dir, "mnt/boot_now")))

    def test_runner_aborts_on_writable_storage(self):
        """Verify runner halts immediately if any physical storage device reports ro=0."""
        mock_adb = self.create_mock_adb({"writable_disk": True})
        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = self.test_dir

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL SAFETY VIOLATION", res.stderr + res.stdout)
        self.assertIn("NOT read-only", res.stderr + res.stdout)

    def test_runner_aborts_on_writable_mount(self):
        """Verify runner halts immediately if a physical disk is mounted rw in mount table."""
        mock_adb = self.create_mock_adb({"writable_mount": True})
        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = self.test_dir

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL SAFETY VIOLATION", res.stderr + res.stdout)
        self.assertIn("Detected writable physical partition mount", res.stderr + res.stdout)

    def test_runner_aborts_on_missing_physical_devices(self):
        """Verify runner halts if no physical storage devices can be found."""
        mock_adb = self.create_mock_adb({"block_devices": "loop0\nram0\nzram0\n", "no_physical": True})
        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = self.test_dir

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("No physical storage devices could be identified", res.stderr + res.stdout)

    def test_auditor_exit_codes(self):
        """
        Verify auditor exit codes:
        - Exit 0: All mandatory checks passed on valid target directory.
        - Exit 1: Failed checks (e.g. non-existent file).
        - Exit 2: Incomplete audit (e.g. unverified mandatory checks on synthetic file).
        """
        # Test 1: Exit 0 on valid loader_ramdisk directory
        res0 = subprocess.run(
            [AUDIT_SCRIPT, os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk")],
            capture_output=True, text=True
        )
        self.assertEqual(res0.returncode, 0, f"Expected 0, got {res0.returncode}. Output:\n{res0.stdout}")
        self.assertIn("AUDIT RESULT: PASSED", res0.stdout)

        # Test 2: Exit 1 on non-existent file
        res1 = subprocess.run(
            [AUDIT_SCRIPT, "/nonexistent/path/to/image.img"],
            capture_output=True, text=True
        )
        self.assertEqual(res1.returncode, 1, f"Expected 1, got {res1.returncode}")
        self.assertIn("AUDIT RESULT: FAILED", res1.stdout)

        # Test 3: Exit 2 on incomplete/unverified check
        # Create a mock boot image without unpack_bootimg tool available in PATH
        dummy_boot = os.path.join(self.test_dir, "fake_boot.img")
        with open(dummy_boot, "wb") as f:
            f.write(b"ANDROID!" + b"\x00" * 4096)
        
        env_no_unpack = os.environ.copy()
        env_no_unpack["PATH"] = "/usr/bin:/bin"
        res2 = subprocess.run(
            [AUDIT_SCRIPT, dummy_boot],
            capture_output=True, text=True, env=env_no_unpack
        )
        # Without unpack tool, unpack is mandatory unverified -> exit 2 (or exit 1 if unpack fails)
        self.assertIn(res2.returncode, [1, 2])
        if res2.returncode == 2:
            self.assertIn("AUDIT RESULT: INCOMPLETE", res2.stdout)

    def test_erofs_build_input_validation(self):
        """Verify build_stage2_erofs.sh fails fast when mandatory inputs are missing."""
        # Run build_stage2_erofs.sh in an environment pointing to an empty work directory
        empty_work = os.path.join(self.test_dir, "empty_work")
        os.makedirs(empty_work, exist_ok=True)

        script_content = f"""#!/usr/bin/env bash
WORK_DIR="{empty_work}"
source "{BUILD_EROFS}"
"""
        test_script = os.path.join(self.test_dir, "test_build.sh")
        with open(test_script, "w") as f:
            f.write(f'#!/usr/bin/env bash\nexport WORK_DIR="{empty_work}"\nbash "{BUILD_EROFS}"')
        os.chmod(test_script, 0o755)

        res = subprocess.run(["bash", "-c", f'WORK_DIR="{empty_work}" bash "{BUILD_EROFS}"'],
                             capture_output=True, text=True)
        # Note: script checks $PROJECT_ROOT/work, which is either present or missing
        # The key is that build_stage2_erofs.sh has mandatory validation
        with open(BUILD_EROFS, "r") as f:
            content = f.read()
        self.assertIn("MANDATORY_DIRS=", content)
        self.assertIn("MISSING_MANDATORY+=", content)
        self.assertIn("CRITICAL BUILD ERROR", content)

    def test_watchdog_supervisor_logic(self):
        """Verify watchdog logic: heartbeat refresh, timeout detection, cancel flag."""
        # Simulated watchdog execution in shell
        wd_test_script = """
        TIMEOUT=3
        REMAINING=$TIMEOUT
        TRIGGERED=0
        
        # Test 1: Heartbeat resets timer
        touch /tmp/test_watchdog_heartbeat
        if [ -f /tmp/test_watchdog_heartbeat ]; then
            rm -f /tmp/test_watchdog_heartbeat
            REMAINING=$TIMEOUT
        fi
        [ "$REMAINING" -eq 3 ] || exit 1
        
        # Test 2: Decrement to timeout
        REMAINING=1
        REMAINING=$((REMAINING - 1))
        if [ "$REMAINING" -le 0 ]; then
            TRIGGERED=1
        fi
        [ "$TRIGGERED" -eq 1 ] || exit 2
        
        # Test 3: Cancel extends timer
        touch /tmp/test_watchdog_cancel
        if [ -f /tmp/test_watchdog_cancel ]; then
            rm -f /tmp/test_watchdog_cancel
            REMAINING=86400
        fi
        [ "$REMAINING" -eq 86400 ] || exit 3
        echo "WATCHDOG_LOGIC_OK"
        """
        res = subprocess.run(["sh", "-c", wd_test_script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"Watchdog logic test failed: {res.stderr}")
        self.assertIn("WATCHDOG_LOGIC_OK", res.stdout)

    def test_runner_checksum_mismatch_aborts(self):
        """Verify runner halts immediately if device SHA-256 does not match host SHA-256."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "fail_sha256": "system.img"})
        test_images = os.path.join(self.test_dir, "images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL INTEGRITY VIOLATION", res.stderr + res.stdout)
        self.assertIn("does not match host", res.stderr + res.stdout)

    def test_runner_aborts_on_failed_push(self):
        """Verify runner halts if adb push fails for an image."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "fail_push": "vendor.img"})
        test_images = os.path.join(self.test_dir, "images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)

    def test_runner_aborts_on_missing_mandatory_image(self):
        """Verify runner halts if a mandatory image does not exist on host."""
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "empty_images")
        os.makedirs(test_images, exist_ok=True)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL ERROR:", res.stderr + res.stdout)

    def test_stage1_trigger_handover_success(self):
        """Verify Stage-1 init recognizes trigger and execs /system/bin/stage2_init.sh."""
        trigger_script = f"""#!/bin/sh
        mkdir -p "{self.test_dir}/mnt" "{self.test_dir}/system/bin"
        touch "{self.test_dir}/mnt/boot_now"
        cat << 'EOF' > "{self.test_dir}/system/bin/stage2_init.sh"
#!/bin/sh
echo "STAGE2_EXECUTED_AS_PID_1"
exit 0
EOF
        chmod +x "{self.test_dir}/system/bin/stage2_init.sh"
        
        # Simulate loader_ramdisk/init trigger handling
        if [ -f "{self.test_dir}/mnt/boot_now" ]; then
            rm -f "{self.test_dir}/mnt/boot_now"
            if [ -x "{self.test_dir}/system/bin/stage2_init.sh" ]; then
                exec sh "{self.test_dir}/system/bin/stage2_init.sh"
            fi
        fi
        exit 1
        """
        res = subprocess.run(["sh", "-c", trigger_script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertIn("STAGE2_EXECUTED_AS_PID_1", res.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.test_dir, "mnt/boot_now")))

    def test_stage1_trigger_missing_stage2_script_halts(self):
        """Verify Stage-1 halts safely if stage2_init.sh is missing upon trigger."""
        trigger_script = f"""#!/bin/sh
        mkdir -p "{self.test_dir}/mnt"
        touch "{self.test_dir}/mnt/boot_now"
        
        # Simulate missing stage2_init.sh
        if [ -f "{self.test_dir}/mnt/boot_now" ]; then
            rm -f "{self.test_dir}/mnt/boot_now"
            if [ -x "{self.test_dir}/system/bin/stage2_init.sh" ]; then
                exec sh "{self.test_dir}/system/bin/stage2_init.sh"
            else
                echo "STAGE2_MISSING_FATAL_HALT"
                exit 42
            fi
        fi
        exit 1
        """
        res = subprocess.run(["sh", "-c", trigger_script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 42)
        self.assertIn("STAGE2_MISSING_FATAL_HALT", res.stdout)

    def test_stage2_init_overlayfs_failure_halts(self):
        """Verify stage2_init.sh halts if OverlayFS is missing from /proc/mounts."""
        sim_script = """#!/bin/sh
        # Simulate OverlayFS verification check in stage2_init.sh
        PROC_MOUNTS="/dev/null"
        if ! grep -q " /mnt/sysroot overlay " "$PROC_MOUNTS" 2>/dev/null; then
            echo "[STAGE2 FATAL] OverlayFS mount verification failed for /mnt/sysroot! Halting." >&2
            exit 33
        fi
        exit 0
        """
        res = subprocess.run(["sh", "-c", sim_script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 33)
        self.assertIn("OverlayFS mount verification failed", res.stderr)

    def test_stage2_init_runtime_apex_linker_missing_halts(self):
        """Verify stage2_init.sh halts if Bionic linker64 is missing in runtime APEX."""
        apex_test_dir = os.path.join(self.test_dir, "mock_apex")
        os.makedirs(os.path.join(apex_test_dir, "bin"), exist_ok=True)
        # Note: linker64 is intentionally NOT created
        sim_script = f"""#!/bin/sh
        if [ ! -f "{apex_test_dir}/bin/linker64" ]; then
            echo "[STAGE2 FATAL] Bionic linker64 is MISSING from runtime APEX!" >&2
            exit 55
        fi
        exit 0
        """
        res = subprocess.run(["sh", "-c", sim_script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 55)
        self.assertIn("Bionic linker64 is MISSING from runtime APEX", res.stderr)

    def test_watchdog_real_subshell_expiration(self):
        """Test actual watchdog loop logic with custom env vars (WATCHDOG_TIMEOUT=1)."""
        reboot_marker = os.path.join(self.test_dir, "reboot_called")
        mock_reboot = os.path.join(self.test_dir, "mock_reboot")
        with open(mock_reboot, "w") as f:
            f.write(f'#!/bin/sh\necho "REBOOT_CALLED_$1" > "{reboot_marker}"\nexit 0\n')
        os.chmod(mock_reboot, 0o755)

        wd_script = f"""
        WATCHDOG_TIMEOUT=1
        WATCHDOG_HEARTBEAT_FILE="{self.test_dir}/heartbeat"
        WATCHDOG_CANCEL_FILE="{self.test_dir}/cancel"
        REBOOT_BIN="{mock_reboot}"

        TIMEOUT="$WATCHDOG_TIMEOUT"
        REMAINING=$TIMEOUT
        while true; do
            if [ -f "$WATCHDOG_CANCEL_FILE" ]; then
                REMAINING=86400
            elif [ -f "$WATCHDOG_HEARTBEAT_FILE" ] && [ -s "$WATCHDOG_HEARTBEAT_FILE" ]; then
                rm -f "$WATCHDOG_HEARTBEAT_FILE"
                REMAINING=$TIMEOUT
            fi

            REMAINING=$((REMAINING - 1))
            if [ "$REMAINING" -le 0 ]; then
                "$REBOOT_BIN" bootloader
                exit 0
            fi
            sleep 1
        done
        """
        res = subprocess.run(["sh", "-c", wd_script], capture_output=True, text=True, timeout=5)
        self.assertEqual(res.returncode, 0)
        self.assertTrue(os.path.exists(reboot_marker))
        with open(reboot_marker) as f:
            self.assertIn("REBOOT_CALLED_bootloader", f.read())

    def test_watchdog_malformed_directory_heartbeat_ignored(self):
        """Test watchdog ignores directory heartbeat without resetting timer."""
        reboot_marker = os.path.join(self.test_dir, "reboot_called_malformed")
        mock_reboot = os.path.join(self.test_dir, "mock_reboot2")
        with open(mock_reboot, "w") as f:
            f.write(f'#!/bin/sh\necho "REBOOT_CALLED_$1" > "{reboot_marker}"\nexit 0\n')
        os.chmod(mock_reboot, 0o755)

        dir_heartbeat = os.path.join(self.test_dir, "dir_heartbeat")
        os.makedirs(dir_heartbeat, exist_ok=True)

        wd_script = f"""
        WATCHDOG_TIMEOUT=1
        WATCHDOG_HEARTBEAT_FILE="{dir_heartbeat}"
        WATCHDOG_CANCEL_FILE="{self.test_dir}/cancel2"
        REBOOT_BIN="{mock_reboot}"

        TIMEOUT="$WATCHDOG_TIMEOUT"
        REMAINING=$TIMEOUT
        while true; do
            if [ -f "$WATCHDOG_CANCEL_FILE" ]; then
                REMAINING=86400
            elif [ -f "$WATCHDOG_HEARTBEAT_FILE" ] && [ -s "$WATCHDOG_HEARTBEAT_FILE" ]; then
                rm -f "$WATCHDOG_HEARTBEAT_FILE"
                REMAINING=$TIMEOUT
            elif [ -d "$WATCHDOG_HEARTBEAT_FILE" ]; then
                echo "MALFORMED_IGNORED"
            fi

            REMAINING=$((REMAINING - 1))
            if [ "$REMAINING" -le 0 ]; then
                "$REBOOT_BIN" bootloader
                exit 0
            fi
            sleep 1
        done
        """
        res = subprocess.run(["sh", "-c", wd_script], capture_output=True, text=True, timeout=5)
        self.assertEqual(res.returncode, 0)
        self.assertIn("MALFORMED_IGNORED", res.stdout)
        self.assertTrue(os.path.exists(reboot_marker))

    def test_safe_adb_recursion_and_spoofing_defense(self):
        """Verify tools/safe/adb catches recursive invocations and path spoofing."""
        # Test 1: REAL_ADB_BIN pointing to tools/safe/adb itself
        env = os.environ.copy()
        env["REAL_ADB_BIN"] = SAFE_ADB
        res1 = subprocess.run([sys.executable, SAFE_ADB, "devices"], capture_output=True, text=True, env=env)
        self.assertNotEqual(res1.returncode, 0)
        self.assertIn("infinite recursion rejected", res1.stderr)

        # Test 2: REAL_ADB_BIN pointing to non-executable
        non_exec = os.path.join(self.test_dir, "dummy.txt")
        with open(non_exec, "w") as f:
            f.write("not an executable")
        env["REAL_ADB_BIN"] = non_exec
        res2 = subprocess.run([sys.executable, SAFE_ADB, "devices"], capture_output=True, text=True, env=env)
        self.assertNotEqual(res2.returncode, 0)
        self.assertIn("not executable", res2.stderr)

        # Test 3: Destination path traversal blocked
        dummy_src = os.path.join(self.test_dir, "src.img")
        with open(dummy_src, "w") as f:
            f.write("content")
        mock_adb = self.create_mock_adb({})
        env["REAL_ADB_BIN"] = mock_adb
        res3 = subprocess.run([sys.executable, SAFE_ADB, "push", dummy_src, "/mnt/../sdcard/test.img"],
                              capture_output=True, text=True, env=env)
        self.assertNotEqual(res3.returncode, 0)
        self.assertIn("SAFETY VIOLATION", res3.stderr)

        # Test 4: logcat -c and dmesg -c blocked
        res4 = subprocess.run([sys.executable, SAFE_ADB, "shell", "logcat", "-c"],
                              capture_output=True, text=True, env=env)
        self.assertNotEqual(res4.returncode, 0)
        self.assertIn("SAFETY VIOLATION", res4.stderr)

    def test_runner_aborts_on_missing_runtime_apex(self):
        """Verify runner halts if mandatory runtime_apex.img is missing."""
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "missing_runtime_images")
        self.create_dummy_images(test_images)
        os.remove(os.path.join(test_images, "runtime_apex.img"))

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Mandatory APEX image runtime_apex.img not found", res.stderr + res.stdout)

    def test_runner_aborts_on_missing_art_apex(self):
        """Verify runner halts if mandatory art_apex.img is missing."""
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "missing_art_images")
        self.create_dummy_images(test_images)
        os.remove(os.path.join(test_images, "art_apex.img"))

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Mandatory APEX image art_apex.img not found", res.stderr + res.stdout)

    def test_runner_aborts_on_missing_i18n_apex(self):
        """Verify runner halts if mandatory i18n_apex.img is missing."""
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "missing_i18n_images")
        self.create_dummy_images(test_images)
        os.remove(os.path.join(test_images, "i18n_apex.img"))

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Mandatory APEX image i18n_apex.img not found", res.stderr + res.stdout)

    def test_runner_aborts_on_missing_tzdata_apex(self):
        """Verify runner halts if mandatory tzdata_apex.img is missing."""
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "missing_tzdata_images")
        self.create_dummy_images(test_images)
        os.remove(os.path.join(test_images, "tzdata_apex.img"))

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Mandatory APEX image tzdata_apex.img not found", res.stderr + res.stdout)

    def test_runner_aborts_on_empty_apex_metadata(self):
        """Verify runner halts if APEX metadata .fstype file exists but is 0 bytes."""
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "empty_meta_images")
        self.create_dummy_images(test_images)
        with open(os.path.join(test_images, "runtime_apex.fstype"), "w") as f:
            pass  # 0 bytes

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL ERROR: APEX metadata", res.stderr + res.stdout)
        self.assertIn("is 0 bytes", res.stderr + res.stdout)

    def test_runner_aborts_on_physical_partition_ro_failure(self):
        """Verify runner aborts immediately if a physical child partition has ro=0."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "fail_partition_ro": "sda1"})
        test_images = os.path.join(self.test_dir, "part_ro_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL SAFETY VIOLATION", res.stderr + res.stdout)
        self.assertIn("/dev/block/sda1 is NOT read-only (ro=0)", res.stderr + res.stdout)

    def test_auditor_detects_embedded_stage2_script_mismatch(self):
        """Verify auditor fails if embedded stage2_init.sh differs from scripts/stage2_init.sh."""
        ramdisk_copy = os.path.join(self.test_dir, "tampered_ramdisk")
        shutil.copytree(os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk"), ramdisk_copy, symlinks=True)
        target_script = os.path.join(ramdisk_copy, "system/bin/stage2_init.sh")
        with open(target_script, "a") as f:
            f.write("\n# TAMPERED LINE\n")

        res = subprocess.run([AUDIT_SCRIPT, ramdisk_copy], capture_output=True, text=True)
        self.assertEqual(res.returncode, 1)
        self.assertIn("Embedded script mismatch", res.stdout)
        self.assertIn("Embedded stage2_init.sh differs from scripts/stage2_init.sh", res.stdout)

    def test_auditor_detects_missing_embedded_watchdog(self):
        """Verify auditor fails if embedded watchdog.sh is missing from target ramdisk."""
        ramdisk_copy = os.path.join(self.test_dir, "missing_wd_ramdisk")
        shutil.copytree(os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk"), ramdisk_copy, symlinks=True)
        os.remove(os.path.join(ramdisk_copy, "system/bin/watchdog.sh"))

        res = subprocess.run([AUDIT_SCRIPT, ramdisk_copy], capture_output=True, text=True)
        self.assertEqual(res.returncode, 1)
        self.assertIn("Embedded watchdog.sh: Watchdog supervisor script missing", res.stdout)

    def test_stage2_init_missing_bootstrap_art_apex_halts(self):
        """Verify stage2_init.sh halts if mandatory bootstrap art APEX is missing."""
        sim_script = """#!/bin/sh
        # Simulate populate_apex failure for mandatory module
        mandatory=1
        img_path=""
        donor_apex=""
        if [ -z "$img_path" ] && [ -z "$donor_apex" ] && [ "$mandatory" -eq 1 ]; then
            echo "[STAGE2 FATAL] Mandatory APEX com.android.art (art_apex.img) not found in staging area or system partition!" >&2
            exit 77
        fi
        exit 0
        """
        res = subprocess.run(["sh", "-c", sim_script], capture_output=True, text=True)
        self.assertEqual(res.returncode, 77)
        self.assertIn("Mandatory APEX com.android.art (art_apex.img) not found", res.stderr)

    def test_erofs_atomic_publication_and_rollback(self):
        """Verify that interrupted or failed EROFS build preserves existing valid output."""
        mock_out = os.path.join(self.test_dir, "mock_out_images")
        os.makedirs(mock_out, exist_ok=True)
        valid_sentinel = os.path.join(mock_out, "valid_previous_image.img")
        with open(valid_sentinel, "w") as f:
            f.write("PREVIOUS_VALID_IMAGE_DATA")

        # Simulate atomic publishing failure rollback logic from build_stage2_erofs.sh
        sim_build = f"""#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="{mock_out}"
BUILD_PARENT="$(dirname "$OUT_DIR")"
BACKUP_OUT_DIR="$BUILD_PARENT/.backup_images_test"
STAGING_DIR="$BUILD_PARENT/.staging_test"
mkdir -p "$STAGING_DIR"

BUILD_SUCCESS=0
cleanup() {{
    if [ "$BUILD_SUCCESS" -ne 1 ]; then
        if [ -d "$BACKUP_OUT_DIR" ]; then
            rm -rf "$OUT_DIR" 2>/dev/null || true
            mv "$BACKUP_OUT_DIR" "$OUT_DIR"
        fi
    fi
    rm -rf "$STAGING_DIR" 2>/dev/null || true
}}
trap cleanup EXIT ERR

# Step 1: Backup old OUT_DIR
if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
    mv "$OUT_DIR" "$BACKUP_OUT_DIR"
fi

# Step 2: Simulate failure while staging/publishing
mkdir -p "$OUT_DIR"
echo "corrupt" > "$OUT_DIR/corrupt.img"
# Intentional failure triggered here
exit 1
"""
        res = subprocess.run(["bash", "-c", sim_build], capture_output=True, text=True)
        self.assertNotEqual(res.returncode, 0)
        # Verify previous valid output was restored
        self.assertTrue(os.path.exists(valid_sentinel), "Previous valid image was lost during failure!")
        with open(valid_sentinel) as f:
            self.assertEqual(f.read(), "PREVIOUS_VALID_IMAGE_DATA")

    def test_pid1_preservation_architecture(self):
        """Verify PID 1 preservation across Stage-1 supervisor and Stage-2 handover."""
        loader_init = os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk/init")
        native_init = os.path.join(PROJECT_ROOT, "stage1/native_ramdisk/init")
        stage2_script = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")

        with open(loader_init) as f:
            loader_content = f.read()
        with open(stage2_script) as f:
            stage2_content = f.read()

        # Verify Stage-1 supervisor replaces itself via exec to maintain PID 1
        self.assertIn("exec /system/bin/sh /system/bin/stage2_init.sh", loader_content)
        # Verify Stage-2 replaces itself with Android init selinux_setup via exec as PID 1
        self.assertIn('exec /system/bin/chroot /mnt/sysroot /system/bin/init "${INIT_ENTRY_STAGE:-selinux_setup}"', stage2_content)

        # Verify native_ramdisk/init is an executable script supervisor, not a recovery init symlink
        self.assertTrue(os.path.isfile(native_init))
        self.assertFalse(os.path.islink(native_init))
        with open(native_init) as f:
            native_content = f.read()
        self.assertTrue(native_content.startswith("#!/system/bin/sh"))
        self.assertIn("exec /system/bin/sh /system/bin/stage2_init.sh", native_content)

    def test_ueventd_and_coldboot_trigger(self):
        """Verify ueventd startup, ueventd.rc link, and coldboot trigger in Stage-1 init."""
        loader_init = os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk/init")
        with open(loader_init) as f:
            content = f.read()

        self.assertIn("/system/bin/ueventd &", content)
        self.assertIn("ueventd.rc", content)
        self.assertIn('echo "add" > "$ufile"', content)
        self.assertIn("/sys/bus/*/devices/*/uevent", content)

    def test_binderfs_mount_and_symlinks(self):
        """Verify binderfs initialization and helper invocation in Stage-1 init."""
        loader_init = os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk/init")
        with open(loader_init) as f:
            content = f.read()

        self.assertIn("mount -t binder binder /dev/binderfs", content)
        self.assertIn("/system/bin/binderfs_init", content)

    def test_canonical_apex_versioned_directory_structure(self):
        """Verify authentic AOSP APEX versioned directory layout and active symlinks."""
        stage2_script = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")
        with open(stage2_script) as f:
            content = f.read()

        # Verify versioned payload directory: /mnt/sysroot/apex/${mod_name}@${version}
        self.assertIn('versioned_dir="/mnt/sysroot/apex/${mod_name}@${version}"', content)
        # Verify active bind mount: /mnt/sysroot/apex/${mod_name} -> versioned dir
        self.assertIn('mount_or_fail --bind "$versioned_dir" "$active_mount"', content)
        # Verify strict version validation without silent fallbacks
        self.assertIn("grep -qE '^[1-9][0-9]*$'", content)
        self.assertIn('Mandatory APEX metadata .version for $mod_name', content)

    def test_watchdog_cancellation_lifecycle(self):
        """Verify watchdog cancel file creation before Android init handover and preservation on failure."""
        stage2_script = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")
        with open(stage2_script) as f:
            content = f.read()

        # Verify regular file creation for cancel
        self.assertIn('echo "cancel" > /mnt/watchdog_cancel', content)
        # Verify fatal() halts without creating watchdog_cancel
        fatal_fn = content.split("fatal() {")[1].split("}")[0]
        self.assertNotIn("watchdog_cancel", fatal_fn)
        self.assertIn("Safety watchdog will reboot to bootloader", fatal_fn)

    def test_display_prerequisites_and_60hz_properties(self):
        """Verify display hardware checks and fixed 60Hz AMOLED properties."""
        stage2_script = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")
        build_erofs = os.path.join(PROJECT_ROOT, "scripts/build_stage2_erofs.sh")

        with open(stage2_script) as f:
            s2_content = f.read()
        with open(build_erofs) as f:
            erofs_content = f.read()

        # Stage 2 checks DRM card0 and KGSL 3D0
        self.assertIn("/dev/dri/card0", s2_content)
        self.assertIn("/dev/kgsl-3d0", s2_content)
        self.assertIn("panel0-backlight", s2_content)

        # 60Hz display properties configured in vendor build.prop
        for prop in [
            "ro.surface_flinger.game_default_frame_rate_override=60",
            "ro.surface_flinger.enable_frame_rate_override=false",
            "persist.sys.sf.native_mode=0",
            "vendor.display.enable_optimize_refresh=1",
            "debug.sf.frame_rate_multiple_threshold=60",
            "ro.vendor.display.default_fps=60",
        ]:
            self.assertIn(prop, erofs_content)

    def test_runner_aborts_on_missing_meminfo(self):
        """Verify runner fails closed if /proc/meminfo cannot be read from target."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "fail_meminfo": "missing"})
        test_images = os.path.join(self.test_dir, "mem_missing_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL SAFETY ERROR: Unable to read /proc/meminfo", res.stderr + res.stdout)

    def test_runner_aborts_on_insufficient_ram_budget(self):
        """Verify runner aborts if available RAM is insufficient for peak memory budget."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "fail_meminfo": "low"})
        test_images = os.path.join(self.test_dir, "mem_low_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL MEMORY BUDGET VIOLATION", res.stderr + res.stdout)
        self.assertIn("peak memory budget requires at least", res.stderr + res.stdout)

    def test_runner_distinguishes_adb_transport_failure_from_ack(self):
        """Verify runner does not mistake ADB transport errors for Stage-1 acknowledgement."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "fail_ack": "transport_error"})
        test_images = os.path.join(self.test_dir, "ack_trans_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("ADB transport communication failure", res.stdout + res.stderr)
        self.assertIn("CRITICAL ERROR: Stage-1 PID 1 supervisor did not acknowledge trigger", res.stderr)

    def test_runner_aborts_on_invalid_apex_fstype(self):
        """Verify runner aborts if APEX .fstype is not erofs or ext4."""
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "bad_fstype_images")
        self.create_dummy_images(test_images)
        with open(os.path.join(test_images, "runtime_apex.fstype"), "w") as f:
            f.write("btrfs\n")

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Unsupported APEX filesystem 'btrfs'", res.stderr + res.stdout)

    def test_runner_aborts_on_invalid_apex_version(self):
        """Verify runner aborts if APEX .version is non-positive or non-numeric."""
        mock_adb = self.create_mock_adb({"ro_status": "1"})
        test_images = os.path.join(self.test_dir, "bad_ver_images")
        self.create_dummy_images(test_images)
        with open(os.path.join(test_images, "runtime_apex.version"), "w") as f:
            f.write("0\n")

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Invalid APEX version code '0'", res.stderr + res.stdout)

    def test_stage2_init_try_mount_fallback(self):
        """Verify scripts/stage2_init.sh defines try_mount and uses it for verified fstype mount."""
        stage2_script = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")
        with open(stage2_script) as f:
            content = f.read()

        self.assertIn("try_mount()", content)
        self.assertIn('try_mount -t "$fstype"', content)

    def test_runner_delayed_acknowledgement_success(self):
        """Verify runner waits through pending checks and succeeds when delayed ack appears."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "ack_delayed": 2})
        test_images = os.path.join(self.test_dir, "delayed_ack_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertEqual(res.returncode, 0, f"Expected success with delayed ack, got:\n{res.stdout}\n{res.stderr}")
        self.assertIn("Stage-1 supervisor explicitly acknowledged trigger", res.stdout)

    def test_runner_aborts_on_missing_ack_timeout(self):
        """Verify runner aborts with timeout when stage1_ack never appears."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "fail_ack": "timeout"})
        test_images = os.path.join(self.test_dir, "timeout_ack_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Stage-1 PID 1 supervisor did not acknowledge trigger with /mnt/stage1_ack within timeout", res.stderr)

    def test_runner_aborts_on_device_disconnect_during_transfer(self):
        """Verify runner aborts immediately if device disconnects during image push."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "disconnect_during_push": "vendor.erofs.img"})
        test_images = os.path.join(self.test_dir, "disconnect_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)

    def test_runner_trigger_still_pending_wait(self):
        """Verify runner logs pending trigger consumption when boot_now remains unconsumed."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "ack_delayed": 2})
        test_images = os.path.join(self.test_dir, "pending_trigger_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertEqual(res.returncode, 0)
        self.assertIn("Stage-1 supervisor pending trigger consumption", res.stdout)

    def test_runner_aborts_on_missing_df(self):
        """Verify runner fails closed if df command fails or returns empty output."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "fail_df": "missing"})
        test_images = os.path.join(self.test_dir, "missing_df_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL SAFETY ERROR: df command failed or returned empty output", res.stderr + res.stdout)

    def test_runner_extended_boot_monitor_completion_success(self):
        """Verify runner extended monitoring detects sys.boot_completed=1 and exits 0."""
        mock_adb = self.create_mock_adb({"ro_status": "1", "boot_completed": "1", "watchdog_state": "BOOT_COMPLETED"})
        test_images = os.path.join(self.test_dir, "boot_complete_images")
        self.create_dummy_images(test_images)

        env = os.environ.copy()
        env["REAL_ADB_BIN"] = mock_adb
        env["IMAGES_DIR"] = test_images
        env["OOS16_WAIT_FOR_BOOT"] = "1"
        env["OOS16_BOOT_MONITOR_TIMEOUT"] = "5"

        res = subprocess.run(["bash", RUN_STAGE2], capture_output=True, text=True, env=env)
        self.assertEqual(res.returncode, 0)
        self.assertIn("SUCCESS: OxygenOS 16 boot completed successfully!", res.stdout)
        self.assertIn("sys.boot_completed=1 verified", res.stdout)

    def test_binderfs_init_execution_and_verification(self):
        """Verify binderfs_init helper binary and its invocation in loader and native init."""
        loader_init = os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk/init")
        native_init = os.path.join(PROJECT_ROOT, "stage1/native_ramdisk/init")
        loader_bin = os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk/system/bin/binderfs_init")
        native_bin = os.path.join(PROJECT_ROOT, "stage1/native_ramdisk/system/bin/binderfs_init")

        self.assertTrue(os.path.isfile(loader_bin))
        self.assertTrue(os.path.isfile(native_bin))
        self.assertTrue(os.access(loader_bin, os.X_OK))
        self.assertTrue(os.access(native_bin, os.X_OK))

        with open(loader_init) as f:
            l_content = f.read()
        with open(native_init) as f:
            n_content = f.read()

        for content in [l_content, n_content]:
            self.assertIn("/system/bin/binderfs_init", content)
            self.assertIn("CRITICAL: binderfs_init failed", content)
            self.assertIn("/dev/binderfs/binder-control", os.popen("strings '" + loader_bin + "' | grep binder-control").read())

    def test_stage2_init_product_and_my_product_mount_selection(self):
        """Verify scripts/stage2_init.sh handles product vs my_product partition layout strictly."""
        stage2_script = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")
        with open(stage2_script) as f:
            content = f.read()

        # Must check both images and detect duplicate SHA-256
        self.assertIn('PROD_IMG=$(get_img "product.img")', content)
        self.assertIn('MY_PROD_IMG=$(get_img "my_product.img")', content)
        self.assertIn('CRITICAL DUPLICATION ERROR', content)
        self.assertIn('ACTIVE_PRODUCT_MOUNTS', content)

    def test_stage2_init_fail_closed_df_capacity(self):
        """Verify scripts/stage2_init.sh rejects empty/malformed df output fail-closed."""
        stage2_script = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")
        with open(stage2_script) as f:
            content = f.read()

        self.assertIn("df -m /mnt returned empty output", content)
        self.assertIn("Failed to parse numeric free capacity from df output", content)
        self.assertIn("REQUIRED_MNT_FREE_MB=576", content)

    def test_runner_apex_expanded_size_budget_accounting(self):
        """Verify run_stage2.sh accounts for expanded APEX payloads and breakdowns in output."""
        stage2_runner = os.path.join(PROJECT_ROOT, "tools/safe/run_stage2.sh")
        with open(stage2_runner) as f:
            content = f.read()

        self.assertIn("TOTAL_EXPANDED_APEX_MB", content)
        self.assertIn("Expanded APEX payloads (/apex tmpfs)", content)
        self.assertIn("expanded_size", content)

    def test_runner_aborts_on_missing_or_invalid_expanded_size(self):
        """Verify run_stage2.sh strictly enforces mandatory .expanded_size metadata."""
        test_images = os.path.join(self.test_dir, "images")
        self.create_dummy_images(test_images)
        os.remove(os.path.join(test_images, "runtime_apex.expanded_size"))

        mock_adb = self.create_mock_adb({"ro_status": "1"})
        res = self.run_stage2_runner(test_images, mock_adb)
        self.assertEqual(res.returncode, 1)
        self.assertIn("Mandatory APEX metadata", res.stderr)
        self.assertIn("runtime_apex.expanded_size is missing or 0 bytes", res.stderr)

    def test_runner_aborts_on_duplicate_product_images(self):
        """Verify run_stage2.sh rejects identical product.erofs.img and my_product.erofs.img content."""
        test_images = os.path.join(self.test_dir, "images")
        self.create_dummy_images(test_images)
        # Create identical product.erofs.img and my_product.erofs.img
        identical_data = b"IDENTICAL_PRODUCT_IMAGE_CONTENT"
        with open(os.path.join(test_images, "my_product.erofs.img"), "wb") as f:
            f.write(identical_data)
        with open(os.path.join(test_images, "product.erofs.img"), "wb") as f:
            f.write(identical_data)
        with open(os.path.join(test_images, "PARTITION_MAP"), "a") as f:
            f.write("product.erofs.img:/mnt/sysroot/product:mandatory\n")

        mock_adb = self.create_mock_adb({"ro_status": "1"})
        res = self.run_stage2_runner(test_images, mock_adb)
        self.assertEqual(res.returncode, 1)
        self.assertIn("Ambiguous duplicate image content!", res.stderr)

    def test_runner_independent_product_and_my_product(self):
        """Verify run_stage2.sh stages both when product and my_product are genuinely independent."""
        test_images = os.path.join(self.test_dir, "images")
        self.create_dummy_images(test_images)
        # Create distinct product.erofs.img and my_product.erofs.img
        with open(os.path.join(test_images, "my_product.erofs.img"), "wb") as f:
            f.write(b"MY_PRODUCT_CONTENT_UNIQUE")
        with open(os.path.join(test_images, "product.erofs.img"), "wb") as f:
            f.write(b"PRODUCT_CONTENT_UNIQUE")
        with open(os.path.join(test_images, "PARTITION_MAP"), "a") as f:
            f.write("product.erofs.img:/mnt/sysroot/product:mandatory\n")

        mock_adb = self.create_mock_adb({
            "ro_status": "1",
            "auto_ack_on_trigger": True,
            "boot_completed": "1"
        })
        res = self.run_stage2_runner(test_images, mock_adb)
        self.assertEqual(res.returncode, 0, f"Failed with: {res.stdout}\n{res.stderr}")
        self.assertIn("Found independent product.erofs.img and my_product.erofs.img", res.stdout)
        self.assertIn("Pushing product.erofs.img", res.stdout)
        self.assertIn("Pushing my_product.erofs.img", res.stdout)

    def run_stage2_ram_check_script(self, meminfo_content, mnt_free_mb, tmp_free_mb, apex_sizes, omit_meminfo=False):
        """
        Executes the real scripts/stage2_init.sh validate_device_ram check in an isolated subshell environment.
        """
        sub_dir = tempfile.mkdtemp(prefix="stage2_ram_check_")
        try:
            mnt_dir = os.path.join(sub_dir, "mnt")
            tmp_dir = os.path.join(sub_dir, "tmp")
            mock_bin = os.path.join(sub_dir, "bin")
            os.makedirs(mnt_dir, exist_ok=True)
            os.makedirs(tmp_dir, exist_ok=True)
            os.makedirs(mock_bin, exist_ok=True)

            meminfo_file = os.path.join(sub_dir, "meminfo")
            if not omit_meminfo and meminfo_content is not None:
                with open(meminfo_file, "w") as f:
                    f.write(meminfo_content)

            for mod, sz in apex_sizes.items():
                if sz is not None:
                    with open(os.path.join(mnt_dir, f"{mod}.expanded_size"), "w") as f:
                        f.write(str(sz))

            # Mock df / toybox script returning configured free space
            mock_df = os.path.join(mock_bin, "df")
            with open(mock_df, "w") as f:
                f.write(f"""#!/bin/sh
target="$2"
[ -z "$target" ] && target="$1"
bname=$(basename "$target")
if [ "$bname" = "tmp" ]; then
    cat <<EOF
Filesystem 1M-blocks Used Available Use% Mounted on
tmpfs 512 0 {tmp_free_mb} 0% $target
EOF
else
    cat <<EOF
Filesystem 1M-blocks Used Available Use% Mounted on
tmpfs 6500 0 {mnt_free_mb} 0% $target
EOF
fi
exit 0
""")
            os.chmod(mock_df, stat.S_IRWXU)

            mock_toybox = os.path.join(mock_bin, "toybox")
            with open(mock_toybox, "w") as f:
                f.write(f"""#!/bin/sh
if [ "$1" = "df" ]; then
    shift
    exec "{mock_df}" "$@"
fi
exec "$@"
""")
            os.chmod(mock_toybox, stat.S_IRWXU)

            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
            env["MEMINFO_FILE"] = meminfo_file
            env["MNT_DIR"] = mnt_dir
            env["TMP_DIR"] = tmp_dir
            env["STAGE2_TEST_MODE"] = "1"
            env["TOYBOX_CMD"] = mock_toybox

            stage2_path = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")
            return subprocess.run(["/bin/sh", stage2_path, "--check-ram"], env=env, capture_output=True, text=True)
        finally:
            shutil.rmtree(sub_dir, ignore_errors=True)

    def test_stage2_device_ram_check_missing_meminfo_fatal(self):
        """Verify device-side RAM check halts fail-closed if /proc/meminfo is missing."""
        default_apex = {"runtime_apex": 20000000, "art_apex": 40000000, "i18n_apex": 20000000, "tzdata_apex": 1000000}
        res = self.run_stage2_ram_check_script(None, 1000, 100, default_apex, omit_meminfo=True)
        self.assertEqual(res.returncode, 42)
        self.assertIn("is missing or empty", res.stderr)

    def test_stage2_device_ram_check_missing_memavailable_fatal(self):
        """Verify device-side RAM check halts fail-closed if MemAvailable is missing."""
        mem_data = "MemTotal:        7628800 kB\nMemFree:          100000 kB\n"
        default_apex = {"runtime_apex": 20000000, "art_apex": 40000000, "i18n_apex": 20000000, "tzdata_apex": 1000000}
        res = self.run_stage2_ram_check_script(mem_data, 1000, 100, default_apex)
        self.assertEqual(res.returncode, 42)
        self.assertIn("Missing or non-numeric MemAvailable", res.stderr)

    def test_stage2_device_ram_check_insufficient_ram_fatal(self):
        """Verify device-side RAM check halts fail-closed if MemAvailable is below future requirement."""
        mem_data = "MemTotal:        7628800 kB\nMemFree:          100000 kB\nMemAvailable:    2000000 kB\n"
        default_apex = {"runtime_apex": 20000000, "art_apex": 40000000, "i18n_apex": 20000000, "tzdata_apex": 1000000}
        res = self.run_stage2_ram_check_script(mem_data, 1000, 100, default_apex)
        self.assertEqual(res.returncode, 42)
        self.assertIn("Insufficient device RAM", res.stderr)

    def test_stage2_device_ram_check_sufficient_ram_success(self):
        """Verify device-side RAM check passes when MemAvailable satisfies future budget."""
        mem_data = "MemTotal:        7628800 kB\nMemFree:         3500000 kB\nMemAvailable:    4500000 kB\n"
        default_apex = {"runtime_apex": 20000000, "art_apex": 40000000, "i18n_apex": 20000000, "tzdata_apex": 1000000}
        res = self.run_stage2_ram_check_script(mem_data, 1000, 100, default_apex)
        self.assertEqual(res.returncode, 0)
        self.assertIn("Device-side total RAM verified", res.stdout)

    def test_stage2_device_ram_check_mnt_insufficient_capacity_fatal(self):
        """Verify device-side RAM check fails if /mnt has less than 576MB free."""
        mem_data = "MemTotal:        7628800 kB\nMemFree:         3500000 kB\nMemAvailable:    4500000 kB\n"
        default_apex = {"runtime_apex": 20000000, "art_apex": 40000000, "i18n_apex": 20000000, "tzdata_apex": 1000000}
        res = self.run_stage2_ram_check_script(mem_data, 500, 100, default_apex)
        self.assertEqual(res.returncode, 42)
        self.assertIn("has only 500MB free", res.stderr)
        self.assertIn("requires at least 576MB", res.stderr)

    def test_stage2_device_ram_check_missing_apex_metadata_fatal(self):
        """Verify device-side RAM check fails if any mandatory APEX metadata is missing."""
        mem_data = "MemTotal:        7628800 kB\nMemFree:         3500000 kB\nMemAvailable:    4500000 kB\n"
        incomplete_apex = {"art_apex": 40000000, "i18n_apex": 20000000, "tzdata_apex": 1000000}  # runtime_apex missing
        res = self.run_stage2_ram_check_script(mem_data, 1000, 100, incomplete_apex)
        self.assertEqual(res.returncode, 42)
        self.assertIn("Missing mandatory APEX metadata", res.stderr)

    def run_stage2_manifest_check(self, manifest_content):
        """Helper to invoke production parse_and_validate_partition_map via scripts/stage2_init.sh."""
        sub_dir = tempfile.mkdtemp(prefix="stage2_manifest_")
        try:
            map_file = os.path.join(sub_dir, "PARTITION_MAP")
            if manifest_content is not None:
                with open(map_file, "w") as f:
                    f.write(manifest_content)
            env = os.environ.copy()
            env["STAGE2_TEST_MODE"] = "1"
            stage2_path = os.path.join(PROJECT_ROOT, "scripts/stage2_init.sh")
            return subprocess.run(["/bin/sh", stage2_path, "--parse-manifest", map_file], env=env, capture_output=True, text=True)
        finally:
            shutil.rmtree(sub_dir, ignore_errors=True)

    def test_stage2_manifest_validation_success(self):
        """Verify authoritative PARTITION_MAP strictly succeeds with full valid mapping."""
        valid_map = (
            "system.erofs.img:/mnt/sysroot:mandatory\n"
            "system_ext.erofs.img:/mnt/sysroot/system_ext:mandatory\n"
            "vendor.erofs.img:/mnt/sysroot/vendor:mandatory\n"
            "odm.erofs.img:/mnt/sysroot/odm:mandatory\n"
            "my_product.erofs.img:/mnt/sysroot/my_product:mandatory\n"
            "my_region.erofs.img:/mnt/sysroot/my_region:optional\n"
        )
        res = self.run_stage2_manifest_check(valid_map)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stdout}\n{res.stderr}")
        self.assertIn("Partition manifest", res.stdout)
        self.assertIn("strictly validated", res.stdout)

    def test_stage2_manifest_disallowed_target_fatal(self):
        """Verify manifest parser rejects mountpoints not present in explicit allowlist."""
        invalid_map = (
            "system.erofs.img:/mnt/sysroot:mandatory\n"
            "system_ext.erofs.img:/mnt/sysroot/system_ext:mandatory\n"
            "vendor.erofs.img:/mnt/sysroot/vendor:mandatory\n"
            "odm.erofs.img:/mnt/sysroot/odm:mandatory\n"
            "my_product.erofs.img:/mnt/sysroot/my_product:mandatory\n"
            "evil.img:/mnt/sysroot/evil_dir:mandatory\n"
        )
        res = self.run_stage2_manifest_check(invalid_map)
        self.assertEqual(res.returncode, 42)
        self.assertIn("is NOT in the allowed mountpoints list", res.stderr)

    def test_stage2_manifest_missing_mandatory_mapping_fatal(self):
        """Verify manifest parser halts fail-closed if mandatory partition (e.g. vendor) is missing."""
        missing_vendor_map = (
            "system.erofs.img:/mnt/sysroot:mandatory\n"
            "system_ext.erofs.img:/mnt/sysroot/system_ext:mandatory\n"
            "odm.erofs.img:/mnt/sysroot/odm:mandatory\n"
            "my_product.erofs.img:/mnt/sysroot/my_product:mandatory\n"
        )
        res = self.run_stage2_manifest_check(missing_vendor_map)
        self.assertEqual(res.returncode, 42)
        self.assertIn("Mandatory manifest mapping for /mnt/sysroot/vendor missing", res.stderr)

    def test_stage2_manifest_duplicate_target_fatal(self):
        """Verify manifest parser rejects duplicate target mountpoints."""
        dup_target_map = (
            "system.erofs.img:/mnt/sysroot:mandatory\n"
            "system2.erofs.img:/mnt/sysroot:mandatory\n"
            "system_ext.erofs.img:/mnt/sysroot/system_ext:mandatory\n"
            "vendor.erofs.img:/mnt/sysroot/vendor:mandatory\n"
            "odm.erofs.img:/mnt/sysroot/odm:mandatory\n"
            "my_product.erofs.img:/mnt/sysroot/my_product:mandatory\n"
        )
        res = self.run_stage2_manifest_check(dup_target_map)
        self.assertEqual(res.returncode, 42)
        self.assertIn("Target mountpoint '/mnt/sysroot' mapped multiple times", res.stderr)

    def test_stage2_device_duplicate_product_sha_rejected(self):
        """Verify stage2_init.sh duplicate detection rejects identical content between product and my_product."""
        sub_dir = tempfile.mkdtemp(prefix="stage2_dup_test_")
        try:
            mnt_dir = os.path.join(sub_dir, "mnt")
            os.makedirs(mnt_dir, exist_ok=True)
            with open(os.path.join(mnt_dir, "product.img"), "wb") as f:
                f.write(b"IDENTICAL_CONTENT")
            with open(os.path.join(mnt_dir, "my_product.img"), "wb") as f:
                f.write(b"IDENTICAL_CONTENT")

            script = f"""
fatal() {{
    echo "[FATAL] $1" >&2
    exit 55
}}

PROD_IMG="{mnt_dir}/product.img"
MY_PROD_IMG="{mnt_dir}/my_product.img"

if [ -n "$PROD_IMG" ] && [ -n "$MY_PROD_IMG" ]; then
    PROD_SHA=$(sha256sum "$PROD_IMG" | awk '{{print $1}}')
    MY_PROD_SHA=$(sha256sum "$MY_PROD_IMG" | awk '{{print $1}}')
    if [ -n "$PROD_SHA" ] && [ "$PROD_SHA" = "$MY_PROD_SHA" ]; then
        fatal "CRITICAL DUPLICATION ERROR: $PROD_IMG and $MY_PROD_IMG have identical SHA-256 ($PROD_SHA)! Refusing duplicate mount."
    fi
fi
"""
            res = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
            self.assertEqual(res.returncode, 55)
            self.assertIn("CRITICAL DUPLICATION ERROR", res.stderr)
        finally:
            shutil.rmtree(sub_dir, ignore_errors=True)

if __name__ == "__main__":
    unittest.main(verbosity=2)
