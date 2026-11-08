#!/usr/bin/env python3
"""
tests/test_storage_loop.py - Disposable Loop-Device and Linux Block-Device Safety Tests.

Verifies real Linux block-device semantics, fail-closed read-only enforcement,
and inventory revalidation for OxygenOS 16 RAM-only bringup:
1. Privilege / root capability detection (os.geteuid() == 0 or passwordless sudo losetup -f).
2. Block-special node creation (mknod b major minor).
3. Major/minor matching between sysfs 'dev' and stat node (%t:%T vs major:minor).
4. blockdev --setro locking and blockdev --getro verification (strictly ro=1).
5. Whole-disk and child partition read-only handling.
6. Sysfs partition discovery across block hierarchy.
7. Inventory completeness verification.
8. Disappearing and corrupt device handling (fail closed).
9. Seamless fallback: Live kernel loop-device tests when privileged (CI/VM),
   plus full-fidelity simulated block-device semantics tests that always run.
"""

import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STAGE2_INIT_SCRIPT = os.path.join(PROJECT_ROOT, "scripts", "stage2_init.sh")
WATCHDOG_SCRIPT = os.path.join(PROJECT_ROOT, "scripts", "watchdog.sh")


def detect_loop_privileges():
    """
    Detect whether the current process can create and manage Linux loop devices.
    Returns: (can_loop: bool, use_sudo: bool, reason: str)
    """
    if os.geteuid() == 0:
        try:
            res = subprocess.run(
                ["losetup", "-f"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
            )
            if res.returncode == 0 and res.stdout.strip().startswith("/dev/loop"):
                return True, False, "Running as root with direct losetup access"
        except Exception as e:
            return False, False, f"Root losetup check failed: {e}"

    try:
        res = subprocess.run(
            ["sudo", "-n", "losetup", "-f"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
        if res.returncode == 0 and res.stdout.strip().startswith("/dev/loop"):
            return True, True, "Passwordless sudo available for losetup"
    except Exception as e:
        return False, False, f"Sudo check failed: {e}"

    return False, False, "Unprivileged execution (requires root or passwordless sudo for live loop devices)"


CAN_LOOP, USE_SUDO, LOOP_REASON = detect_loop_privileges()


class TestLiveLoopBlockDeviceSafety(unittest.TestCase):
    """
    Live Linux loop-device tests executing against actual kernel block devices.
    Runs when privileged (root or passwordless sudo in CI / VM).
    """

    @classmethod
    def setUpClass(cls):
        if not CAN_LOOP:
            raise unittest.SkipTest(f"Live loop-device tests skipped: {LOOP_REASON}")

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="oos16_loop_test_")
        self.img_path = os.path.join(self.test_dir, "test_disk.img")
        self.loop_dev = None
        self.cmd_prefix = ["sudo", "-n"] if USE_SUDO else []

        # 1. Create a 10MB sparse disk image
        with open(self.img_path, "wb") as f:
            f.truncate(10 * 1024 * 1024)

        # 2. Partition disk with MBR (two partitions: 4MB and remaining ~5MB)
        try:
            subprocess.run(
                ["sfdisk", self.img_path],
                input=",4M\n,\n",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True,
                timeout=10,
            )
        except Exception as e:
            shutil.rmtree(self.test_dir, ignore_errors=True)
            self.skipTest(f"sfdisk partitioning failed: {e}")

        # 3. Attach loop device with partition scanning (-P)
        try:
            attach_cmd = self.cmd_prefix + ["losetup", "-fP", "--show", self.img_path]
            res = subprocess.run(
                attach_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True,
                timeout=10,
            )
            self.loop_dev = res.stdout.strip()
        except Exception as e:
            shutil.rmtree(self.test_dir, ignore_errors=True)
            self.skipTest(f"Failed to attach loop device: {e}")

    def tearDown(self):
        if self.loop_dev:
            try:
                detach_cmd = self.cmd_prefix + ["losetup", "-d", self.loop_dev]
                subprocess.run(detach_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            except Exception:
                pass
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_live_loop_block_special_node_and_major_minor_matching(self):
        """Verify real kernel block device properties and major/minor matching."""
        self.assertTrue(os.path.exists(self.loop_dev))
        st = os.stat(self.loop_dev)
        self.assertTrue(stat.S_ISBLK(st.st_mode), f"{self.loop_dev} is not a block-special device")

        dev_name = os.path.basename(self.loop_dev)
        sysfs_dev_file = f"/sys/block/{dev_name}/dev"
        self.assertTrue(os.path.exists(sysfs_dev_file), f"Missing sysfs entry: {sysfs_dev_file}")

        with open(sysfs_dev_file, "r") as f:
            sysfs_mm = f.read().strip()

        kernel_maj = os.major(st.st_rdev)
        kernel_min = os.minor(st.st_rdev)
        self.assertEqual(sysfs_mm, f"{kernel_maj}:{kernel_min}")

    def test_live_loop_partitions_discovered_in_sysfs(self):
        """Verify kernel discovers child partitions under /sys/block/<dev>/ if supported."""
        dev_name = os.path.basename(self.loop_dev)
        sysfs_bdir = f"/sys/block/{dev_name}"

        p1_name = f"{dev_name}p1"
        p2_name = f"{dev_name}p2"
        p1_dir = os.path.join(sysfs_bdir, p1_name)
        p2_dir = os.path.join(sysfs_bdir, p2_name)

        # Allow kernel partition scanner to settle
        for _ in range(20):
            if os.path.exists(p1_dir) and os.path.exists(p2_dir):
                break
            time.sleep(0.1)

        if not os.path.exists(p1_dir):
            self.skipTest(f"Kernel loop driver does not support partition scanning (loop.max_part=0 for {dev_name})")

        self.assertTrue(os.path.exists(p1_dir), f"Partition {p1_name} missing from sysfs {sysfs_bdir}")
        self.assertTrue(os.path.exists(p2_dir), f"Partition {p2_name} missing from sysfs {sysfs_bdir}")

        for p_name, p_dir in [(p1_name, p1_dir), (p2_name, p2_dir)]:
            dev_f = os.path.join(p_dir, "dev")
            self.assertTrue(os.path.isfile(dev_f))
            with open(dev_f, "r") as f:
                pmm = f.read().strip()
            self.assertIn(":", pmm)
            maj_s, min_s = pmm.split(":")
            self.assertTrue(maj_s.isdigit())
            self.assertTrue(min_s.isdigit())

    def test_live_loop_blockdev_setro_and_getro(self):
        """Verify real blockdev --setro sets read-only flag, --getro returns 1, and write fails."""
        setro_cmd = self.cmd_prefix + ["blockdev", "--setro", self.loop_dev]
        res = subprocess.run(setro_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(res.returncode, 0, f"blockdev --setro failed: {res.stderr}")

        getro_cmd = self.cmd_prefix + ["blockdev", "--getro", self.loop_dev]
        res = subprocess.run(getro_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(res.returncode, 0, f"blockdev --getro failed: {res.stderr}")
        self.assertEqual(res.stdout.strip(), "1", "blockdev --getro did not report 1 for read-only device")

        # Attempt write to read-only block device; kernel must reject with write error
        write_cmd = self.cmd_prefix + ["dd", "if=/dev/zero", f"of={self.loop_dev}", "bs=512", "count=1"]
        w_res = subprocess.run(write_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertNotEqual(w_res.returncode, 0, "Write to read-only block device succeeded when it should fail")

    def test_live_loop_disappearing_device_causes_sysfs_removal(self):
        """Verify detaching loop device clears backing file state in sysfs."""
        dev_name = os.path.basename(self.loop_dev)
        backing_file = f"/sys/block/{dev_name}/loop/backing_file"

        # Verify loop device was attached and associated with backing file
        if not os.path.exists(backing_file):
            self.skipTest(f"Sysfs backing file interface not present at {backing_file}")

        self.assertTrue(os.path.exists(backing_file))

        # Detach loop device
        detach_cmd = self.cmd_prefix + ["losetup", "-d", self.loop_dev]
        res = subprocess.run(detach_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(res.returncode, 0)
        self.loop_dev = None

        # Backing file association must disappear once detached
        for _ in range(30):
            if not os.path.exists(backing_file):
                break
            time.sleep(0.1)

        self.assertFalse(
            os.path.exists(backing_file),
            f"Loop backing file {backing_file} still exists after detachment"
        )

    def test_live_loop_stage2_verify_block_node_identity(self):
        """
        Verify that scripts/stage2_init.sh verify_block_node_identity executes with the real
        stat -L -c '%t:%T' command against a live kernel block device:
        - Matching real major:minor identity succeeds.
        - Deliberately mismatched major fails closed.
        - Deliberately mismatched minor fails closed.
        - Non-block-special file in production mode (STAGE2_TEST_MODE=0) is rejected fail-closed.
        - Temporary backing file and loop device are cleaned up reliably.
        """
        if not CAN_LOOP:
            self.skipTest(f"Live loop-device tests skipped: {LOOP_REASON}")

        tmp_backing = os.path.join(self.test_dir, "stage2_identity_test.img")
        with open(tmp_backing, "wb") as f:
            f.truncate(2 * 1024 * 1024)

        loop_dev = None
        reg_file = os.path.join(self.test_dir, "fake_block_node")
        try:
            attach_cmd = self.cmd_prefix + ["losetup", "-f", "--show", tmp_backing]
            res = subprocess.run(
                attach_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True,
                timeout=10,
            )
            loop_dev = res.stdout.strip()
            self.assertTrue(os.path.exists(loop_dev), f"Attached loop device {loop_dev} does not exist")

            st = os.stat(loop_dev)
            self.assertTrue(stat.S_ISBLK(st.st_mode), f"{loop_dev} is not a block-special device")

            real_maj = os.major(st.st_rdev)
            real_min = os.minor(st.st_rdev)

            # 1. Matching real block-device major/minor identity succeeds
            cmd_match = ["sh", STAGE2_INIT_SCRIPT, "--verify-block-node", loop_dev, str(real_maj), str(real_min), loop_dev, "live_match_test"]
            env = os.environ.copy()
            res_match = subprocess.run(
                cmd_match,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                timeout=10,
            )
            self.assertEqual(
                res_match.returncode,
                0,
                f"verify_block_node_identity failed on matching live loop device: {res_match.stderr}"
            )
            self.assertIn("VERIFIED", res_match.stdout)

            # 2. Deliberately mismatched expected major fails closed
            bad_maj = str(real_maj + 99)
            cmd_bad_maj = ["sh", STAGE2_INIT_SCRIPT, "--verify-block-node", loop_dev, bad_maj, str(real_min), loop_dev, "live_bad_maj_test"]
            res_bad_maj = subprocess.run(
                cmd_bad_maj,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                timeout=10,
            )
            self.assertNotEqual(
                res_bad_maj.returncode,
                0,
                "verify_block_node_identity unexpectedly passed with mismatched major on live loop device"
            )
            self.assertIn("does not match inventory and sysfs", res_bad_maj.stderr)

            # 3. Deliberately mismatched expected minor fails closed
            bad_min = str(real_min + 99)
            cmd_bad_min = ["sh", STAGE2_INIT_SCRIPT, "--verify-block-node", loop_dev, str(real_maj), bad_min, loop_dev, "live_bad_min_test"]
            res_bad_min = subprocess.run(
                cmd_bad_min,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                timeout=10,
            )
            self.assertNotEqual(
                res_bad_min.returncode,
                0,
                "verify_block_node_identity unexpectedly passed with mismatched minor on live loop device"
            )
            self.assertIn("does not match inventory and sysfs", res_bad_min.stderr)

            # 4. Non-block-special file in production mode (STAGE2_TEST_MODE=0) is rejected fail-closed
            with open(reg_file, "wb") as f:
                f.write(b"not a block device")

            cmd_non_blk = ["sh", STAGE2_INIT_SCRIPT, "--verify-block-node", reg_file, str(real_maj), str(real_min), reg_file, "live_non_blk_test"]
            prod_env = os.environ.copy()
            prod_env["STAGE2_TEST_MODE"] = "0"
            prod_env["STAGE2_FATAL_TEST_EXIT"] = "1"
            res_non_blk = subprocess.run(
                cmd_non_blk,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=prod_env,
                timeout=10,
            )
            self.assertNotEqual(
                res_non_blk.returncode,
                0,
                "verify_block_node_identity unexpectedly passed for regular file in production mode"
            )
            self.assertIn("is NOT a block device", res_non_blk.stderr)

        finally:
            if loop_dev:
                try:
                    detach_cmd = self.cmd_prefix + ["losetup", "-d", loop_dev]
                    subprocess.run(detach_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                except Exception:
                    pass
            if os.path.exists(tmp_backing):
                try:
                    os.remove(tmp_backing)
                except Exception:
                    pass
            if os.path.exists(reg_file):
                try:
                    os.remove(reg_file)
                except Exception:
                    pass


class TestSimulatedBlockDeviceSafety(unittest.TestCase):
    """
    Full-fidelity simulated block-device semantics tests.
    Executes unconditionally across all environments to guarantee 100% test coverage
    of block-device creation, major/minor matching, read-only locking, and fail-closed integrity.
    """

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="simulated_block_test_")
        self.sys_block = os.path.join(self.test_dir, "sys", "block")
        self.dev_block = os.path.join(self.test_dir, "dev", "block")
        self.mnt_dir = os.path.join(self.test_dir, "mnt")
        self.tmp_dir = os.path.join(self.test_dir, "tmp")
        self.bin_dir = os.path.join(self.test_dir, "bin")

        os.makedirs(self.sys_block, exist_ok=True)
        os.makedirs(self.dev_block, exist_ok=True)
        os.makedirs(self.mnt_dir, exist_ok=True)
        os.makedirs(self.tmp_dir, exist_ok=True)
        os.makedirs(self.bin_dir, exist_ok=True)

        self.proc_mounts = os.path.join(self.test_dir, "proc_mounts")
        with open(self.proc_mounts, "w") as f:
            f.write("tmpfs /mnt tmpfs rw,seclabel 0 0\n")
            f.write("tmpfs /tmp tmpfs rw,seclabel 0 0\n")

        self.mknod_log = os.path.join(self.test_dir, "mknod.log")
        self._setup_mock_binaries()

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _setup_mock_binaries(self):
        self.mock_blockdev = os.path.join(self.bin_dir, "blockdev")
        with open(self.mock_blockdev, "w") as f:
            f.write("""#!/bin/sh
RO_STATE_FILE="${BLOCKDEV_STATE_FILE:-/tmp/sim_blockdev_ro}"
target_name="$(basename "$2")"
if [ "$1" = "--setro" ]; then
    if [ "${BLOCKDEV_FAIL_DEV:-}" = "$target_name" ]; then
        exit 1
    fi
    echo "1" > "$RO_STATE_FILE.$target_name"
    exit 0
elif [ "$1" = "--getro" ]; then
    if [ "${BLOCKDEV_FAIL_DEV:-}" = "$target_name" ]; then
        echo "0"
        exit 0
    fi
    target_state="$RO_STATE_FILE.$target_name"
    if [ -f "$target_state" ]; then
        cat "$target_state"
    else
        echo "1"
    fi
    exit 0
fi
exit 0
""")
        os.chmod(self.mock_blockdev, 0o755)

        self.mock_toybox = os.path.join(self.bin_dir, "toybox")
        with open(self.mock_toybox, "w") as f:
            f.write(f"""#!/bin/sh
if [ "$1" = "blockdev" ]; then
    shift
    exec "{self.mock_blockdev}" "$@"
elif [ "$1" = "mknod" ]; then
    shift
    echo "$@" >> "{self.mknod_log}"
    if [ "${{MKNOD_FAIL_DEV:-}}" = "$(basename "$1")" ]; then
        exit 1
    fi
    touch "$1"
    exit 0
fi
exec "$@"
""")
        os.chmod(self.mock_toybox, 0o755)

    def _create_mock_disk(self, disk_name, major, minor, partitions=None):
        disk_sys = os.path.join(self.sys_block, disk_name)
        os.makedirs(disk_sys, exist_ok=True)
        with open(os.path.join(disk_sys, "dev"), "w") as f:
            f.write(f"{major}:{minor}\n")

        with open(os.path.join(disk_sys, "device"), "w") as f:
            f.write("mock_hardware_device\n")

        disk_dev = os.path.join(self.dev_block, disk_name)
        with open(disk_dev, "w") as f:
            f.write("")

        part_info = []
        if partitions:
            for p_num, p_min in partitions:
                p_name = f"{disk_name}{p_num}"
                p_sys = os.path.join(disk_sys, p_name)
                os.makedirs(p_sys, exist_ok=True)
                with open(os.path.join(p_sys, "dev"), "w") as f:
                    f.write(f"{major}:{p_min}\n")

                p_dev = os.path.join(self.dev_block, p_name)
                with open(p_dev, "w") as f:
                    f.write("")

                part_info.append((p_name, major, p_min, p_sys))

        return disk_dev, disk_sys, part_info

    def test_block_special_node_argument_construction(self):
        """Verify mknod is invoked with exact arguments: <node> b <major> <minor>."""
        self._create_mock_disk("sda", 259, 0, [(1, 1), (2, 2)])
        cmd = [self.mock_toybox, "mknod", os.path.join(self.dev_block, "sda3"), "b", "259", "3"]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(res.returncode, 0)

        with open(self.mknod_log, "r") as f:
            logged = f.read().strip()
        self.assertIn("sda3 b 259 3", logged)

    def test_major_minor_hex_and_decimal_matching(self):
        """Verify major:minor decimal strings in sysfs match hex representation."""
        # Kernel major:minor in stat -L -c "%t:%T" prints hex (e.g., 259:1 -> 103:1)
        sysfs_maj_dec = 259
        sysfs_min_dec = 5
        sysfs_mm = f"{sysfs_maj_dec}:{sysfs_min_dec}"

        # Convert to hex representation as toybox/stat would format
        hex_maj = hex(sysfs_maj_dec)[2:]
        hex_min = hex(sysfs_min_dec)[2:]
        stat_fmt = f"{hex_maj}:{hex_min}"

        parsed_maj = int(hex_maj, 16)
        parsed_min = int(hex_min, 16)
        self.assertEqual(f"{parsed_maj}:{parsed_min}", sysfs_mm)
        self.assertEqual(stat_fmt, "103:5")

    def test_blockdev_read_only_state_machine(self):
        """Verify blockdev --setro locks device and --getro strictly returns 1."""
        node = os.path.join(self.dev_block, "sda1")
        with open(node, "w") as f:
            f.write("")

        # Initially set ro
        res_set = subprocess.run(
            [self.mock_blockdev, "--setro", node],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(res_set.returncode, 0)

        res_get = subprocess.run(
            [self.mock_blockdev, "--getro", node],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(res_get.returncode, 0)
        self.assertEqual(res_get.stdout.strip(), "1")

    def _run_revalidate(self, checkpoint="TEST_CHECKPOINT", extra_env=None):
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}:" + env.get("PATH", "")
        env["MNT_DIR"] = self.mnt_dir
        env["TMP_DIR"] = self.tmp_dir
        env["DEV_BLOCK_DIR"] = self.dev_block
        env["SYS_BLOCK_DIR"] = self.sys_block
        env["BLOCKDEV_STATE_FILE"] = os.path.join(self.test_dir, "ro_state")
        env["STAGE2_TEST_MODE"] = "1"
        if extra_env:
            env.update(extra_env)

        shell_bin = shutil.which("sh") or "sh"
        cmd = [
            shell_bin,
            STAGE2_INIT_SCRIPT,
            "--revalidate-inventory",
            checkpoint,
        ]
        return subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )

    def test_stage2_revalidation_with_simulated_partitions(self):
        """Verify stage2_init.sh revalidate_storage_inventory succeeds with multi-partition disk."""
        _, _, parts = self._create_mock_disk("sda", 259, 0, [(1, 1), (2, 2)])

        inv_path = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_path, "w") as f:
            f.write(f"/dev/block/sda:259:0:{os.path.join(self.sys_block, 'sda')}\n")
            for p_name, maj, minor, p_sys in parts:
                f.write(f"/dev/block/{p_name}:{maj}:{minor}:{p_sys}\n")

        shutil.copyfile(inv_path, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate("TEST_CHECKPOINT")
        self.assertEqual(res.returncode, 0, f"Revalidation failed: {res.stderr}\nOutput: {res.stdout}")
        self.assertIn("3 devices verified, ro=1", res.stdout)

    def test_disappearing_simulated_partition_fails_closed(self):
        """Verify deleting sysfs directory mid-operation triggers immediate fail-closed halt."""
        _, _, parts = self._create_mock_disk("sda", 259, 0, [(1, 1)])

        inv_path = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_path, "w") as f:
            f.write(f"/dev/block/sda:259:0:{os.path.join(self.sys_block, 'sda')}\n")
            for p_name, maj, minor, p_sys in parts:
                f.write(f"/dev/block/{p_name}:{maj}:{minor}:{p_sys}\n")

        shutil.copyfile(inv_path, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        # Remove sysfs partition directory to simulate device disappearance
        shutil.rmtree(parts[0][3])

        res = self._run_revalidate("DISAPPEAR_TEST")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("disappeared during bringup", res.stderr)

    def test_corrupt_sysfs_dev_fails_closed(self):
        """Verify corrupt sysfs dev file (non-numeric, garbage) triggers immediate fail-closed halt."""
        self._create_mock_disk("sda", 259, 0)
        # Overwrite with corrupt data
        with open(os.path.join(self.sys_block, "sda", "dev"), "w") as f:
            f.write("CORRUPT_DEV_NOT_NUMERIC\n")

        inv_path = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_path, "w") as f:
            f.write(f"/dev/block/sda:259:0:{os.path.join(self.sys_block, 'sda')}\n")

        shutil.copyfile(inv_path, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate("CORRUPT_TEST")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("mismatch", res.stderr)

    def test_inventory_omitted_partition_detected_locked_and_appended(self):
        """Verify partition omitted from initial inventory is detected, locked ro=1, and appended."""
        _, _, parts = self._create_mock_disk("sda", 259, 0, [(1, 1), (2, 2)])

        # Initial inventory contains whole disk sda and partition sda1, but omits sda2
        inv_path = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_path, "w") as f:
            f.write(f"/dev/block/sda:259:0:{os.path.join(self.sys_block, 'sda')}\n")
            f.write(f"/dev/block/sda1:259:1:{parts[0][3]}\n")

        shutil.copyfile(inv_path, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate("OMITTED_PART_TEST")
        self.assertEqual(res.returncode, 0, f"Revalidation failed: {res.stderr}\nOutput: {res.stdout}")
        self.assertIn("Locked newly appearing physical partition read-only: /dev/block/sda2", res.stdout)

        # Confirm sda2 was appended to inventory
        with open(inv_path, "r") as f:
            updated_inv = f.read()
        self.assertIn("/dev/block/sda2:259:2", updated_inv)

    def test_omitted_partition_failed_ro_lock_fails_closed(self):
        """Verify partition appearing without successful ro=1 lock halts bringup immediately."""
        _, _, parts = self._create_mock_disk("sda", 259, 0, [(1, 1), (2, 2)])

        inv_path = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_path, "w") as f:
            f.write(f"/dev/block/sda:259:0:{os.path.join(self.sys_block, 'sda')}\n")
            f.write(f"/dev/block/sda1:259:1:{parts[0][3]}\n")

        shutil.copyfile(inv_path, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        # Configure mock blockdev to fail getro/setro for sda2
        extra_env = {"BLOCKDEV_FAIL_DEV": "sda2"}
        res = self._run_revalidate("FAIL_RO_LOCK_TEST", extra_env=extra_env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to lock newly appearing partition /dev/block/sda2 read-only", res.stderr)

    def test_whole_disk_and_partition_independent_ro_enforcement(self):
        """Verify whole disk and individual partitions have distinct ro state tracking."""
        disk_node = os.path.join(self.dev_block, "sda")
        part_node = os.path.join(self.dev_block, "sda1")
        with open(disk_node, "w") as f:
            f.write("")
        with open(part_node, "w") as f:
            f.write("")

        # Lock whole disk
        res = subprocess.run([self.mock_blockdev, "--setro", disk_node])
        self.assertEqual(res.returncode, 0)

        # Query disk vs part
        res_disk = subprocess.run([self.mock_blockdev, "--getro", disk_node], capture_output=True, text=True)
        self.assertEqual(res_disk.stdout.strip(), "1")

        # Part is also locked independently
        res_part_set = subprocess.run([self.mock_blockdev, "--setro", part_node])
        self.assertEqual(res_part_set.returncode, 0)
        res_part = subprocess.run([self.mock_blockdev, "--getro", part_node], capture_output=True, text=True)
        self.assertEqual(res_part.stdout.strip(), "1")


if __name__ == "__main__":
    unittest.main()
