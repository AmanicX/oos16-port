#!/usr/bin/env bash
# ==============================================================================
# run_stage2.sh - Host-Side Orchestrator for Stage-2 RAM-Resident OxygenOS 16
# Enforces dynamic physical device write locks, active host heartbeat,
# image staging to volatile RAM (/mnt/), and Stage-1 supervisor activation.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SAFE_ADB="$PROJECT_ROOT/tools/safe/adb"
IMAGES_DIR="${IMAGES_DIR:-$PROJECT_ROOT/build/images}"

echo "=========================================================="
echo "      STAGE-2 RAM RESIDENT BOOT ORCHESTRATOR             "
echo "      OxygenOS 16 on OnePlus 7T (HD1901)                 "
echo "=========================================================="

# 1. Verify phone connection
echo "1. Checking phone ADB connection in RAM mode..."
if ! "$SAFE_ADB" get-state 2>/dev/null | grep -qE "device|recovery"; then
    echo "Error: Phone is not connected in Stage-1 ADB mode." >&2
    echo "Please boot Stage-1 first using: tools/safe/fastboot boot build/stage1.img (or build/loader.img)" >&2
    exit 1
fi
echo "Phone connected successfully in Stage-1 RAM mode."

# 2. Dynamic Physical Storage Device Detection (Metacharacter-free ADB commands)
echo "2. Dynamically detecting physical storage devices on target..."
DISCOVERED_PHYSICAL_DEVS=()

# Query sysfs block devices on target using safe diagnostic 'ls -1 /sys/block'
BLOCK_ENTRIES=$("$SAFE_ADB" shell "ls -1 /sys/block" | tr -d '\r')

for bdev in $BLOCK_ENTRIES; do
    [ -z "$bdev" ] && continue
    # Skip virtual loop devices, zram, and RAM disks
    if [[ "$bdev" =~ ^(loop|ram|zram|dm-) ]]; then
        continue
    fi

    # Check physical hardware device backing node using safe test command
    if "$SAFE_ADB" shell "test -e /sys/block/$bdev/device" >/dev/null 2>&1; then
        DISCOVERED_PHYSICAL_DEVS+=("/dev/block/$bdev")
    elif [[ "$bdev" =~ ^(sd[a-z]|mmcblk[0-9]) ]]; then
        # Known physical storage prefix fallback
        DISCOVERED_PHYSICAL_DEVS+=("/dev/block/$bdev")
    fi
done

if [ "${#DISCOVERED_PHYSICAL_DEVS[@]}" -eq 0 ]; then
    echo "CRITICAL ERROR: No physical storage devices could be identified on target!" >&2
    echo "Refusing to proceed without verifying physical disk write locks." >&2
    exit 1
fi

echo "Identified physical storage devices: ${DISCOVERED_PHYSICAL_DEVS[*]}"

# 3. Verify Block Layer Read-Only Status on All Discovered Physical Devices
echo "3. Verifying block-layer write-lock (ro=1) on all physical devices..."
for dev_path in "${DISCOVERED_PHYSICAL_DEVS[@]}"; do
    ro_val=$("$SAFE_ADB" shell "blockdev --getro $dev_path" 2>/dev/null | tr -d '\r\n[:space:]')
    if [ "$ro_val" != "1" ]; then
        echo "CRITICAL SAFETY VIOLATION: Device $dev_path is NOT read-only (ro=$ro_val)!" >&2
        echo "Halting immediately to protect physical internal storage." >&2
        exit 1
    fi
    echo "  Verified: $dev_path is read-only (ro=1)"
done

# Check live mount table to ensure zero physical block devices are mounted writable
WRITABLE_MOUNTS=$("$SAFE_ADB" shell "mount" | grep -E "^/dev/block/(sd|mmcblk)" | grep -v "ro," || true)
if [ -n "$WRITABLE_MOUNTS" ]; then
    echo "CRITICAL SAFETY VIOLATION: Detected writable physical partition mount:" >&2
    echo "$WRITABLE_MOUNTS" >&2
    exit 1
fi
echo "Verified: Zero physical storage devices mounted writable."

# 4. Start Active Host Heartbeat Loop
echo "4. Starting active host safety heartbeat loop..."
# Sends heartbeat signal to /mnt/watchdog_heartbeat every 10 seconds.
# Stage-1 watchdog resets on each heartbeat. If host disconnects, Stage-1 reboots to bootloader after timeout.
(
    while true; do
        "$SAFE_ADB" shell "touch /mnt/watchdog_heartbeat" >/dev/null 2>&1 || true
        sleep 10
    done
) >/dev/null 2>&1 &
HEARTBEAT_PID=$!
trap 'kill -9 "$HEARTBEAT_PID" 2>/dev/null || true' EXIT
echo "Active host heartbeat loop running (PID: $HEARTBEAT_PID targeting /mnt/watchdog_heartbeat)."

# 5. Check Available RAM on Phone
echo "5. Checking free volatile RAM on target..."
"$SAFE_ADB" shell "free -m"

# 6. Push Partition Images to Phone RAM (/mnt/)
echo "6. Pushing verified partition images to phone volatile RAM (/mnt/)..."
# Mandatory images required for Android bringup
MANDATORY_IMAGES=(
    "system.erofs.img:/mnt/system.img"
    "system_ext.erofs.img:/mnt/system_ext.img"
    "vendor.erofs.img:/mnt/vendor.img"
    "odm.erofs.img:/mnt/odm.img"
)

# Product image resolution (my_product.erofs.img vs product.erofs.img)
if [ -f "$IMAGES_DIR/my_product.erofs.img" ]; then
    MANDATORY_IMAGES+=("my_product.erofs.img:/mnt/product.img")
elif [ -f "$IMAGES_DIR/product.erofs.img" ]; then
    MANDATORY_IMAGES+=("product.erofs.img:/mnt/product.img")
else
    echo "CRITICAL ERROR: Neither my_product.erofs.img nor product.erofs.img found in $IMAGES_DIR!" >&2
    exit 1
fi

# Optional partition images
OPTIONAL_IMAGES=()
if [ -f "$IMAGES_DIR/my_region.erofs.img" ]; then
    OPTIONAL_IMAGES+=("my_region.erofs.img:/mnt/my_region.img")
fi
if [ -f "$IMAGES_DIR/runtime_apex.img" ]; then
    OPTIONAL_IMAGES+=("runtime_apex.img:/mnt/runtime_apex.img")
fi
if [ -f "$IMAGES_DIR/runtime_apex.fstype" ]; then
    OPTIONAL_IMAGES+=("runtime_apex.fstype:/mnt/runtime_apex.fstype")
fi

ALL_IMAGES=("${MANDATORY_IMAGES[@]}" "${OPTIONAL_IMAGES[@]}")

# Validate mandatory image sources exist and are non-empty before pushing anything
for pair in "${MANDATORY_IMAGES[@]}"; do
    SRC="${pair%%:*}"
    SRC_PATH="$IMAGES_DIR/$SRC"
    if [ ! -f "$SRC_PATH" ] || [ ! -s "$SRC_PATH" ]; then
        echo "CRITICAL ERROR: Mandatory image $SRC_PATH does not exist or is 0 bytes!" >&2
        exit 1
    fi
done

for pair in "${ALL_IMAGES[@]}"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"
    SRC_PATH="$IMAGES_DIR/$SRC"
    SIZE=$(ls -lh "$SRC_PATH" | awk '{print $5}')
    echo " -> Pushing $SRC ($SIZE) to $DST..."
    "$SAFE_ADB" push "$SRC_PATH" "$DST"

    # Verify image transfer completed successfully on target
    if ! "$SAFE_ADB" shell "test -f $DST" >/dev/null 2>&1; then
        echo "CRITICAL ERROR: Failed to verify staged image $DST on target device!" >&2
        exit 1
    fi
done

# If my_product image was staged as /mnt/product.img, also stage /mnt/my_product.img
if [ -f "$IMAGES_DIR/my_product.erofs.img" ]; then
    echo " -> Staging /mnt/my_product.img for ColorOS/OxygenOS compatibility..."
    "$SAFE_ADB" push "$IMAGES_DIR/my_product.erofs.img" "/mnt/my_product.img"
fi

echo "All required images successfully staged in target volatile RAM."

# 7. Activate Stage-1 Boot Trigger (/mnt/boot_now)
echo "7. Activating Stage-1 PID 1 boot supervisor trigger (/mnt/boot_now)..."
"$SAFE_ADB" shell "touch /mnt/boot_now"

echo "=========================================================="
echo "Boot trigger (/mnt/boot_now) sent to Stage-1 Supervisor."
echo "Stage-1 PID 1 will now mount RAM filesystems and execute"
echo "OxygenOS 16 init second_stage."
echo "Hardware safety: Physical storage remains strictly read-only."
echo "=========================================================="
