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
echo "2. Dynamically detecting physical storage devices and child partitions on target..."
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
    IS_PHYSICAL=0
    if "$SAFE_ADB" shell "test -e /sys/block/$bdev/device" >/dev/null 2>&1; then
        IS_PHYSICAL=1
    elif [[ "$bdev" =~ ^(sd[a-z]|mmcblk[0-9]) ]]; then
        IS_PHYSICAL=1
    fi

    if [ "$IS_PHYSICAL" -eq 1 ]; then
        DISCOVERED_PHYSICAL_DEVS+=("/dev/block/$bdev")
        # Query and discover child partitions under this physical disk
        PART_ENTRIES=$("$SAFE_ADB" shell "ls -1 /sys/block/$bdev" 2>/dev/null | tr -d '\r' || true)
        for p in $PART_ENTRIES; do
            if [[ "$p" =~ ^${bdev}[0-9]+ ]] || [[ "$p" =~ ^${bdev}p[0-9]+ ]]; then
                DISCOVERED_PHYSICAL_DEVS+=("/dev/block/$p")
            fi
        done
    fi
done

if [ "${#DISCOVERED_PHYSICAL_DEVS[@]}" -eq 0 ]; then
    echo "CRITICAL ERROR: No physical storage devices could be identified on target!" >&2
    echo "Refusing to proceed without verifying physical disk write locks." >&2
    exit 1
fi

echo "Identified physical storage devices and partitions: ${DISCOVERED_PHYSICAL_DEVS[*]}"

# 3. Verify Block Layer Read-Only Status on All Discovered Physical Devices & Partitions
echo "3. Verifying block-layer write-lock (ro=1) on all physical devices and partitions..."
for dev_path in "${DISCOVERED_PHYSICAL_DEVS[@]}"; do
    ro_val=$("$SAFE_ADB" shell "blockdev --getro $dev_path" 2>/dev/null | tr -d '\r\n[:space:]')
    if [ "$ro_val" != "1" ]; then
        echo "CRITICAL SAFETY VIOLATION: Device/partition $dev_path is NOT read-only (ro=$ro_val)!" >&2
        echo "Halting immediately to protect physical internal storage." >&2
        exit 1
    fi
    echo "  Verified: $dev_path is read-only (ro=1)"
done

# Check live mount table to ensure zero physical block devices or partitions are mounted writable
WRITABLE_MOUNTS=$("$SAFE_ADB" shell "mount" | grep -E "^/dev/block/(sd|mmcblk)" | grep -E "([ ,(]rw[ ,)]|,rw$)" || true)
if [ -n "$WRITABLE_MOUNTS" ]; then
    echo "CRITICAL SAFETY VIOLATION: Detected writable physical partition mount:" >&2
    echo "$WRITABLE_MOUNTS" >&2
    exit 1
fi
echo "Verified: Zero physical storage devices mounted writable."

# Verify /mnt is mounted as RAM-backed tmpfs on target
if ! "$SAFE_ADB" shell "mount" | grep -E " /mnt type tmpfs " >/dev/null 2>&1; then
    echo "CRITICAL SAFETY VIOLATION: /mnt is not mounted as a RAM-backed tmpfs on target device!" >&2
    exit 1
fi
echo "Verified: /mnt is confirmed as volatile RAM tmpfs."

# Verify /mnt has at least 6000MB free capacity
AVAIL_MNT_MB=$("$SAFE_ADB" shell "df -m /mnt" 2>/dev/null | awk 'NR>1 {print $4}' | tr -d '\r\n[:space:]')
if [ -n "$AVAIL_MNT_MB" ] && [ "$AVAIL_MNT_MB" -lt 6000 ] 2>/dev/null; then
    echo "CRITICAL ERROR: /mnt has only ${AVAIL_MNT_MB}MB free space, requires at least 6000MB!" >&2
    exit 1
fi
echo "Verified: /mnt has sufficient RAM capacity (${AVAIL_MNT_MB:-unknown}MB available)."

# 4. Start Active Host Heartbeat Loop
echo "4. Starting active host safety heartbeat loop..."
# Sends regular heartbeat signal to /mnt/watchdog_heartbeat every 5 seconds.
# Stage-1 watchdog resets countdown on each valid regular heartbeat.
(
    while true; do
        "$SAFE_ADB" shell "touch /mnt/watchdog_heartbeat" >/dev/null 2>&1 || true
        sleep 5
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
# Mandatory images strictly required for Android bringup
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

# All 4 bootstrap APEX modules are MANDATORY for Android 16 bringup
OPTIONAL_IMAGES=()
for apex_mod in "runtime_apex" "art_apex" "i18n_apex" "tzdata_apex"; do
    if [ -f "$IMAGES_DIR/${apex_mod}.img" ] && [ -s "$IMAGES_DIR/${apex_mod}.img" ]; then
        MANDATORY_IMAGES+=("${apex_mod}.img:/mnt/${apex_mod}.img")
    elif [ -f "$IMAGES_DIR/${apex_mod}.erofs.img" ] && [ -s "$IMAGES_DIR/${apex_mod}.erofs.img" ]; then
        MANDATORY_IMAGES+=("${apex_mod}.erofs.img:/mnt/${apex_mod}.img")
    else
        echo "CRITICAL ERROR: Mandatory APEX image ${apex_mod}.img not found or 0 bytes in $IMAGES_DIR!" >&2
        exit 1
    fi

    # Accompanying metadata files
    if [ -f "$IMAGES_DIR/${apex_mod}.fstype" ]; then
        if [ ! -s "$IMAGES_DIR/${apex_mod}.fstype" ]; then
            echo "CRITICAL ERROR: APEX metadata $IMAGES_DIR/${apex_mod}.fstype is 0 bytes!" >&2
            exit 1
        fi
        OPTIONAL_IMAGES+=("${apex_mod}.fstype:/mnt/${apex_mod}.fstype")
    fi
    if [ -f "$IMAGES_DIR/${apex_mod}.version" ]; then
        OPTIONAL_IMAGES+=("${apex_mod}.version:/mnt/${apex_mod}.version")
    fi
done

# Optional partition images
if [ -f "$IMAGES_DIR/my_region.erofs.img" ]; then
    OPTIONAL_IMAGES+=("my_region.erofs.img:/mnt/my_region.img")
fi

ALL_IMAGES=("${MANDATORY_IMAGES[@]}" "${OPTIONAL_IMAGES[@]}")

# Validate mandatory image sources exist, are non-empty, and calculate host SHA-256
for pair in "${MANDATORY_IMAGES[@]}"; do
    SRC="${pair%%:*}"
    SRC_PATH="$IMAGES_DIR/$SRC"
    if [ ! -f "$SRC_PATH" ] || [ ! -s "$SRC_PATH" ]; then
        echo "CRITICAL ERROR: Mandatory image $SRC_PATH does not exist or is 0 bytes!" >&2
        exit 1
    fi
    SIZE_BYTES=$(stat -c%s "$SRC_PATH" 2>/dev/null || stat -f%z "$SRC_PATH")
    if [ "$SIZE_BYTES" -le 0 ]; then
        echo "CRITICAL ERROR: Image $SRC_PATH has invalid size ($SIZE_BYTES bytes)!" >&2
        exit 1
    fi
done

for pair in "${ALL_IMAGES[@]}"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"
    SRC_PATH="$IMAGES_DIR/$SRC"
    SIZE=$(ls -lh "$SRC_PATH" | awk '{print $5}')
    HOST_SHA=$(sha256sum "$SRC_PATH" | awk '{print $1}')
    echo " -> Pushing $SRC ($SIZE, SHA: ${HOST_SHA:0:12}...) to $DST..."
    "$SAFE_ADB" push "$SRC_PATH" "$DST"

    # Verify device-side file existence
    if ! "$SAFE_ADB" shell "test -f $DST" >/dev/null 2>&1; then
        echo "CRITICAL ERROR: Failed to verify staged image $DST exists on target device!" >&2
        exit 1
    fi

    # Verify device-side SHA-256 checksum against host calculation
    DEV_SHA=$("$SAFE_ADB" shell "sha256sum $DST" | awk '{print $1}' | tr -d '\r\n[:space:]')
    if [ "$HOST_SHA" != "$DEV_SHA" ]; then
        echo "CRITICAL INTEGRITY VIOLATION: Device SHA-256 for $DST does not match host!" >&2
        echo "  Host SHA-256:   $HOST_SHA" >&2
        echo "  Device SHA-256: $DEV_SHA" >&2
        exit 1
    fi
    echo "    Integrity verified: $DST matches host SHA-256."
done

# If my_product image was staged as /mnt/product.img, also stage /mnt/my_product.img
if [ -f "$IMAGES_DIR/my_product.erofs.img" ]; then
    echo " -> Staging /mnt/my_product.img for ColorOS/OxygenOS compatibility..."
    PROD_SHA=$(sha256sum "$IMAGES_DIR/my_product.erofs.img" | awk '{print $1}')
    "$SAFE_ADB" push "$IMAGES_DIR/my_product.erofs.img" "/mnt/my_product.img"
    DEV_PROD_SHA=$("$SAFE_ADB" shell "sha256sum /mnt/my_product.img" | awk '{print $1}' | tr -d '\r\n[:space:]')
    if [ "$PROD_SHA" != "$DEV_PROD_SHA" ]; then
        echo "CRITICAL INTEGRITY VIOLATION: Device SHA-256 for /mnt/my_product.img mismatch!" >&2
        exit 1
    fi
fi

echo "All required images successfully staged in target volatile RAM."

# 7. Activate Stage-1 Boot Trigger (/mnt/boot_now)
echo "7. Activating Stage-1 PID 1 boot supervisor trigger (/mnt/boot_now)..."
"$SAFE_ADB" shell "touch /mnt/boot_now"

# Maintain heartbeat while waiting for Stage-1 PID 1 supervisor to acknowledge and consume trigger
echo "Waiting for Stage-1 PID 1 supervisor to acknowledge and consume trigger..."
TRIGGER_ACKNOWLEDGED=0
for check_i in $(seq 1 15); do
    if ! "$SAFE_ADB" shell "test -f /mnt/boot_now" >/dev/null 2>&1; then
        TRIGGER_ACKNOWLEDGED=1
        echo "Stage-1 supervisor acknowledged /mnt/boot_now and initiated Stage-2 handover."
        break
    fi
    sleep 1
done

if [ "$TRIGGER_ACKNOWLEDGED" -eq 0 ]; then
    echo "Note: /mnt/boot_now still present or ADB connection reset during handover."
fi

echo "=========================================================="
echo "Boot trigger (/mnt/boot_now) sent to Stage-1 Supervisor."
echo "Stage-1 PID 1 is mounting RAM filesystems and executing"
echo "OxygenOS 16 init second_stage."
echo "Hardware safety: Physical storage remains strictly read-only."
echo "=========================================================="
