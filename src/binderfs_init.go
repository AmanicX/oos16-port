package main

import (
	"crypto/rand"
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	// BINDER_CTL_ADD = _IOWR('b', 1, struct binderfs_device) = 0xc1086201
	binderCtlAdd = 0xc1086201
	// BINDER_VERSION = _IOWR('b', 9, struct binder_version) = 0xc0046209
	binderVersionIoctl = 0xc0046209
	binderFsNameMax    = 256
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
	if minor > 0xfffff {
		return 0, fmt.Errorf("minor %d exceeds Linux limit (0xfffff)", minor)
	}
	dev := (uint64(major&0xfff) << 8) |
		uint64(minor&0xff) |
		(uint64(major&^uint32(0xfff)) << 32) |
		(uint64(minor&^uint32(0xff)) << 12)
	return int(dev), nil
}

// major extracts 32-bit major number from Linux 64-bit dev_t
func major(dev uint64) uint32 {
	return uint32((dev >> 8) & 0xfff) | uint32((dev >> 32) &^ 0xfff)
}

// minor extracts 32-bit minor number from Linux 64-bit dev_t
func minor(dev uint64) uint32 {
	return uint32(dev & 0xff) | uint32((dev >> 12) &^ 0xff)
}

// generateCollisionResistantTempPath generates a unique, collision-resistant temporary file path
func generateCollisionResistantTempPath(basePath string) string {
	var rnd [8]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		binary.LittleEndian.PutUint64(rnd[:], uint64(time.Now().UnixNano()))
	}
	return fmt.Sprintf("%s.tmp.%d.%x", basePath, os.Getpid(), rnd[:])
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
	if min > 0xfffff {
		return 0, 0, fmt.Errorf("minor %d exceeds supported limit (0xfffff)", min)
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

type OpResult int

const (
	ResultAlreadyValid OpResult = iota
	ResultCreated
)

// validateOrCreateLegacyNode atomically creates a character device node without destroying existing nodes before replacement
func validateOrCreateLegacyNode(destNode string, maj, min uint32, testMode bool) (OpResult, error) {
	if maj == 1 {
		return 0, fmt.Errorf("major 1 is reserved for system memory devices (/dev/null, /dev/zero); refusing fake binder node at %s", destNode)
	}

	devNum, err := mkdev(maj, min)
	if err != nil {
		return 0, fmt.Errorf("invalid dev numbers (%d:%d): %w", maj, min, err)
	}

	if fi, err := os.Lstat(destNode); err == nil {
		if testMode {
			if content, err := os.ReadFile(destNode); err == nil && string(content) == "test-legacy" {
				return ResultAlreadyValid, nil
			}
		}

		if fi.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(destNode)
			if err == nil {
				resolvedTarget := target
				if !filepath.IsAbs(target) {
					resolvedTarget = filepath.Join(filepath.Dir(destNode), target)
				}
				if tfi, err := os.Stat(resolvedTarget); err == nil && (tfi.Mode()&os.ModeCharDevice != 0) {
					st, ok := tfi.Sys().(*syscall.Stat_t)
					if ok && st != nil {
						if major(st.Rdev) == 1 {
							return 0, fmt.Errorf("symlink target %s is a system memory device (major 1); refusing fake binder device", resolvedTarget)
						}
						if st.Rdev == uint64(devNum) {
							return ResultAlreadyValid, nil
						}
					}
				}
			}
			// Stale symlink: do not remove destNode immediately. Create replacement first, then atomic rename.
		} else if fi.Mode()&os.ModeCharDevice != 0 {
			st, ok := fi.Sys().(*syscall.Stat_t)
			if !ok || st == nil {
				return 0, fmt.Errorf("existing character device %s missing Stat_t info; refusing to overwrite", destNode)
			}
			if major(st.Rdev) == 1 {
				return 0, fmt.Errorf("existing character device %s is a system memory device (major 1); refusing fake binder device", destNode)
			}
			if st.Rdev == uint64(devNum) {
				_ = os.Chmod(destNode, 0666)
				return ResultAlreadyValid, nil
			}
			return 0, fmt.Errorf("existing character device %s has conflicting rdev (%d != %d); refusing to overwrite",
				destNode, st.Rdev, devNum)
		} else {
			return 0, fmt.Errorf("target %s exists and is not a character device or symlink (mode: %s); refusing to overwrite",
				destNode, fi.Mode())
		}
	}

	// Create replacement node using collision-resistant temporary name with exclusive creation
	var tmpPath string
	var created bool
	for attempt := 0; attempt < 5; attempt++ {
		candidate := generateCollisionResistantTempPath(destNode)
		if testMode {
			f, err := os.OpenFile(candidate, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0666)
			if err == nil {
				_, _ = f.WriteString("test-legacy")
				_ = f.Close()
				tmpPath = candidate
				created = true
				break
			}
		} else {
			err := syscall.Mknod(candidate, syscall.S_IFCHR|0666, devNum)
			if err == nil {
				tmpPath = candidate
				created = true
				break
			}
		}
	}
	if !created {
		return 0, fmt.Errorf("failed to create exclusive temporary device node for %s after 5 attempts", destNode)
	}

	if err := os.Chmod(tmpPath, 0666); err != nil {
		_ = os.Remove(tmpPath)
		return 0, fmt.Errorf("chmod 0666 on temp node %s failed: %w", tmpPath, err)
	}

	// Atomically replace destination with newly created node
	if err := os.Rename(tmpPath, destNode); err != nil {
		_ = os.Remove(tmpPath)
		return 0, fmt.Errorf("atomic rename %s -> %s failed: %w", tmpPath, destNode, err)
	}

	return ResultCreated, nil
}

// safeSymlink creates or updates a symlink atomically without deleting destPath before creation succeeds
func safeSymlink(srcPath, destPath string) (OpResult, error) {
	if _, err := os.Stat(srcPath); err != nil {
		return 0, fmt.Errorf("source %s does not exist: %w", srcPath, err)
	}

	if fi, err := os.Lstat(destPath); err == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(destPath)
			if err == nil {
				cleanTarget := target
				if !filepath.IsAbs(target) {
					cleanTarget = filepath.Clean(filepath.Join(filepath.Dir(destPath), target))
				}
				cleanSrc := filepath.Clean(srcPath)
				if cleanTarget == cleanSrc {
					return ResultAlreadyValid, nil
				}
			}
		} else if fi.Mode()&os.ModeCharDevice != 0 {
			st, ok := fi.Sys().(*syscall.Stat_t)
			if ok && st != nil {
				srcFi, err := os.Stat(srcPath)
				if err == nil && (srcFi.Mode()&os.ModeCharDevice != 0) {
					srcSt, ok2 := srcFi.Sys().(*syscall.Stat_t)
					if ok2 && srcSt != nil && st.Rdev == srcSt.Rdev {
						_ = os.Chmod(destPath, 0666)
						return ResultAlreadyValid, nil
					}
				}
			}
			return 0, fmt.Errorf("existing char device %s does not match source %s; refusing to overwrite", destPath, srcPath)
		} else {
			return 0, fmt.Errorf("target %s exists and is not a symlink or character device; refusing to overwrite", destPath)
		}
	}

	// Create symlink at collision-resistant temporary path
	var tmpPath string
	var created bool
	for attempt := 0; attempt < 5; attempt++ {
		candidate := generateCollisionResistantTempPath(destPath)
		if err := os.Symlink(srcPath, candidate); err == nil {
			tmpPath = candidate
			created = true
			break
		}
	}
	if !created {
		return 0, fmt.Errorf("failed to create exclusive temporary symlink for %s after 5 attempts", destPath)
	}

	// Atomically replace destination
	if err := os.Rename(tmpPath, destPath); err != nil {
		_ = os.Remove(tmpPath)
		return 0, fmt.Errorf("atomic rename %s -> %s failed: %w", tmpPath, destPath, err)
	}

	return ResultCreated, nil
}

// rollbackCreated cleans up ONLY resources created during the current invocation
func rollbackCreated(newlyAllocated, newlySymlinked, newlyLegacy []string) {
	logKmsg("[BINDERFS_INIT WARNING] Rolling back newly created resources from failed initialization...")
	for _, p := range newlyLegacy {
		if err := os.Remove(p); err == nil {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT] Rolled back newly created legacy device %s", p))
		}
	}
	for _, p := range newlySymlinked {
		if err := os.Remove(p); err == nil {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT] Rolled back newly created symlink %s", p))
		}
	}
	for _, p := range newlyAllocated {
		if err := os.Remove(p); err == nil {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT] Rolled back newly allocated binderfs device %s", p))
		}
	}
}

// runInit coordinates dynamic Binder device allocation, symlink management, and strict verification
func runInit(controlPath, mountPath, devDir, sysDir, procDir string, unitTestMode bool) error {
	logKmsg("[BINDERFS_INIT] Starting dynamic Binder device initialization...")

	devices := []string{"binder", "hwbinder", "vndbinder"}
	var newlyAllocated []string
	var newlySymlinked []string
	var newlyLegacy []string

	// Verify binderfs support and mount state
	if !isBinderfsSupported(procDir) {
		logKmsg("[BINDERFS_INIT WARNING] Kernel /proc/filesystems does not list 'binder' filesystem.")
	} else if !isBinderfsMounted(mountPath, procDir) {
		logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] Binderfs filesystem supported but %s is not mounted as binderfs!", mountPath))
	}

	// 1. Allocate devices in binderfs via binder-control
	controlFd, err := syscall.Open(controlPath, syscall.O_RDWR|syscall.O_CLOEXEC, 0)
	if err == nil {
		defer syscall.Close(controlFd)

		var ctrlMajor uint32
		if ctrlFi, err := os.Stat(controlPath); err == nil {
			if ctrlSt, ok := ctrlFi.Sys().(*syscall.Stat_t); ok && ctrlSt != nil {
				ctrlMajor = major(ctrlSt.Rdev)
			}
		}

		for _, name := range devices {
			targetNode := filepath.Join(mountPath, name)
			if fi, err := os.Lstat(targetNode); err == nil {
				if fi.Mode()&os.ModeCharDevice != 0 {
					if st, ok := fi.Sys().(*syscall.Stat_t); ok && st != nil {
						nodeMaj := major(st.Rdev)
						if nodeMaj == 1 {
							logKmsg(fmt.Sprintf("[BINDERFS_INIT ERROR] Existing node %s has major 1 (fake /dev/null device); refusing!", targetNode))
							rollbackCreated(newlyAllocated, newlySymlinked, newlyLegacy)
							return fmt.Errorf("fake binder device with major 1 detected at %s", targetNode)
						}
						if ctrlMajor > 0 && nodeMaj != ctrlMajor {
							logKmsg(fmt.Sprintf("[BINDERFS_INIT ERROR] Existing node %s has conflicting major (%d != %d); refusing!", targetNode, nodeMaj, ctrlMajor))
							rollbackCreated(newlyAllocated, newlySymlinked, newlyLegacy)
							return fmt.Errorf("conflicting major number for %s", targetNode)
						}
					}
					logKmsg(fmt.Sprintf("[BINDERFS_INIT] Device '%s' already allocated in binderfs", name))
					continue
				}
			}

			var req binderfsDevice
			copy(req.name[:], name)

			var r1 uintptr
			var errSys syscall.Errno
			if unitTestMode {
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
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Successfully allocated new device '%s' in binderfs (major: %d, minor: %d)",
					name, req.major, req.minor))
				if err := os.Chmod(targetNode, 0666); err != nil {
					logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] chmod 0666 failed for %s: %v", targetNode, err))
				}
			} else {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] ioctl BINDER_CTL_ADD failed for '%s': %v", name, errSys))
			}
		}
	} else {
		logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] Cannot open %s: %v. Checking legacy sysfs fallback.", controlPath, err))
	}

	// 2. Establish symlinks /dev/<name> -> /dev/binderfs/<name> or legacy sysfs fallback
	for _, name := range devices {
		srcNode := filepath.Join(mountPath, name)
		destNode := filepath.Join(devDir, name)

		if fi, err := os.Lstat(srcNode); err == nil && (fi.Mode()&os.ModeCharDevice != 0) {
			res, err := safeSymlink(srcNode, destNode)
			if err != nil {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] safeSymlink failed for %s -> %s: %v", destNode, srcNode, err))
			} else {
				if res == ResultCreated {
					newlySymlinked = append(newlySymlinked, destNode)
					logKmsg(fmt.Sprintf("[BINDERFS_INIT] Symlinked newly created %s -> %s", destNode, srcNode))
				} else {
					logKmsg(fmt.Sprintf("[BINDERFS_INIT] Preserved existing valid symlink/device: %s -> %s", destNode, srcNode))
				}
			}
		} else {
			// Check legacy sysfs fallback: /sys/class/misc/<name>/dev
			sysDev := filepath.Join(sysDir, "class/misc", name, "dev")
			content, err := os.ReadFile(sysDev)
			if err == nil {
				maj, min, err := parseSysfsDev(string(content))
				if err != nil {
					logKmsg(fmt.Sprintf("[BINDERFS_INIT ERROR] Malformed sysfs entry %s: %v", sysDev, err))
					continue
				}
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Discovered legacy binder '%s' via sysfs (%d:%d)", name, maj, min))
				res, err := validateOrCreateLegacyNode(destNode, maj, min, unitTestMode)
				if err != nil {
					logKmsg(fmt.Sprintf("[BINDERFS_INIT ERROR] validateOrCreateLegacyNode failed for %s: %v", destNode, err))
				} else {
					if res == ResultCreated {
						newlyLegacy = append(newlyLegacy, destNode)
						logKmsg(fmt.Sprintf("[BINDERFS_INIT] Newly created legacy binder node at %s (%d:%d)", destNode, maj, min))
					} else {
						logKmsg(fmt.Sprintf("[BINDERFS_INIT] Preserved existing valid legacy binder node at %s (%d:%d)", destNode, maj, min))
					}
				}
			}
		}
	}

	// 3. Strict Verification: All three devices must exist, be character devices, non-memory major, and openable O_RDWR
	allOk := true
	for _, name := range devices {
		devPath := filepath.Join(devDir, name)
		fi, err := os.Stat(devPath)
		if err != nil {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Binder device %s does NOT exist!", devPath))
			allOk = false
			continue
		}

		if fi.Mode()&os.ModeCharDevice == 0 && !unitTestMode {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Device %s is NOT a character device! Mode: %s", devPath, fi.Mode()))
			allOk = false
			continue
		}

		if st, ok := fi.Sys().(*syscall.Stat_t); ok && st != nil {
			maj := major(st.Rdev)
			if maj == 1 {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Device %s has major 1 (system memory device /dev/null or /dev/zero); refusing fake binder device!", devPath))
				allOk = false
				continue
			}
		}

		if !unitTestMode {
			fd, err := syscall.Open(devPath, syscall.O_RDWR|syscall.O_CLOEXEC, 0)
			if err != nil {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Failed to open %s with O_RDWR: %v", devPath, err))
				allOk = false
				continue
			}

			// Verify genuine Binder driver via BINDER_VERSION ioctl
			var ver int32
			_, _, errno := syscall.Syscall(
				syscall.SYS_IOCTL,
				uintptr(fd),
				uintptr(binderVersionIoctl),
				uintptr(unsafe.Pointer(&ver)),
			)
			_ = syscall.Close(fd)
			if errno != 0 {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Device %s failed BINDER_VERSION ioctl (errno: %v); not a genuine Binder device!", devPath, errno))
				allOk = false
				continue
			}
			logKmsg(fmt.Sprintf("[BINDERFS_INIT] Binder device %s verified (char device, protocol version %d)", devPath, ver))
		} else {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT] Binder device %s verified (char device, test mode)", devPath))
		}
	}

	if !allOk {
		// Clean up ONLY resources created by this execution without deleting pre-existing valid nodes
		rollbackCreated(newlyAllocated, newlySymlinked, newlyLegacy)
		return fmt.Errorf("critical Binder IPC device initialization failed; newly created resources rolled back")
	}

	logKmsg("[BINDERFS_INIT] All required Binder IPC devices initialized and verified successfully.")
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

	if err := runInit(*controlPath, *mountPath, *devDir, *sysDir, *procDir, *unitTestMode); err != nil {
		logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] %v", err))
		os.Exit(1)
	}
	os.Exit(0)
}
