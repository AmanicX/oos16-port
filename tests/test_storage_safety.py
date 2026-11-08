#!/usr/bin/env python3
"""
tests/test_storage_safety.py - Comprehensive Unit & Regression Tests for
Physical Storage Protection, Fail-Closed Locking & Inventory Revalidation.

Tests:
1. Multiple physical disks (sda, sdb, sdc).
2. Multiple partitions (sda1..sda32).
3. Missing device nodes causing fail-closed halt.
4. Invalid / malformed major/minor numbers in sysfs dev files.
5. Failed mknod causing immediate fail-closed halt without silent suppression.
6. Failed blockdev --setro causing immediate fail-closed halt.
7. blockdev --getro returning zero causing immediate fail-closed halt.
8. Newly appearing physical partition detected, locked, and recorded.
9. Disappearing physical device during verification causing immediate fail-closed halt.
10. Writable mount in /proc/mounts causing immediate fail-closed halt.
11. Multi-checkpoint revalidation coverage across Stage-2 bringup.
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STAGE2_INIT_SCRIPT = os.path.join(PROJECT_ROOT, "scripts", "stage2_init.sh")


class StorageSafetyTestBase(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="storage_safety_test_")
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

        self._setup_mock_binaries()

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _setup_mock_binaries(self):
        # Create mock blockdev
        self.mock_blockdev = os.path.join(self.bin_dir, "blockdev")
        with open(self.mock_blockdev, "w") as f:
            f.write("""#!/bin/sh
RO_STATE_FILE="${BLOCKDEV_STATE_FILE:-/tmp/mock_blockdev_ro}"
if [ "$1" = "--setro" ]; then
    if [ "${BLOCKDEV_FAIL_SETRO:-0}" = "1" ]; then
        exit 1
    fi
    echo "1" > "$RO_STATE_FILE.$(basename "$2")"
    exit 0
elif [ "$1" = "--getro" ]; then
    if [ "${BLOCKDEV_FORCE_GETRO_ZERO:-0}" = "1" ]; then
        echo "0"
        exit 0
    fi
    target_state="$RO_STATE_FILE.$(basename "$2")"
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

        # Create mock toybox
        self.mock_toybox = os.path.join(self.bin_dir, "toybox")
        with open(self.mock_toybox, "w") as f:
            f.write(f"""#!/bin/sh
if [ "$1" = "blockdev" ]; then
    shift
    exec "{self.mock_blockdev}" "$@"
elif [ "$1" = "mknod" ]; then
    shift
    if [ "${{MKNOD_FAIL:-0}}" = "1" ]; then
        exit 1
    fi
    # Emulate block device node creation as regular file for unprivileged testing
    touch "$1"
    exit 0
elif [ "$1" = "mount" ]; then
    cat "{self.proc_mounts}"
    exit 0
fi
exec "$@"
""")
        os.chmod(self.mock_toybox, 0o755)

    def _create_mock_disk(self, disk_name, major, minor, partition_count=0):
        d_dir = os.path.join(self.sys_block, disk_name)
        os.makedirs(d_dir, exist_ok=True)
        # Create device marker
        with open(os.path.join(d_dir, "device"), "w") as f:
            f.write("mock_hardware_device\n")
        with open(os.path.join(d_dir, "dev"), "w") as f:
            f.write(f"{major}:{minor}\n")

        # Create block dev node
        dev_node = os.path.join(self.dev_block, disk_name)
        with open(dev_node, "w") as f:
            f.write("")

        # Create child partitions
        for i in range(1, partition_count + 1):
            p_name = f"{disk_name}{i}"
            p_dir = os.path.join(d_dir, p_name)
            os.makedirs(p_dir, exist_ok=True)
            p_min = minor + i
            with open(os.path.join(p_dir, "dev"), "w") as f:
                f.write(f"{major}:{p_min}\n")
            p_node = os.path.join(self.dev_block, p_name)
            with open(p_node, "w") as f:
                f.write("")

    def _run_revalidate(self, checkpoint="test_checkpoint", extra_env=None):
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

        cmd = [
            "sh",
            f"{STAGE2_INIT_SCRIPT}",
            "--revalidate-inventory",
            f"{checkpoint}"
        ]
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env
        )
        return res


class TestPhysicalStorageProtection(StorageSafetyTestBase):
    def test_multiple_physical_disks_and_partitions_inventory_validation(self):
        """Verify discovery and strict inventory tracking with multiple disks and 32 partitions."""
        # Setup sda with 32 partitions, sdb with 4 partitions, sdc with 1 partition
        self._create_mock_disk("sda", 8, 0, partition_count=32)
        self._create_mock_disk("sdb", 8, 16, partition_count=4)
        self._create_mock_disk("sdc", 8, 32, partition_count=1)

        # Write initial inventory file
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            # Add sda and all 32 partitions
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
            for i in range(1, 33):
                f.write(f"/dev/block/sda{i}:8:{i}:{os.path.join(self.sys_block, 'sda', f'sda{i}')}\n")
            # Add sdb and 4 partitions
            f.write(f"/dev/block/sdb:8:16:{os.path.join(self.sys_block, 'sdb')}\n")
            for i in range(1, 5):
                f.write(f"/dev/block/sdb{i}:8:{16+i}:{os.path.join(self.sys_block, 'sdb', f'sdb{i}')}\n")
            # Add sdc and 1 partition
            f.write(f"/dev/block/sdc:8:32:{os.path.join(self.sys_block, 'sdc')}\n")
            f.write(f"/dev/block/sdc1:8:33:{os.path.join(self.sys_block, 'sdc', 'sdc1')}\n")

        res = self._run_revalidate(checkpoint="multi_disk_test")
        self.assertEqual(res.returncode, 0, f"Revalidation failed: {res.stderr}\n{res.stdout}")
        self.assertIn("Storage inventory revalidation PASSED (40 devices verified", res.stdout)

    def test_missing_inventory_file_fails_closed(self):
        """Verify revalidation fails closed if physical_storage_inventory is missing."""
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        if os.path.exists(inv_file):
            os.remove(inv_file)

        res = self._run_revalidate(checkpoint="missing_inv_test")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Physical storage inventory", res.stderr)
        self.assertIn("missing or 0 bytes", res.stderr)

    def test_device_disappearing_during_verification_fails_closed(self):
        """Verify that a device disappearing from sysfs triggers immediate fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=2)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
            f.write(f"/dev/block/sda1:8:1:{os.path.join(self.sys_block, 'sda', 'sda1')}\n")
            f.write(f"/dev/block/sda2:8:2:{os.path.join(self.sys_block, 'sda', 'sda2')}\n")

        # Simulate sda2 disappearing
        shutil.rmtree(os.path.join(self.sys_block, "sda", "sda2"))

        res = self._run_revalidate(checkpoint="disappearing_device_checkpoint")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("disappeared during bringup", res.stderr)

    def test_major_minor_mismatch_fails_closed(self):
        """Verify that mismatched sysfs major:minor numbers fail closed."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            # Declare major 9 instead of actual 8
            f.write(f"/dev/block/sda:9:0:{os.path.join(self.sys_block, 'sda')}\n")

        res = self._run_revalidate(checkpoint="mismatch_test")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("major:minor mismatch", res.stderr)

    def test_missing_device_node_fails_closed(self):
        """Verify that a missing /dev/block node triggers fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")

        # Remove device node
        os.remove(os.path.join(self.dev_block, "sda"))

        res = self._run_revalidate(checkpoint="missing_node_test")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("missing or not a block device", res.stderr)

    def test_blockdev_getro_returning_zero_fails_closed(self):
        """Verify that any writable physical storage node (ro=0) triggers fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")

        res = self._run_revalidate(
            checkpoint="writable_disk_test",
            extra_env={"BLOCKDEV_FORCE_GETRO_ZERO": "1"}
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("is NOT read-only (ro=0, expected 1)", res.stderr)

    def test_writable_mount_in_mount_table_fails_closed(self):
        """Verify that detecting a writable physical partition mount fails closed."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")

        # Inject dangerous writable physical mount
        with open(self.proc_mounts, "a") as f:
            f.write("/dev/block/sda1 /mnt/userdata ext4 rw,seclabel 0 0\n")

        res = self._run_revalidate(checkpoint="writable_mount_test")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Detected writable physical partition mount", res.stderr)

    def test_newly_appearing_physical_partition_detected_and_locked(self):
        """Verify newly appearing physical partition is detected, locked read-only, and added to inventory."""
        # Initially only sda is known in inventory
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")

        # In sysfs, sda1 exists (newly appeared partition not in inventory)
        res = self._run_revalidate(checkpoint="new_partition_checkpoint")
        self.assertEqual(res.returncode, 0, f"Revalidation failed: {res.stderr}\n{res.stdout}")
        with open(inv_file, "r") as f:
            new_inv = f.read()
        self.assertIn("/dev/block/sda1:8:1:", new_inv)

    def test_malformed_major_minor_in_sysfs_dev_fails_closed(self):
        """Verify malformed major:minor string (non-numeric, negative, or multiple colons) fails closed."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        # Corrupt dev file
        with open(os.path.join(self.sys_block, "sda", "dev"), "w") as f:
            f.write("invalid_major_minor\n")

        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")

        res = self._run_revalidate(checkpoint="corrupt_mm_checkpoint")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("major:minor mismatch", res.stderr)

    def test_failed_mknod_on_new_partition_fails_closed(self):
        """Verify that a failure in mknod when a new partition appears fails closed without silent suppression."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        # sda is in inventory, but sda1 is new and its node does not exist
        if os.path.exists(os.path.join(self.dev_block, "sda1")):
            os.remove(os.path.join(self.dev_block, "sda1"))

        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")

        res = self._run_revalidate(
            checkpoint="failed_mknod_checkpoint",
            extra_env={"MKNOD_FAIL": "1"}
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to mknod newly appearing partition", res.stderr)

    def test_failed_blockdev_setro_fails_closed(self):
        """Verify that blockdev --setro failure fails closed."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        # sda1 is new and needs setro
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")

        res = self._run_revalidate(
            checkpoint="failed_setro_checkpoint",
            extra_env={"BLOCKDEV_FAIL_SETRO": "1"}
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to lock newly appearing partition", res.stderr)

    def test_all_six_revalidation_checkpoints_present_in_stage2(self):
        """Verify all 6 mandatory storage revalidation checkpoints are present in scripts/stage2_init.sh."""
        with open(STAGE2_INIT_SCRIPT, "r") as f:
            content = f.read()

        checkpoints = [
            "stage2_startup",
            "before_base_system_and_overlay_mount",
            "before_child_partition_mounts",
            "before_apex_loop_mounts",
            "before_data_tmpfs_mount",
            "before_init_handover",
        ]
        for cp in checkpoints:
            self.assertIn(
                f'revalidate_storage_inventory "{cp}"',
                content,
                f"Missing mandatory storage revalidation checkpoint: {cp}"
            )


if __name__ == "__main__":
    unittest.main()
