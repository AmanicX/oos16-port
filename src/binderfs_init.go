package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

const (
	// BINDER_CTL_ADD = _IOWR('b', 1, struct binderfs_device) = 0xc1086201
	binderCtlAdd    = 0xc1086201
	binderFsNameMax = 256
	// BINDERFS_SUPER_MAGIC = 0x6c6f6f70
	binderFsSuperMagic = 0x6c6f6f70
)

// binderfsDevice represents struct binderfs_device from linux/android/binderfs.h
type binderfsDevice struct {
	name  [binderFsNameMax]byte
	major uint32
	minor uint32
}

func logKmsg(msg string) {
	fmt.Println(msg)
	f, err := os.OpenFile("/dev/kmsg", os.O_WRONLY|os.O_APPEND, 0)
	if err == nil {
		_, _ = f.WriteString(msg + "\n")
		_ = f.Close()
	}
}

// mkdev implements standard Linux 64-bit dev_t encoding (new_encode_dev / sysmacros.h):
// ((major & 0xfff) << 8) | (minor & 0xff) | ((major & ~0xfff) << 32) | ((minor & ~0xff) << 12)
func mkdev(major, minor uint32) (int, error) {
	if major > 0xfffff {
		return 0, fmt.Errorf("major %d exceeds Linux limit (0xfffff)", major)
	}
	dev := (uint64(major&0xfff) << 8) |
		uint64(minor&0xff) |
		(uint64(major&^uint32(0xfff)) << 32) |
		(uint64(minor&^uint32(0xff)) << 12)
	return int(dev), nil
}

// parseSysfsDev parses /sys/class/misc/<name>/dev in strict <major>:<minor> format
func parseSysfsDev(content string) (uint32, uint32, error) {
	trimmed := strings.TrimSpace(content)
	if trimmed == "" {
		return 0, 0, fmt.Errorf("empty sysfs dev entry")
	}
	parts := strings.Split(trimmed, ":")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("malformed sysfs dev format (expected maj:min): '%s'", trimmed)
	}
	maj64, err := strconv.ParseUint(parts[0], 10, 32)
	if err != nil {
		return 0, 0, fmt.Errorf("invalid major '%s': %w", parts[0], err)
	}
	min64, err := strconv.ParseUint(parts[1], 10, 32)
	if err != nil {
		return 0, 0, fmt.Errorf("invalid minor '%s': %w", parts[1], err)
	}
	maj := uint32(maj64)
	min := uint32(min64)
	if maj > 0xfffff {
		return 0, 0, fmt.Errorf("major %d exceeds supported limit (0xfffff)", maj)
	}
	return maj, min, nil
}

// isBinderfsSupported checks if the kernel exposes the 'binder' filesystem in /proc/filesystems
func isBinderfsSupported(procDir string) bool {
	data, err := os.ReadFile(filepath.Join(procDir, "filesystems"))
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[len(fields)-1] == "binder" {
			return true
		}
	}
	return false
}

// isBinderfsMounted checks if mountPath is mounted as binder filesystem
func isBinderfsMounted(mountPath string, procDir string) bool {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(mountPath, &stat); err == nil {
		if stat.Type == binderFsSuperMagic {
			return true
		}
	}
	// Fallback to /proc/mounts
	if data, err := os.ReadFile(filepath.Join(procDir, "mounts")); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 3 && fields[1] == mountPath && fields[2] == "binder" {
				return true
			}
		}
	}
	return false
}

// validateOrCreateLegacyNode safely creates a character device node without overwriting unrelated files
func validateOrCreateLegacyNode(destNode string, maj, min uint32, testMode bool) error {
	devNum, err := mkdev(maj, min)
	if err != nil {
		return fmt.Errorf("invalid dev numbers (%d:%d): %w", maj, min, err)
	}

	if fi, err := os.Lstat(destNode); err == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(destNode)
			if err == nil {
				if tfi, err := os.Stat(target); err == nil && (tfi.Mode()&os.ModeCharDevice != 0) {
					return nil
				}
			}
			if err := os.Remove(destNode); err != nil {
				return fmt.Errorf("failed to remove stale symlink %s: %w", destNode, err)
			}
		} else if fi.Mode()&os.ModeCharDevice != 0 {
			st, ok := fi.Sys().(*syscall.Stat_t)
			if ok && st != nil && st.Rdev == uint64(devNum) {
				return os.Chmod(destNode, 0666)
			}
			return fmt.Errorf("existing character device %s has conflicting rdev (%d != %d); refusing to overwrite", destNode, st.Rdev, devNum)
		} else {
			return fmt.Errorf("path %s already exists and is not a binder device (mode: %s); refusing to overwrite", destNode, fi.Mode())
		}
	}

	if testMode {
		return os.WriteFile(destNode, []byte("test-legacy"), 0666)
	}

	if err := syscall.Mknod(destNode, syscall.S_IFCHR|0666, devNum); err != nil {
		return fmt.Errorf("mknod failed for %s (dev %d): %w", destNode, devNum, err)
	}
	if err := os.Chmod(destNode, 0666); err != nil {
		return fmt.Errorf("chmod failed for %s: %w", destNode, err)
	}
	return nil
}

// safeSymlink creates a symlink from destNode to srcNode, strictly validating types
func safeSymlink(srcNode, destNode string) error {
	fi, err := os.Stat(srcNode)
	if err != nil {
		return fmt.Errorf("source node %s does not exist: %w", srcNode, err)
	}
	if fi.Mode()&os.ModeCharDevice == 0 {
		return fmt.Errorf("source node %s is not a character device (mode: %s)", srcNode, fi.Mode())
	}

	if lfi, err := os.Lstat(destNode); err == nil {
		if lfi.Mode()&os.ModeSymlink != 0 {
			target, _ := os.Readlink(destNode)
			rel, _ := filepath.Rel(filepath.Dir(destNode), srcNode)
			if target == srcNode || target == rel {
				_ = os.Chmod(srcNode, 0666)
				return nil
			}
			if err := os.Remove(destNode); err != nil {
				return fmt.Errorf("failed to remove existing symlink %s: %w", destNode, err)
			}
		} else if lfi.Mode()&os.ModeCharDevice != 0 {
			// Direct char device node at destNode
			_ = os.Chmod(destNode, 0666)
			return nil
		} else {
			return fmt.Errorf("destination %s exists and is not a symlink/char-device (mode: %s); refusing to overwrite", destNode, lfi.Mode())
		}
	}

	relPath := srcNode
	if rel, err := filepath.Rel(filepath.Dir(destNode), srcNode); err == nil {
		relPath = rel
	}

	if err := os.Symlink(relPath, destNode); err != nil {
		return fmt.Errorf("symlink %s -> %s failed: %w", destNode, relPath, err)
	}
	if err := os.Chmod(srcNode, 0666); err != nil {
		return fmt.Errorf("chmod source node %s failed: %w", srcNode, err)
	}
	return nil
}

func main() {
	controlPath := flag.String("control", "/dev/binderfs/binder-control", "Path to binder-control device")
	mountPath := flag.String("mount", "/dev/binderfs", "Path to binderfs mountpoint")
	devDir := flag.String("dev", "/dev", "Path to /dev directory for symlinks")
	sysDir := flag.String("sys", "/sys", "Path to /sys directory for legacy sysfs fallback")
	procDir := flag.String("proc", "/proc", "Path to /proc directory")
	unitTestMode := flag.Bool("unit-test", false, "Unit test execution flag (isolated, no live kernel calls)")
	flag.Parse()

	devices := []string{"binder", "hwbinder", "vndbinder"}
	logKmsg("[BINDERFS_INIT] Starting dynamic Binder device initialization...")

	// 1. Verify kernel driver support
	binderfsSupported := isBinderfsSupported(*procDir)
	binderfsMounted := isBinderfsMounted(*mountPath, *procDir)

	if !binderfsSupported {
		logKmsg("[BINDERFS_INIT INFO] Kernel /proc/filesystems does not report 'binder' filesystem. Will attempt direct control node or legacy fallback.")
	} else if !binderfsMounted {
		logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] Binderfs filesystem supported but %s is not mounted as binderfs!", *mountPath))
	} else {
		logKmsg(fmt.Sprintf("[BINDERFS_INIT] Verified binderfs filesystem mounted at %s.", *mountPath))
	}

	var newlyAllocated []string
	controlFd, err := syscall.Open(*controlPath, syscall.O_RDONLY|syscall.O_CLOEXEC, 0)
	controlAvailable := (err == nil)
	if controlAvailable {
		defer syscall.Close(controlFd)
		logKmsg(fmt.Sprintf("[BINDERFS_INIT] Opened binder-control at %s", *controlPath))

		for _, name := range devices {
			targetNode := filepath.Join(*mountPath, name)
			if fi, err := os.Stat(targetNode); err == nil && (fi.Mode()&os.ModeCharDevice != 0) {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Device %s already exists in %s", name, *mountPath))
				continue
			}

			var req binderfsDevice
			copy(req.name[:], name)

			var r1 uintptr
			var errSys error
			if *unitTestMode {
				r1 = 0
				_ = os.WriteFile(targetNode, []byte("unit-test"), 0666)
			} else {
				r1, _, errSys = syscall.Syscall(
					syscall.SYS_IOCTL,
					uintptr(controlFd),
					uintptr(binderCtlAdd),
					uintptr(unsafe.Pointer(&req)),
				)
			}

			if r1 == 0 {
				newlyAllocated = append(newlyAllocated, targetNode)
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Successfully allocated '%s' in binderfs (major: %d, minor: %d)",
					name, req.major, req.minor))
				if err := os.Chmod(targetNode, 0666); err != nil {
					logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] chmod 0666 failed for %s: %v", targetNode, err))
				}
			} else {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] ioctl BINDER_CTL_ADD failed for '%s': %v", name, errSys))
			}
		}
	} else {
		logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] Cannot open %s: %v. Checking legacy sysfs fallback.", *controlPath, err))
	}

	// 2. Establish symlinks /dev/<name> -> /dev/binderfs/<name> or legacy sysfs fallback
	for _, name := range devices {
		srcNode := filepath.Join(*mountPath, name)
		destNode := filepath.Join(*devDir, name)

		if fi, err := os.Lstat(srcNode); err == nil && (fi.Mode()&os.ModeCharDevice != 0) {
			if err := safeSymlink(srcNode, destNode); err != nil {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] safeSymlink failed for %s -> %s: %v", destNode, srcNode, err))
			} else {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Symlinked %s -> %s", destNode, srcNode))
			}
		} else {
			// Check legacy sysfs fallback: /sys/class/misc/<name>/dev
			sysDev := filepath.Join(*sysDir, "class/misc", name, "dev")
			content, err := os.ReadFile(sysDev)
			if err == nil {
				maj, min, err := parseSysfsDev(string(content))
				if err != nil {
					logKmsg(fmt.Sprintf("[BINDERFS_INIT ERROR] Malformed sysfs entry %s: %v", sysDev, err))
					continue
				}
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Discovered legacy binder '%s' via sysfs (%d:%d)", name, maj, min))
				if err := validateOrCreateLegacyNode(destNode, maj, min, *unitTestMode); err != nil {
					logKmsg(fmt.Sprintf("[BINDERFS_INIT ERROR] validateOrCreateLegacyNode failed for %s: %v", destNode, err))
				} else {
					logKmsg(fmt.Sprintf("[BINDERFS_INIT] Legacy binder node verified at %s (%d:%d)", destNode, maj, min))
				}
			}
		}
	}

	// 3. Strict Verification: All three devices must exist, be character devices, and openable O_RDWR
	allOk := true
	for _, name := range devices {
		devPath := filepath.Join(*devDir, name)
		fi, err := os.Stat(devPath)
		if err != nil {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Binder device %s does NOT exist!", devPath))
			allOk = false
			continue
		}

		if !*unitTestMode && (fi.Mode()&os.ModeCharDevice == 0) {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Device %s is NOT a character device! Mode: %s", devPath, fi.Mode()))
			allOk = false
			continue
		}

		if !*unitTestMode {
			fd, err := syscall.Open(devPath, syscall.O_RDWR|syscall.O_CLOEXEC, 0)
			if err != nil {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Failed to open %s with O_RDWR: %v", devPath, err))
				allOk = false
				continue
			}
			_ = syscall.Close(fd)
		}
		logKmsg(fmt.Sprintf("[BINDERFS_INIT] Binder device %s verified (char device, openable O_RDWR)", devPath))
	}

	if !allOk {
		// Clean up partial allocations to avoid inconsistent state
		for _, node := range newlyAllocated {
			_ = os.Remove(node)
		}
		logKmsg("[BINDERFS_INIT FATAL] Critical Binder IPC device initialization FAILED! Partial state cleaned up.")
		os.Exit(1)
	}

	logKmsg("[BINDERFS_INIT] All required Binder IPC devices initialized and verified successfully.")
	os.Exit(0)
}
