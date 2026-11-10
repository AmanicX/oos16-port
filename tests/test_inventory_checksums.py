#!/usr/bin/env python3
"""
tests/test_inventory_checksums.py
Comprehensive test suite for tools/inventory_target_partitions.py.

Verifies:
1. Valid checksum calculation and 100% verification status.
2. Corrupted image detection (tampered bytes cause CHECKSUM_MISMATCH).
3. Missing manifest entry detection (image on disk but absent in SHA256SUMS).
4. Incorrect checksum detection.
5. Duplicate manifest entry detection.
6. Unexpected manifest entry detection (entry in SHA256SUMS but absent on disk).
7. Proper exit code and Markdown documentation reporting of provenance tiers.
"""

import os
import sys
import unittest
import tempfile
import shutil
import hashlib
import subprocess

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
INVENTORY_SCRIPT = os.path.join(PROJECT_ROOT, "tools", "inventory_target_partitions.py")

sys.path.insert(0, os.path.join(PROJECT_ROOT, "tools"))
import inventory_target_partitions as itp

class TestInventoryChecksums(unittest.TestCase):
    """Test suite for target partition cryptographic inventory tool."""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="test_inventory_")
        self.part_dir = os.path.join(self.test_dir, "partitions")
        self.manifest_path = os.path.join(self.part_dir, "SHA256SUMS")
        self.docs_out = os.path.join(self.test_dir, "inventory.md")
        os.makedirs(self.part_dir, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _create_mock_image(self, name, content=b"MOCK_IMAGE_CONTENT_DEFAULT"):
        p = os.path.join(self.part_dir, name)
        with open(p, "wb") as f:
            f.write(content)
        sha = hashlib.sha256(content).hexdigest()
        return p, sha

    def _write_manifest(self, entries):
        with open(self.manifest_path, "w", encoding="utf-8") as f:
            for sha, name in entries:
                f.write(f"{sha}  {name}\n")

    def test_valid_checksum_verification(self):
        """Verify that matching images and manifest pass with 100% verification status."""
        p1, sha1 = self._create_mock_image("boot_a.img", b"BOOT_DATA_12345")
        p2, sha2 = self._create_mock_image("dtbo_a.img", b"DTBO_DATA_67890")
        self._write_manifest([(sha1, "boot_a.img"), (sha2, "dtbo_a.img")])

        res = itp.verify_and_inventory(
            partitions_dir=self.part_dir,
            manifest_file=self.manifest_path,
            docs_out=self.docs_out,
        )

        self.assertEqual(res["status"], "VERIFIED_100_PERCENT")
        self.assertEqual(res["verified_count"], 2)
        self.assertEqual(res["mismatch_count"], 0)
        self.assertEqual(res["missing_count"], 0)
        self.assertEqual(res["duplicate_count"], 0)
        self.assertEqual(res["unexpected_count"], 0)
        self.assertTrue(os.path.isfile(self.docs_out))

    def test_corrupted_image_detected(self):
        """Verify that tampered bytes in an image cause CHECKSUM_MISMATCH and failure."""
        p1, sha1 = self._create_mock_image("modem_a.img", b"AUTHENTIC_MODEM_DATA")
        self._write_manifest([(sha1, "modem_a.img")])

        # Tamper with image after manifest generation
        with open(p1, "wb") as f:
            f.write(b"CORRUPTED_TAMPERED_MODEM_DATA")

        res = itp.verify_and_inventory(
            partitions_dir=self.part_dir,
            manifest_file=self.manifest_path,
            docs_out=self.docs_out,
        )

        self.assertEqual(res["status"], "VERIFICATION_FAILED")
        self.assertEqual(res["mismatch_count"], 1)
        self.assertEqual(res["verified_count"], 0)
        self.assertEqual(res["inventory"][0]["verification_status"], "CHECKSUM_MISMATCH")

    def test_missing_manifest_entry_detected(self):
        """Verify that an image on disk missing from SHA256SUMS is detected and fails verification."""
        p1, sha1 = self._create_mock_image("boot_a.img", b"BOOT_DATA")
        p2, sha2 = self._create_mock_image("unlisted.img", b"UNLISTED_DATA")
        # Only list boot_a.img in manifest
        self._write_manifest([(sha1, "boot_a.img")])

        res = itp.verify_and_inventory(
            partitions_dir=self.part_dir,
            manifest_file=self.manifest_path,
            docs_out=self.docs_out,
        )

        self.assertEqual(res["status"], "VERIFICATION_FAILED")
        self.assertEqual(res["missing_count"], 1)
        unlisted_item = next(i for i in res["inventory"] if i["filename"] == "unlisted.img")
        self.assertEqual(unlisted_item["verification_status"], "MISSING_MANIFEST_ENTRY")

    def test_incorrect_checksum_detected(self):
        """Verify that a manifest containing the wrong hash is caught."""
        p1, sha1 = self._create_mock_image("dsp_a.img", b"DSP_DATA")
        fake_sha = "0" * 64
        self._write_manifest([(fake_sha, "dsp_a.img")])

        res = itp.verify_and_inventory(
            partitions_dir=self.part_dir,
            manifest_file=self.manifest_path,
            docs_out=self.docs_out,
        )

        self.assertEqual(res["status"], "VERIFICATION_FAILED")
        self.assertEqual(res["mismatch_count"], 1)
        self.assertEqual(res["inventory"][0]["expected_sha256"], fake_sha)
        self.assertEqual(res["inventory"][0]["actual_sha256"], sha1)

    def test_duplicate_manifest_entry_detected(self):
        """Verify that duplicate lines in SHA256SUMS are detected and reported."""
        p1, sha1 = self._create_mock_image("abl_a.img", b"ABL_DATA")
        # Write duplicate entry
        with open(self.manifest_path, "w", encoding="utf-8") as f:
            f.write(f"{sha1}  abl_a.img\n")
            f.write(f"{sha1}  abl_a.img\n")

        res = itp.verify_and_inventory(
            partitions_dir=self.part_dir,
            manifest_file=self.manifest_path,
            docs_out=self.docs_out,
        )

        self.assertEqual(res["duplicate_count"], 1)
        self.assertEqual(res["status"], "VERIFICATION_FAILED")
        self.assertEqual(res["duplicates"][0]["filename"], "abl_a.img")

    def test_unexpected_manifest_entry_detected(self):
        """Verify that entries in SHA256SUMS for files absent from disk are detected."""
        p1, sha1 = self._create_mock_image("xbl_a.img", b"XBL_DATA")
        ghost_sha = "a" * 64
        self._write_manifest([
            (sha1, "xbl_a.img"),
            (ghost_sha, "ghost_partition.img"),
        ])

        res = itp.verify_and_inventory(
            partitions_dir=self.part_dir,
            manifest_file=self.manifest_path,
            docs_out=self.docs_out,
        )

        self.assertEqual(res["unexpected_count"], 1)
        self.assertIn("ghost_partition.img", res["unexpected"])
        self.assertEqual(res["status"], "VERIFICATION_FAILED")

    def test_cli_execution_success_and_failure(self):
        """Verify CLI exits 0 on valid verification and 1 on failure."""
        p1, sha1 = self._create_mock_image("boot_a.img", b"BOOT_OK")
        self._write_manifest([(sha1, "boot_a.img")])

        # Success case
        res_ok = subprocess.run([
            sys.executable, INVENTORY_SCRIPT,
            "--partitions-dir", self.part_dir,
            "--manifest", self.manifest_path,
            "--docs-out", self.docs_out,
        ], capture_output=True, text=True)
        self.assertEqual(res_ok.returncode, 0)
        self.assertIn("100% verified", res_ok.stdout)

        # Failure case (tamper image)
        with open(p1, "wb") as f: f.write(b"TAMPERED")
        res_fail = subprocess.run([
            sys.executable, INVENTORY_SCRIPT,
            "--partitions-dir", self.part_dir,
            "--manifest", self.manifest_path,
            "--docs-out", self.docs_out,
        ], capture_output=True, text=True)
        self.assertEqual(res_fail.returncode, 1)
        self.assertIn("Verification failed", res_fail.stderr + res_fail.stdout)

if __name__ == "__main__":
    unittest.main()
