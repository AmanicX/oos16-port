#!/usr/bin/env bash
# ==============================================================================
# run_stage2.sh - Host-Side RAM Image Staging & Stage-2 Boot Orchestrator
# OxygenOS 16 on OnePlus 7T (HD1901 / hotdogb)
#
# Enforces dynamic physical device write locks, active host heartbeat,
# accurate peak memory budgeting, verified APEX metadata, and Stage-1 handover.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SAFE_ADB="$SCRIPT_DIR/adb"
IMAGES_DIR="${IMAGES_DIR:-$PROJECT_ROOT/build/images}"

echo "=========================================================="
echo "    OxygenOS 16 Stage-2 RAM Boot Orchestrator (Safe Runner)"
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
        # Discover all child partitions under this block device
        PART_ENTRIES=$("$SAFE_ADB" shell "ls -1 /sys/block/$bdev" 2>/dev/null | tr -d '\r' || true)
        for part in $PART_ENTRIES; do
            if [[ "$part" =~ ^${bdev}[0-9]+ || "$part" =~ ^${bdev}p[0-9]+ ]]; then
                DISCOVERED_PHYSICAL_DEVS+=("/dev/block/$part")
            fi
        done
    fi
done

if [ "${#DISCOVERED_PHYSICAL_DEVS[@]}" -eq 0 ]; then
    echo "CRITICAL SAFETY ERROR: No physical block devices detected on target device!" >&2
    echo "No physical storage devices could be identified. Cannot confirm hardware read-only safety locks. Aborting." >&2
    exit 1
fi

echo "Discovered ${#DISCOVERED_PHYSICAL_DEVS[@]} physical storage devices & partitions on target."

# 3. Verify Hardware-Level Read-Only Write Locks (ro=1) on Every Discovered Node
echo "3. Verifying hardware read-only write locks (blockdev --getro == 1)..."
for dev_path in "${DISCOVERED_PHYSICAL_DEVS[@]}"; do
    RO_STATE=$("$SAFE_ADB" shell "blockdev --getro $dev_path" 2>/dev/null | tr -d '\r\n[:space:]')
    if [ "$RO_STATE" != "1" ]; then
        echo "CRITICAL SAFETY VIOLATION: Device node $dev_path is NOT read-only (ro=$RO_STATE)!" >&2
        echo "Internal flash write protection failed. Aborting to protect device storage." >&2
        exit 1
    fi
    echo "  Verified: $dev_path is read-only (ro=1)"
done

get_device_mounts() {
    local m
    m=$("$SAFE_ADB" shell "cat /proc/mounts" 2>/dev/null || true)
    if [ -z "$m" ]; then
        m=$("$SAFE_ADB" shell "mount" 2>/dev/null || true)
    fi
    printf "%s\n" "$m"
}

# Check live mount table to ensure zero physical block devices or partitions are mounted writable
WRITABLE_MOUNTS=$(get_device_mounts | grep -E "^/dev/block/(sd|mmcblk)" | grep -E "([ ,(]rw[ ,)]|,rw$)" || true)
if [ -n "$WRITABLE_MOUNTS" ]; then
    echo "CRITICAL SAFETY VIOLATION: Detected writable physical partition mount:" >&2
    echo "$WRITABLE_MOUNTS" >&2
    exit 1
fi
echo "Verified: Zero physical storage devices mounted writable."

# 4. Mandatory & Optional Staged Images Discovery & Metadata Validation
echo "4. Validating staged images and calculating required memory budget..."
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

# All 4 bootstrap APEX modules are MANDATORY with validated metadata
for apex_mod in "runtime_apex" "art_apex" "i18n_apex" "tzdata_apex"; do
    APEX_IMG_FOUND=0
    for img_candidate in "${apex_mod}.img" "${apex_mod}.erofs.img"; do
        if [ -f "$IMAGES_DIR/$img_candidate" ] && [ -s "$IMAGES_DIR/$img_candidate" ]; then
            MANDATORY_IMAGES+=("$img_candidate:/mnt/${apex_mod}.img")
            APEX_IMG_FOUND=1
            break
        fi
    done
    if [ "$APEX_IMG_FOUND" -eq 0 ]; then
        echo "CRITICAL ERROR: Mandatory APEX image ${apex_mod}.img not found or 0 bytes in $IMAGES_DIR!" >&2
        exit 1
    fi

    # Mandatory .fstype validation
    FSTYPE_PATH="$IMAGES_DIR/${apex_mod}.fstype"
    if [ ! -f "$FSTYPE_PATH" ] || [ ! -s "$FSTYPE_PATH" ]; then
        echo "CRITICAL ERROR: APEX metadata $FSTYPE_PATH is 0 bytes or missing!" >&2
        exit 1
    fi
    APEX_FSTYPE=$(cat "$FSTYPE_PATH" | tr -d '[:space:]')
    if [ "$APEX_FSTYPE" != "erofs" ] && [ "$APEX_FSTYPE" != "ext4" ]; then
        echo "CRITICAL ERROR: Unsupported APEX filesystem '$APEX_FSTYPE' in $FSTYPE_PATH (must be erofs or ext4)!" >&2
        exit 1
    fi
    MANDATORY_IMAGES+=("${apex_mod}.fstype:/mnt/${apex_mod}.fstype")

    # Mandatory .version validation
    VERSION_PATH="$IMAGES_DIR/${apex_mod}.version"
    if [ ! -f "$VERSION_PATH" ] || [ ! -s "$VERSION_PATH" ]; then
        echo "CRITICAL ERROR: APEX metadata $VERSION_PATH is 0 bytes or missing!" >&2
        exit 1
    fi
    APEX_VERSION=$(cat "$VERSION_PATH" | tr -d '[:space:]')
    if ! echo "$APEX_VERSION" | grep -qE '^[1-9][0-9]*$'; then
        echo "CRITICAL ERROR: Invalid APEX version code '$APEX_VERSION' in $VERSION_PATH (must be positive integer)!" >&2
        exit 1
    fi
    MANDATORY_IMAGES+=("${apex_mod}.version:/mnt/${apex_mod}.version")
done

# Optional partition images
OPTIONAL_IMAGES=()
if [ -f "$IMAGES_DIR/my_region.erofs.img" ]; then
    OPTIONAL_IMAGES+=("my_region.erofs.img:/mnt/my_region.img")
fi

ALL_STAGED=("${MANDATORY_IMAGES[@]}" "${OPTIONAL_IMAGES[@]}")

# Calculate total staged bytes and round UPWARD to whole MB
TOTAL_STAGED_BYTES=0
for pair in "${ALL_STAGED[@]}"; do
    SRC="${pair%%:*}"
    SRC_PATH="$IMAGES_DIR/$SRC"
    if [ ! -f "$SRC_PATH" ] || [ ! -s "$SRC_PATH" ]; then
        echo "CRITICAL ERROR: Staged file $SRC_PATH does not exist or is 0 bytes!" >&2
        exit 1
    fi
    SZ=$(stat -c%s "$SRC_PATH" 2>/dev/null || stat -f%z "$SRC_PATH" 2>/dev/null || echo "0")
    TOTAL_STAGED_BYTES=$((TOTAL_STAGED_BYTES + SZ))
done

# Accurate upward rounding: (bytes + 1048575) / 1048576
TOTAL_STAGED_MB=$(((TOTAL_STAGED_BYTES + 1048575) / 1048576))

# 5. Volatile RAM & tmpfs Capacity Verification (Fail-Closed)
echo "5. Verifying /mnt tmpfs mount and free capacity on target..."

# Verify /mnt is mounted as RAM-backed tmpfs on target
MNT_MOUNT_CHECK=$(get_device_mounts | grep -E "[[:space:]]/mnt[[:space:]]+(type[[:space:]]+)?tmpfs" || true)
if [ -z "$MNT_MOUNT_CHECK" ]; then
    echo "CRITICAL SAFETY VIOLATION: /mnt is not mounted as a RAM-backed tmpfs on target device!" >&2
    exit 1
fi
echo "Verified: /mnt is confirmed as volatile RAM tmpfs."

# Parse df output reliably and strictly validate numeric free space
DF_OUTPUT=$("$SAFE_ADB" shell "df -m /mnt" 2>/dev/null || true)
if [ -z "$DF_OUTPUT" ]; then
    echo "CRITICAL SAFETY ERROR: df command failed or returned empty output for /mnt! Failing closed." >&2
    exit 1
fi

AVAIL_MNT_MB=$(echo "$DF_OUTPUT" | awk 'NR>1 {print $4}' | tr -d '\r\n[:space:]')
if [ -z "$AVAIL_MNT_MB" ] || ! echo "$AVAIL_MNT_MB" | grep -qE '^[0-9]+$'; then
    echo "CRITICAL SAFETY ERROR: Failed to parse valid numeric free capacity for /mnt from df output: '$DF_OUTPUT'! Failing closed." >&2
    exit 1
fi

REQUIRED_MNT_FREE_MB=$TOTAL_STAGED_MB
if [ "$AVAIL_MNT_MB" -lt "$REQUIRED_MNT_FREE_MB" ]; then
    echo "CRITICAL ERROR: /mnt has only ${AVAIL_MNT_MB}MB free capacity, but staging requires at least ${REQUIRED_MNT_FREE_MB}MB!" >&2
    exit 1
fi
echo "Verified: /mnt has sufficient RAM capacity (${AVAIL_MNT_MB}MB available >= ${REQUIRED_MNT_FREE_MB}MB required)."

# Verify Total RAM & Available RAM from /proc/meminfo
MEMINFO_OUTPUT=$("$SAFE_ADB" shell "cat /proc/meminfo" 2>/dev/null || true)
if [ -z "$MEMINFO_OUTPUT" ]; then
    echo "CRITICAL SAFETY ERROR: Unable to read /proc/meminfo from target device! Failing closed." >&2
    exit 1
fi

MEM_TOTAL_KB=$(echo "$MEMINFO_OUTPUT" | awk '/MemTotal:/ {print $2}' | tr -d '[:space:]')
MEM_AVAIL_KB=$(echo "$MEMINFO_OUTPUT" | awk '/MemAvailable:/ {print $2}' | tr -d '[:space:]')

if [ -z "$MEM_TOTAL_KB" ] || ! echo "$MEM_TOTAL_KB" | grep -qE '^[0-9]+$'; then
    echo "CRITICAL SAFETY ERROR: Failed to parse valid MemTotal from target device! Failing closed." >&2
    exit 1
fi

if [ -z "$MEM_AVAIL_KB" ] || ! echo "$MEM_AVAIL_KB" | grep -qE '^[0-9]+$'; then
    echo "CRITICAL SAFETY ERROR: Failed to parse valid MemAvailable from target device! Failing closed." >&2
    exit 1
fi

MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))
echo "Target volatile memory status: ${MEM_AVAIL_MB}MB available / ${MEM_TOTAL_MB}MB total."

# Target OnePlus 7T has 8 GB RAM (SM8150); after kernel carveouts MemTotal is typically >6500MB
if [ "$MEM_TOTAL_MB" -lt 6500 ]; then
    echo "CRITICAL SAFETY ERROR: Target device reports MemTotal ${MEM_TOTAL_MB}MB (< 6500MB). Target requires 8 GB physical RAM!" >&2
    exit 1
fi

# Budget Breakdown:
# 1. Staged Images (/mnt tmpfs): TOTAL_STAGED_MB
# 2. Ephemeral Data (/data tmpfs): 1024MB
# 3. OverlayFS upper/work & tmp staging: 512MB
# 4. Kernel, ZRAM & Android Runtime reserve: 1536MB
REQUIRED_RAM_MB=$((TOTAL_STAGED_MB + 1024 + 512 + 1536))
echo "Memory Budget Estimation:"
echo "  - Staged partition & APEX images: ${TOTAL_STAGED_MB}MB"
echo "  - Ephemeral /data (tmpfs):        1024MB"
echo "  - OverlayFS upper/work & tmp:     512MB"
echo "  - Kernel & Android runtime reserve: 1536MB"
echo "  ----------------------------------------"
echo "  Total Peak Memory Required:       ${REQUIRED_RAM_MB}MB"

if [ "$MEM_AVAIL_MB" -lt "$REQUIRED_RAM_MB" ]; then
    echo "CRITICAL MEMORY BUDGET VIOLATION: Target has only ${MEM_AVAIL_MB}MB available RAM," >&2
    echo "but the peak memory budget requires at least ${REQUIRED_RAM_MB}MB!" >&2
    echo "Aborting bringup to prevent kernel Out-Of-Memory panic or hardware crash." >&2
    exit 1
fi
echo "Verified: Peak memory budget safely fits within available target RAM."

# 6. Start Active Host Heartbeat Loop
echo "6. Starting active host safety heartbeat loop..."
(
    while true; do
        "$SAFE_ADB" shell "touch /mnt/watchdog_heartbeat" >/dev/null 2>&1 || true
        sleep 5
    done
) >/dev/null 2>&1 &
HEARTBEAT_PID=$!
trap 'kill -9 "$HEARTBEAT_PID" 2>/dev/null || true' EXIT
echo "Active host heartbeat loop running (PID: $HEARTBEAT_PID targeting /mnt/watchdog_heartbeat)."

# 7. Push Partition Images to Phone RAM (/mnt/)
echo "7. Pushing verified partition images to phone volatile RAM (/mnt/)..."
for pair in "${ALL_STAGED[@]}"; do
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

# 8. Activate Stage-1 Boot Trigger (/mnt/boot_now)
echo "8. Activating Stage-1 PID 1 boot supervisor trigger (/mnt/boot_now)..."
"$SAFE_ADB" shell "touch /mnt/boot_now"
echo "Boot trigger (/mnt/boot_now) sent to Stage-1 Supervisor."

# Maintain heartbeat while waiting for Stage-1 PID 1 supervisor to acknowledge and consume trigger
echo "Waiting for Stage-1 PID 1 supervisor to explicitly acknowledge trigger..."
TRIGGER_ACKNOWLEDGED=0
for check_i in $(seq 1 20); do
    ACK_STATUS=0
    ACK_OUT=$("$SAFE_ADB" shell "test -f /mnt/stage1_ack" 2>&1) || ACK_STATUS=$?

    if [ "$ACK_STATUS" -eq 0 ] && [ -z "$ACK_OUT" ]; then
        TRIGGER_ACKNOWLEDGED=1
        echo "Stage-1 supervisor explicitly acknowledged trigger (/mnt/stage1_ack confirmed, exit code 0)."
        break
    fi

    if [ "$ACK_STATUS" -ne 0 ] && [ -n "$ACK_OUT" ]; then
        echo "  [Wait $check_i/20] ADB transport communication failure (exit code $ACK_STATUS): $ACK_OUT"
        sleep 1
        continue
    fi

    DEV_STATE=""
    DEV_STATE=$("$SAFE_ADB" get-state 2>&1 | tr -d '[:space:]') || true
    if [ "$DEV_STATE" != "device" ]; then
        echo "  [Wait $check_i/20] ADB transport communication failure: '$DEV_STATE'. Awaiting reconnection..."
        sleep 1
        continue
    fi

    PENDING_STATUS=0
    PENDING_OUT=$("$SAFE_ADB" shell "test -f /mnt/boot_now" 2>&1) || PENDING_STATUS=$?
    if [ "$PENDING_STATUS" -eq 0 ] && [ -z "$PENDING_OUT" ]; then
        echo "  [Wait $check_i/20] Stage-1 supervisor pending trigger consumption (/mnt/boot_now present)..."
    else
        echo "  [Wait $check_i/20] Trigger consumed, awaiting Stage-1 explicit acknowledgement marker..."
    fi
    sleep 1
done

if [ "$TRIGGER_ACKNOWLEDGED" -eq 0 ]; then
    echo "CRITICAL ERROR: Stage-1 PID 1 supervisor did not acknowledge trigger with /mnt/stage1_ack within timeout!" >&2
    echo "Failing closed to prevent unverified handover." >&2
    exit 1
fi

echo "=========================================================="
echo "Boot trigger (/mnt/boot_now) confirmed by Stage-1 Supervisor."
echo "Stage-1 PID 1 is mounting RAM filesystems and executing"
echo "OxygenOS 16 init second_stage."
echo "Hardware safety: Physical storage remains strictly read-only."
echo "=========================================================="

# 9. Extended Health Monitoring & Heartbeat Retention
WAIT_FOR_BOOT="${OOS16_WAIT_FOR_BOOT:-0}"
MONITOR_TIMEOUT="${OOS16_BOOT_MONITOR_TIMEOUT:-600}"

if [ "$WAIT_FOR_BOOT" = "1" ]; then
    echo "Waiting for Android boot completion (sys.boot_completed=1, timeout: ${MONITOR_TIMEOUT}s)..."
    MONITOR_ELAPSED=0
    while [ "$MONITOR_ELAPSED" -lt "$MONITOR_TIMEOUT" ]; do
        CUR_STATE=""
        CUR_STATE=$("$SAFE_ADB" shell "cat /mnt/watchdog_state" 2>/dev/null | tr -d '\r\n[:space:]') || true

        BOOT_PROP=""
        BOOT_PROP=$("$SAFE_ADB" shell "getprop sys.boot_completed" 2>/dev/null | tr -d '\r\n[:space:]') || true

        if [ "$BOOT_PROP" = "1" ] || [ "$CUR_STATE" = "BOOT_COMPLETED" ]; then
            echo "=========================================================="
            echo "SUCCESS: OxygenOS 16 boot completed successfully!"
            echo "Device status: sys.boot_completed=1 verified."
            echo "Hardware safety: Physical storage remains strictly read-only."
            echo "=========================================================="
            exit 0
        fi

        if [[ "$CUR_STATE" =~ ^TIMEOUT_ ]]; then
            echo "CRITICAL ERROR: Watchdog reported failure state: $CUR_STATE!" >&2
            exit 1
        fi

        sleep 5
        MONITOR_ELAPSED=$((MONITOR_ELAPSED + 5))
    done
fi

exit 0
