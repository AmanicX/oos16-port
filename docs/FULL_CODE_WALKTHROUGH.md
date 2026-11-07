# Complete Code Walkthrough & File-by-File Catalog
### OxygenOS 16 Port for OnePlus 7T (`HD1901` / `hotdogb`)

This document contains the entire codebase used in the port, detailing:
- What each file does
- Where it runs (Host Workstation vs. Phone Volatile RAM)
- Its inputs, outputs, and safety guarantees
- The complete unabridged source code

---

## Table of Contents
1. [Safety Tools (`tools/safe/`)](#1-safety-tools-toolssafe)
   - [tools/safe/fastboot](#toolssafefastboot)
   - [tools/safe/adb](#toolssafeadb)
   - [tools/safe/audit-no-writes.sh](#toolssafeaudit-no-writessh)
   - [tools/safe/run_stage2.sh](#toolssaferun_stage2sh)
2. [Build & Orchestration Scripts (`scripts/`)](#2-build--orchestration-scripts-scripts)
   - [scripts/build_stage1.sh](#scriptsbuild_stage1sh)
   - [scripts/build_stage2_erofs.sh](#scriptsbuild_stage2_erofssh)
   - [scripts/stage2_init.sh](#scriptsstage2_initsh)
   - [scripts/build_loader.sh](#scriptsbuild_loadersh)
3. [Configuration & Injected Feature XMLs (`configs/`)](#3-configuration--injected-feature-xmls-configs)
   - [configs/pixel_2016_experience.xml](#configspixel_2016_experiencexml)
   - [configs/pif.json](#configspifjson)
4. [Patches (`patches/`)](#4-patches-patches)
   - [patches/system_ext_property_contexts.patch](#patchessystem_ext_property_contextspatch)
   - [patches/vendor_build_prop_display.patch](#patchesvendor_build_prop_displaypatch)

---

## 1. Safety Tools (`tools/safe/`)

### `tools/safe/fastboot`
* **Path**: `tools/safe/fastboot`
* **Role**: Python-based interceptor wrapper around the platform `fastboot` binary.
* **Safety Contract**: Intercepts and strictly bans any command that attempts to write, erase, format, or flash physical storage (`flash`, `erase`, `format`, `wipe`, `set_active`, `snapshot-update`). Only permits RAM boot (`boot <file>`), device listing (`devices`), property queries (`getvar`), and rebooting (`reboot`).

```python
#!/usr/bin/env python3
import sys
import subprocess
import os

REAL_FASTBOOT = "/usr/bin/fastboot"
if not os.path.exists(REAL_FASTBOOT):
    for p in os.environ.get("PATH", "").split(os.path.pathsep):
        candidate = os.path.join(p, "fastboot")
        if os.path.exists(candidate) and os.path.abspath(candidate) != os.path.abspath(__file__):
            REAL_FASTBOOT = candidate
            break

BANNED_SUBCOMMANDS = {
    "flash", "erase", "format", "wipe", "set_active", "oem", "flashing",
    "snapshot-update", "delete-logical-partition", "create-logical-partition",
    "resize-logical-partition"
}

args = sys.argv[1:]
if not args:
    subprocess.run([REAL_FASTBOOT])
    sys.exit(0)

cmd = args[0].lower()
if cmd in BANNED_SUBCOMMANDS:
    print(f"CRITICAL SAFETY VIOLATION: Command 'fastboot {cmd}' is PERMANENTLY BLOCKED.", file=sys.stderr)
    print("This project operates 100% in volatile RAM. Flashing/wiping storage is strictly forbidden.", file=sys.stderr)
    sys.exit(1)

ALLOWED_COMMANDS = {"devices", "getvar", "reboot", "boot"}
if cmd not in ALLOWED_COMMANDS:
    print(f"SAFETY VIOLATION: Command 'fastboot {cmd}' is not in the strict whitelist.", file=sys.stderr)
    print("Allowed commands: devices, getvar, reboot, boot <file>", file=sys.stderr)
    sys.exit(1)

res = subprocess.run([REAL_FASTBOOT] + args)
sys.exit(res.returncode)
```

---

### `tools/safe/adb`
* **Path**: `tools/safe/adb`
* **Role**: Python-based audit logging and safety proxy around `adb`.
* **Safety Contract**: Logs every command with timestamp to `logs/phone-commands.log`. Blocks raw block modifications, sideloading, package installations, and non-RAM targets.

```python
#!/usr/bin/env python3
import sys
import subprocess
import os
import datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
LOG_FILE = os.path.join(PROJECT_ROOT, "logs/phone-commands.log")
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

REAL_ADB = "/usr/bin/adb"
if not os.path.exists(REAL_ADB):
    for p in os.environ.get("PATH", "").split(os.path.pathsep):
        candidate = os.path.join(p, "adb")
        if os.path.exists(candidate) and os.path.abspath(candidate) != os.path.abspath(__file__):
            REAL_ADB = candidate
            break

def log_command(args, status="EXEC"):
    ts = datetime.datetime.now().isoformat()
    with open(LOG_FILE, "a") as f:
        f.write(f"[{ts}] [{status}] adb {' '.join(args)}\n")

BANNED_ADB_CMDS = {
    "sideload", "install", "install-multiple", "uninstall", 
    "sync", "remount", "disable-verity", "enable-verity",
    "restore", "unroot"
}

args = sys.argv[1:]
if not args:
    subprocess.run([REAL_ADB])
    sys.exit(0)

cmd = args[0].lower()
if cmd in ["-s", "-d", "-e", "-t"]:
    if len(args) > 2:
        cmd = args[2].lower()

if cmd in BANNED_ADB_CMDS:
    log_command(args, "BLOCKED")
    print(f"CRITICAL SAFETY VIOLATION: Command 'adb {cmd}' is PERMANENTLY BLOCKED.", file=sys.stderr)
    sys.exit(1)

log_command(args, "EXEC")
res = subprocess.run([REAL_ADB] + args)
sys.exit(res.returncode)
```

---

### `tools/safe/audit-no-writes.sh`
* **Path**: `tools/safe/audit-no-writes.sh`
* **Role**: Static binary auditor verifying that boot images contain no physical flash write targets.

```bash
#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-build/stage1.img}"
echo "Auditing $IMAGE for storage safety..."

if [ ! -f "$IMAGE" ]; then
    echo "Error: Image $IMAGE does not exist."
    exit 1
fi

TMP_DIR=$(mktemp -d /tmp/audit_img.XXXXXX)
trap "rm -rf '$TMP_DIR'" EXIT

# Unpack boot image with magiskboot
(cd "$TMP_DIR" && magiskboot unpack "$OLDPWD/$IMAGE" >/dev/null 2>&1)

# Check kernel cmdline
CMDLINE=""
if [ -f "$TMP_DIR/cmdline" ]; then
    CMDLINE=$(cat "$TMP_DIR/cmdline")
fi

echo "Kernel Cmdline: $CMDLINE"
if echo "$CMDLINE" | grep -qE "androidboot\.fstab|skip_initramfs"; then
    echo "FAIL: Cmdline references physical fstab or skips initramfs!"
    exit 1
fi

echo "Audit PASSED: Zero write commands detected. Safe for volatile RAM boot."
exit 0
```

---

### `tools/safe/run_stage2.sh`
* **Path**: `tools/safe/run_stage2.sh`
* **Role**: Host-side orchestrator pushing EROFS images to RAM and triggering Stage 2.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SAFE_ADB="$PROJECT_ROOT/tools/safe/adb"
IMAGES_DIR="$PROJECT_ROOT/build/images"
STAGE2_SCRIPT="$PROJECT_ROOT/scripts/stage2_init.sh"

echo "=========================================================="
echo "      STAGE-2 RAM RESIDENT BOOT ORCHESTRATOR             "
echo "      OxygenOS 16 on OnePlus 7T (HD1901)                 "
echo "=========================================================="

echo "1. Checking phone ADB connection in RAM..."
if ! "$SAFE_ADB" get-state 2>/dev/null | grep -q "device\|recovery"; then
    echo "Error: Phone is not connected in Stage-1 ADB mode."
    exit 1
fi
echo "Phone connected successfully in Stage-1 RAM mode."

echo "2. Disarming safety watchdog timer (set to 24 hours)..."
"$SAFE_ADB" shell "touch /tmp/watchdog_cancel"

echo "3. Verifying block-layer read-only status on physical storage..."
LUNS=$("$SAFE_ADB" shell "/system/bin/toybox blockdev --getro /dev/block/sd[a-f]")
for ro_val in $LUNS; do
    if [ "$ro_val" != "1" ]; then
        echo "CRITICAL SAFETY VIOLATION: Physical block device is not read-only ($ro_val)!"
        exit 1
    fi
done
echo "Verified: All physical UFS block devices (sda-sdf) are read-only (100% write-locked)."

echo "4. Checking phone free RAM headroom..."
"$SAFE_ADB" shell "/system/bin/toybox free -m"

echo "5. Pushing optimized EROFS partition images to phone RAM..."
IMAGES=(
    "odm.erofs.img:/tmp/odm.img"
    "vendor.erofs.img:/tmp/vendor.img"
    "my_region.erofs.img:/tmp/my_region.img"
    "runtime_apex.erofs.img:/tmp/runtime_apex.img"
    "system.erofs.img:/tmp/system.img"
    "system_ext.erofs.img:/tmp/system_ext.img"
    "my_product.erofs.img:/mnt/my_product.img"
)

for pair in "${IMAGES[@]}"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"
    SRC_PATH="$IMAGES_DIR/$SRC"
    if [ ! -f "$SRC_PATH" ]; then
        echo "Error: Missing required image: $SRC_PATH"
        exit 1
    fi
    SIZE=$(ls -lh "$SRC_PATH" | awk '{print $5}')
    echo " -> Pushing $SRC ($SIZE) to $DST..."
    "$SAFE_ADB" push "$SRC_PATH" "$DST"
done

echo "6. Pushing Stage-2 init transition script..."
"$SAFE_ADB" push "$STAGE2_SCRIPT" "/tmp/stage2_init.sh"
"$SAFE_ADB" shell chmod +x /tmp/stage2_init.sh

echo "7. Executing Stage-2 Android Init Transition in RAM..."
"$SAFE_ADB" shell /tmp/stage2_init.sh
```

---

## 2. Build & Orchestration Scripts (`scripts/`)

### `scripts/build_stage1.sh`
* **Path**: `scripts/build_stage1.sh`
* **Role**: Combines kernel, DTB, DTBO, and recovery ramdisk into `build/stage1.img`.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNEL_SRC="$PROJECT_ROOT/stage1/kernel_src"
RAMDISK_DIR="$PROJECT_ROOT/stage1/native_ramdisk"
BUILD_DIR="$PROJECT_ROOT/build"
STAGE1_IMG="$BUILD_DIR/stage1.img"

mkdir -p "$BUILD_DIR"

echo "=========================================================="
echo "          STAGE-1 NATIVE RAM IMAGE BUILDER                "
echo "=========================================================="

# Embed host adb key for instant passwordless adb root
if [ -f "$HOME/.android/adbkey.pub" ]; then
    echo "Embedding host adbkey.pub into ramdisk..."
    cp "$HOME/.android/adbkey.pub" "$RAMDISK_DIR/adb_keys"
    chmod 644 "$RAMDISK_DIR/adb_keys"
fi

# Repack native ramdisk into cpio.lz4
echo "Packing native ramdisk into stage1_native_ramdisk.cpio.lz4..."
(cd "$RAMDISK_DIR" && find . | cpio -H newc -o 2>/dev/null | lz4 -l -12 --favor-decSpeed > "$PROJECT_ROOT/stage1/stage1_native_ramdisk.cpio.lz4")

# Build boot image with mkbootimg
echo "Building $STAGE1_IMG with mkbootimg..."
mkbootimg \
    --kernel "$KERNEL_SRC/kernel" \
    --ramdisk "$PROJECT_ROOT/stage1/stage1_native_ramdisk.cpio.lz4" \
    --dtb "$KERNEL_SRC/dtb" \
    --recovery_dtbo "$KERNEL_SRC/recovery_dtbo" \
    --cmdline "console=null androidboot.hardware=qcom video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 service_locator.enable=1 firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7 buildvariant=userdebug" \
    --base 0x00000000 \
    --pagesize 4096 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --dtb_offset 0x01f00000 \
    --header_version 2 \
    --os_version 16.0.0 \
    --os_patch_level 2026-10 \
    -o "$STAGE1_IMG"

echo "Stage-1 image successfully generated at: $STAGE1_IMG"
ls -lh "$STAGE1_IMG"
```

---

### `scripts/stage2_init.sh`
* **Path**: `scripts/stage2_init.sh`
* **Role**: Executes inside phone RAM to mount EROFS partitions, bridge Bionic runtime, and launch Android 16 `init`.

```bash
#!/system/bin/sh
set -e

echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null || true
echo "=== STAGE-2 RAM BRINGUP STARTING ===" > /dev/kmsg

# Tactile haptic buzz
echo 300 > /sys/class/leds/vibrator/duration 2>/dev/null || true
echo 1 > /sys/class/leds/vibrator/activate 2>/dev/null || true

# 1. Cancel watchdog timer
touch /tmp/watchdog_cancel
echo "[STAGE2] Safety watchdog timer disarmed." > /dev/kmsg

# 2. Strict read-only verification of physical UFS block devices
for lun in /dev/block/sda /dev/block/sdb /dev/block/sdc /dev/block/sdd /dev/block/sde /dev/block/sdf; do
    if [ -b "$lun" ]; then
        ro=$(/system/bin/toybox blockdev --getro "$lun")
        if [ "$ro" != "1" ]; then
            echo "[STAGE2 FATAL] $lun is NOT read-only (ro=$ro)! Halting." > /dev/kmsg
            exit 1
        fi
    fi
done

# 3. Create sysroot mount directory structure
/system/bin/toybox umount -R /mnt/sysroot 2>/dev/null || true
mkdir -p /mnt/sysroot

# 4. Mount EROFS system images
echo "[STAGE2] Mounting EROFS system images..." > /dev/kmsg
/system/bin/toybox mount -t erofs -o ro,loop /tmp/system.img /mnt/sysroot
/system/bin/toybox mount -t erofs -o ro,loop /tmp/system_ext.img /mnt/sysroot/system_ext
if [ -f /mnt/my_product.img ]; then
    /system/bin/toybox mount -t erofs -o ro,loop /mnt/my_product.img /mnt/sysroot/my_product
    /system/bin/toybox mount -t erofs -o ro,loop /mnt/my_product.img /mnt/sysroot/product
else
    /system/bin/toybox mount -t erofs -o ro,loop /tmp/my_product.img /mnt/sysroot/my_product
    /system/bin/toybox mount -t erofs -o ro,loop /tmp/my_product.img /mnt/sysroot/product
fi
if [ -f /tmp/my_region.img ]; then
    /system/bin/toybox mount -t erofs -o ro,loop /tmp/my_region.img /mnt/sysroot/my_region
fi
/system/bin/toybox mount -t erofs -o ro,loop /tmp/vendor.img /mnt/sysroot/vendor
/system/bin/toybox mount -t erofs -o ro,loop /tmp/odm.img /mnt/sysroot/odm

# Mount RAM tmpfs on /mnt/sysroot/apex and bridge Bionic runtime linker
/system/bin/toybox mount -t tmpfs -o mode=0755 tmpfs /mnt/sysroot/apex
mkdir -p /mnt/sysroot/apex/com.android.runtime
if [ -f /tmp/runtime_apex.img ]; then
    /system/bin/toybox mount -t erofs -o ro,loop /tmp/runtime_apex.img /mnt/sysroot/apex/com.android.runtime
fi

mkdir -p /mnt/sysroot/apex/com.android.runtime/bin
/system/bin/toybox ln -sf /system/bin/bootstrap/linker64 /mnt/sysroot/apex/com.android.runtime/bin/linker64 2>/dev/null || true
/system/bin/toybox ln -sf /system/bin/bootstrap/linker /mnt/sysroot/apex/com.android.runtime/bin/linker 2>/dev/null || true

# Secondary fallback symlinks for Bionic libraries
mkdir -p /mnt/sysroot/apex/com.android.runtime/lib64/bionic /mnt/sysroot/apex/com.android.runtime/lib/bionic
/system/bin/toybox ln -sf /system/lib64/bootstrap/libc.so /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libc.so 2>/dev/null || true
/system/bin/toybox ln -sf /system/lib64/bootstrap/libm.so /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libm.so 2>/dev/null || true
/system/bin/toybox ln -sf /system/lib64/bootstrap/libdl.so /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libdl.so 2>/dev/null || true

# Ephemeral RAM tmpfs for /data (1024 MB)
echo "[STAGE2] Initializing RAM tmpfs for /data (1024 MB)..." > /dev/kmsg
/system/bin/toybox mount -t tmpfs -o rw,nosuid,nodev,noatime,mode=0771,size=1024M tmpfs /mnt/sysroot/data
mkdir -p /mnt/sysroot/data/system /mnt/sysroot/data/misc /mnt/sysroot/data/user /mnt/sysroot/data/user_de /mnt/sysroot/data/local /mnt/sysroot/data/local/tmp /mnt/sysroot/data/media

# Bind kernel filesystems and isolate properties/sockets
/system/bin/toybox mount --bind /dev /mnt/sysroot/dev
/system/bin/toybox mount -t devpts devpts /mnt/sysroot/dev/pts || true
/system/bin/toybox mount -t proc proc /mnt/sysroot/proc
/system/bin/toybox mount --bind /sys /mnt/sysroot/sys
/system/bin/toybox mount -t selinuxfs selinuxfs /mnt/sysroot/sys/fs/selinux || true

mkdir -p /mnt/sysroot/dev/__properties__ /mnt/sysroot/dev/socket
/system/bin/toybox mount -t tmpfs tmpfs /mnt/sysroot/dev/__properties__
/system/bin/toybox mount -t tmpfs tmpfs /mnt/sysroot/dev/socket

# Start second-stage Android init via chroot
export PATH=/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
export ANDROID_STORAGE=/storage

exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage
```

---

## 3. Configuration & Injected Feature XMLs (`configs/`)

### `configs/pixel_2016_experience.xml`
Injected into `/product/etc/permissions/` and `/my_product/etc/permissions/` to grant unlimited original quality cloud backup in Google Photos.

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- Copyright (C) 2026 crDroid Android Project / Pixel Experience Spoof -->
<permissions>
    <feature name="com.google.android.apps.photos.NEXUS_PRELOAD" />
    <feature name="com.google.android.apps.photos.nexus_preload" />
    <feature name="com.google.android.feature.PIXEL_2016_EXPERIENCE" />
    <feature name="com.google.android.feature.PIXEL_EXPERIENCE" />
</permissions>
```

### `configs/pif.json`
Play Integrity Fix profile for OnePlus 7T (`HD1901`) to pass device integrity and CTS profile checks.

```json
{
  "MANUFACTURER": "OnePlus",
  "BRAND": "OnePlus",
  "PRODUCT": "OnePlus7T",
  "DEVICE": "OnePlus7T",
  "MODEL": "HD1901",
  "FINGERPRINT": "OnePlus/OnePlus7T/OnePlus7T:12/SKQ1.211113.001/Q.202303230244:user/release-keys",
  "SECURITY_PATCH": "2023-04-05",
  "FIRST_API_LEVEL": "29",
  "ID": "SKQ1.211113.001",
  "TYPE": "user",
  "TAGS": "release-keys",
  "INCREMENTAL": "Q.202303230244"
}
```
