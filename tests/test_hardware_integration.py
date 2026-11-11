#!/usr/bin/env python3
"""
tests/test_hardware_integration.py
Comprehensive unit and integration test suite for tools/integrate_hardware_assets.py.

Verifies:
1. Complete verification and classification of all 84 authentic OnePlus 7T physical partition images.
2. Strict rejection of corrupted checksums, duplicate entries, unexpected entries, missing images, empty files, and symlinks.
3. Strict format validation preventing arbitrary fake binaries from passing as authentic partitions:
   - Android Boot Image v2
   - DTBO Image
   - FAT / vfat Filesystem
   - ext4 Filesystem
   - AVB vbmeta Structure
   - ELF Binary / Qualcomm MBN
4. Stage-1 extraction & staged asset validation (DTB, Recovery DTBO, Kernel ARM64/4.14 banner).
5. Stage-2 runtime firmware mount validation in fstab.qcom (paths, filesystems, 'ro' flag, slotselect).
6. Separation of discrete verification stages:
   INVENTORY_VERIFIED, ASSET_CLASSIFIED, ASSET_EXTRACTED, ASSET_STAGED, RUNTIME_CONFIG_VERIFIED, INTEGRATION_VERIFIED.
7. Mock test semantics: Mock CLI runs are explicitly labeled as mock simulations, never claimed as authentic 100% verified hardware.
"""

import os
import sys
import unittest
import tempfile
import shutil
import subprocess
import json
import struct

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
INTEGRATE_SCRIPT = os.path.join(PROJECT_ROOT, "tools", "integrate_hardware_assets.py")

sys.path.insert(0, os.path.join(PROJECT_ROOT, "tools"))
import integrate_hardware_assets as iha


class TestHardwareIntegration(unittest.TestCase):
    """Test suite for OnePlus 7T hardware asset integration, inspection, and verification."""

    def setUp(self):
        self.partitions_dir = getattr(self, "partitions_dir", os.path.join(PROJECT_ROOT, "partitions"))
        self.manifest_path = getattr(self, "manifest_path", os.path.join(PROJECT_ROOT, "partitions", "SHA256SUMS"))
        self.test_dir = tempfile.mkdtemp(prefix="test_hw_integrate_")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_all_84_images_verified_in_real_partitions(self):
        """Verify that the real partitions/ directory contains exactly 84 cryptographically verified images."""
        if not os.path.isdir(self.partitions_dir):
            self.skipTest("partitions/ directory not found in workspace (CI environment)")

        inventory = iha.verify_hardware_assets(self.partitions_dir, self.manifest_path)
        self.assertEqual(len(inventory), 84)

        categories = set(item["category"] for item in inventory.values())
        self.assertIn("REQUIRED_RAM_BOOT", categories)
        self.assertIn("REQUIRED_HARDWARE_FIRMWARE", categories)
        self.assertIn("DEVICE_CALIBRATION_NVRAM", categories)
        self.assertIn("FORBIDDEN_USERSPACE", categories)
        self.assertIn("VERIFIED_BOOT_AVB", categories)
        self.assertIn("REFERENCE_ONLY", categories)

    def test_boot_and_device_tree_assets_classified(self):
        """Verify specific classification and expected format of boot and device tree assets."""
        for img in ["boot_a.img", "boot_b.img", "recovery_a.img", "recovery_b.img", "dtbo_a.img", "dtbo_b.img"]:
            item = iha.ASSET_CLASSIFICATIONS.get(img)
            self.assertIsNotNone(item, f"{img} missing from classifications")
            self.assertEqual(item["category"], "REQUIRED_RAM_BOOT")
            if "boot" in img or "recovery" in img:
                self.assertEqual(item["expected_format"], "Android Boot Image v2")
            elif "dtbo" in img:
                self.assertEqual(item["expected_format"], "DTBO Image (dtbo/dtb)")

    def test_hardware_firmware_assets_classified(self):
        """Verify specific classification and format of subsystem firmware assets."""
        for img in ["modem_a.img", "modem_b.img", "dsp_a.img", "dsp_b.img", "bluetooth_a.img", "bluetooth_b.img", "persist.img"]:
            item = iha.ASSET_CLASSIFICATIONS.get(img)
            self.assertIsNotNone(item, f"{img} missing from classifications")
            self.assertEqual(item["category"], "REQUIRED_HARDWARE_FIRMWARE")

    def test_forbidden_userspace_assets_classified(self):
        """Verify bootloader and security partitions are marked FORBIDDEN_USERSPACE."""
        for img in ["xbl_a.img", "abl_a.img", "tz_a.img", "hyp_a.img", "aop_a.img", "keymaster_a.img", "cmnlib_a.img"]:
            item = iha.ASSET_CLASSIFICATIONS.get(img)
            self.assertIsNotNone(item, f"{img} missing from classifications")
            self.assertEqual(item["category"], "FORBIDDEN_USERSPACE")

    def test_mismatched_checksum_fails_closed(self):
        """Verify that a corrupted image checksum raises an exception and fails closed."""
        mock_parts = os.path.join(self.test_dir, "mock_partitions")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "SHA256SUMS")

        manifest_lines = []
        for i, fname in enumerate(iha.ASSET_CLASSIFICATIONS.keys()):
            fpath = os.path.join(mock_parts, fname)
            with open(fpath, "wb") as f:
                f.write(b"content" * (i + 1))
            sha = iha.compute_sha256(fpath)
            if i == 0:
                sha = "0" * 64
            manifest_lines.append(f"{sha}  {fname}\n")

        with open(mock_manifest, "w") as f:
            f.writelines(manifest_lines)

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest, is_mock=True)
        self.assertIn("mismatch", str(ctx.exception).lower())

    def test_duplicate_manifest_entry_rejected(self):
        """Verify that duplicate entries in checksum manifest raise ValueError."""
        mock_parts = os.path.join(self.test_dir, "mock_dup_parts")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "SHA256SUMS")

        fpath = os.path.join(mock_parts, "boot_a.img")
        with open(fpath, "wb") as f:
            f.write(b"DATA")
        sha = iha.compute_sha256(fpath)

        with open(mock_manifest, "w") as f:
            f.write(f"{sha}  boot_a.img\n")
            f.write(f"{sha}  boot_a.img\n")

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest, is_mock=True)
        self.assertIn("duplicate", str(ctx.exception).lower())

    def test_unexpected_manifest_entry_rejected(self):
        """Verify that manifest entries missing on disk raise ValueError."""
        mock_parts = os.path.join(self.test_dir, "mock_unexp_parts")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "SHA256SUMS")

        fpath = os.path.join(mock_parts, "boot_a.img")
        with open(fpath, "wb") as f:
            f.write(b"DATA")
        sha = iha.compute_sha256(fpath)

        with open(mock_manifest, "w") as f:
            f.write(f"{sha}  boot_a.img\n")
            f.write(f"{'a'*64}  ghost_partition.img\n")

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest, is_mock=True)
        self.assertIn("entries not found", str(ctx.exception).lower())

    def test_missing_image_fails_closed(self):
        """Verify that fewer than 84 images raises an error in authentic mode."""
        mock_parts = os.path.join(self.test_dir, "mock_partitions_missing")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "SHA256SUMS")

        with open(os.path.join(mock_parts, "only_one.img"), "wb") as f:
            f.write(b"data")
        with open(mock_manifest, "w") as f:
            f.write(f"{iha.compute_sha256(os.path.join(mock_parts, 'only_one.img'))}  only_one.img\n")

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest, is_mock=False)
        self.assertIn("expected exactly 84", str(ctx.exception).lower())

    def test_empty_image_fails_closed(self):
        """Verify that a 0-byte partition image is rejected."""
        mock_parts = os.path.join(self.test_dir, "mock_empty_parts")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "SHA256SUMS")

        empty_file = os.path.join(mock_parts, "boot_a.img")
        with open(empty_file, "wb") as f:
            pass

        with open(mock_manifest, "w") as f:
            f.write(f"{'e'*64}  boot_a.img\n")

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest, is_mock=True)
        self.assertIn("empty", str(ctx.exception).lower())

    def test_symlink_image_fails_closed(self):
        """Verify that a symlink masquerading as an image is rejected."""
        mock_parts = os.path.join(self.test_dir, "mock_link_parts")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "SHA256SUMS")

        real_target = os.path.join(self.test_dir, "real_target.bin")
        with open(real_target, "wb") as f:
            f.write(b"REAL_TARGET_BYTES")

        link_file = os.path.join(mock_parts, "boot_a.img")
        os.symlink(real_target, link_file)

        with open(mock_manifest, "w") as f:
            f.write(f"{iha.compute_sha256(real_target)}  boot_a.img\n")

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest, is_mock=True)
        self.assertIn("not a regular file", str(ctx.exception).lower())

    def test_fake_boot_image_fails_format_validation(self):
        """Verify that arbitrary bytes in boot_a.img fail strict format validation."""
        mock_parts = os.path.join(self.test_dir, "mock_fake_boot")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "SHA256SUMS")

        manifest_lines = []
        for name in iha.ASSET_CLASSIFICATIONS.keys():
            img_path = os.path.join(mock_parts, name)
            with open(img_path, "wb") as f:
                f.write(b"NOT_A_VALID_BOOT_MAGIC_OR_HEADER" * 10)
            sha = iha.compute_sha256(img_path)
            manifest_lines.append(f"{sha}  {name}\n")

        with open(mock_manifest, "w") as f:
            f.writelines(manifest_lines)

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest, is_mock=False)
        self.assertIn("format mismatch", str(ctx.exception).lower())

    def test_fake_dtbo_image_fails_format_validation(self):
        """Verify that invalid DTBO header magic fails format validation."""
        head = b"NOT_DTBO" + b"\x00" * 32
        with self.assertRaises(ValueError) as ctx:
            iha.detect_and_validate_format(head, 1024, "dtbo_a.img", "DTBO Image (dtbo/dtb)", is_mock=False)
        self.assertIn("format mismatch", str(ctx.exception).lower())

    def test_fake_ext4_image_fails_format_validation(self):
        """Verify that missing ext4 superblock magic 0xef53 fails format validation."""
        head = b"\x00" * 2048
        with self.assertRaises(ValueError) as ctx:
            iha.detect_and_validate_format(head, 2048, "dsp_a.img", "ext4 Filesystem", is_mock=False)
        self.assertIn("format mismatch", str(ctx.exception).lower())

    def test_fake_avb_image_fails_format_validation(self):
        """Verify that invalid AVB magic fails format validation."""
        head = b"NOAVB" + b"\x00" * 64
        with self.assertRaises(ValueError) as ctx:
            iha.detect_and_validate_format(head, 1024, "vbmeta_a.img", "AVB vbmeta Structure", is_mock=False)
        self.assertIn("format mismatch", str(ctx.exception).lower())

    def test_fake_elf_image_fails_format_validation(self):
        """Verify that invalid ELF magic fails format validation."""
        head = b"\x00\x00\x00\x00" + b"\x00" * 64
        with self.assertRaises(ValueError) as ctx:
            iha.detect_and_validate_format(head, 1024, "xbl_a.img", "ELF Binary / Qualcomm MBN", is_mock=False)
        self.assertIn("format mismatch", str(ctx.exception).lower())

    def test_missing_stage1_asset_fails_integration(self):
        """Verify that missing DTB or kernel in stage1_dir causes extraction/staging to fail."""
        empty_stage1 = os.path.join(self.test_dir, "empty_stage1")
        os.makedirs(empty_stage1, exist_ok=True)
        res = iha.extract_and_verify_stage1_assets(self.partitions_dir, empty_stage1, is_mock=False)
        self.assertEqual(res["status"], "FAILED")
        self.assertTrue(any("missing" in err.lower() for err in res["errors"]))

    def test_missing_fstab_mount_fails_integration(self):
        """Verify that fstab.qcom missing mandatory mounts fails validation."""
        bad_fstab = os.path.join(self.test_dir, "fstab_bad.qcom")
        with open(bad_fstab, "w") as f:
            f.write("# Incomplete fstab\nnone /data tmpfs rw wait\n")
        res = iha.verify_runtime_firmware_mounts(bad_fstab, is_mock=False)
        self.assertEqual(res["status"], "FAILED")
        self.assertTrue(any("missing mandatory firmware mount" in err.lower() for err in res["errors"]))

    def test_fstab_missing_ro_flag_fails_safety_check(self):
        """Verify that fstab.qcom mounts lacking the 'ro' option fail closed with critical error."""
        rw_fstab = os.path.join(self.test_dir, "fstab_rw.qcom")
        with open(rw_fstab, "w") as f:
            f.write(
                "/dev/block/bootdevice/by-name/modem /vendor/firmware_mnt vfat rw wait,slotselect\n"
                "/dev/block/bootdevice/by-name/dsp /vendor/dsp ext4 rw wait,slotselect\n"
                "/dev/block/bootdevice/by-name/bluetooth /vendor/bt_firmware vfat rw wait,slotselect\n"
                "/dev/block/bootdevice/by-name/persist /mnt/vendor/persist ext4 rw wait\n"
            )
        res = iha.verify_runtime_firmware_mounts(rw_fstab, is_mock=False)
        self.assertEqual(res["status"], "FAILED")
        self.assertTrue(any("critical safety violation" in err.lower() for err in res["errors"]))

    def test_real_hardware_integration_verification(self):
        """Verify authentic hardware extraction, kernel staging, and fstab mounts."""
        if not os.path.isdir(self.partitions_dir):
            self.skipTest("partitions/ directory not found in workspace (CI environment)")

        stage1_dir = os.path.join(PROJECT_ROOT, "stage1", "kernel_src")
        fstab_path = os.path.join(PROJECT_ROOT, "work", "vendor", "vendor", "etc", "fstab.qcom")

        stage1_res = iha.extract_and_verify_stage1_assets(self.partitions_dir, stage1_dir, is_mock=False)
        self.assertEqual(stage1_res["status"], "PASSED", f"Stage-1 verification failed: {stage1_res.get('errors')}")
        self.assertEqual(stage1_res["extracted"]["dtb"]["sha256"], "e4faf7c553f88246077343de51487d90517bb534e345ee44893d2e4fb348df3c")
        self.assertEqual(stage1_res["extracted"]["recovery_dtbo"]["sha256"], "7cfdd1984a7be7edd8ef4e761540cf32e69f1cba6a844afe6ba6780dd12223c1")
        self.assertEqual(stage1_res["staged"]["kernel"]["sha256"], "c32e3a267b1e44e92f0bdb909358e1c95fa900cb8219076581cdbb4084cc9129")

        fstab_res = iha.verify_runtime_firmware_mounts(fstab_path, is_mock=False)
        self.assertEqual(fstab_res["status"], "PASSED", f"fstab verification failed: {fstab_res.get('errors')}")
        self.assertTrue(fstab_res["mounts"]["/mnt/vendor/persist"]["verified_ro"])

    def test_real_cli_execution_and_manifest_generation(self):
        """Verify CLI execution on authentic hardware generates complete manifest and exits 0."""
        if not os.path.isdir(self.partitions_dir):
            self.skipTest("partitions/ directory not found in workspace (CI environment)")

        docs_out = os.path.join(self.test_dir, "HARDWARE_INTEGRATION_MANIFEST.md")
        json_out = os.path.join(self.test_dir, "HARDWARE_INTEGRATION_MANIFEST.json")

        res = subprocess.run([
            sys.executable, INTEGRATE_SCRIPT,
            "--verify-integration",
            "--docs-out", docs_out,
            "--json-out", json_out,
        ], capture_output=True, text=True)

        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}\n{res.stdout}")
        self.assertIn("Hardware Verification Status: PASSED", res.stdout)
        self.assertTrue(os.path.isfile(docs_out))
        self.assertTrue(os.path.isfile(json_out))

        with open(json_out) as f:
            data = json.load(f)
        self.assertFalse(data["is_mock"])
        self.assertEqual(data["verification_stages"]["overall_integration"], "PASSED")
        self.assertEqual(data["verification_stages"]["inventory"], "PASSED")
        self.assertEqual(data["verification_stages"]["extraction"], "PASSED")
        self.assertEqual(data["verification_stages"]["staging"], "PASSED")
        self.assertEqual(data["verification_stages"]["runtime_config"], "PASSED")

    def test_mock_cli_execution_labeled_as_mock(self):
        """Verify CLI execution with --mock is explicitly labeled as mock and never claims 100% verified authentic hardware."""
        mock_parts = os.path.join(self.test_dir, "mock_cli_parts")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "MOCK_SHA256SUMS")

        manifest_lines = []
        for name in iha.ASSET_CLASSIFICATIONS.keys():
            img_path = os.path.join(mock_parts, name)
            with open(img_path, "wb") as f:
                f.write(f"MOCK_DUMMY_DATA_{name}".encode("utf-8"))
            sha = iha.compute_sha256(img_path)
            manifest_lines.append(f"{sha}  {name}\n")

        with open(mock_manifest, "w", encoding="utf-8") as f:
            f.writelines(manifest_lines)

        docs_out = os.path.join(self.test_dir, "MOCK_MANIFEST.md")
        json_out = os.path.join(self.test_dir, "MOCK_MANIFEST.json")

        res = subprocess.run([
            sys.executable, INTEGRATE_SCRIPT,
            "--mock",
            "--partitions-dir", mock_parts,
            "--manifest", mock_manifest,
            "--docs-out", docs_out,
            "--json-out", json_out,
        ], capture_output=True, text=True)

        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}\n{res.stdout}")
        self.assertIn("Mode:                        MOCK SIMULATION", res.stdout)
        self.assertIn("Hardware Verification Status: MOCK_VERIFIED", res.stdout)
        self.assertTrue(os.path.isfile(docs_out))
        self.assertTrue(os.path.isfile(json_out))

        with open(json_out) as f:
            data = json.load(f)
        self.assertTrue(data["is_mock"], "Mock test run must be flagged is_mock=True in JSON")
        self.assertEqual(data["verification_stages"]["overall_integration"], "MOCK_VERIFIED")
        self.assertNotEqual(data["verification_stages"]["overall_integration"], "PASSED")

        with open(docs_out) as f:
            md_content = f.read()
        self.assertIn("MOCK TEST SIMULATION", md_content)


if __name__ == "__main__":
    unittest.main()
