package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestMkdevEncoding(t *testing.T) {
	tests := []struct {
		name    string
		maj     uint32
		min     uint32
		wantErr bool
	}{
		{"zero_zero", 0, 0, false},
		{"standard_loop", 7, 0, false},
		{"standard_misc", 10, 237, false},
		{"high_major_511", 511, 1024, false},
		{"max_supported_boundary", 0xfffff, 0xfffff, false},
		{"overflow_major", 0x100000, 0, true},
		{"overflow_minor", 0, 0x100000, true},
		{"overflow_both", 0x100000, 0x100000, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dev, err := mkdev(tc.maj, tc.min)
			if (err != nil) != tc.wantErr {
				t.Fatalf("mkdev(%d, %d) error = %v, wantErr %v", tc.maj, tc.min, err, tc.wantErr)
			}
			if !tc.wantErr {
				// Verify decoding matches Linux glibc macro
				decMaj := uint32((uint64(dev)>>8)&0xfff | ((uint64(dev) >> 32) & ^uint64(0xfff)))
				decMin := uint32((uint64(dev) & 0xff) | ((uint64(dev) >> 12) & ^uint64(0xff)))
				if decMaj != tc.maj || decMin != tc.min {
					t.Errorf("Decoded mismatch: got (%d, %d), expected (%d, %d)", decMaj, decMin, tc.maj, tc.min)
				}
			}
		})
	}
}

func TestParseSysfsDev(t *testing.T) {
	tests := []struct {
		input   string
		wantMaj uint32
		wantMin uint32
		wantErr bool
	}{
		{"10:237\n", 10, 237, false},
		{"  7:0  ", 7, 0, false},
		{"0:0", 0, 0, false},
		{"1048575:1048575", 0xfffff, 0xfffff, false},
		{"", 0, 0, true},
		{"invalid", 0, 0, true},
		{"10", 0, 0, true},
		{"10:237:99", 0, 0, true},
		{"-10:20", 0, 0, true},
		{"10:-20", 0, 0, true},
		{"abc:237", 0, 0, true},
		{"10:xyz", 0, 0, true},
		{"99999999999999999999:1", 0, 0, true},
		{"1048576:1", 0, 0, true}, // major > 0xfffff
		{"10:1048576", 0, 0, true}, // minor > 0xfffff
	}

	for _, tc := range tests {
		maj, min, err := parseSysfsDev(tc.input)
		if (err != nil) != tc.wantErr {
			t.Errorf("parseSysfsDev(%q) err = %v, wantErr %v", tc.input, err, tc.wantErr)
		}
		if !tc.wantErr && (maj != tc.wantMaj || min != tc.wantMin) {
			t.Errorf("parseSysfsDev(%q) = (%d, %d), want (%d, %d)", tc.input, maj, min, tc.wantMaj, tc.wantMin)
		}
	}
}

func TestValidateOrCreateLegacyNodeRefuseOverwrite(t *testing.T) {
	tmpDir := t.TempDir()
	existingFile := filepath.Join(tmpDir, "regular_file")
	if err := os.WriteFile(existingFile, []byte("important-data"), 0644); err != nil {
		t.Fatal(err)
	}

	// Attempting to create legacy node on top of an ordinary file must fail
	_, err := validateOrCreateLegacyNode(existingFile, 10, 237, true)
	if err == nil {
		t.Fatalf("Expected error when target is regular file, got nil")
	}

	// Verify original content was untouched
	content, _ := os.ReadFile(existingFile)
	if string(content) != "important-data" {
		t.Fatalf("Original file content was corrupted!")
	}
}

func TestValidateOrCreateLegacyNodeExistingDirectory(t *testing.T) {
	tmpDir := t.TempDir()
	dirPath := filepath.Join(tmpDir, "sub_dir")
	if err := os.Mkdir(dirPath, 0755); err != nil {
		t.Fatal(err)
	}

	_, err := validateOrCreateLegacyNode(dirPath, 10, 237, true)
	if err == nil {
		t.Fatalf("Expected error when target is directory, got nil")
	}
}

func TestValidateOrCreateLegacyNodeConflictingCharDevice(t *testing.T) {
	// /dev/null is character device 1:3 on Linux
	if fi, err := os.Stat("/dev/null"); err == nil && (fi.Mode()&os.ModeCharDevice != 0) {
		// Try to validate /dev/null with mismatched maj/min (e.g. 10:237)
		_, err := validateOrCreateLegacyNode("/dev/null", 10, 237, true)
		if err == nil {
			t.Fatalf("Expected error when validating /dev/null with wrong rdev, got nil")
		}
	}
}

func TestValidateOrCreateLegacyNodeSymlinkHandling(t *testing.T) {
	tmpDir := t.TempDir()
	symlinkPath := filepath.Join(tmpDir, "stale_symlink")
	unrelatedTarget := filepath.Join(tmpDir, "unrelated_target")
	_ = os.WriteFile(unrelatedTarget, []byte("unrelated"), 0644)
	if err := os.Symlink(unrelatedTarget, symlinkPath); err != nil {
		t.Fatal(err)
	}

	// Stale symlink to regular file should be atomically replaced in test mode
	res, err := validateOrCreateLegacyNode(symlinkPath, 10, 237, true)
	if err != nil {
		t.Fatalf("validateOrCreateLegacyNode failed on stale symlink: %v", err)
	}
	if res != ResultCreated {
		t.Errorf("Expected ResultCreated on recreating stale symlink, got %v", res)
	}
	content, _ := os.ReadFile(symlinkPath)
	if string(content) != "test-legacy" {
		t.Errorf("Expected recreated test-legacy node, got %s", string(content))
	}

	// Subsequent call on valid legacy node in test mode should return ResultAlreadyValid
	res2, err := validateOrCreateLegacyNode(symlinkPath, 10, 237, true)
	if err != nil {
		t.Fatalf("Idempotent validateOrCreateLegacyNode failed: %v", err)
	}
	if res2 != ResultAlreadyValid {
		t.Errorf("Expected ResultAlreadyValid on second call, got %v", res2)
	}
}

func TestSafeSymlinkRefuseOverwrite(t *testing.T) {
	tmpDir := t.TempDir()
	destFile := filepath.Join(tmpDir, "unrelated")
	if err := os.WriteFile(destFile, []byte("do-not-overwrite"), 0644); err != nil {
		t.Fatal(err)
	}

	// Source missing
	_, err := safeSymlink(filepath.Join(tmpDir, "nonexistent"), destFile)
	if err == nil {
		t.Fatalf("Expected error when source does not exist, got nil")
	}

	// Source is regular file (not character device)
	srcMock := filepath.Join(tmpDir, "src_mock")
	_ = os.WriteFile(srcMock, []byte("mock"), 0666)
	_, err = safeSymlink(srcMock, destFile)
	if err == nil {
		t.Fatalf("Expected error when source is not character device, got nil")
	}
}

func TestSafeSymlinkRealCharDeviceAndAtomicReplacement(t *testing.T) {
	// On Linux host, /dev/null is character device
	if fi, err := os.Stat("/dev/null"); err == nil && (fi.Mode()&os.ModeCharDevice != 0) {
		tmpDir := t.TempDir()
		symlinkDest := filepath.Join(tmpDir, "binder_symlink")

		// 1. Create initial valid symlink
		res, err := safeSymlink("/dev/null", symlinkDest)
		if err != nil {
			t.Fatalf("safeSymlink to /dev/null failed: %v", err)
		}
		if res != ResultCreated {
			t.Errorf("Expected ResultCreated on first symlink, got %v", res)
		}

		// 2. Calling safeSymlink again on existing identical symlink should be idempotent ResultAlreadyValid
		res2, err := safeSymlink("/dev/null", symlinkDest)
		if err != nil {
			t.Fatalf("Idempotent safeSymlink failed: %v", err)
		}
		if res2 != ResultAlreadyValid {
			t.Errorf("Expected ResultAlreadyValid on second symlink, got %v", res2)
		}

		// 3. Stale symlink pointing to nonexistent path: should be atomically replaced
		staleSym := filepath.Join(tmpDir, "stale_sym")
		_ = os.Symlink(filepath.Join(tmpDir, "nonexistent_target"), staleSym)
		res3, err := safeSymlink("/dev/null", staleSym)
		if err != nil {
			t.Fatalf("safeSymlink failed on stale symlink: %v", err)
		}
		if res3 != ResultCreated {
			t.Errorf("Expected ResultCreated on replacing stale symlink, got %v", res3)
		}
		target, err := os.Readlink(staleSym)
		if err != nil {
			t.Fatalf("Failed to readlink %s: %v", staleSym, err)
		}
		resolvedTarget := target
		if !filepath.IsAbs(target) {
			resolvedTarget = filepath.Clean(filepath.Join(filepath.Dir(staleSym), target))
		}
		if resolvedTarget != "/dev/null" {
			t.Errorf("Expected target resolving to /dev/null, got %s (raw %s)", resolvedTarget, target)
		}

		// 4. Destination conflicting with /dev/zero (different char device)
		if zfi, err := os.Stat("/dev/zero"); err == nil && (zfi.Mode()&os.ModeCharDevice != 0) {
			_, err := safeSymlink("/dev/null", "/dev/zero")
			if err == nil {
				t.Fatalf("Expected error when destination is conflicting char device (/dev/zero), got nil")
			}
		}
	}
}

func TestSafeSymlinkPreservesOnFailure(t *testing.T) {
	tmpDir := t.TempDir()
	staleSymlink := filepath.Join(tmpDir, "stale_symlink")
	_ = os.Symlink(filepath.Join(tmpDir, "dead_link"), staleSymlink)

	// Attempting to replace with nonexistent source must fail
	nonexistentSrc := filepath.Join(tmpDir, "nonexistent_source")
	_, err := safeSymlink(nonexistentSrc, staleSymlink)
	if err == nil {
		t.Fatalf("Expected error when source does not exist, got nil")
	}

	// Verify destination symlink was NOT destroyed before failure
	lfi, lerr := os.Lstat(staleSymlink)
	if lerr != nil {
		t.Fatalf("Destination stale symlink was prematurely removed: %v", lerr)
	}
	if lfi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("Destination is no longer a symlink!")
	}
	target, _ := os.Readlink(staleSymlink)
	if target != filepath.Join(tmpDir, "dead_link") {
		t.Fatalf("Original stale symlink target corrupted!")
	}
}

func TestRollbackPreservesPreExisting(t *testing.T) {
	tmpDir := t.TempDir()

	// Pre-existing valid node
	preExistingNode := filepath.Join(tmpDir, "pre_existing_binder")
	if err := os.WriteFile(preExistingNode, []byte("pre-existing-content"), 0644); err != nil {
		t.Fatal(err)
	}

	// Pre-existing symlink
	preExistingSymlink := filepath.Join(tmpDir, "pre_existing_symlink")
	if err := os.Symlink(preExistingNode, preExistingSymlink); err != nil {
		t.Fatal(err)
	}

	// Newly created resources by current invocation
	newAlloc := filepath.Join(tmpDir, "new_allocated")
	if err := os.WriteFile(newAlloc, []byte("new-alloc"), 0644); err != nil {
		t.Fatal(err)
	}
	newSym := filepath.Join(tmpDir, "new_symlink")
	if err := os.Symlink(newAlloc, newSym); err != nil {
		t.Fatal(err)
	}
	newLegacy := filepath.Join(tmpDir, "new_legacy")
	if err := os.WriteFile(newLegacy, []byte("new-legacy"), 0644); err != nil {
		t.Fatal(err)
	}

	// Execute rollback specifying ONLY newly created items
	rollbackCreated(
		[]string{newAlloc},
		[]string{newSym},
		[]string{newLegacy},
	)

	// Newly created items MUST be removed
	if _, err := os.Lstat(newAlloc); !os.IsNotExist(err) {
		t.Errorf("Expected %s to be removed by rollback, but it still exists", newAlloc)
	}
	if _, err := os.Lstat(newSym); !os.IsNotExist(err) {
		t.Errorf("Expected %s to be removed by rollback, but it still exists", newSym)
	}
	if _, err := os.Lstat(newLegacy); !os.IsNotExist(err) {
		t.Errorf("Expected %s to be removed by rollback, but it still exists", newLegacy)
	}

	// Pre-existing items MUST be preserved
	if _, err := os.Lstat(preExistingNode); err != nil {
		t.Errorf("Pre-existing node was erroneously removed or modified: %v", err)
	}
	content, _ := os.ReadFile(preExistingNode)
	if string(content) != "pre-existing-content" {
		t.Errorf("Pre-existing node content changed: %s", string(content))
	}
	if _, err := os.Lstat(preExistingSymlink); err != nil {
		t.Errorf("Pre-existing symlink was erroneously removed: %v", err)
	}
}

func TestRunInitFullLifecycleAndRollback(t *testing.T) {
	tmpDir := t.TempDir()
	devDir := filepath.Join(tmpDir, "dev")
	mountDir := filepath.Join(devDir, "binderfs")
	sysDir := filepath.Join(tmpDir, "sys")
	procDir := filepath.Join(tmpDir, "proc")

	os.MkdirAll(mountDir, 0755)
	os.MkdirAll(filepath.Join(sysDir, "class/misc"), 0755)
	os.MkdirAll(procDir, 0755)

	// Set up mock proc files
	os.WriteFile(filepath.Join(procDir, "filesystems"), []byte("nodev\tbinder\n"), 0644)
	os.WriteFile(filepath.Join(procDir, "mounts"), []byte("binder /dev/binderfs binder rw,relatime 0 0\n"), 0644)

	// Set up mock sysfs for legacy binder and hwbinder, but intentionally omit vndbinder to trigger failure
	for _, dev := range []string{"binder", "hwbinder"} {
		mDir := filepath.Join(sysDir, "class/misc", dev)
		os.MkdirAll(mDir, 0755)
		os.WriteFile(filepath.Join(mDir, "dev"), []byte("10:237\n"), 0644)
	}

	// Pre-existing valid file in dev
	preExisting := filepath.Join(devDir, "pre_existing")
	os.WriteFile(preExisting, []byte("untouched"), 0644)

	// Executing runInit with missing vndbinder MUST fail and rollback created items
	err := runInit(filepath.Join(mountDir, "binder-control"), mountDir, devDir, sysDir, procDir, true)
	if err == nil {
		t.Fatalf("Expected runInit to fail when vndbinder is missing, got nil")
	}

	// Verify rollback cleaned up newly allocated nodes in devDir
	if _, err := os.Stat(filepath.Join(devDir, "binder")); !os.IsNotExist(err) {
		t.Errorf("Expected newly created /dev/binder to be rolled back on failure")
	}
	if _, err := os.Stat(filepath.Join(devDir, "hwbinder")); !os.IsNotExist(err) {
		t.Errorf("Expected newly created /dev/hwbinder to be rolled back on failure")
	}

	// Verify pre-existing file remains intact
	content, err := os.ReadFile(preExisting)
	if err != nil || string(content) != "untouched" {
		t.Errorf("Pre-existing file was affected during rollback: %v", err)
	}

	// Now add vndbinder sysfs entry and verify successful execution
	vndDir := filepath.Join(sysDir, "class/misc/vndbinder")
	os.MkdirAll(vndDir, 0755)
	os.WriteFile(filepath.Join(vndDir, "dev"), []byte("10:238\n"), 0644)

	err2 := runInit(filepath.Join(mountDir, "binder-control"), mountDir, devDir, sysDir, procDir, true)
	if err2 != nil {
		t.Fatalf("Expected runInit to succeed with all 3 devices, got error: %v", err2)
	}

	// Verify all 3 devices exist in devDir
	for _, dev := range []string{"binder", "hwbinder", "vndbinder"} {
		if _, err := os.Stat(filepath.Join(devDir, dev)); err != nil {
			t.Errorf("Expected /dev/%s to exist after successful runInit: %v", dev, err)
		}
	}

	// Re-running runInit should be idempotent and succeed
	err3 := runInit(filepath.Join(mountDir, "binder-control"), mountDir, devDir, sysDir, procDir, true)
	if err3 != nil {
		t.Fatalf("Expected idempotent runInit to succeed, got error: %v", err3)
	}
}

func TestProcFilesystemsAndMountsParsing(t *testing.T) {
	tmpDir := t.TempDir()
	procDir := filepath.Join(tmpDir, "proc")
	os.MkdirAll(procDir, 0755)

	filesystemsPath := filepath.Join(procDir, "filesystems")
	os.WriteFile(filesystemsPath, []byte("nodev\tsysfs\nnodev\ttmpfs\nnodev\tbinder\n"), 0644)

	if !isBinderfsSupported(procDir) {
		t.Errorf("Expected isBinderfsSupported to return true for proc with binder")
	}

	mountsPath := filepath.Join(procDir, "mounts")
	os.WriteFile(mountsPath, []byte("binder /dev/binderfs binder rw,relatime 0 0\n"), 0644)

	if !isBinderfsMounted("/dev/binderfs", procDir) {
		t.Errorf("Expected isBinderfsMounted to return true for /dev/binderfs")
	}
	if isBinderfsMounted("/dev/other", procDir) {
		t.Errorf("Expected isBinderfsMounted to return false for unmounted path")
	}
}

func TestRejectFakeBinderNull(t *testing.T) {
	tmpDir := t.TempDir()
	devDir := filepath.Join(tmpDir, "dev")
	mountDir := filepath.Join(devDir, "binderfs")
	sysDir := filepath.Join(tmpDir, "sys")
	procDir := filepath.Join(tmpDir, "proc")

	os.MkdirAll(mountDir, 0755)
	os.MkdirAll(filepath.Join(sysDir, "class/misc"), 0755)
	os.MkdirAll(procDir, 0755)

	os.WriteFile(filepath.Join(procDir, "filesystems"), []byte("nodev\tbinder\n"), 0644)
	os.WriteFile(filepath.Join(procDir, "mounts"), []byte("binder /dev/binderfs binder rw,relatime 0 0\n"), 0644)

	// Direct call to validateOrCreateLegacyNode with major 1 must fail
	fakeBinderPath := filepath.Join(devDir, "binder")
	_, err := validateOrCreateLegacyNode(fakeBinderPath, 1, 3, true)
	if err == nil {
		t.Fatalf("Expected validateOrCreateLegacyNode to reject major 1 (/dev/null), got nil")
	}

	// Symlink pointing to real /dev/null must be rejected
	nullSymlink := filepath.Join(devDir, "null_symlink")
	if err := os.Symlink("/dev/null", nullSymlink); err == nil {
		_, err := validateOrCreateLegacyNode(nullSymlink, 10, 237, true)
		if err == nil {
			t.Fatalf("Expected validateOrCreateLegacyNode to reject symlink pointing to /dev/null, got nil")
		}
	}
}

func TestRejectFakeBinderZero(t *testing.T) {
	tmpDir := t.TempDir()
	devDir := filepath.Join(tmpDir, "dev")

	// Direct call to validateOrCreateLegacyNode with major 1 minor 5 must fail
	fakeZeroPath := filepath.Join(devDir, "zero_binder")
	_, err := validateOrCreateLegacyNode(fakeZeroPath, 1, 5, true)
	if err == nil {
		t.Fatalf("Expected validateOrCreateLegacyNode to reject major 1 minor 5 (/dev/zero), got nil")
	}

	// Symlink pointing to real /dev/zero must be rejected
	zeroSymlink := filepath.Join(devDir, "zero_symlink")
	if err := os.Symlink("/dev/zero", zeroSymlink); err == nil {
		_, err := validateOrCreateLegacyNode(zeroSymlink, 10, 237, true)
		if err == nil {
			t.Fatalf("Expected validateOrCreateLegacyNode to reject symlink pointing to /dev/zero, got nil")
		}
	}
}

func TestRejectConflictingDeviceNumbers(t *testing.T) {
	tmpDir := t.TempDir()
	// Real char device /dev/null has major 1, minor 3
	// Testing with a mismatch in minor/major
	if _, err := os.Stat("/dev/null"); err == nil {
		// Try validateOrCreateLegacyNode targeting /dev/null with diff rdev
		_, err := validateOrCreateLegacyNode("/dev/null", 10, 237, true)
		if err == nil {
			t.Fatalf("Expected error when targeting /dev/null with conflicting rdev, got nil")
		}
	}

	// Also test with regular file pretending to be wrong device
	filePath := filepath.Join(tmpDir, "wrong_dev")
	os.WriteFile(filePath, []byte("wrong"), 0644)
	_, err := validateOrCreateLegacyNode(filePath, 10, 237, false)
	if err == nil {
		t.Fatalf("Expected validateOrCreateLegacyNode to fail for regular file in non-test mode")
	}
}

func TestCollisionResistantTempPath(t *testing.T) {
	basePath := "/tmp/test_node"
	path1 := generateCollisionResistantTempPath(basePath)
	path2 := generateCollisionResistantTempPath(basePath)

	if path1 == path2 {
		t.Fatalf("Generated identical temp paths: %s and %s", path1, path2)
	}
	if !filepath.IsAbs(path1) || !filepath.IsAbs(path2) {
		t.Fatalf("Expected absolute paths, got %s and %s", path1, path2)
	}
	pidStr := fmt.Sprintf(".%d.", os.Getpid())
	if !filepath.HasPrefix(filepath.Base(path1), filepath.Base(basePath)+".tmp.") {
		t.Errorf("Path %s does not have expected prefix", path1)
	}
	if !filepath.HasPrefix(filepath.Base(path2), filepath.Base(basePath)+".tmp.") {
		t.Errorf("Path %s does not have expected prefix", path2)
	}
	_ = pidStr
}

