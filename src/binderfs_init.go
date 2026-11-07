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
)

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

func main() {
	controlPath := flag.String("control", "/dev/binderfs/binder-control", "Path to binder-control device")
	mountPath := flag.String("mount", "/dev/binderfs", "Path to binderfs mountpoint")
	devDir := flag.String("dev", "/dev", "Path to /dev directory for symlinks")
	sysDir := flag.String("sys", "/sys", "Path to /sys directory for legacy sysfs fallback")
	testMode := flag.Bool("test", false, "Test mode for host unit tests")
	flag.Parse()

	devices := []string{"binder", "hwbinder", "vndbinder"}
	logKmsg("[BINDERFS_INIT] Starting dynamic Binder device initialization...")

	// 1. Attempt allocation via binder-control
	controlFd, err := syscall.Open(*controlPath, syscall.O_RDONLY|syscall.O_CLOEXEC, 0)
	controlAvailable := (err == nil)
	if controlAvailable {
		defer syscall.Close(controlFd)
		logKmsg(fmt.Sprintf("[BINDERFS_INIT] Opened binder-control at %s", *controlPath))

		for _, name := range devices {
			targetNode := filepath.Join(*mountPath, name)
			// Check if already exists in binderfs
			if fi, err := os.Stat(targetNode); err == nil && (fi.Mode()&os.ModeCharDevice != 0) {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Device %s already exists in %s", name, *mountPath))
				continue
			}

			var req binderfsDevice
			copy(req.name[:], name)

			var r1 uintptr
			var errSys error
			if *testMode {
				// In test mode without root/kernel ioctl, simulate device node creation
				_ = os.WriteFile(targetNode, []byte("mock-char-device"), 0666)
				r1 = 0
			} else {
				r1, _, errSys = syscall.Syscall(
					syscall.SYS_IOCTL,
					uintptr(controlFd),
					uintptr(binderCtlAdd),
					uintptr(unsafe.Pointer(&req)),
				)
			}

			if r1 == 0 {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Successfully allocated '%s' in binderfs (major: %d, minor: %d)",
					name, req.major, req.minor))
				_ = os.Chmod(targetNode, 0666)
			} else {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] ioctl BINDER_CTL_ADD failed for '%s': %v", name, errSys))
			}
		}
	} else {
		logKmsg(fmt.Sprintf("[BINDERFS_INIT WARNING] Cannot open %s: %v. Checking legacy fallback.", *controlPath, err))
	}

	// 2. Establish symlinks /dev/<name> -> /dev/binderfs/<name>
	for _, name := range devices {
		srcNode := filepath.Join(*mountPath, name)
		destNode := filepath.Join(*devDir, name)

		if fi, err := os.Lstat(srcNode); err == nil && (fi.Mode()&os.ModeCharDevice != 0 || *testMode) {
			_ = os.Remove(destNode)
			relPath := srcNode
			if rel, err := filepath.Rel(*devDir, srcNode); err == nil {
				relPath = rel
			}
			if err := os.Symlink(relPath, destNode); err == nil {
				logKmsg(fmt.Sprintf("[BINDERFS_INIT] Symlinked %s -> %s", destNode, relPath))
			}
			_ = os.Chmod(srcNode, 0666)
			_ = os.Chmod(destNode, 0666)
		} else {
			// Check legacy sysfs fallback: /sys/class/misc/<name>/dev
			sysDev := filepath.Join(*sysDir, "class/misc", name, "dev")
			if content, err := os.ReadFile(sysDev); err == nil {
				parts := strings.Split(strings.TrimSpace(string(content)), ":")
				if len(parts) == 2 {
					maj, _ := strconv.Atoi(parts[0])
					min, _ := strconv.Atoi(parts[1])
					logKmsg(fmt.Sprintf("[BINDERFS_INIT] Discovered legacy binder '%s' via sysfs (%d:%d)", name, maj, min))
					if _, err := os.Stat(destNode); os.IsNotExist(err) {
						if *testMode {
							_ = os.WriteFile(destNode, []byte("mock-legacy"), 0666)
						} else {
							devNum := (maj << 8) | min
							_ = syscall.Mknod(destNode, syscall.S_IFCHR|0666, devNum)
						}
					}
					_ = os.Chmod(destNode, 0666)
				}
			}
		}
	}

	// 3. Strict Verification: All three devices must exist, be character devices, and openable
	allOk := true
	for _, name := range devices {
		devPath := filepath.Join(*devDir, name)
		fi, err := os.Stat(devPath)
		if err != nil {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Binder device %s does NOT exist!", devPath))
			allOk = false
			continue
		}

		if !*testMode && (fi.Mode()&os.ModeCharDevice == 0) {
			logKmsg(fmt.Sprintf("[BINDERFS_INIT FATAL] Device %s is NOT a character device! Mode: %s", devPath, fi.Mode()))
			allOk = false
			continue
		}

		// Verify openable
		if !*testMode {
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
		logKmsg("[BINDERFS_INIT FATAL] Critical Binder IPC device initialization FAILED!")
		os.Exit(1)
	}

	logKmsg("[BINDERFS_INIT] All required Binder IPC devices initialized and verified successfully.")
	os.Exit(0)
}
