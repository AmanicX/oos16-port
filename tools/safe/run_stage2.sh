#!/usr/bin/env bash
# ==============================================================================
# run_stage2.sh - Host-Side Orchestrator for Stage-2 RAM-Resident OxygenOS 16
# Enforces dynamic physical device write locks, active host heartbeat,
# and high-speed USB 3.0 image staging.
# ==============================================================================

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

# 1. Verify phone connection
echo "1. Checking phone ADB connection in RAM mode..."
if ! "$SAFE_ADB" get-state 2>/dev/null | grep -qE "device|recovery"; then
    echo "Error: Phone is not connected in Stage-1 ADB mode." >&2
    echo "Please boot Stage-1 first using: tools/safe/fastboot boot build/stage1.img" >&2
    exit 1
fi
echo "Phone connected successfully in Stage-1 RAM mode."

# 2. Dynamic Physical Storage Device Detection
echo "2. Dynamically detecting physical storage devices on target..."
DISCOVERED_PHYSICAL_DEVS=()

# Query sysfs block devices on target
BLOCK_DEV_LIST=$("$SAFE_ADB" shell "for b in /sys/block/*; do [ -e \"\$b/device\" ] && echo \"\$(basename \"\$b\")\"; done" | tr -d '\r')

for bdev in $BLOCK_DEV_LIST; do
    # Skip virtual loop devices, zram, and RAM disks
    if [[ "$bdev" =~ ^(loop|ram|zram|dm-) ]]; then
        continue
    fi
    # Identify physical non-removable storage (SCSI UFS LUNs or eMMC)
    if [[ "$bdev" =~ ^(sd[a-z]|mmcblk[0-9]) ]]; then
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
    ro_val=$("$SAFE_ADB" shell "/system/bin/toybox blockdev --getro $dev_path" | tr -d '\r\n[:space:]')
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
# Sends heartbeat signal every 10 seconds. Stage 1 watchdog resets on each heartbeat.
# If laptop disconnects or crashes, heartbeat stops and Stage 1 reboots device after timeout.
(
    while true; do
        "$SAFE_ADB" shell "touch /tmp/watchdog_heartbeat" >/dev/null 2>&1 || true
        sleep 10
    done
) &
HEARTBEAT_PID=$!
trap 'kill "$HEARTBEAT_PID" 2>/dev/null || true' EXIT
echo "Active host heartbeat loop running (PID: $HEARTBEAT_PID)."

# 5. Check Available RAM on Phone
echo "5. Checking free volatile RAM on target..."
"$SAFE_ADB" shell "/system/bin/toybox free -m"

# 6. Push EROFS Images to Phone RAM (/tmp/ and /mnt/)
echo "6. Pushing optimized EROFS partition images to phone RAM..."
IMAGES=(
    "odm.erofs.img:/tmp/odm.img"
    "vendor.erofs.img:/tmp/vendor.img"
    "my_region.erofs.img:/tmp/my_region.img"
    "system.erofs.img:/tmp/system.img"
    "system_ext.erofs.img:/tmp/system_ext.img"
    "my_product.erofs.img:/mnt/my_product.img"
)

# Optional APEX payload image
if [ -f "$IMAGES_DIR/runtime_apex.img" ]; then
    IMAGES+=("runtime_apex.img:/tmp/runtime_apex.img")
fi
if [ -f "$IMAGES_DIR/runtime_apex.fstype" ]; then
    IMAGES+=("runtime_apex.fstype:/tmp/runtime_apex.fstype")
fi

for pair in "${IMAGES[@]}"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"
    SRC_PATH="$IMAGES_DIR/$SRC"
    if [ ! -f "$SRC_PATH" ]; then
        echo "Error: Missing required image: $SRC_PATH" >&2
        exit 1
    fi
    SIZE=$(ls -lh "$SRC_PATH" | awk '{print $5}')
    echo " -> Pushing $SRC ($SIZE) to $DST..."
    "$SAFE_ADB" push "$SRC_PATH" "$DST"
done

# 7. Push Stage-2 Init Transition Script
echo "7. Pushing Stage-2 init transition script..."
"$SAFE_ADB" push "$STAGE2_SCRIPT" "/tmp/stage2_init.sh"
"$SAFE_ADB" shell "chmod +x /tmp/stage2_init.sh"

# 8. Execute Stage-2 Android Init Transition in RAM
echo "8. Executing Stage-2 Android Init Transition in RAM..."
echo "Starting Stage-2..."
"$SAFE_ADB" shell "/tmp/stage2_init.sh"
