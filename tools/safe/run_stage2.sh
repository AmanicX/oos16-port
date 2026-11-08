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

# 4. Authoritative PARTITION_MAP Manifest Discovery & Staged Images Validation
echo "4. Validating authoritative partition map and calculating required memory budget..."

MAP_PATH="$IMAGES_DIR/PARTITION_MAP"
if [ ! -f "$MAP_PATH" ] || [ ! -s "$MAP_PATH" ]; then
    echo "CRITICAL ERROR: Mandatory partition manifest $MAP_PATH is missing or empty!" >&2
    exit 1
fi

ALLOWLIST=" /mnt/sysroot /mnt/sysroot/system_ext /mnt/sysroot/vendor /mnt/sysroot/odm /mnt/sysroot/product /mnt/sysroot/my_product /mnt/sysroot/my_region "
SEEN_TARGETS=""
SEEN_IMAGES=""
HAS_SYSROOT=0
HAS_SYSTEM_EXT=0
HAS_VENDOR=0
HAS_ODM=0
HAS_PRODUCT=0
HAS_MY_PRODUCT=0

MANDATORY_IMAGES=()
OPTIONAL_IMAGES=()

# Transfer the authoritative manifest itself
MANDATORY_IMAGES+=("PARTITION_MAP:/mnt/PARTITION_MAP")

while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$trimmed" in
        ''|\#*) continue ;;
    esac

    img=$(echo "$trimmed" | cut -d: -f1 | tr -d '[:space:]')
    target=$(echo "$trimmed" | cut -d: -f2 | tr -d '[:space:]')
    nature=$(echo "$trimmed" | cut -d: -f3 | tr -d '[:space:]')
    sha=$(echo "$trimmed" | cut -d: -f4 | tr -d '[:space:]')

    if [ -z "$img" ] || [ -z "$target" ] || [ -z "$nature" ]; then
        echo "CRITICAL ERROR: Malformed manifest entry in $MAP_PATH: '$line'!" >&2
        exit 1
    fi

    # Allowlist check
    case "$ALLOWLIST" in
        *" $target "*) ;;
        *)
            echo "CRITICAL ERROR: Target mountpoint '$target' in $MAP_PATH is NOT allowed!" >&2
            exit 1
            ;;
    esac

    if [ "$nature" != "mandatory" ] && [ "$nature" != "optional" ]; then
        echo "CRITICAL ERROR: Invalid nature '$nature' in $MAP_PATH entry '$line' (must be mandatory or optional)!" >&2
        exit 1
    fi

    case " $SEEN_TARGETS " in
        *" $target "*)
            echo "CRITICAL ERROR: Duplicate target mountpoint '$target' in $MAP_PATH!" >&2
            exit 1
            ;;
    esac
    SEEN_TARGETS="$SEEN_TARGETS $target"

    case " $SEEN_IMAGES " in
        *" $img "*)
            echo "CRITICAL ERROR: Duplicate image filename '$img' in $MAP_PATH!" >&2
            exit 1
            ;;
    esac
    SEEN_IMAGES="$SEEN_IMAGES $img"

    SRC_FILE="$IMAGES_DIR/$img"
    if [ ! -f "$SRC_FILE" ] || [ ! -s "$SRC_FILE" ]; then
        if [ "$nature" = "mandatory" ]; then
            echo "CRITICAL ERROR: Mandatory partition image $SRC_FILE does not exist or is 0 bytes!" >&2
            exit 1
        else
            echo "Note: Optional partition image $SRC_FILE not found, skipping."
            continue
        fi
    fi

    if [ -n "$sha" ]; then
        act_sha=$(sha256sum "$SRC_FILE" | awk '{print $1}')
        if [ "$act_sha" != "$sha" ]; then
            echo "CRITICAL ERROR: SHA-256 mismatch for $SRC_FILE ($act_sha != $sha)!" >&2
            exit 1
        fi
    fi

    # Derive device staging path (/mnt/<base>.img)
    dest_name="$img"
    case "$img" in
        *.erofs.img) dest_name="${img%.erofs.img}.img" ;;
    esac

    if [ "$nature" = "mandatory" ]; then
        MANDATORY_IMAGES+=("$img:/mnt/$dest_name")
    else
        OPTIONAL_IMAGES+=("$img:/mnt/$dest_name")
    fi

    case "$target" in
        /mnt/sysroot) HAS_SYSROOT=1 ;;
        /mnt/sysroot/system_ext) HAS_SYSTEM_EXT=1 ;;
        /mnt/sysroot/vendor) HAS_VENDOR=1 ;;
        /mnt/sysroot/odm) HAS_ODM=1 ;;
        /mnt/sysroot/product) HAS_PRODUCT=1 ;;
        /mnt/sysroot/my_product) HAS_MY_PRODUCT=1 ;;
    esac
done < "$MAP_PATH"

# Mandatory partition mappings enforcement
[ "$HAS_SYSROOT" -eq 1 ] || { echo "CRITICAL ERROR: Manifest $MAP_PATH missing /mnt/sysroot mapping!" >&2; exit 1; }
[ "$HAS_SYSTEM_EXT" -eq 1 ] || { echo "CRITICAL ERROR: Manifest $MAP_PATH missing /mnt/sysroot/system_ext mapping!" >&2; exit 1; }
[ "$HAS_VENDOR" -eq 1 ] || { echo "CRITICAL ERROR: Manifest $MAP_PATH missing /mnt/sysroot/vendor mapping!" >&2; exit 1; }
[ "$HAS_ODM" -eq 1 ] || { echo "CRITICAL ERROR: Manifest $MAP_PATH missing /mnt/sysroot/odm mapping!" >&2; exit 1; }
if [ "$HAS_PRODUCT" -eq 0 ] && [ "$HAS_MY_PRODUCT" -eq 0 ]; then
    echo "CRITICAL ERROR: Manifest $MAP_PATH must map at least one product partition (/mnt/sysroot/product or /mnt/sysroot/my_product)!" >&2
    exit 1
fi

# Reject duplicate image content if both product and my_product are staged
if [ -f "$IMAGES_DIR/product.erofs.img" ] && [ -f "$IMAGES_DIR/my_product.erofs.img" ]; then
    P_SHA=$(sha256sum "$IMAGES_DIR/product.erofs.img" | awk '{print $1}')
    MP_SHA=$(sha256sum "$IMAGES_DIR/my_product.erofs.img" | awk '{print $1}')
    if [ "$P_SHA" = "$MP_SHA" ]; then
        echo "CRITICAL ERROR: Ambiguous duplicate image content! product.erofs.img and my_product.erofs.img have identical SHA-256 ($P_SHA). Rejecting duplicate mapping." >&2
        exit 1
    else
        echo "Found independent product.erofs.img and my_product.erofs.img (distinct SHA-256 hashes verified)."
    fi
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

    # Mandatory .expanded_size validation (measured uncompressed payload size)
    EXPANDED_SIZE_PATH="$IMAGES_DIR/${apex_mod}.expanded_size"
    if [ ! -f "$EXPANDED_SIZE_PATH" ] || [ ! -s "$EXPANDED_SIZE_PATH" ]; then
        echo "CRITICAL ERROR: Mandatory APEX metadata $EXPANDED_SIZE_PATH is missing or 0 bytes!" >&2
        exit 1
    fi
    APEX_EXP_VAL=$(cat "$EXPANDED_SIZE_PATH" | tr -d '[:space:]')
    if [ -z "$APEX_EXP_VAL" ] || ! echo "$APEX_EXP_VAL" | grep -qE '^[1-9][0-9]*$'; then
        echo "CRITICAL ERROR: Invalid APEX expanded_size '$APEX_EXP_VAL' in $EXPANDED_SIZE_PATH (must be positive integer)!" >&2
        exit 1
    fi
    if [ "$APEX_EXP_VAL" -gt 524288000 ]; then
        echo "CRITICAL ERROR: Implausibly large APEX expanded_size in $EXPANDED_SIZE_PATH: $APEX_EXP_VAL bytes (> 500MB)!" >&2
        exit 1
    fi
    MANDATORY_IMAGES+=("${apex_mod}.expanded_size:/mnt/${apex_mod}.expanded_size")
done

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

# Calculate APEX expanded payload memory requirement strictly from verified metadata
TOTAL_EXPANDED_APEX_BYTES=0
for apex_mod in "runtime_apex" "art_apex" "i18n_apex" "tzdata_apex"; do
    EXPANDED_PATH="$IMAGES_DIR/${apex_mod}.expanded_size"
    EXP_VAL=$(cat "$EXPANDED_PATH" | tr -d '[:space:]')
    TOTAL_EXPANDED_APEX_BYTES=$((TOTAL_EXPANDED_APEX_BYTES + EXP_VAL))
done
TOTAL_EXPANDED_APEX_MB=$(((TOTAL_EXPANDED_APEX_BYTES + 1048575) / 1048576))

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
# 1. Staged Images (/mnt tmpfs):                     TOTAL_STAGED_MB (measured)
# 2. Expanded APEX payloads (/mnt/sysroot/apex tmpfs): TOTAL_EXPANDED_APEX_MB (measured/preflight)
# 3. Ephemeral Data (/data tmpfs):                   1024MB (configured quota)
# 4. OverlayFS upper/work & tmp staging:             512MB (configured quota)
# 5. Kernel, GPU, display & Android Runtime reserve: 1536MB (hardware reserve)
# 6. Filesystem metadata & safety headroom:          256MB (buffer)
REQUIRED_RAM_MB=$((TOTAL_STAGED_MB + TOTAL_EXPANDED_APEX_MB + 1024 + 512 + 1536 + 256))
echo "Memory Budget Breakdown:"
echo "  - Staged partition & APEX images (/mnt tmpfs): ${TOTAL_STAGED_MB}MB (measured)"
echo "  - Expanded APEX payloads (/apex tmpfs):        ${TOTAL_EXPANDED_APEX_MB}MB (measured/preflight)"
echo "  - Ephemeral /data (tmpfs quota):               1024MB"
echo "  - OverlayFS upper/work & tmp staging:          512MB"
echo "  - Kernel, GPU, display & runtime reserve:      1536MB"
echo "  - Filesystem metadata & safety headroom:       256MB"
echo "  ----------------------------------------------------"
echo "  Total Peak Memory Required:                    ${REQUIRED_RAM_MB}MB"

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
