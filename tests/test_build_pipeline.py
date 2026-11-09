#!/usr/bin/env python3
"""
Unit and integration tests for the OxygenOS 16 build pipeline:
- scripts/build_all.sh CLI argument validation and mode dispatch
- scripts/build_all.sh host tool dependency validation
- scripts/build_all.sh authentic OnePlus 7T hardware asset validation
- scripts/build_all.sh donor partition and APEX input validation
- scripts/verify_boot_image.sh independent boot image verifier
- build/images/PARTITION_MAP schema and cryptographic contract
- tools/safe/audit-no-writes.sh static safety audit enforcement
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
BUILD_ALL_SCRIPT = os.path.join(PROJECT_ROOT, "scripts", "build_all.sh")
VERIFY_SCRIPT = os.path.join(PROJECT_ROOT, "scripts", "verify_boot_image.sh")
AUDIT_SCRIPT = os.path.join(PROJECT_ROOT, "tools", "safe", "audit-no-writes.sh")


class TestBuildAllCLI(unittest.TestCase):
    """Test CLI argument parsing, mode dispatch, and mutual exclusivity in build_all.sh."""

    def test_cli_help(self):
        res = subprocess.run(
            [BUILD_ALL_SCRIPT, "--help"],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("Usage: scripts/build_all.sh", res.stdout)
        self.assertIn("--skip-stage2", res.stdout)
        self.assertIn("--verify-only", res.stdout)
        self.assertIn("--check-tools", res.stdout)
        self.assertIn("--check-donor", res.stdout)

    def test_cli_unknown_argument(self):
        res = subprocess.run(
            [BUILD_ALL_SCRIPT, "--unrecognized-flag-xyz"],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Unknown argument", res.stderr)

    def test_cli_mutually_exclusive_modes(self):
        modes = ["--stage2-only", "--boot-only", "--verify-only", "--check-tools", "--check-donor"]
        for i in range(len(modes)):
            for j in range(i + 1, len(modes)):
                res = subprocess.run(
                    [BUILD_ALL_SCRIPT, modes[i], modes[j]],
                    capture_output=True,
                    text=True,
                    cwd=PROJECT_ROOT,
                )
                self.assertNotEqual(res.returncode, 0, f"Expected conflict between {modes[i]} and {modes[j]}")
                self.assertIn("mutually exclusive", res.stderr)

    def test_cli_skip_stage2_with_stage2_only_conflict(self):
        res = subprocess.run(
            [BUILD_ALL_SCRIPT, "--skip-stage2", "--stage2-only"],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Cannot combine --skip-stage2 with --stage2-only", res.stderr)


class TestHostToolDependencyChecks(unittest.TestCase):
    """Test fail-closed behavior when host tools are missing."""

    def test_missing_host_tool_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            # Provide standard tools but exclude lz4
            for tool in ["bash", "sh", "python3", "go", "sha256sum", "stat", "cpio", "grep", "awk", "sed", "tr", "cut", "dirname", "basename"]:
                real_path = shutil.which(tool)
                if real_path:
                    os.symlink(real_path, os.path.join(tmp_dir, tool))

            env = os.environ.copy()
            env["PATH"] = tmp_dir
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--verify-only"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertTrue(
                "lz4" in res.stderr or "lz4" in res.stdout,
                f"Expected lz4 error, got stderr: {res.stderr}, stdout: {res.stdout}",
            )


class TestHardwareAssetValidation(unittest.TestCase):
    """Test cryptographic and architectural validation of OnePlus 7T hardware assets."""

    def setUp(self):
        self.orig_kernel = os.path.join(PROJECT_ROOT, "stage1", "kernel_src", "kernel")
        self.orig_dtb = os.path.join(PROJECT_ROOT, "stage1", "kernel_src", "dtb")
        self.orig_dtbo = os.path.join(PROJECT_ROOT, "stage1", "kernel_src", "recovery_dtbo")
        if not (os.path.isfile(self.orig_kernel) and os.path.isfile(self.orig_dtb) and os.path.isfile(self.orig_dtbo)):
            self.skipTest("Hardware kernel assets not present in checkout (CI environment)")

    def test_authentic_assets_exist(self):
        self.assertTrue(os.path.isfile(self.orig_kernel))
        self.assertTrue(os.path.isfile(self.orig_dtb))
        self.assertTrue(os.path.isfile(self.orig_dtbo))

    def _setup_mock_project(self, tmp_dir):
        ksrc = os.path.join(tmp_dir, "stage1", "kernel_src")
        os.makedirs(ksrc, exist_ok=True)
        shutil.copy(self.orig_kernel, os.path.join(ksrc, "kernel"))
        shutil.copy(self.orig_dtb, os.path.join(ksrc, "dtb"))
        shutil.copy(self.orig_dtbo, os.path.join(ksrc, "recovery_dtbo"))

        os.makedirs(os.path.join(tmp_dir, "scripts"), exist_ok=True)
        shutil.copy(BUILD_ALL_SCRIPT, os.path.join(tmp_dir, "scripts", "build_all.sh"))
        os.chmod(os.path.join(tmp_dir, "scripts", "build_all.sh"), 0o755)

        os.makedirs(os.path.join(tmp_dir, "tools", "safe"), exist_ok=True)
        shutil.copy(AUDIT_SCRIPT, os.path.join(tmp_dir, "tools", "safe", "audit-no-writes.sh"))
        os.chmod(os.path.join(tmp_dir, "tools", "safe", "audit-no-writes.sh"), 0o755)

        # Symlink or stub otatools to satisfy Android tool requirements
        otatools_src = os.path.join(PROJECT_ROOT, "external", "coloros_port", "otatools", "bin")
        if os.path.isdir(otatools_src):
            os.makedirs(os.path.join(tmp_dir, "external", "coloros_port", "otatools"), exist_ok=True)
            os.symlink(otatools_src, os.path.join(tmp_dir, "external", "coloros_port", "otatools", "bin"))
        else:
            mock_bin = os.path.join(tmp_dir, "external", "coloros_port", "otatools", "bin")
            os.makedirs(mock_bin, exist_ok=True)
            for tool in ["mkbootfs", "mkbootimg", "unpack_bootimg", "mkfs.erofs", "fsck.erofs"]:
                t_path = os.path.join(mock_bin, tool)
                with open(t_path, "w") as f:
                    f.write("#!/bin/sh\nexit 0\n")
                os.chmod(t_path, 0o755)

    def test_missing_kernel_fails(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            self._setup_mock_project(tmp_dir)
            os.remove(os.path.join(tmp_dir, "stage1", "kernel_src", "kernel"))

            script_path = os.path.join(tmp_dir, "scripts", "build_all.sh")
            res = subprocess.run([script_path, "--verify-only"], capture_output=True, text=True, cwd=tmp_dir)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Hardware kernel image missing", res.stderr)

    def test_corrupted_kernel_size_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            self._setup_mock_project(tmp_dir)
            kernel_file = os.path.join(tmp_dir, "stage1", "kernel_src", "kernel")
            with open(kernel_file, "wb") as f:
                f.write(b"CORRUPTED_SHORT_KERNEL")

            script_path = os.path.join(tmp_dir, "scripts", "build_all.sh")
            res = subprocess.run([script_path, "--verify-only"], capture_output=True, text=True, cwd=tmp_dir)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Kernel size mismatch", res.stderr)

    def test_corrupted_kernel_sha_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            self._setup_mock_project(tmp_dir)
            kernel_file = os.path.join(tmp_dir, "stage1", "kernel_src", "kernel")
            with open(kernel_file, "r+b") as f:
                f.seek(500)
                f.write(b"CORRUPTED_KERNEL_PAYLOAD")

            script_path = os.path.join(tmp_dir, "scripts", "build_all.sh")
            res = subprocess.run([script_path, "--verify-only"], capture_output=True, text=True, cwd=tmp_dir)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Kernel SHA-256 mismatch", res.stderr)

    def test_missing_dtb_fails(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            self._setup_mock_project(tmp_dir)
            os.remove(os.path.join(tmp_dir, "stage1", "kernel_src", "dtb"))

            script_path = os.path.join(tmp_dir, "scripts", "build_all.sh")
            res = subprocess.run([script_path, "--verify-only"], capture_output=True, text=True, cwd=tmp_dir)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Device Tree Blob missing", res.stderr)

    def test_corrupted_dtb_sha_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            self._setup_mock_project(tmp_dir)
            dtb_file = os.path.join(tmp_dir, "stage1", "kernel_src", "dtb")
            with open(dtb_file, "r+b") as f:
                f.seek(100)
                f.write(b"CORRUPTED_BYTES")

            script_path = os.path.join(tmp_dir, "scripts", "build_all.sh")
            res = subprocess.run([script_path, "--verify-only"], capture_output=True, text=True, cwd=tmp_dir)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("DTB SHA-256 mismatch", res.stderr)

    def test_missing_recovery_dtbo_fails(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            self._setup_mock_project(tmp_dir)
            os.remove(os.path.join(tmp_dir, "stage1", "kernel_src", "recovery_dtbo"))

            script_path = os.path.join(tmp_dir, "scripts", "build_all.sh")
            res = subprocess.run([script_path, "--verify-only"], capture_output=True, text=True, cwd=tmp_dir)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Recovery DTBO missing", res.stderr)

    def test_corrupted_recovery_dtbo_sha_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            self._setup_mock_project(tmp_dir)
            dtbo_file = os.path.join(tmp_dir, "stage1", "kernel_src", "recovery_dtbo")
            with open(dtbo_file, "r+b") as f:
                f.seek(100)
                f.write(b"CORRUPTED_BYTES")

            script_path = os.path.join(tmp_dir, "scripts", "build_all.sh")
            res = subprocess.run([script_path, "--verify-only"], capture_output=True, text=True, cwd=tmp_dir)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Recovery DTBO SHA-256 mismatch", res.stderr)


class TestDonorPartitionValidation(unittest.TestCase):
    """Test donor partition and bootstrap APEX input validation."""

    def _create_valid_apex(self, path, pkg_name, version=1):
        manifest = {
            "name": pkg_name,
            "version": version,
            "versionName": "1.0",
        }
        with zipfile.ZipFile(path, "w") as zf:
            zf.writestr("apex_manifest.json", json.dumps(manifest))
            zf.writestr("apex_payload.img", b"\x00" * 4096)

    def test_missing_work_directory_rejected(self):
        env = os.environ.copy()
        env["WORK_DIR"] = "/tmp/nonexistent_donor_work_dir_xyz"
        res = subprocess.run(
            [BUILD_ALL_SCRIPT, "--check-donor"],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
            env=env,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Work directory", res.stderr)

    def test_missing_mandatory_partition_tree_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_work:
            for p in ["system", "system_ext", "vendor", "odm"]:
                os.makedirs(os.path.join(tmp_work, p))

            env = os.environ.copy()
            env["WORK_DIR"] = tmp_work
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-donor"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("my_product", res.stderr)

    def test_missing_apex_directory_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_work:
            for p in ["system", "system_ext", "vendor", "odm", "my_product"]:
                os.makedirs(os.path.join(tmp_work, p))
            env = os.environ.copy()
            env["WORK_DIR"] = tmp_work
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-donor"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Authoritative APEX directory not found", res.stderr)

    def test_missing_mandatory_apex_module_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_work:
            for p in ["system", "system_ext", "vendor", "odm", "my_product"]:
                os.makedirs(os.path.join(tmp_work, p))
            apex_dir = os.path.join(tmp_work, "system", "system", "apex")
            os.makedirs(apex_dir, exist_ok=True)
            # Create art, i18n, tzdata, but omit runtime
            self._create_valid_apex(os.path.join(apex_dir, "com.google.android.art_compressed.apex"), "com.android.art")
            self._create_valid_apex(os.path.join(apex_dir, "com.android.i18n.apex"), "com.android.i18n")
            self._create_valid_apex(os.path.join(apex_dir, "com.google.android.tzdata6.apex"), "com.android.tzdata")

            env = os.environ.copy()
            env["WORK_DIR"] = tmp_work
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-donor"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Mandatory runtime APEX module", res.stderr)

    def test_authoritative_apex_resolution_from_system_system_apex(self):
        with tempfile.TemporaryDirectory() as tmp_work:
            for p in ["system", "system_ext", "vendor", "odm", "my_product"]:
                os.makedirs(os.path.join(tmp_work, p))
            apex_dir = os.path.join(tmp_work, "system", "system", "apex")
            os.makedirs(apex_dir, exist_ok=True)
            self._create_valid_apex(os.path.join(apex_dir, "com.android.runtime.apex"), "com.android.runtime")
            self._create_valid_apex(os.path.join(apex_dir, "com.google.android.art_compressed.apex"), "com.android.art")
            self._create_valid_apex(os.path.join(apex_dir, "com.android.i18n.apex"), "com.android.i18n")
            self._create_valid_apex(os.path.join(apex_dir, "com.google.android.tzdata6.apex"), "com.android.tzdata")

            env = os.environ.copy()
            env["WORK_DIR"] = tmp_work
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-donor"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertEqual(res.returncode, 0, f"Expected validation to succeed, got:\n{res.stderr}\n{res.stdout}")
            self.assertIn("All donor ROM partitions and APEX modules are verified", res.stdout)

    def test_flat_apex_resolution_from_system_apex(self):
        with tempfile.TemporaryDirectory() as tmp_work:
            for p in ["system", "system_ext", "vendor", "odm", "my_product"]:
                os.makedirs(os.path.join(tmp_work, p))
            apex_dir = os.path.join(tmp_work, "system", "apex")
            os.makedirs(apex_dir, exist_ok=True)
            self._create_valid_apex(os.path.join(apex_dir, "com.android.runtime.apex"), "com.android.runtime")
            self._create_valid_apex(os.path.join(apex_dir, "com.android.art.apex"), "com.android.art")
            self._create_valid_apex(os.path.join(apex_dir, "com.android.i18n.apex"), "com.android.i18n")
            self._create_valid_apex(os.path.join(apex_dir, "com.android.tzdata.apex"), "com.android.tzdata")

            env = os.environ.copy()
            env["WORK_DIR"] = tmp_work
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-donor"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertEqual(res.returncode, 0, f"Expected validation to succeed, got:\n{res.stderr}\n{res.stdout}")
            self.assertIn("All donor ROM partitions and APEX modules are verified", res.stdout)

    def test_corrupted_apex_archive_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_work:
            for p in ["system", "system_ext", "vendor", "odm", "my_product"]:
                os.makedirs(os.path.join(tmp_work, p))
            apex_dir = os.path.join(tmp_work, "system", "system", "apex")
            os.makedirs(apex_dir, exist_ok=True)
            self._create_valid_apex(os.path.join(apex_dir, "com.android.runtime.apex"), "com.android.runtime")
            with open(os.path.join(apex_dir, "com.google.android.art_compressed.apex"), "wb") as f:
                f.write(b"CORRUPTED_NON_ZIP_DATA")
            self._create_valid_apex(os.path.join(apex_dir, "com.android.i18n.apex"), "com.android.i18n")
            self._create_valid_apex(os.path.join(apex_dir, "com.google.android.tzdata6.apex"), "com.android.tzdata")

            env = os.environ.copy()
            env["WORK_DIR"] = tmp_work
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-donor"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Mandatory ART APEX manifest validation failed", res.stderr)

    def test_mismatched_apex_package_identity_rejected(self):
        with tempfile.TemporaryDirectory() as tmp_work:
            for p in ["system", "system_ext", "vendor", "odm", "my_product"]:
                os.makedirs(os.path.join(tmp_work, p))
            apex_dir = os.path.join(tmp_work, "system", "system", "apex")
            os.makedirs(apex_dir, exist_ok=True)
            self._create_valid_apex(os.path.join(apex_dir, "com.android.runtime.apex"), "com.wrong.rogue.runtime")
            self._create_valid_apex(os.path.join(apex_dir, "com.google.android.art_compressed.apex"), "com.android.art")
            self._create_valid_apex(os.path.join(apex_dir, "com.android.i18n.apex"), "com.android.i18n")
            self._create_valid_apex(os.path.join(apex_dir, "com.google.android.tzdata6.apex"), "com.android.tzdata")

            env = os.environ.copy()
            env["WORK_DIR"] = tmp_work
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-donor"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Mandatory runtime APEX manifest validation failed", res.stderr)


class TestStage2WorkDirImmutability(unittest.TestCase):
    """Test that build_stage2_erofs.sh never modifies WORK_DIR or leaves .orig files."""

    def test_work_dir_remains_strictly_unmodified(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            work_dir = os.path.join(tmp_dir, "work")
            out_dir = os.path.join(tmp_dir, "build", "images")
            for p in ["system", "system_ext", "vendor", "odm", "my_product"]:
                os.makedirs(os.path.join(work_dir, p))

            # Create sample files in work_dir
            v_prop = os.path.join(work_dir, "vendor", "vendor", "build.prop")
            os.makedirs(os.path.dirname(v_prop), exist_ok=True)
            orig_prop_content = "ro.build.id=ORIGINAL_PROP\n"
            with open(v_prop, "w") as f:
                f.write(orig_prop_content)

            ctx_file = os.path.join(work_dir, "system_ext", "etc", "selinux", "system_ext_property_contexts")
            os.makedirs(os.path.dirname(ctx_file), exist_ok=True)
            orig_ctx_content = "ro.build.date u:object_r:build_prop:s0\n"
            with open(ctx_file, "w") as f:
                f.write(orig_ctx_content)

            apex_dir = os.path.join(work_dir, "system", "system", "apex")
            os.makedirs(apex_dir, exist_ok=True)
            manifest = {"name": "com.android.runtime", "version": 1}
            with zipfile.ZipFile(os.path.join(apex_dir, "com.android.runtime.apex"), "w") as zf:
                zf.writestr("apex_manifest.json", json.dumps(manifest))
                zf.writestr("apex_payload.img", b"\x00" * 4096)

            stage2_script = os.path.join(PROJECT_ROOT, "scripts", "build_stage2_erofs.sh")
            env = os.environ.copy()
            env["WORK_DIR"] = work_dir
            env["OUT_DIR"] = out_dir

            # Run build_stage2_erofs.sh (may halt on missing full APEXes or fsck, but must not alter WORK_DIR)
            subprocess.run([stage2_script], capture_output=True, text=True, env=env, cwd=PROJECT_ROOT)

            with open(v_prop, "r") as f:
                self.assertEqual(f.read(), orig_prop_content)
            with open(ctx_file, "r") as f:
                self.assertEqual(f.read(), orig_ctx_content)

            # Check no .orig files anywhere in work_dir
            orig_files = []
            for root, _, files in os.walk(work_dir):
                for f in files:
                    if f.endswith(".orig"):
                        orig_files.append(os.path.join(root, f))
            self.assertEqual(orig_files, [], f"Found .orig backup files in WORK_DIR: {orig_files}")


class TestOtatoolsEnvironmentHandling(unittest.TestCase):
    """Test that OTATOOLS environment variable is respected and prioritized."""

    def test_otatools_precedence_in_path(self):
        with tempfile.TemporaryDirectory() as custom_otatools:
            bin_dir = os.path.join(custom_otatools, "bin")
            os.makedirs(bin_dir, exist_ok=True)

            mock_tools = {}
            for tool_name in ["mkbootfs", "mkbootimg", "unpack_bootimg", "mkfs.erofs", "fsck.erofs"]:
                tool_path = os.path.join(bin_dir, tool_name)
                with open(tool_path, "w") as f:
                    f.write(f"#!/bin/sh\necho 'CUSTOM_OTATOOLS_{tool_name.upper()}'\n")
                os.chmod(tool_path, 0o755)
                mock_tools[tool_name] = tool_path

            if not shutil.which("7z") and not shutil.which("7za"):
                stub_7z = os.path.join(bin_dir, "7z")
                with open(stub_7z, "w") as f:
                    f.write("#!/bin/sh\nexit 0\n")
                os.chmod(stub_7z, 0o755)

            env = os.environ.copy()
            env["OTATOOLS"] = custom_otatools
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-tools"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertEqual(res.returncode, 0, f"Expected --check-tools to succeed, got {res.returncode}:\n{res.stderr}\n{res.stdout}")
            self.assertIn(f"mkbootfs ({mock_tools['mkbootfs']})", res.stdout)
            self.assertIn(f"mkbootimg ({mock_tools['mkbootimg']})", res.stdout)
            self.assertIn(f"unpack_bootimg ({mock_tools['unpack_bootimg']})", res.stdout)
            self.assertIn(f"mkfs.erofs ({mock_tools['mkfs.erofs']})", res.stdout)
            self.assertIn(f"fsck.erofs ({mock_tools['fsck.erofs']})", res.stdout)

    def test_otatools_flat_directory_precedence(self):
        with tempfile.TemporaryDirectory() as custom_otatools:
            mock_tools = {}
            for tool_name in ["mkbootfs", "mkbootimg", "unpack_bootimg", "mkfs.erofs", "fsck.erofs"]:
                tool_path = os.path.join(custom_otatools, tool_name)
                with open(tool_path, "w") as f:
                    f.write(f"#!/bin/sh\necho 'CUSTOM_FLAT_{tool_name.upper()}'\n")
                os.chmod(tool_path, 0o755)
                mock_tools[tool_name] = tool_path

            if not shutil.which("7z") and not shutil.which("7za"):
                stub_7z = os.path.join(custom_otatools, "7z")
                with open(stub_7z, "w") as f:
                    f.write("#!/bin/sh\nexit 0\n")
                os.chmod(stub_7z, 0o755)

            env = os.environ.copy()
            env["OTATOOLS"] = custom_otatools
            res = subprocess.run(
                [BUILD_ALL_SCRIPT, "--check-tools"],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
                env=env,
            )
            self.assertEqual(res.returncode, 0, f"Expected --check-tools to succeed with flat OTATOOLS, got {res.returncode}:\n{res.stderr}\n{res.stdout}")
            self.assertIn(f"mkbootfs ({mock_tools['mkbootfs']})", res.stdout)
            self.assertIn(f"mkbootimg ({mock_tools['mkbootimg']})", res.stdout)


class TestBootImageIndependentVerifier(unittest.TestCase):
    """Test scripts/verify_boot_image.sh functionality."""

    def test_verifier_rejects_non_existent_file(self):
        res = subprocess.run(
            [VERIFY_SCRIPT, "/tmp/non_existent_boot_image.img"],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("does not exist", res.stderr)

    def test_verifier_rejects_invalid_boot_magic(self):
        with tempfile.NamedTemporaryFile() as tmp:
            tmp.write(b"NOT_AN_ANDROID_BOOT_IMAGE_HEADER_MAGIC_123456789")
            tmp.flush()
            res = subprocess.run(
                [VERIFY_SCRIPT, tmp.name],
                capture_output=True,
                text=True,
                cwd=PROJECT_ROOT,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("is not a valid Android boot image", res.stderr)

    def test_verifier_passes_loader_img(self):
        loader_path = os.path.join(PROJECT_ROOT, "build", "loader.img")
        if not os.path.isfile(loader_path):
            self.skipTest("build/loader.img not yet built")
        res = subprocess.run(
            [VERIFY_SCRIPT, loader_path],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
        )
        self.assertEqual(res.returncode, 0, f"Verifier failed on loader.img: {res.stderr}\n{res.stdout}")
        self.assertIn("BOOT IMAGE INDEPENDENT VERIFICATION PASSED", res.stdout)
        self.assertIn("Header Version: 2", res.stdout)
        self.assertIn("c32e3a267b1e44e92f0bdb909358e1c95fa900cb8219076581cdbb4084cc9129", res.stdout)
        self.assertIn("Diagnostic RAM Loader", res.stdout)
        self.assertIn("androidboot.mode=normal", res.stdout)

    def test_verifier_passes_stage1_img(self):
        stage1_path = os.path.join(PROJECT_ROOT, "build", "stage1.img")
        if not os.path.isfile(stage1_path):
            self.skipTest("build/stage1.img not yet built")
        res = subprocess.run(
            [VERIFY_SCRIPT, stage1_path],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
        )
        self.assertEqual(res.returncode, 0, f"Verifier failed on stage1.img: {res.stderr}\n{res.stdout}")
        self.assertIn("BOOT IMAGE INDEPENDENT VERIFICATION PASSED", res.stdout)
        self.assertIn("Header Version: 2", res.stdout)
        self.assertIn("c32e3a267b1e44e92f0bdb909358e1c95fa900cb8219076581cdbb4084cc9129", res.stdout)
        self.assertIn("Autonomous RAM Supervisor", res.stdout)
        self.assertIn("SELinux Mode: permissive", res.stdout)


class TestPartitionMapContract(unittest.TestCase):
    """Test authoritative 4-field PARTITION_MAP schema and cryptographic checksums."""

    def test_partition_map_exists_and_valid(self):
        map_path = os.path.join(PROJECT_ROOT, "build", "images", "PARTITION_MAP")
        if not os.path.isfile(map_path):
            self.skipTest("build/images/PARTITION_MAP does not exist")

        with open(map_path, "r") as f:
            lines = [line.strip() for line in f if line.strip() and not line.strip().startswith("#")]

        self.assertGreater(len(lines), 0, "PARTITION_MAP should have at least one partition")

        allowed_mounts = {
            "/mnt/sysroot",
            "/mnt/sysroot/system_ext",
            "/mnt/sysroot/vendor",
            "/mnt/sysroot/odm",
            "/mnt/sysroot/product",
            "/mnt/sysroot/my_product",
            "/mnt/sysroot/my_region",
        }

        seen_images = set()
        seen_targets = set()

        for line in lines:
            fields = line.split(":")
            self.assertEqual(len(fields), 4, f"Line '{line}' must have exactly 4 fields")
            img, target, nature, sha = fields

            self.assertTrue(img.endswith(".img"), f"Image name '{img}' must end with .img")
            self.assertIn(nature, {"mandatory", "optional"}, f"Nature must be mandatory or optional: {nature}")
            self.assertEqual(len(sha), 64, f"SHA-256 must be 64 characters: {sha}")
            int(sha, 16)  # Verify hex

            self.assertIn(target, allowed_mounts, f"Mountpoint {target} not in allowlist")
            self.assertNotIn(img, seen_images, f"Duplicate image filename: {img}")
            self.assertNotIn(target, seen_targets, f"Duplicate target mountpoint: {target}")

            seen_images.add(img)
            seen_targets.add(target)

            # Verify image file exists on disk
            img_path = os.path.join(PROJECT_ROOT, "build", "images", img)
            self.assertTrue(os.path.isfile(img_path), f"File {img_path} does not exist")

    def test_sha256sums_manifest_integrity(self):
        sums_path = os.path.join(PROJECT_ROOT, "build", "images", "SHA256SUMS")
        if not os.path.isfile(sums_path):
            self.skipTest("build/images/SHA256SUMS does not exist")

        res = subprocess.run(
            ["sha256sum", "-c", "SHA256SUMS", "--status"],
            cwd=os.path.join(PROJECT_ROOT, "build", "images"),
            capture_output=True,
        )
        self.assertEqual(res.returncode, 0, "SHA256SUMS check failed for build/images/")


class TestStaticSafetyAuditPasses(unittest.TestCase):
    """Test that static safety auditor passes cleanly without write violations."""

    def test_audit_no_writes_clean(self):
        res = subprocess.run(
            [AUDIT_SCRIPT],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
        )
        self.assertEqual(res.returncode, 0, f"Audit failed:\n{res.stderr}\n{res.stdout}")
        self.assertIn("0 Failed, 0 Mandatory Unverified", res.stdout)
        self.assertIn("AUDIT RESULT: PASSED", res.stdout)

        if os.path.isfile(os.path.join(PROJECT_ROOT, "build", "stage1.img")):
            self.assertIn("36 Passed", res.stdout)
        else:
            self.assertIn("34 Passed", res.stdout)
            self.assertIn("Falling back to source ramdisk directory", res.stdout)

    def test_audit_no_writes_ramdisk_target(self):
        res = subprocess.run(
            [AUDIT_SCRIPT, os.path.join(PROJECT_ROOT, "stage1", "loader_ramdisk")],
            capture_output=True,
            text=True,
            cwd=PROJECT_ROOT,
        )
        self.assertEqual(res.returncode, 0, f"Audit failed on ramdisk:\n{res.stderr}\n{res.stdout}")
        self.assertIn("34 Passed, 0 Failed, 0 Mandatory Unverified", res.stdout)
        self.assertIn("AUDIT RESULT: PASSED", res.stdout)


if __name__ == "__main__":
    unittest.main()
