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

        # Create mock stat
        self.mock_stat = os.path.join(self.bin_dir, "stat")
        with open(self.mock_stat, "w") as f:
            f.write(f"""#!/bin/sh
if [ "${{STAT_FAIL:-0}}" = "1" ]; then
    echo "stat: cannot stat: I/O error" >&2
    exit 1
fi
if [ -n "${{STAT_RAW_OUTPUT+x}}" ]; then
    echo "${{STAT_RAW_OUTPUT}}"
    exit 0
fi
node=""
for arg in "$@"; do
    case "$arg" in
        -*|"%t:%T") ;;
        *) node="$arg" ;;
    esac
done
bname=$(basename "$node")
dev_file="{self.sys_block}/$bname/dev"
if [ ! -f "$dev_file" ]; then
    for parent in "{self.sys_block}"/*; do
        if [ -f "$parent/$bname/dev" ]; then
            dev_file="$parent/$bname/dev"
            break
        fi
    done
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
echo "0:0"
""")
        os.chmod(self.mock_stat, 0o755)

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
elif [ "$1" = "stat" ]; then
    shift
    exec "{self.mock_stat}" "$@"
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

    def test_duplicate_device_entries_in_inventory_fail_closed(self):
        """Verify duplicate device entries in inventory trigger immediate fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")

        res = self._run_revalidate(checkpoint="duplicate_test")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Duplicate device entry", res.stderr)

    def test_inventory_byte_identity_mismatch_fails_closed(self):
        """Verify byte-identity mismatch between /mnt and /tmp inventory copies triggers fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        mnt_inv = os.path.join(self.mnt_dir, "physical_storage_inventory")
        tmp_inv = os.path.join(self.tmp_dir, "physical_storage_inventory")
        with open(mnt_inv, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        with open(tmp_inv, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
            f.write(f"/dev/block/sdb:8:16:{os.path.join(self.sys_block, 'sdb')}\n")

        res = self._run_revalidate(checkpoint="identity_mismatch_test")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("byte-identity mismatch", res.stderr)

    def test_checkpoints_recorded_to_mnt_and_tmp(self):
        """Verify successful revalidation records the checkpoint to /mnt and /tmp checkpoints_verified."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        mnt_inv = os.path.join(self.mnt_dir, "physical_storage_inventory")
        tmp_inv = os.path.join(self.tmp_dir, "physical_storage_inventory")
        inv_content = f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n"
        with open(mnt_inv, "w") as f:
            f.write(inv_content)
        with open(tmp_inv, "w") as f:
            f.write(inv_content)

        res = self._run_revalidate(checkpoint="before_apex_loop_mounts")
        self.assertEqual(res.returncode, 0, f"Revalidation failed: {res.stderr}\n{res.stdout}")

        mnt_cp = os.path.join(self.mnt_dir, "checkpoints_verified")
        tmp_cp = os.path.join(self.tmp_dir, "checkpoints_verified")
        self.assertTrue(os.path.isfile(mnt_cp), "Missing /mnt/checkpoints_verified")
        self.assertTrue(os.path.isfile(tmp_cp), "Missing /tmp/checkpoints_verified")

        with open(mnt_cp, "r") as f:
            self.assertIn("before_apex_loop_mounts", f.read())
        with open(tmp_cp, "r") as f:
            self.assertIn("before_apex_loop_mounts", f.read())

    def test_verify_checkpoints_cli_lists_six_checkpoints(self):
        """Verify --verify-checkpoints CLI prints all 6 mandatory checkpoints."""
        res = subprocess.run(
            ["sh", f"{STAGE2_INIT_SCRIPT}", "--verify-checkpoints"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        self.assertEqual(res.returncode, 0)
        expected = [
            "stage2_startup",
            "before_base_system_and_overlay_mount",
            "before_child_partition_mounts",
            "before_apex_loop_mounts",
            "before_data_tmpfs_mount",
            "before_init_handover",
        ]
        for cp in expected:
            self.assertIn(cp, res.stdout)

    # --------------------------------------------------------------------------
    # Stage-2 Block-Node Identity Verification Tests
    # --------------------------------------------------------------------------
    def test_stage2_block_node_identity_matching_passes(self):
        """Verify matching block-node identity passes Stage-2 revalidation."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate(
            checkpoint="stage2_identity_matching",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_RAW_OUTPUT": "8:0",
            }
        )
        self.assertEqual(res.returncode, 0, f"Expected success but got: {res.stderr}\n{res.stdout}")
        self.assertIn("Storage inventory revalidation PASSED", res.stdout)

    def test_stage2_block_node_identity_hex_conversion_passes(self):
        """Verify hexadecimal conversion (0x10 hex -> 16 decimal) passes verification."""
        self._create_mock_disk("sda", 8, 16, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:16:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate(
            checkpoint="stage2_hex_conversion",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_RAW_OUTPUT": "8:10",  # 0x10 == 16
            }
        )
        self.assertEqual(res.returncode, 0, f"Expected success but got: {res.stderr}\n{res.stdout}")
        self.assertIn("Storage inventory revalidation PASSED", res.stdout)

    def test_stage2_block_node_identity_major_mismatch_fails_closed(self):
        """Verify major mismatch in stat output triggers immediate fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate(
            checkpoint="stage2_major_mismatch",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_RAW_OUTPUT": "9:0",
            }
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("does not match inventory and sysfs", res.stderr)

    def test_stage2_block_node_identity_minor_mismatch_fails_closed(self):
        """Verify minor mismatch in stat output triggers immediate fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate(
            checkpoint="stage2_minor_mismatch",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_RAW_OUTPUT": "8:99",
            }
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("does not match inventory and sysfs", res.stderr)

    def test_stage2_block_node_identity_malformed_stat_output_fails_closed(self):
        """Verify malformed stat output (missing colon, extra colons, non-hex) fails closed."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        for malformed in ["invalid_output", "8:0:1", "g:0", "8:z"]:
            with self.subTest(malformed=malformed):
                res = self._run_revalidate(
                    checkpoint="stage2_malformed_stat",
                    extra_env={
                        "STAGE2_TEST_VERIFY_STAT": "1",
                        "STAT_RAW_OUTPUT": malformed,
                    }
                )
                self.assertNotEqual(res.returncode, 0)
                self.assertTrue(
                    "Malformed stat output" in res.stderr or "Non-hexadecimal" in res.stderr,
                    f"Unexpected stderr for '{malformed}': {res.stderr}"
                )

    def test_stage2_block_node_identity_empty_stat_output_fails_closed(self):
        """Verify empty stat output triggers immediate fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate(
            checkpoint="stage2_empty_stat",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_RAW_OUTPUT": "",
            }
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Empty stat output", res.stderr)

    def test_stage2_block_node_identity_stat_nonzero_exit_fails_closed(self):
        """Verify non-zero stat exit code triggers immediate fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate(
            checkpoint="stage2_stat_fail",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_FAIL": "1",
            }
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("stat -L -c '%t:%T' failed on block node", res.stderr)

    def test_stage2_block_node_identity_stat_unavailable_fails_closed(self):
        """Verify absence of any stat binary triggers immediate fail-closed halt."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        no_stat_dir = os.path.join(self.test_dir, "no_stat_bin")
        os.makedirs(no_stat_dir, exist_ok=True)
        sh_path = shutil.which("sh") or "/bin/sh"
        os.symlink(sh_path, os.path.join(no_stat_dir, "sh"))
        for tool in ["rm", "mv", "cp", "cat", "echo", "grep", "tr", "cut", "sed", "wc", "basename", "dirname", "printf", "cmp", "blockdev"]:
            tool_path = shutil.which(tool)
            if tool_path:
                os.symlink(tool_path, os.path.join(no_stat_dir, tool))

        res = self._run_revalidate(
            checkpoint="stage2_stat_unavailable",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_BIN": "/nonexistent/stat_binary",
                "PATH": no_stat_dir,
            }
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("No stat binary available to verify block device node identity", res.stderr)

    def test_stage2_block_node_identity_zero_identity_rejected_fails_closed(self):
        """Verify unexpected zero device identity (0:0) is rejected fail-closed."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate(
            checkpoint="stage2_zero_identity",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_RAW_OUTPUT": "0:0",
            }
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Unexpected zero device identity (0:0)", res.stderr)

    def test_stage2_newly_appearing_disk_identity_mismatch_fails_closed(self):
        """Verify newly appearing disk with mismatched node identity fails closed."""
        # Initial inventory has sda only
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        # Newly appearing disk sdb in sysfs
        self._create_mock_disk("sdb", 8, 16, partition_count=0)

        # Force stat to return mismatched identity 8:99
        res = self._run_revalidate(
            checkpoint="stage2_new_disk_mismatch",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_RAW_OUTPUT": "8:63",  # 0x63 == 99 decimal != 16
            }
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("does not match inventory and sysfs", res.stderr)

    def test_stage2_newly_appearing_partition_identity_mismatch_fails_closed(self):
        """Verify newly appearing partition with mismatched node identity fails closed."""
        self._create_mock_disk("sda", 8, 0, partition_count=1)
        # Inventory only has sda (sda1 is newly appearing)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        res = self._run_revalidate(
            checkpoint="stage2_new_part_mismatch",
            extra_env={
                "STAGE2_TEST_VERIFY_STAT": "1",
                "STAT_RAW_OUTPUT": "8:2",  # expected 8:1
            }
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("does not match inventory and sysfs", res.stderr)

    def test_stage2_production_mode_rejects_regular_file_mock_fails_closed(self):
        """Verify regular file mocks pass in test mode but fail closed in production mode."""
        self._create_mock_disk("sda", 8, 0, partition_count=0)
        inv_file = os.path.join(self.mnt_dir, "physical_storage_inventory")
        with open(inv_file, "w") as f:
            f.write(f"/dev/block/sda:8:0:{os.path.join(self.sys_block, 'sda')}\n")
        shutil.copyfile(inv_file, os.path.join(self.tmp_dir, "physical_storage_inventory"))

        # Test mode = 1: regular file mock passes
        res_test = self._run_revalidate(checkpoint="test_mode_check")
        self.assertEqual(res_test.returncode, 0, f"Failed in test mode: {res_test.stderr}")

        # Production mode (STAGE2_TEST_MODE = 0): regular file mock is rejected fail-closed
        res_prod = self._run_revalidate(
            checkpoint="prod_mode_check",
            extra_env={
                "STAGE2_TEST_MODE": "0",
                "STAGE2_FATAL_TEST_EXIT": "1",
            }
        )
        self.assertNotEqual(res_prod.returncode, 0)
        self.assertIn("is NOT a block device", res_prod.stderr)


class TestStage1StorageSafety(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="stage1_safety_test_")
        self.bin_dir = os.path.join(self.test_dir, "bin")
        os.makedirs(self.bin_dir, exist_ok=True)
        self.mnt_dir = os.path.join(self.test_dir, "mnt")
        self.tmp_dir = os.path.join(self.test_dir, "tmp")
        os.makedirs(self.mnt_dir, exist_ok=True)
        os.makedirs(self.tmp_dir, exist_ok=True)

        self.proc_dir = os.path.join(self.test_dir, "proc")
        os.makedirs(self.proc_dir, exist_ok=True)
        self.proc_mounts = os.path.join(self.proc_dir, "mounts")
        with open(self.proc_mounts, "w") as f:
            f.write("none /proc proc rw 0 0\n")

        # Mock toybox
        self.toybox_bin = os.path.join(self.bin_dir, "toybox")
        with open(self.toybox_bin, "w") as f:
            f.write(f"""#!/usr/bin/env bash
subcmd="$1"
shift
case "$subcmd" in
    grep)
        exec grep "$@"
        ;;
    awk)
        exec awk "$@"
        ;;
    tr)
        exec tr "$@"
        ;;
    cut)
        exec cut "$@"
        ;;
    sort)
        exec sort "$@"
        ;;
    uniq)
        exec uniq "$@"
        ;;
    cmp)
        exec cmp "$@"
        ;;
    df)
        if [ "${{MOCK_DF_FAIL:-0}}" = "1" ]; then
            echo "df: failed" >&2
            exit 1
        elif [ "${{MOCK_DF_CORRUPT:-0}}" = "1" ]; then
            echo "Filesystem 1M-blocks Used Available Use% Mounted on"
            echo "tmpfs 6500 100 UNKNOWN 2% $1"
            exit 0
        elif [ "${{MOCK_DF_LOW_CAPACITY:-0}}" = "1" ]; then
            echo "Filesystem 1M-blocks Used Available Use% Mounted on"
            echo "tmpfs 100 90 10 90% $1"
            exit 0
        else
            echo "Filesystem 1M-blocks Used Available Use% Mounted on"
            echo "tmpfs 6500 100 6400 2% $1"
            exit 0
        fi
        ;;
    mkdir)
        if [ "${{MOCK_MKDIR_FAIL:-0}}" = "1" ]; then
            echo "mkdir: permission denied" >&2
            exit 1
        fi
        exec /bin/mkdir "$@"
        ;;
    mount)
        if [ "${{MOCK_MOUNT_FAIL:-0}}" = "1" ]; then
            echo "mount: error: mount failed" >&2
            exit 1
        fi
        exit 0
        ;;
    *)
        exec "$subcmd" "$@"
        ;;
esac
""")
        os.chmod(self.toybox_bin, 0o755)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _extract_and_run_mount_tmpfs(self, target, size_opt, min_free, extra_env=None):
        """Extract mount_and_verify_tmpfs definition from stage1/loader_ramdisk/init and run it."""
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}:" + env.get("PATH", "")
        env["PROC_MOUNTS_FILE"] = self.proc_mounts
        if extra_env:
            env.update(extra_env)

        # Extract function from loader_ramdisk/init
        init_file = os.path.join(PROJECT_ROOT, "stage1/loader_ramdisk/init")
        with open(init_file, "r") as f:
            init_code = f.read()

        start_marker = "mount_and_verify_tmpfs() {"
        end_marker = '\nmount_and_verify_tmpfs "/mnt"'
        self.assertIn(start_marker, init_code)
        self.assertIn(end_marker, init_code)
        start_idx = init_code.index(start_marker)
        end_idx = init_code.index(end_marker)
        prod_function = init_code[start_idx:end_idx].strip()

        # Verify that native_ramdisk/init defines the exact same function
        native_init_file = os.path.join(PROJECT_ROOT, "stage1/native_ramdisk/init")
        with open(native_init_file, "r") as f:
            native_init_code = f.read()
        native_prod_function = native_init_code[native_init_code.index(start_marker):native_init_code.index(end_marker)].strip()
        self.assertEqual(prod_function, native_prod_function, "Loader and native ramdisks must have identical mount_and_verify_tmpfs")

        # Build runner script that executes the ACTUAL production function
        test_script = f"""#!/usr/bin/env bash
set -e
fatal_halt() {{
    echo "[FATAL] $1" >&2
    exit 1
}}
log_kmsg() {{
    echo "$1"
}}
/system/bin/toybox() {{
    "{self.toybox_bin}" "$@"
}}

{prod_function}

mount_and_verify_tmpfs "$1" "$2" "$3"
"""
        runner_path = os.path.join(self.test_dir, "run_mount_test.sh")
        with open(runner_path, "w") as f:
            f.write(test_script)
        os.chmod(runner_path, 0o755)

        return subprocess.run(
            ["bash", runner_path, target, size_opt, str(min_free)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env
        )

    def test_stage1_mount_success_mnt(self):
        """Verify successful /mnt tmpfs mount and verification in Stage 1."""
        with open(self.proc_mounts, "a") as f:
            f.write(f"tmpfs {self.mnt_dir} tmpfs rw,mode=777 0 0\n")

        res = self._extract_and_run_mount_tmpfs(self.mnt_dir, "size=6500M", 576)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}\n{res.stdout}")
        self.assertIn("Verified", res.stdout)
        self.assertIn("quota: size=6500M", res.stdout)

    def test_stage1_mount_success_tmp(self):
        """Verify successful /tmp tmpfs mount and verification in Stage 1."""
        tmp_dir = os.path.join(self.test_dir, "mock_tmp")
        with open(self.proc_mounts, "a") as f:
            f.write(f"tmpfs {tmp_dir} tmpfs rw,mode=777 0 0\n")

        res = self._extract_and_run_mount_tmpfs(tmp_dir, "size=512M", 64)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}\n{res.stdout}")
        self.assertIn("Verified", res.stdout)
        self.assertIn("quota: size=512M", res.stdout)

    def test_stage1_mount_command_failure_fails_closed(self):
        """Verify mount failure when mount command fails."""
        res = self._extract_and_run_mount_tmpfs(
            self.mnt_dir,
            "size=6500M",
            576,
            extra_env={"MOCK_MOUNT_FAIL": "1"}
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to mount tmpfs on", res.stderr)

    def test_stage1_missing_mount_table_entry_fails_closed(self):
        """Verify failure when mount command succeeds but /proc/mounts lacks the target."""
        # proc_mounts is empty
        res = self._extract_and_run_mount_tmpfs(self.mnt_dir, "size=6500M", 576)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("is not mounted according to /proc/mounts", res.stderr)

    def test_stage1_mount_wrong_fstype_fails_closed(self):
        """Verify mount failure when filesystem type is not tmpfs."""
        with open(self.proc_mounts, "a") as f:
            f.write(f"ext4 {self.mnt_dir} ext4 rw 0 0\n")

        res = self._extract_and_run_mount_tmpfs(self.mnt_dir, "size=6500M", 576)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("filesystem is 'ext4', expected 'tmpfs'", res.stderr)

    def test_stage1_mount_physical_device_source_fails_closed(self):
        """Verify mount failure when source is backed by a physical block device."""
        with open(self.proc_mounts, "a") as f:
            f.write(f"/dev/block/sda32 {self.mnt_dir} tmpfs rw 0 0\n")

        res = self._extract_and_run_mount_tmpfs(self.mnt_dir, "size=6500M", 576)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CRITICAL SAFETY VIOLATION: ", res.stderr)
        self.assertIn("backed by physical block device", res.stderr)

    def test_stage1_mount_df_failure_fails_closed(self):
        """Verify mount failure when df command returns non-zero error."""
        with open(self.proc_mounts, "a") as f:
            f.write(f"tmpfs {self.mnt_dir} tmpfs rw 0 0\n")

        res = self._extract_and_run_mount_tmpfs(
            self.mnt_dir,
            "size=6500M",
            576,
            extra_env={"MOCK_DF_FAIL": "1"}
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to parse numeric free capacity", res.stderr)

    def test_stage1_mount_invalid_capacity_output_fails_closed(self):
        """Verify mount failure when df returns malformed non-numeric output."""
        with open(self.proc_mounts, "a") as f:
            f.write(f"tmpfs {self.mnt_dir} tmpfs rw 0 0\n")

        res = self._extract_and_run_mount_tmpfs(
            self.mnt_dir,
            "size=6500M",
            576,
            extra_env={"MOCK_DF_CORRUPT": "1"}
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to parse numeric free capacity", res.stderr)

    def test_stage1_mount_capacity_exhaustion_fails_closed(self):
        """Verify mount failure when usable capacity is below requirement."""
        with open(self.proc_mounts, "a") as f:
            f.write(f"tmpfs {self.mnt_dir} tmpfs rw 0 0\n")

        res = self._extract_and_run_mount_tmpfs(
            self.mnt_dir,
            "size=6500M",
            576,
            extra_env={"MOCK_DF_LOW_CAPACITY": "1"}
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Mount capacity error:", res.stderr)
        self.assertIn("provides only 10MB free", res.stderr)

    def test_stage1_mount_missing_mountpoint_creation_success(self):
        """Verify mountpoint directory is automatically created if it does not exist."""
        nonexistent = os.path.join(self.test_dir, "nonexistent_mnt")
        self.assertFalse(os.path.exists(nonexistent))
        with open(self.proc_mounts, "a") as f:
            f.write(f"tmpfs {nonexistent} tmpfs rw 0 0\n")

        res = self._extract_and_run_mount_tmpfs(nonexistent, "size=6500M", 576)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}\n{res.stdout}")
        self.assertTrue(os.path.isdir(nonexistent))

    def test_stage1_mount_mkdir_failure_fails_closed(self):
        """Verify failure when mountpoint directory creation fails."""
        nonexistent = os.path.join(self.test_dir, "nonexistent_mnt_fail")
        res = self._extract_and_run_mount_tmpfs(
            nonexistent,
            "size=6500M",
            576,
            extra_env={"MOCK_MKDIR_FAIL": "1"}
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to create directory", res.stderr)


if __name__ == "__main__":
    unittest.main()
