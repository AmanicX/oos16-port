#!/usr/bin/env python3
"""
tests/test_donor_target_resolver.py
Unit tests for tools/resolve_partition_sources.py.

Verifies:
1. Authoritative resolution of donor and target partition trees and images.
2. Immediate fail-closed rejection on missing mandatory donor or target partitions.
3. Strict rejection of cross-device contamination (donor OnePlus 9 / SM8350 vendor or ODM).
4. Strict validation of Android release 16 and SDK 36 (both required; neither can compensate for the other).
5. Strict target vendor and ODM device identity checks, rejecting unrelated SM8150 devices and contradictory properties.
6. Rejection of ODM trees lacking build.prop or identity properties (zero silent default fallbacks).
7. Comprehensive symlink handling across all variants (relative, absolute, dir, file, broken, dangling, chains, outside).
8. Detection of modified or removed symlinks and files in the cryptographic immutability checker.
9. Immutability verification on failure paths.
10. Explicit rejection of 7-Zip for ext4 extraction due to loss of Android filesystem metadata.
"""

import os
import sys
import unittest
import tempfile
import shutil
import subprocess
import json

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RESOLVER_SCRIPT = os.path.join(PROJECT_ROOT, "tools", "resolve_partition_sources.py")

# Import functions directly for targeted unit testing
sys.path.insert(0, os.path.join(PROJECT_ROOT, "tools"))
import resolve_partition_sources as rps

class TestDonorTargetResolver(unittest.TestCase):
    """Test suite for partition-source resolver logic, role enforcement, and asset immutability."""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="test_resolver_")
        self.donor_dir = os.path.join(self.test_dir, "donor")
        self.target_dir = os.path.join(self.test_dir, "target")
        self.staging_dir = os.path.join(self.test_dir, "staging")
        os.makedirs(self.donor_dir, exist_ok=True)
        os.makedirs(self.target_dir, exist_ok=True)
        os.makedirs(self.staging_dir, exist_ok=True)

        self._setup_mock_donor(self.donor_dir)
        self._setup_mock_target(self.target_dir)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _setup_mock_donor(self, base_dir):
        # system
        sys_dir = os.path.join(base_dir, "system", "system")
        os.makedirs(os.path.join(sys_dir, "apex"), exist_ok=True)
        with open(os.path.join(sys_dir, "build.prop"), "w") as f:
            f.write("ro.build.version.release=16\nro.build.version.sdk=36\nro.product.system.brand=oplus\nro.product.system.device=ossi\n")
        with open(os.path.join(sys_dir, "apex", "com.android.runtime.apex"), "wb") as f:
            f.write(b"MOCK_RUNTIME_APEX_DATA")

        # system_ext
        sys_ext_dir = os.path.join(base_dir, "system_ext", "etc")
        os.makedirs(sys_ext_dir, exist_ok=True)
        with open(os.path.join(sys_ext_dir, "build.prop"), "w") as f:
            f.write("ro.build.version.release=16\nro.build.version.sdk=36\nro.product.system_ext.brand=oplus\n")

        # my_product
        my_prod_dir = os.path.join(base_dir, "my_product")
        os.makedirs(my_prod_dir, exist_ok=True)
        with open(os.path.join(my_prod_dir, "build.prop"), "w") as f:
            f.write("ro.product.device=OnePlus9\n")

    def _setup_mock_target(self, base_dir):
        # vendor
        ven_dir = os.path.join(base_dir, "vendor", "vendor")
        os.makedirs(ven_dir, exist_ok=True)
        with open(os.path.join(ven_dir, "build.prop"), "w") as f:
            f.write(
                "ro.product.vendor.brand=OnePlus\n"
                "ro.product.vendor.device=OnePlus7T\n"
                "ro.product.vendor.model=HD1901\n"
                "ro.board.platform=msmnile\n"
                "ro.vendor.build.version.sdk=36\n"
                "ro.vendor.build.version.release=16\n"
                "ro.vendor.build.fingerprint=OnePlus/OnePlus7T/OnePlus7T:16/BP4A:user/release-keys\n"
            )

        # odm
        odm_dir = os.path.join(base_dir, "odm", "odm", "etc")
        os.makedirs(odm_dir, exist_ok=True)
        with open(os.path.join(odm_dir, "build.prop"), "w") as f:
            f.write(
                "ro.product.odm.brand=OnePlus\n"
                "ro.product.odm.device=OnePlus7T\n"
                "ro.product.odm.model=HD1901\n"
                "ro.odm.build.version.sdk=36\n"
                "ro.odm.build.version.release=16\n"
                "ro.soc.model=SM8150\n"
            )

    def test_valid_resolution_and_staging(self):
        """Verify successful resolution and independent staging from valid donor and target dirs."""
        json_manifest = os.path.join(self.test_dir, "build_manifest.json")
        prov_manifest = os.path.join(self.test_dir, "provenance.txt")

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", self.staging_dir,
            "--json-manifest", json_manifest,
            "--provenance-manifest", prov_manifest,
        ], capture_output=True, text=True)

        self.assertEqual(res.returncode, 0, f"Resolver failed: {res.stderr}\n{res.stdout}")
        self.assertIn("Partition staging and source verification completed successfully", res.stdout)
        self.assertIn("100% cryptographic source asset immutability verified", res.stdout)

        # Verify staged contents
        self.assertTrue(os.path.isfile(os.path.join(self.staging_dir, "system", "system", "build.prop")))
        self.assertTrue(os.path.isfile(os.path.join(self.staging_dir, "vendor", "vendor", "build.prop")))
        self.assertTrue(os.path.isfile(json_manifest))
        self.assertTrue(os.path.isfile(prov_manifest))

        with open(json_manifest) as f:
            manifest = json.load(f)
        self.assertEqual(manifest["partitions"]["system"]["role"], "DONOR")
        self.assertEqual(manifest["partitions"]["vendor"]["role"], "TARGET")
        self.assertEqual(manifest["partitions"]["vendor"]["metadata"]["platform"], "msmnile")

    def test_missing_mandatory_donor_partition_fails_closed(self):
        """Verify resolver fails closed if mandatory donor partition (e.g. system) is missing."""
        shutil.rmtree(os.path.join(self.donor_dir, "system"))

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", self.staging_dir,
            "--verify-only",
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to resolve mandatory partition sources", res.stderr + res.stdout)
        self.assertIn("system (role: DONOR)", res.stderr + res.stdout)

    def test_missing_mandatory_target_partition_fails_closed(self):
        """Verify resolver fails closed if mandatory target partition (e.g. vendor) is missing."""
        shutil.rmtree(os.path.join(self.target_dir, "vendor"))

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", self.staging_dir,
            "--verify-only",
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Failed to resolve mandatory partition sources", res.stderr + res.stdout)
        self.assertIn("vendor (role: TARGET)", res.stderr + res.stdout)

    def test_rejection_of_donor_vendor_contamination(self):
        """Verify that assigning a OnePlus 9 / SM8350 donor vendor partition as target is rejected."""
        ven_prop = os.path.join(self.target_dir, "vendor", "vendor", "build.prop")
        with open(ven_prop, "w") as f:
            f.write(
                "ro.product.vendor.device=OnePlus9\n"
                "ro.board.platform=lahaina\n"
                "ro.vendor.build.version.sdk=36\n"
                "ro.vendor.build.version.release=16\n"
            )

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", self.staging_dir,
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Donor vendor partition (OnePlus 9 / SM8350) mistakenly assigned as target vendor", res.stderr + res.stdout)

    def test_rejection_of_wrong_android_versions(self):
        """Verify that system partition requires BOTH SDK 36 and release 16 (neither can compensate for the other)."""
        sys_prop = os.path.join(self.donor_dir, "system", "system", "build.prop")

        # Case 1: SDK 36 but release 15 (should fail)
        with open(sys_prop, "w") as f:
            f.write("ro.build.version.release=15\nro.build.version.sdk=36\n")
        with self.assertRaises(ValueError):
            rps.validate_system_donor(os.path.join(self.donor_dir, "system"))

        # Case 2: SDK 35 but release 16 (should fail)
        with open(sys_prop, "w") as f:
            f.write("ro.build.version.release=16\nro.build.version.sdk=35\n")
        with self.assertRaises(ValueError):
            rps.validate_system_donor(os.path.join(self.donor_dir, "system"))

        # Case 3: Both correct
        with open(sys_prop, "w") as f:
            f.write("ro.build.version.release=16\nro.build.version.sdk=36\n")
        meta = rps.validate_system_donor(os.path.join(self.donor_dir, "system"))
        self.assertEqual(meta["release"], "16")
        self.assertEqual(meta["sdk"], "36")

    def test_rejection_of_missing_vendor_identity(self):
        """Verify vendor partition missing device identity properties is rejected."""
        ven_dir = os.path.join(self.target_dir, "vendor", "vendor")
        with open(os.path.join(ven_dir, "build.prop"), "w") as f:
            f.write("ro.board.platform=msmnile\nro.vendor.build.version.sdk=36\nro.vendor.build.version.release=16\n")

        with self.assertRaises(ValueError) as ctx:
            rps.validate_vendor_target(os.path.join(self.target_dir, "vendor"))
        self.assertIn("missing required device property", str(ctx.exception).lower())

    def test_rejection_of_unrelated_sm8150_device(self):
        """Verify unrelated SM8150 devices (e.g. Pixel 4 / coral, Galaxy S10) are rejected."""
        ven_dir = os.path.join(self.target_dir, "vendor", "vendor")
        with open(os.path.join(ven_dir, "build.prop"), "w") as f:
            f.write(
                "ro.board.platform=msmnile\n"
                "ro.vendor.build.version.sdk=36\n"
                "ro.vendor.build.version.release=16\n"
                "ro.product.vendor.brand=Google\n"
                "ro.product.vendor.device=coral\n"
                "ro.product.vendor.model=Pixel 4 XL\n"
                "ro.vendor.build.fingerprint=google/coral/coral:12/SP1A:user/release-keys\n"
            )

        with self.assertRaises(ValueError) as ctx:
            rps.validate_vendor_target(os.path.join(self.target_dir, "vendor"))
        self.assertIn("not oneplus", str(ctx.exception).lower())

    def test_rejection_of_contradictory_vendor_identity(self):
        """Verify vendor partition with contradictory device identity properties is rejected."""
        ven_dir = os.path.join(self.target_dir, "vendor", "vendor")
        with open(os.path.join(ven_dir, "build.prop"), "w") as f:
            f.write(
                "ro.board.platform=msmnile\n"
                "ro.vendor.build.version.sdk=36\n"
                "ro.vendor.build.version.release=16\n"
                "ro.product.vendor.brand=OnePlus\n"
                "ro.product.vendor.device=OnePlus7T\n"
                "ro.product.vendor.model=HD1901\n"
                "ro.vendor.build.fingerprint=google/coral/coral:12:user/release-keys\n"
            )

        with self.assertRaises(ValueError) as ctx:
            rps.validate_vendor_target(os.path.join(self.target_dir, "vendor"))
        self.assertIn("contradictory", str(ctx.exception).lower())

    def test_rejection_of_missing_odm_build_prop(self):
        """Verify ODM partition missing build.prop is strictly rejected without silent fallback."""
        odm_prop = os.path.join(self.target_dir, "odm", "odm", "etc", "build.prop")
        os.remove(odm_prop)

        with self.assertRaises(ValueError) as ctx:
            rps.validate_odm_target(os.path.join(self.target_dir, "odm"))
        self.assertIn("missing build.prop", str(ctx.exception).lower())

    def test_rejection_of_missing_odm_identity_properties(self):
        """Verify ODM partition with empty build.prop or missing identity is rejected."""
        odm_prop = os.path.join(self.target_dir, "odm", "odm", "etc", "build.prop")
        with open(odm_prop, "w") as f:
            f.write("ro.odm.build.version.sdk=36\nro.odm.build.version.release=16\n")

        with self.assertRaises(ValueError) as ctx:
            rps.validate_odm_target(os.path.join(self.target_dir, "odm"))
        self.assertIn("missing required device identity", str(ctx.exception).lower())

    def test_rejection_of_contradictory_odm_identity(self):
        """Verify ODM partition with contradictory device/model is rejected."""
        odm_prop = os.path.join(self.target_dir, "odm", "odm", "etc", "build.prop")
        with open(odm_prop, "w") as f:
            f.write(
                "ro.odm.build.version.sdk=36\n"
                "ro.odm.build.version.release=16\n"
                "ro.product.odm.brand=OnePlus\n"
                "ro.product.odm.device=OnePlus7T\n"
                "ro.product.odm.model=SM-G975F\n"
            )

        with self.assertRaises(ValueError) as ctx:
            rps.validate_odm_target(os.path.join(self.target_dir, "odm"))
        self.assertIn("contradictory", str(ctx.exception).lower())

    def test_rejection_of_donor_odm_contamination(self):
        """Verify donor ODM properties (OnePlus 9 / lemonade) are rejected."""
        odm_prop = os.path.join(self.target_dir, "odm", "odm", "etc", "build.prop")
        with open(odm_prop, "w") as f:
            f.write(
                "ro.odm.build.version.sdk=36\n"
                "ro.odm.build.version.release=16\n"
                "ro.product.odm.brand=OnePlus\n"
                "ro.product.odm.device=OnePlus9\n"
                "ro.product.odm.model=LE2113\n"
            )

        with self.assertRaises(ValueError) as ctx:
            rps.validate_odm_target(os.path.join(self.target_dir, "odm"))
        self.assertIn("donor device contamination", str(ctx.exception).lower())

    def test_comprehensive_symlink_handling(self):
        """
        Verify staging properly handles all 8 symlink variants without dereferencing:
        1. Relative symlink
        2. Absolute symlink
        3. Symlink to directory
        4. Symlink to file
        5. Broken symlink (target does not exist)
        6. Dangling symlink (target removed)
        7. Symlink chain (link -> link -> target)
        8. Symlink target outside the source directory
        """
        symlink_test_dir = os.path.join(self.test_dir, "symlink_source")
        staging_dest = os.path.join(self.test_dir, "symlink_staged")
        os.makedirs(symlink_test_dir, exist_ok=True)

        # Base target file and dir
        real_file = os.path.join(symlink_test_dir, "real_file.txt")
        with open(real_file, "w") as f: f.write("HELLO_FILE\n")
        real_dir = os.path.join(symlink_test_dir, "real_dir")
        os.makedirs(real_dir, exist_ok=True)
        with open(os.path.join(real_dir, "inner.txt"), "w") as f: f.write("INNER\n")

        # 1. Relative symlink to file
        os.symlink("real_file.txt", os.path.join(symlink_test_dir, "rel_file_link"))
        # 2. Absolute symlink
        os.symlink("/system/bin/app_process64", os.path.join(symlink_test_dir, "abs_link"))
        # 3. Symlink to directory
        os.symlink("real_dir", os.path.join(symlink_test_dir, "dir_link"))
        # 4. Symlink to file
        os.symlink("real_file.txt", os.path.join(symlink_test_dir, "file_link"))
        # 5. Broken symlink
        os.symlink("/non/existent/target/path", os.path.join(symlink_test_dir, "broken_link"))
        # 6. Dangling symlink
        temp_dangle = os.path.join(symlink_test_dir, "dangle_src.txt")
        with open(temp_dangle, "w") as f: f.write("TMP")
        os.symlink("dangle_src.txt", os.path.join(symlink_test_dir, "dangling_link"))
        os.remove(temp_dangle)
        # 7. Symlink chain: chain1 -> chain2 -> real_file.txt
        os.symlink("real_file.txt", os.path.join(symlink_test_dir, "chain2"))
        os.symlink("chain2", os.path.join(symlink_test_dir, "chain1"))
        # 8. Symlink target outside directory
        os.symlink("../../outside_target.txt", os.path.join(symlink_test_dir, "outside_link"))

        # Snapshot before staging
        snap_before = rps.snapshot_dir_state(symlink_test_dir)

        # Stage via stage_partition
        rps.stage_partition({"type": "directory", "path": symlink_test_dir}, staging_dest)

        # Verify staged symlinks
        expected_links = {
            "rel_file_link": "real_file.txt",
            "abs_link": "/system/bin/app_process64",
            "dir_link": "real_dir",
            "file_link": "real_file.txt",
            "broken_link": "/non/existent/target/path",
            "dangling_link": "dangle_src.txt",
            "chain1": "chain2",
            "chain2": "real_file.txt",
            "outside_link": "../../outside_target.txt",
        }

        for link_name, expected_target in expected_links.items():
            staged_path = os.path.join(staging_dest, link_name)
            self.assertTrue(os.path.islink(staged_path), f"Staged {link_name} is not a symlink! Accidental dereferencing occurred.")
            actual_target = os.readlink(staged_path)
            self.assertEqual(actual_target, expected_target, f"Staged {link_name} target '{actual_target}' != '{expected_target}'")

        # Verify source files were not modified
        rps.verify_immutability(snap_before, symlink_test_dir, "symlink_source")

    def test_immutability_checker_detects_symlink_tampering(self):
        """Verify the cryptographic immutability checker detects modified or removed symlinks."""
        test_dir = os.path.join(self.test_dir, "immut_symlink_test")
        os.makedirs(test_dir, exist_ok=True)
        link_path = os.path.join(test_dir, "test_link")
        os.symlink("original_target", link_path)

        snap = rps.snapshot_dir_state(test_dir)

        # Case 1: Target changed
        os.remove(link_path)
        os.symlink("altered_target", link_path)
        with self.assertRaises(RuntimeError) as ctx:
            rps.verify_immutability(snap, test_dir, "test_dir")
        self.assertIn("symlink target", str(ctx.exception))

        # Case 2: Symlink removed
        os.remove(link_path)
        with self.assertRaises(RuntimeError) as ctx:
            rps.verify_immutability(snap, test_dir, "test_dir")
        self.assertIn("Removed entries", str(ctx.exception))

    def test_rejection_of_7z_for_ext4_image_extraction(self):
        """Verify that extracting an ext4 image via 7-Zip is explicitly rejected due to metadata loss."""
        # Create mock ext4 image header with 0x53 0xef at offset 1080
        img_path = os.path.join(self.test_dir, "test_vendor.img")
        with open(img_path, "wb") as f:
            f.write(b"\x00" * 1080)
            f.write(b"\x53\xef")
            f.write(b"\x00" * 1024)

        with self.assertRaises(RuntimeError) as ctx:
            rps.extract_image_to_dir(img_path, os.path.join(self.test_dir, "ext4_out"))
        self.assertIn("rejected", str(ctx.exception).lower())
        self.assertIn("7-zip cannot preserve required android filesystem metadata", str(ctx.exception).lower())

    def test_immutability_verified_even_on_staging_failure(self):
        """Verify that source asset immutability is verified even if staging fails midway."""
        # Corrupt vendor so validation fails after staging begins
        ven_prop = os.path.join(self.target_dir, "vendor", "vendor", "build.prop")
        with open(ven_prop, "w") as f:
            f.write("ro.board.platform=lahaina\n")  # triggers failure

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", self.staging_dir,
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Verifying source asset immutability after staging", res.stdout)
        self.assertIn("100% cryptographic source asset immutability verified", res.stdout)

    def test_image_source_validation_erofs_verify_only(self):
        """Verify that an EROFS image-based vendor source is extracted and validated in --verify-only mode."""
        mkfs = shutil.which("mkfs.erofs") or os.path.join(PROJECT_ROOT, "external/coloros_port/otatools/bin/mkfs.erofs")
        if not mkfs or not os.path.isfile(mkfs):
            self.skipTest("mkfs.erofs not available for creating test EROFS image")

        # Create temporary directory tree for vendor image
        ven_tree = os.path.join(self.test_dir, "raw_vendor_tree", "vendor")
        os.makedirs(ven_tree, exist_ok=True)
        with open(os.path.join(ven_tree, "build.prop"), "w") as f:
            f.write(
                "ro.product.vendor.brand=OnePlus\n"
                "ro.product.vendor.device=OnePlus7T\n"
                "ro.product.vendor.model=HD1901\n"
                "ro.board.platform=msmnile\n"
                "ro.vendor.build.version.sdk=36\n"
                "ro.vendor.build.version.release=16\n"
            )

        ven_img = os.path.join(self.target_dir, "vendor.erofs.img")
        res_mkfs = subprocess.run([mkfs, ven_img, os.path.join(self.test_dir, "raw_vendor_tree")], capture_output=True, text=True)
        self.assertEqual(res_mkfs.returncode, 0, f"mkfs.erofs failed: {res_mkfs.stderr}")

        # Remove the directory vendor so resolver picks up vendor.erofs.img
        shutil.rmtree(os.path.join(self.target_dir, "vendor"))

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--verify-only",
        ], capture_output=True, text=True)

        self.assertEqual(res.returncode, 0, f"Resolver failed on EROFS image: {res.stderr}\n{res.stdout}")
        self.assertIn("Extracting and validating image source for vendor", res.stdout)
        self.assertIn("Vendor Target (Image): Device=OnePlus7T", res.stdout)
        self.assertIn("All mandatory donor and target partition sources successfully verified", res.stdout)

    def test_image_source_validation_corrupt_rejected(self):
        """Verify that a corrupted image source fails extraction and fails closed in --verify-only."""
        shutil.rmtree(os.path.join(self.target_dir, "vendor"))
        ven_img = os.path.join(self.target_dir, "vendor.img")
        with open(ven_img, "wb") as f:
            f.write(b"\xe2\xe1\xf5\xe0" + b"\xff" * 2048)  # Corrupted EROFS

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--verify-only",
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertTrue("failed" in (res.stderr + res.stdout).lower())

    def test_image_source_validation_ext4_rejected(self):
        """Verify that an ext4 image source is strictly rejected due to Android metadata preservation policy."""
        shutil.rmtree(os.path.join(self.target_dir, "vendor"))
        ven_img = os.path.join(self.target_dir, "vendor.img")
        with open(ven_img, "wb") as f:
            f.write(b"\x00" * 1080 + b"\x53\xef" + b"\x00" * 1024)

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--verify-only",
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertIn("rejected", (res.stderr + res.stdout).lower())

    def test_image_source_validation_wrong_device_rejected(self):
        """Verify that an extracted image source with wrong device identity fails validation."""
        mkfs = shutil.which("mkfs.erofs") or os.path.join(PROJECT_ROOT, "external/coloros_port/otatools/bin/mkfs.erofs")
        if not mkfs or not os.path.isfile(mkfs):
            self.skipTest("mkfs.erofs not available for creating test EROFS image")

        ven_tree = os.path.join(self.test_dir, "wrong_vendor_tree", "vendor")
        os.makedirs(ven_tree, exist_ok=True)
        with open(os.path.join(ven_tree, "build.prop"), "w") as f:
            f.write(
                "ro.product.vendor.brand=OnePlus\n"
                "ro.product.vendor.device=OnePlus9\n"
                "ro.product.vendor.model=LE2113\n"
                "ro.board.platform=lahaina\n"
                "ro.vendor.build.version.sdk=36\n"
                "ro.vendor.build.version.release=16\n"
            )

        ven_img = os.path.join(self.target_dir, "vendor.erofs.img")
        subprocess.run([mkfs, ven_img, os.path.join(self.test_dir, "wrong_vendor_tree")], check=True, capture_output=True)
        shutil.rmtree(os.path.join(self.target_dir, "vendor"))

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--verify-only",
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertTrue("contamination" in (res.stderr + res.stdout).lower() or "lahaina" in (res.stderr + res.stdout).lower())

    def test_image_source_validation_missing_metadata_rejected(self):
        """Verify that an extracted image missing build.prop fails validation."""
        mkfs = shutil.which("mkfs.erofs") or os.path.join(PROJECT_ROOT, "external/coloros_port/otatools/bin/mkfs.erofs")
        if not mkfs or not os.path.isfile(mkfs):
            self.skipTest("mkfs.erofs not available for creating test EROFS image")

        empty_tree = os.path.join(self.test_dir, "empty_vendor_tree")
        os.makedirs(os.path.join(empty_tree, "dummy_dir"), exist_ok=True)
        ven_img = os.path.join(self.target_dir, "vendor.erofs.img")
        subprocess.run([mkfs, ven_img, empty_tree], check=True, capture_output=True)
        shutil.rmtree(os.path.join(self.target_dir, "vendor"))

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--verify-only",
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertIn("missing build.prop", (res.stderr + res.stdout).lower())

    def test_vendor_missing_version_properties_rejected(self):
        """Verify vendor partition missing SDK or release version properties is rejected (no defaults)."""
        prop_path = os.path.join(self.target_dir, "vendor", "vendor", "build.prop")
        with open(prop_path, "w") as f:
            f.write(
                "ro.product.vendor.brand=OnePlus\n"
                "ro.product.vendor.device=OnePlus7T\n"
                "ro.product.vendor.model=HD1901\n"
                "ro.board.platform=msmnile\n"
            )

        with self.assertRaises(ValueError) as ctx:
            rps.validate_vendor_target(os.path.join(self.target_dir, "vendor"))
        self.assertIn("missing required android version properties", str(ctx.exception).lower())

    def test_vendor_rejects_oneplus7t_pro(self):
        """Verify vendor partition specifically for OnePlus 7T Pro (hotdog/HD1910) is rejected."""
        prop_path = os.path.join(self.target_dir, "vendor", "vendor", "build.prop")
        with open(prop_path, "w") as f:
            f.write(
                "ro.product.vendor.brand=OnePlus\n"
                "ro.product.vendor.device=hotdog\n"
                "ro.product.vendor.model=HD1910\n"
                "ro.board.platform=msmnile\n"
                "ro.vendor.build.version.sdk=36\n"
                "ro.vendor.build.version.release=16\n"
            )

        with self.assertRaises(ValueError) as ctx:
            rps.validate_vendor_target(os.path.join(self.target_dir, "vendor"))
        self.assertIn("oneplus 7t pro", str(ctx.exception).lower())

    def test_odm_missing_version_properties_rejected(self):
        """Verify ODM partition missing SDK or release version properties is rejected."""
        prop_path = os.path.join(self.target_dir, "odm", "odm", "etc", "build.prop")
        with open(prop_path, "w") as f:
            f.write(
                "ro.product.odm.brand=OnePlus\n"
                "ro.product.odm.device=OnePlus7T\n"
                "ro.product.odm.model=HD1901\n"
            )

        with self.assertRaises(ValueError) as ctx:
            rps.validate_odm_target(os.path.join(self.target_dir, "odm"))
        self.assertIn("missing required version properties", str(ctx.exception).lower())

    def test_odm_rejects_oneplus7t_pro(self):
        """Verify ODM partition specifically for OnePlus 7T Pro (hotdog/HD1913) is rejected."""
        prop_path = os.path.join(self.target_dir, "odm", "odm", "etc", "build.prop")
        with open(prop_path, "w") as f:
            f.write(
                "ro.product.odm.brand=OnePlus\n"
                "ro.product.odm.device=hotdog\n"
                "ro.product.odm.model=HD1913\n"
                "ro.odm.build.version.sdk=36\n"
                "ro.odm.build.version.release=16\n"
            )

        with self.assertRaises(ValueError) as ctx:
            rps.validate_odm_target(os.path.join(self.target_dir, "odm"))
        self.assertIn("oneplus 7t pro", str(ctx.exception).lower())

    def test_regional_variants_accepted(self):
        """Verify that genuine OnePlus 7T regional models (HD1900, HD1903, HD1905, HD1907) are accepted."""
        for model in ["HD1900", "HD1903", "HD1905", "HD1907"]:
            ven_prop = os.path.join(self.target_dir, "vendor", "vendor", "build.prop")
            with open(ven_prop, "w") as f:
                f.write(
                    f"ro.product.vendor.brand=OnePlus\n"
                    f"ro.product.vendor.device=hotdogb\n"
                    f"ro.product.vendor.model={model}\n"
                    f"ro.board.platform=msmnile\n"
                    f"ro.vendor.build.version.sdk=36\n"
                    f"ro.vendor.build.version.release=16\n"
                )
            meta_ven = rps.validate_vendor_target(os.path.join(self.target_dir, "vendor"))
            self.assertEqual(meta_ven["model"], model)

            odm_prop = os.path.join(self.target_dir, "odm", "odm", "etc", "build.prop")
            with open(odm_prop, "w") as f:
                f.write(
                    f"ro.product.odm.brand=OnePlus\n"
                    f"ro.product.odm.device=hotdogb\n"
                    f"ro.product.odm.model={model}\n"
                    f"ro.odm.build.version.sdk=36\n"
                    f"ro.odm.build.version.release=16\n"
                )
            meta_odm = rps.validate_odm_target(os.path.join(self.target_dir, "odm"))
            self.assertEqual(meta_odm["model"], model)

    def test_immutability_detects_permission_change(self):
        """Verify that changing file permissions is detected as an immutability violation."""
        snap_dir = os.path.join(self.test_dir, "snap_test_perm")
        os.makedirs(snap_dir, exist_ok=True)
        target_f = os.path.join(snap_dir, "test.txt")
        with open(target_f, "w") as f:
            f.write("content")
        os.chmod(target_f, 0o644)

        snap = rps.snapshot_dir_state(snap_dir)
        os.chmod(target_f, 0o755)

        with self.assertRaises(RuntimeError) as ctx:
            rps.verify_immutability(snap, snap_dir, "snap_test_perm")
        self.assertIn("mode:", str(ctx.exception))

    def test_immutability_detects_root_directory_change(self):
        """Verify that changing the root directory itself is detected as an immutability violation."""
        snap_dir = os.path.join(self.test_dir, "snap_test_root")
        os.makedirs(snap_dir, exist_ok=True)
        os.chmod(snap_dir, 0o755)

        snap = rps.snapshot_dir_state(snap_dir)
        self.assertIn(".", snap)
        os.chmod(snap_dir, 0o700)

        with self.assertRaises(RuntimeError) as ctx:
            rps.verify_immutability(snap, snap_dir, "snap_test_root")
        self.assertIn(". (mode:", str(ctx.exception))

    def test_immutability_fails_on_unreadable_file(self):
        """Verify snapshot fails closed and raises RuntimeError on unreadable file (no silent skip)."""
        snap_dir = os.path.join(self.test_dir, "snap_test_unreadable")
        os.makedirs(snap_dir, exist_ok=True)
        unreadable_f = os.path.join(snap_dir, "secret.bin")
        with open(unreadable_f, "wb") as f:
            f.write(b"secret_data")
        os.chmod(unreadable_f, 0o000)

        try:
            with self.assertRaises(RuntimeError) as ctx:
                rps.snapshot_dir_state(snap_dir)
            self.assertIn("unreadable", str(ctx.exception).lower())
        finally:
            os.chmod(unreadable_f, 0o644)

if __name__ == "__main__":
    unittest.main()
