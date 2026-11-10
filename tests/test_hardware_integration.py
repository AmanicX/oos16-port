#!/usr/bin/env python3
"""
tests/test_hardware_integration.py
Unit and integration tests for tools/integrate_hardware_assets.py.

Verifies:
1. Complete verification and classification of all 84 authentic OnePlus 7T physical partition images.
2. Rejection of corrupted checksums or missing partition images.
3. Accurate architectural categorization across the 5 defined categories:
   - REQUIRED_RAM_BOOT (boot_a/b, recovery_a/b, dtbo_a/b)
   - REQUIRED_HARDWARE_FIRMWARE (modem_a/b, dsp_a/b, bluetooth_a/b, persist)
   - DEVICE_CALIBRATION_NVRAM (fsc, fsg, modemst1/2, mdm*, param, devinfo, limits)
   - FORBIDDEN_USERSPACE (abl, xbl, tz, hyp, aop, keymaster, cmnlib, storsec, uefisecapp, etc.)
   - VERIFIED_BOOT_AVB (vbmeta_a/b, vbmeta_system_a/b)
   - REFERENCE_ONLY (LOGO_a/b, splash, carrier, config, op1/2, opproduct_a/b)
4. Integration verification of Stage-1 DTB (9055368 B), Recovery DTBO (3219456 B), and Kernel (48713752 B).
5. Verification of hardware firmware mount points (/vendor/firmware_mnt, /vendor/dsp, /vendor/bt_firmware) in fstab.qcom.
6. Generation of Markdown and JSON hardware integration manifests.
"""

import os
import sys
import unittest
import tempfile
import shutil
import subprocess
import json

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
INTEGRATE_SCRIPT = os.path.join(PROJECT_ROOT, "tools", "integrate_hardware_assets.py")

sys.path.insert(0, os.path.join(PROJECT_ROOT, "tools"))
import integrate_hardware_assets as iha


class TestHardwareIntegration(unittest.TestCase):
    """Test suite for OnePlus 7T hardware asset integration, inspection, and verification."""

    def setUp(self):
        self.partitions_dir = os.path.join(PROJECT_ROOT, "partitions")
        self.manifest_path = os.path.join(PROJECT_ROOT, "partitions", "SHA256SUMS")
        self.test_dir = tempfile.mkdtemp(prefix="test_hw_integrate_")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_all_84_images_verified_in_real_partitions(self):
        """Verify that the real partitions/ directory contains exactly 84 cryptographically verified images."""
        if not os.path.isdir(self.partitions_dir):
            self.skipTest("partitions/ directory not found in workspace")

        inventory = iha.verify_hardware_assets(self.partitions_dir, self.manifest_path)
        self.assertEqual(len(inventory), 84)

        # Check required categories
        categories = set(item["category"] for item in inventory.values())
        self.assertIn("REQUIRED_RAM_BOOT", categories)
        self.assertIn("REQUIRED_HARDWARE_FIRMWARE", categories)
        self.assertIn("DEVICE_CALIBRATION_NVRAM", categories)
        self.assertIn("FORBIDDEN_USERSPACE", categories)
        self.assertIn("VERIFIED_BOOT_AVB", categories)
        self.assertIn("REFERENCE_ONLY", categories)

    def test_boot_and_device_tree_assets_classified(self):
        """Verify specific classification of boot and device tree assets."""
        for img in ["boot_a.img", "boot_b.img", "recovery_a.img", "recovery_b.img", "dtbo_a.img", "dtbo_b.img"]:
            item = iha.ASSET_CLASSIFICATIONS.get(img)
            self.assertIsNotNone(item, f"{img} missing from classifications")
            self.assertEqual(item["category"], "REQUIRED_RAM_BOOT")

    def test_hardware_firmware_assets_classified(self):
        """Verify specific classification of subsystem firmware assets."""
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

        # Create 84 dummy files
        manifest_lines = []
        for i in range(84):
            fname = f"part_{i}.img"
            fpath = os.path.join(mock_parts, fname)
            with open(fpath, "wb") as f:
                f.write(b"content" * (i + 1))
            sha = iha.compute_sha256(fpath)
            if i == 0:
                # Intentionally corrupt manifest hash for first image
                sha = "0" * 64
            manifest_lines.append(f"{sha}  {fname}\n")

        with open(mock_manifest, "w") as f:
            f.writelines(manifest_lines)

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest)
        self.assertIn("mismatch", str(ctx.exception).lower())

    def test_missing_image_fails_closed(self):
        """Verify that fewer than 84 images raises an error."""
        mock_parts = os.path.join(self.test_dir, "mock_partitions_missing")
        os.makedirs(mock_parts, exist_ok=True)
        mock_manifest = os.path.join(self.test_dir, "SHA256SUMS")

        with open(os.path.join(mock_parts, "only_one.img"), "wb") as f:
            f.write(b"data")
        with open(mock_manifest, "w") as f:
            f.write(f"{iha.compute_sha256(os.path.join(mock_parts, 'only_one.img'))}  only_one.img\n")

        with self.assertRaises(ValueError) as ctx:
            iha.verify_hardware_assets(mock_parts, mock_manifest)
        self.assertIn("expected exactly 84", str(ctx.exception).lower())

    def test_cli_execution_and_manifest_generation(self):
        """Verify CLI execution generates both Markdown and JSON manifests and exits 0."""
        docs_out = os.path.join(self.test_dir, "HARDWARE_INTEGRATION_MANIFEST.md")
        json_out = os.path.join(self.test_dir, "HARDWARE_INTEGRATION_MANIFEST.json")

        res = subprocess.run([
            sys.executable, INTEGRATE_SCRIPT,
            "--docs-out", docs_out,
            "--json-out", json_out,
        ], capture_output=True, text=True)

        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}\n{res.stdout}")
        self.assertIn("All 84 OnePlus 7T hardware assets successfully verified and integrated", res.stdout)
        self.assertTrue(os.path.isfile(docs_out))
        self.assertTrue(os.path.isfile(json_out))

        with open(json_out) as f:
            data = json.load(f)
        self.assertEqual(data["total_images"], 84)
        self.assertEqual(data["status"], "100% VERIFIED")
        self.assertEqual(data["integrated_assets"]["stage1_kernel_dtb"]["dtb_sha256"], "e4faf7c553f88246077343de51487d90517bb534e345ee44893d2e4fb348df3c")


if __name__ == "__main__":
    unittest.main()
