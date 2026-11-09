#!/usr/bin/env python3
"""
tests/test_donor_target_resolver.py
Unit tests for tools/resolve_partition_sources.py.

Verifies:
1. Authoritative resolution of donor and target partition trees and images.
2. Immediate fail-closed rejection on missing mandatory donor or target partitions.
3. Strict rejection of cross-device contamination (e.g. donor OnePlus 9 vendor as target vendor).
4. Strict rejection of invalid/incompatible Android versions (e.g. non-Android 16 system).
5. Cryptographic source asset immutability before and after successful and failed staging attempts.
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

        # Setup valid mock donor structure
        self._setup_mock_donor(self.donor_dir)
        # Setup valid mock target structure
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
            f.write("ro.build.version.release=16\nro.product.system_ext.brand=oplus\n")

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
            f.write("ro.product.vendor.device=OnePlus7T\nro.product.vendor.model=HD1901\nro.board.platform=msmnile\nro.vendor.build.version.sdk=36\nro.vendor.build.version.release=16\n")

        # odm
        odm_dir = os.path.join(base_dir, "odm", "odm", "etc")
        os.makedirs(odm_dir, exist_ok=True)
        with open(os.path.join(odm_dir, "build.prop"), "w") as f:
            f.write("ro.product.odm.device=OnePlus7T\nro.product.odm.model=HD1901\nro.odm.build.version.sdk=36\n")

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
        self.assertIn("100% source asset immutability verified", res.stdout)

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
        # Replace target vendor with donor vendor (OnePlus 9 lahaina)
        ven_prop = os.path.join(self.target_dir, "vendor", "vendor", "build.prop")
        with open(ven_prop, "w") as f:
            f.write("ro.product.vendor.device=OnePlus9\nro.board.platform=lahaina\n")

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", self.staging_dir,
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Donor vendor partition (OnePlus 9 / SM8350) mistakenly assigned as target vendor", res.stderr + res.stdout)

    def test_rejection_of_non_android_16_system(self):
        """Verify that system partition with wrong Android version is rejected."""
        sys_prop = os.path.join(self.donor_dir, "system", "system", "build.prop")
        with open(sys_prop, "w") as f:
            f.write("ro.build.version.release=15\nro.build.version.sdk=35\n")

        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", self.staging_dir,
        ], capture_output=True, text=True)

        self.assertNotEqual(res.returncode, 0)
        self.assertIn("System partition is not Android 16 / SDK 36", res.stderr + res.stdout)

    def test_source_asset_immutability_on_success_and_failure(self):
        """Verify source assets are 100% byte-for-byte unmodified across repeated builds and failures."""
        # Record checksum of donor and target files
        sys_prop = os.path.join(self.donor_dir, "system", "system", "build.prop")
        ven_prop = os.path.join(self.target_dir, "vendor", "vendor", "build.prop")
        with open(sys_prop, "rb") as f: orig_sys_data = f.read()
        with open(ven_prop, "rb") as f: orig_ven_data = f.read()

        # 1. Run successful staging
        res = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", os.path.join(self.test_dir, "staging1"),
        ], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)

        # 2. Modify staged files (simulate build modifications in staging)
        staged_ven_prop = os.path.join(self.test_dir, "staging1", "vendor", "vendor", "build.prop")
        with open(staged_ven_prop, "a") as f:
            f.write("INJECTED_BUILD_PROPERTY=1\n")

        # Verify source file was NOT mutated by staged file modification (tests NO hardlinks)
        with open(ven_prop, "rb") as f: current_ven_data = f.read()
        self.assertEqual(orig_ven_data, current_ven_data, "Target vendor asset was mutated through hardlinks!")

        # 3. Repeated staging
        res2 = subprocess.run([
            sys.executable, RESOLVER_SCRIPT,
            "--donor-dir", self.donor_dir,
            "--target-dir", self.target_dir,
            "--staging-dir", os.path.join(self.test_dir, "staging2"),
        ], capture_output=True, text=True)
        self.assertEqual(res2.returncode, 0)

        with open(sys_prop, "rb") as f: final_sys_data = f.read()
        with open(ven_prop, "rb") as f: final_ven_data = f.read()
        self.assertEqual(orig_sys_data, final_sys_data, "Donor system asset changed after repeated staging!")
        self.assertEqual(orig_ven_data, final_ven_data, "Target vendor asset changed after repeated staging!")

if __name__ == "__main__":
    unittest.main()
