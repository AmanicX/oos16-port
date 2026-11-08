#!/system/bin/sh
# ==============================================================================
# stage2_init.sh - Stage-2 Android 16 Bringup in RAM on OnePlus 7T (HD1901)
# Target: OnePlus 7T HD1901 (hotdogb), Snapdragon 855+ / SM8150, Adreno 640.
# 100% Volatile RAM resident, Zero Physical Storage Writes.
# Handles strict OverlayFS root, manifest-driven partition verification,
# canonical AOSP APEX versioned directories & active bind mounts, display
# diagnostics for 60Hz AMOLED panel, watchdog handover, and single PID 1 handover.
# ==============================================================================

set -e

# Disable kernel printk ratelimiting so no init diagnostic lines are suppressed
[ -w /proc/sys/kernel/printk_ratelimit ] && echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null || true

# Helper for logging messages to kmsg and stdout
log_msg() {
    [ -w /dev/kmsg ] && echo "$1" > /dev/kmsg 2>/dev/null || true
    echo "$1"
}

# Helper for fatal errors - logs to kmsg and halts safely without disarming watchdog
fatal() {
    [ -w /dev/kmsg ] && echo "[STAGE2 FATAL] $1" > /dev/kmsg 2>/dev/null || true
    echo "[STAGE2 FATAL] $1" >&2
    [ -w /dev/kmsg ] && echo "[STAGE2 FATAL] System halted in safe RAM state. Safety watchdog will reboot to bootloader." > /dev/kmsg 2>/dev/null || true
    if [ "${STAGE2_TEST_MODE:-0}" = "1" ]; then
        exit 42
    fi
    while true; do
        /system/bin/toybox sleep 60 2>/dev/null || sleep 60
    done
}

# Resolve command wrappers with host fallbacks for test isolation
TOYBOX_CMD="/system/bin/toybox"
if [ ! -x "$TOYBOX_CMD" ]; then
    TOYBOX_CMD="toybox"
    if ! command -v toybox >/dev/null 2>&1; then
        TOYBOX_CMD=""
    fi
fi

tb_run() {
    if [ -n "$TOYBOX_CMD" ]; then
        "$TOYBOX_CMD" "$@"
    else
        "$@"
    fi
}

# Helper to execute and verify mount
mount_or_fail() {
    echo "[STAGE2] Mounting: $*" > /dev/kmsg 2>/dev/null || true
    tb_run mount "$@" || fatal "Failed mandatory mount: mount $*"
}

# Helper for non-fatal mount attempt (for multi-filesystem fallback)
try_mount() {
    echo "[STAGE2] Attempting mount: $*" > /dev/kmsg 2>/dev/null || true
    tb_run mount "$@" 2>/dev/null
}

# Resolve image paths preferring /mnt/ over /tmp/
get_img() {
    local name="$1"
    local mnt_p="${MNT_DIR:-/mnt}/$name"
    local tmp_p="${TMP_DIR:-/tmp}/$name"
    if [ -f "$mnt_p" ] && [ -s "$mnt_p" ]; then
        echo "$mnt_p"
    elif [ -f "$tmp_p" ] && [ -s "$tmp_p" ]; then
        echo "$tmp_p"
    else
        echo ""
    fi
}

# Device RAM and Capacity Validation (Reusable function)
validate_device_ram() {
    local mnt_path="${MNT_DIR:-/mnt}"
    local tmp_path="${TMP_DIR:-/tmp}"
    local meminfo_path="${MEMINFO_FILE:-/proc/meminfo}"

    # 1. Verify /mnt capacity
    REQUIRED_MNT_FREE_MB=576
    local mnt_df_out
    mnt_df_out=$(tb_run df -m "$mnt_path" 2>/dev/null || true)
    if [ -z "$mnt_df_out" ]; then
        fatal "Device-side RAM check: df -m /mnt returned empty output. Cannot verify tmpfs capacity. Halting."
    fi
    local mnt_free_mb
    mnt_free_mb=$(echo "$mnt_df_out" | awk 'NR>1 {print $4}' | tr -d '[:space:]')
    case "$mnt_free_mb" in
        ''|*[!0-9]*)
            fatal "Device-side RAM check: Failed to parse numeric free capacity from df output ('$mnt_df_out'). Halting." ;;
    esac
    if [ "$mnt_free_mb" -lt "$REQUIRED_MNT_FREE_MB" ]; then
        fatal "Device-side RAM check: /mnt has only ${mnt_free_mb}MB free; bringup requires at least ${REQUIRED_MNT_FREE_MB}MB for OverlayFS upper/work headroom. Halting."
    fi
    log_msg "[STAGE2] Device-side /mnt tmpfs check passed: /mnt has ${mnt_free_mb}MB free (required: ${REQUIRED_MNT_FREE_MB}MB)."

    # 2. Verify /tmp capacity
    local tmp_df_out
    tmp_df_out=$(tb_run df -m "$tmp_path" 2>/dev/null || true)
    if [ -z "$tmp_df_out" ]; then
        fatal "Device-side RAM check: df -m $tmp_path returned empty output. Halting."
    fi
    local tmp_free_mb
    tmp_free_mb=$(echo "$tmp_df_out" | awk 'NR>1 {print $4}' | tr -d '[:space:]')
    case "$tmp_free_mb" in
        ''|*[!0-9]*)
            fatal "Device-side RAM check: Failed to parse numeric free capacity from df $tmp_path ('$tmp_df_out'). Halting." ;;
    esac
    if [ "$tmp_free_mb" -lt 64 ]; then
        fatal "Device-side RAM check: $tmp_path has only ${tmp_free_mb}MB free; staging requires at least 64MB. Halting."
    fi
    log_msg "[STAGE2] Device-side $tmp_path tmpfs check passed: has ${tmp_free_mb}MB free."

    # 3. Verify /proc/meminfo
    if [ ! -f "$meminfo_path" ] || [ ! -s "$meminfo_path" ]; then
        fatal "Device-side RAM check: $meminfo_path is missing or empty! Failing closed to protect hardware."
    fi
    local dev_meminfo
    dev_meminfo=$(cat "$meminfo_path" 2>/dev/null || true)
    if [ -z "$dev_meminfo" ]; then
        fatal "Device-side RAM check: Unable to read $meminfo_path! Failing closed."
    fi

    local dev_mem_total_kb
    dev_mem_total_kb=$(echo "$dev_meminfo" | awk '/MemTotal:/ {print $2}' | tr -d '[:space:]')
    case "$dev_mem_total_kb" in
        ''|*[!0-9]*)
            fatal "Device-side RAM check: Missing or non-numeric MemTotal in $meminfo_path ('$dev_mem_total_kb'). Halting." ;;
    esac
    if [ "$dev_mem_total_kb" -gt 100000000 ]; then
        fatal "Device-side RAM check: MemTotal value overflow: $dev_mem_total_kb kB. Halting."
    fi
    local dev_mem_total_mb=$((dev_mem_total_kb / 1024))
    if [ "$dev_mem_total_mb" -lt 6500 ]; then
        fatal "Device-side RAM check: MemTotal is ${dev_mem_total_mb}MB (< 6500MB). Target OnePlus 7T requires 8 GB RAM! Halting."
    fi

    local dev_mem_avail_kb
    dev_mem_avail_kb=$(echo "$dev_meminfo" | awk '/MemAvailable:/ {print $2}' | tr -d '[:space:]')
    case "$dev_mem_avail_kb" in
        ''|*[!0-9]*)
            fatal "Device-side RAM check: Missing or non-numeric MemAvailable in $meminfo_path ('$dev_mem_avail_kb'). Halting." ;;
    esac
    if [ "$dev_mem_avail_kb" -gt "$dev_mem_total_kb" ]; then
        fatal "Device-side RAM check: MemAvailable ($dev_mem_avail_kb kB) exceeds MemTotal ($dev_mem_total_kb kB). Halting."
    fi
    local dev_mem_avail_mb=$((dev_mem_avail_kb / 1024))

    # 4. Measure authentic expanded sizes for APEX modules
    local total_exp_apex_bytes=0
    for mod in runtime_apex art_apex i18n_apex tzdata_apex; do
        local exp_f="$mnt_path/${mod}.expanded_size"
        [ -f "$exp_f" ] || exp_f="$tmp_path/${mod}.expanded_size"
        if [ ! -f "$exp_f" ] || [ ! -s "$exp_f" ]; then
            fatal "Device-side RAM check: Missing mandatory APEX metadata $exp_f! Halting."
        fi
        local val
        val=$(cat "$exp_f" 2>/dev/null | tr -d '[:space:]')
        case "$val" in
            ''|*[!0-9]*)
                fatal "Device-side RAM check: Malformed non-numeric APEX expanded size in $exp_f: '$val'. Halting." ;;
        esac
        if [ "$val" -le 0 ] || [ "$val" -gt 524288000 ]; then
            fatal "Device-side RAM check: APEX expanded size in $exp_f out of range: $val bytes. Halting."
        fi
        total_exp_apex_bytes=$((total_exp_apex_bytes + val))
    done
    local exp_apex_mb=$(( (total_exp_apex_bytes + 1048575) / 1048576 ))

    # 5. Future RAM allocations model:
    # Staged images in /mnt tmpfs are already counted by kernel VM.
    # Future allocations:
    # - Direct APEX loop mount buffer: 64 MB (direct loop backed, no duplicate copy)
    # - Ephemeral /data tmpfs:         1024 MB
    # - OverlayFS upper/work on tmpfs: 512 MB
    # - Kernel, GPU, display runtime:  1536 MB
    # - Safety headroom:               256 MB
    local future_ram_req_mb=$((64 + 1024 + 512 + 1536 + 256))

    if [ "$dev_mem_avail_mb" -lt "$future_ram_req_mb" ]; then
        fatal "Device-side RAM check: Insufficient device RAM! MemAvailable is ${dev_mem_avail_mb}MB, but future bringup allocations require ${future_ram_req_mb}MB (APEX loop buffer: 64MB, /data: 1024MB, overlay: 512MB, runtime: 1536MB, buffer: 256MB). Halting."
    fi
    log_msg "[STAGE2] Device-side total RAM verified: ${dev_mem_avail_mb}MB available >= ${future_ram_req_mb}MB future required."
}

# Manifest Parser and Strict Validator
parse_and_validate_partition_map() {
    local map_file="$1"
    if [ ! -f "$map_file" ] || [ ! -s "$map_file" ]; then
        fatal "Mandatory partition map manifest $map_file not found or 0 bytes! Cannot determine partition layout."
    fi

    # Explicit Allowlist of Target Mountpoints
    local ALLOWLIST=" /mnt/sysroot /mnt/sysroot/system_ext /mnt/sysroot/vendor /mnt/sysroot/odm /mnt/sysroot/product /mnt/sysroot/my_product /mnt/sysroot/my_region "

    local SEEN_TARGETS=""
    local SEEN_IMAGES=""
    local HAS_SYSROOT=0
    local HAS_SYSTEM_EXT=0
    local HAS_VENDOR=0
    local HAS_ODM=0
    local HAS_PRODUCT=0
    local HAS_MY_PRODUCT=0

    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading/trailing whitespace
        local trimmed=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        # Skip empty lines and comment lines
        case "$trimmed" in
            ''|\#*) continue ;;
        esac

        # Strict contract: image_filename:target_mountpoint:nature:sha256 (exactly 4 fields, 3 colons)
        local num_colons=$(echo "$trimmed" | tr -cd ':' | wc -c)
        if [ "$num_colons" -ne 3 ]; then
            fatal "Malformed manifest entry in $map_file: '$line' (must have exactly 4 fields separated by 3 colons)"
        fi

        local img=$(echo "$trimmed" | cut -d: -f1 | tr -d '[:space:]')
        local target=$(echo "$trimmed" | cut -d: -f2 | tr -d '[:space:]')
        local nature=$(echo "$trimmed" | cut -d: -f3 | tr -d '[:space:]')
        local sha=$(echo "$trimmed" | cut -d: -f4 | tr -d '[:space:]')

        if [ -z "$img" ] || [ -z "$target" ] || [ -z "$nature" ] || [ -z "$sha" ]; then
            fatal "Malformed manifest entry in $map_file: '$line' (empty field detected)"
        fi

        # Safe basename validation: reject path traversal, slashes, or special characters
        if [ "$img" != "$(basename "$img")" ] || echo "$img" | grep -qE '/|\.\.'; then
            fatal "Unsafe image filename '$img' in manifest entry '$line' (must be safe basename without path traversal)"
        fi

        # Strict 64-hex SHA-256 enforcement
        if ! echo "$sha" | grep -qE '^[0-9a-fA-F]{64}$'; then
            fatal "Invalid 64-hex SHA-256 checksum '$sha' in manifest entry '$line'"
        fi

        # Validate target against allowlist
        case "$ALLOWLIST" in
            *" $target "*) ;;
            *) fatal "Target mountpoint '$target' in $map_file is NOT in the allowed mountpoints list! Halting." ;;
        esac

        # Validate nature
        if [ "$nature" != "mandatory" ] && [ "$nature" != "optional" ]; then
            fatal "Invalid partition nature '$nature' in manifest entry '$line' (must be 'mandatory' or 'optional')"
        fi

        # Core partition targets MUST be marked mandatory
        case "$target" in
            /mnt/sysroot|/mnt/sysroot/system_ext|/mnt/sysroot/vendor|/mnt/sysroot/odm)
                if [ "$nature" != "mandatory" ]; then
                    fatal "Core partition target '$target' must have nature 'mandatory' in $map_file!"
                fi
                ;;
        esac

        # Check duplicate target mountpoints
        case " $SEEN_TARGETS " in
            *" $target "*) fatal "Conflicting manifest: Target mountpoint '$target' mapped multiple times!" ;;
        esac
        SEEN_TARGETS="$SEEN_TARGETS $target"

        # Check duplicate images
        case " $SEEN_IMAGES " in
            *" $img "*) fatal "Conflicting manifest: Image filename '$img' mapped multiple times!" ;;
        esac
        SEEN_IMAGES="$SEEN_IMAGES $img"

        case "$target" in
            /mnt/sysroot) HAS_SYSROOT=1 ;;
            /mnt/sysroot/system_ext) HAS_SYSTEM_EXT=1 ;;
            /mnt/sysroot/vendor) HAS_VENDOR=1 ;;
            /mnt/sysroot/odm) HAS_ODM=1 ;;
            /mnt/sysroot/product) HAS_PRODUCT=1 ;;
            /mnt/sysroot/my_product) HAS_MY_PRODUCT=1 ;;
        esac
    done < "$map_file"

    # Enforce mandatory partition presence in manifest
    [ "$HAS_SYSROOT" -eq 1 ] || fatal "Mandatory manifest mapping for base system (/mnt/sysroot) missing from $map_file!"
    [ "$HAS_SYSTEM_EXT" -eq 1 ] || fatal "Mandatory manifest mapping for /mnt/sysroot/system_ext missing from $map_file!"
    [ "$HAS_VENDOR" -eq 1 ] || fatal "Mandatory manifest mapping for /mnt/sysroot/vendor missing from $map_file!"
    [ "$HAS_ODM" -eq 1 ] || fatal "Mandatory manifest mapping for /mnt/sysroot/odm missing from $map_file!"
    if [ "$HAS_PRODUCT" -eq 0 ] && [ "$HAS_MY_PRODUCT" -eq 0 ]; then
        fatal "Neither /mnt/sysroot/product nor /mnt/sysroot/my_product mapped in $map_file! At least one product partition is required."
    fi

    echo "[STAGE2] Partition manifest $map_file strictly validated."
    [ -w /dev/kmsg ] && echo "[STAGE2] Partition manifest $map_file strictly validated." > /dev/kmsg 2>/dev/null || true
}

# CLI Dispatch for Test Isolation and Direct Subcommand Invocations
if [ "${1:-}" = "--check-ram" ]; then
    STAGE2_TEST_MODE=1
    validate_device_ram
    exit 0
fi

if [ "${1:-}" = "--parse-manifest" ]; then
    STAGE2_TEST_MODE=1
    parse_and_validate_partition_map "${2:-${MNT_DIR:-/mnt}/PARTITION_MAP}"
    exit 0
fi

echo "=== STAGE-2 RAM BRINGUP STARTING ===" > /dev/kmsg 2>/dev/null || true

# Tactile feedback: haptic vibration pulse
echo 300 > /sys/class/leds/vibrator/duration 2>/dev/null || true
echo 1 > /sys/class/leds/vibrator/activate 2>/dev/null || true

# Background device-side heartbeat for Stage-2 watchdog monitoring
(
    while [ ! -f /mnt/stage2_done ] && [ ! -f /tmp/stage2_done ]; do
        echo "heartbeat" > /mnt/stage2_heartbeat 2>/dev/null || true
        /system/bin/toybox sleep 2 2>/dev/null || sleep 2
    done
) &
STAGE2_HB_PID=$!
trap 'kill -9 "$STAGE2_HB_PID" 2>/dev/null || true' EXIT

# 1. Heartbeat check (Validates regular file, rejects symlinks and directories)
if ([ -f /mnt/watchdog_heartbeat ] && [ ! -L /mnt/watchdog_heartbeat ]) || \
   ([ -f /tmp/watchdog_heartbeat ] && [ ! -L /tmp/watchdog_heartbeat ]); then
    echo "[STAGE2] Active host heartbeat signal verified." > /dev/kmsg
fi

# 2. Strict read-only verification of physical block devices and child partitions
echo "[STAGE2] Verifying physical block devices and child partitions are write-locked read-only..." > /dev/kmsg
DISCOVERED_PHYSICAL=0
for bdir in /sys/block/*; do
    [ -d "$bdir" ] || continue
    bname=$(basename "$bdir")
    case "$bname" in
        loop*|ram*|zram*|dm-*) continue ;;
    esac

    if [ -e "$bdir/device" ] || case "$bname" in sd*|mmcblk*) true ;; *) false ;; esac; then
        dev_node="/dev/block/$bname"
        if [ -b "$dev_node" ]; then
            DISCOVERED_PHYSICAL=$((DISCOVERED_PHYSICAL + 1))
            ro=$(/system/bin/toybox blockdev --getro "$dev_node" 2>/dev/null || echo "0")
            if [ "$ro" != "1" ]; then
                fatal "$dev_node is NOT read-only (ro=$ro)! Halting to protect physical storage."
            fi
        fi

        # Verify all child partitions
        for pdir in "$bdir"/"$bname"*; do
            [ -d "$pdir" ] || continue
            pname=$(basename "$pdir")
            part_node="/dev/block/$pname"
            if [ -b "$part_node" ]; then
                DISCOVERED_PHYSICAL=$((DISCOVERED_PHYSICAL + 1))
                pro=$(/system/bin/toybox blockdev --getro "$part_node" 2>/dev/null || echo "0")
                if [ "$pro" != "1" ]; then
                    fatal "Partition $part_node is NOT read-only (ro=$pro)! Halting to protect physical storage."
                fi
            fi
        done
    fi
done

if [ "$DISCOVERED_PHYSICAL" -eq 0 ]; then
    fatal "No physical block devices detected. Cannot verify physical disk write locks!"
fi

# Verify no physical devices or partitions are mounted writable
if /system/bin/toybox mount | grep -E "^/dev/block/(sd|mmcblk)" | grep -E "([ ,(]rw[ ,)]|,rw$)"; then
    fatal "CRITICAL SAFETY VIOLATION: Detected writable physical partition mount!"
fi

# Verify /mnt and /tmp are mounted as RAM-backed tmpfs
if ! /system/bin/toybox mount | grep -q " /mnt type tmpfs "; then
    fatal "CRITICAL SAFETY FAILURE: Staging directory /mnt is not mounted as RAM tmpfs!"
fi

/system/bin/toybox mkdir -p /tmp 2>/dev/null || true
if ! /system/bin/toybox mount | grep -q " /tmp type tmpfs "; then
    /system/bin/toybox mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /tmp 2>/dev/null || true
    if ! /system/bin/toybox mount | grep -q " /tmp type tmpfs "; then
        fatal "CRITICAL SAFETY FAILURE: Temporary directory /tmp is not mounted as RAM tmpfs!"
    fi
fi

# Execute device-side RAM capacity checks
validate_device_ram

echo "[STAGE2] Verified: All $DISCOVERED_PHYSICAL physical storage devices and partitions are strictly locked read-only (ro=1)." > /dev/kmsg

# 3. Clean up any previous mounts
/system/bin/toybox umount -R /mnt/sysroot 2>/dev/null || true
/system/bin/toybox umount /mnt/system_ro 2>/dev/null || true
/system/bin/toybox mkdir -p /mnt/sysroot /mnt/system_ro /mnt/overlay_upper /mnt/overlay_work

# 4. Resolve & Strictly Validate Authoritative PARTITION_MAP Manifest
MAP_FILE="/mnt/PARTITION_MAP"
[ -f "$MAP_FILE" ] || MAP_FILE="/tmp/PARTITION_MAP"
parse_and_validate_partition_map "$MAP_FILE"

# 5. Mount Base System Image from Manifest
# Identify entry in PARTITION_MAP whose target is /mnt/sysroot
SYSROOT_ENTRY=$(grep ":/mnt/sysroot:" "$MAP_FILE" | head -n 1)
[ -n "$SYSROOT_ENTRY" ] || fatal "No manifest entry mapping /mnt/sysroot found!"

SYS_IMG_FILE=$(echo "$SYSROOT_ENTRY" | cut -d: -f1 | tr -d '[:space:]')
SYS_IMG_SHA=$(echo "$SYSROOT_ENTRY" | cut -d: -f4 | tr -d '[:space:]')

SYSTEM_IMG="/mnt/system.img"
[ -n "$SYS_IMG_FILE" ] && SYSTEM_IMG=$(get_img "$SYS_IMG_FILE")
[ -n "$SYSTEM_IMG" ] || SYSTEM_IMG=$(get_img "${SYS_IMG_FILE%.erofs.img}.img")
[ -n "$SYSTEM_IMG" ] || SYSTEM_IMG="/mnt/system.img"
[ -f "$SYSTEM_IMG" ] && [ -s "$SYSTEM_IMG" ] || fatal "Required base system image ($SYS_IMG_FILE) not found or 0 bytes!"

if [ -n "$SYS_IMG_SHA" ]; then
    ACTUAL_SYS_SHA=$(/system/bin/toybox sha256sum "$SYSTEM_IMG" | awk '{print $1}')
    if [ "$ACTUAL_SYS_SHA" != "$SYS_IMG_SHA" ]; then
        fatal "Base system image SHA-256 mismatch ($ACTUAL_SYS_SHA != $SYS_IMG_SHA)!"
    fi
fi

# Mount base system image to /mnt/system_ro (read-only EROFS loop mount)
mount_or_fail -t erofs -o ro,loop "$SYSTEM_IMG" /mnt/system_ro

# Mount OverlayFS on /mnt/sysroot with upper and work directories on RAM tmpfs (/mnt)
mount_or_fail -t overlay overlay -o lowerdir=/mnt/system_ro,upperdir=/mnt/overlay_upper,workdir=/mnt/overlay_work /mnt/sysroot

if ! /system/bin/toybox grep -q " /mnt/sysroot overlay " /proc/mounts 2>/dev/null; then
    fatal "OverlayFS mount verification failed for /mnt/sysroot! Halting."
fi
echo "[STAGE2] Mounted writable OverlayFS root at /mnt/sysroot." > /dev/kmsg

# 6. Pre-Create Required Child Mountpoints on Rootfs
REQUIRED_MOUNTPOINTS="system_ext vendor odm product my_product my_region apex data dev proc sys linkerconfig mnt"
for mp in $REQUIRED_MOUNTPOINTS; do
    /system/bin/toybox mkdir -p "/mnt/sysroot/$mp"
    if [ ! -d "/mnt/sysroot/$mp" ]; then
        fatal "Failed to establish required mountpoint directory /mnt/sysroot/$mp!"
    fi
done
echo "[STAGE2] All child mountpoints verified on rootfs." > /dev/kmsg

# Helper to mount partition image
mount_partition() {
    local name="$1"
    local img_path="$2"
    local target="/mnt/sysroot/$name"
    local mandatory="${3:-1}"

    if [ ! -f "$img_path" ] || [ ! -s "$img_path" ]; then
        if [ "$mandatory" -eq 1 ]; then
            fatal "Mandatory partition image $img_path does not exist or is 0 bytes!"
        else
            echo "[STAGE2] Optional partition image $img_path not present, skipping." > /dev/kmsg
            return 0
        fi
    fi

    if [ ! -d "$target" ]; then
        if [ "$mandatory" -eq 1 ]; then
            fatal "Mountpoint directory $target does not exist!"
        else
            echo "[STAGE2] Optional mountpoint $target missing, skipping." > /dev/kmsg
            return 0
        fi
    fi

    mount_or_fail -t erofs -o ro,loop "$img_path" "$target"

    # Verify mount in /proc/mounts
    if ! /system/bin/toybox grep -q " $target erofs " /proc/mounts 2>/dev/null; then
        if [ "$mandatory" -eq 1 ]; then
            fatal "Verification failed: $target is not mounted as erofs in /proc/mounts!"
        fi
    fi
    echo "[STAGE2] Successfully mounted and verified $name at $target." > /dev/kmsg
}

# 7. Mount Child Partitions Directly from Authoritative PARTITION_MAP
ACTIVE_PRODUCT_MOUNTS=""
MANIFEST_IMAGES=""

while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$trimmed" in ''|\#*) continue ;; esac

    m_img=$(echo "$trimmed" | cut -d: -f1 | tr -d '[:space:]')
    m_target=$(echo "$trimmed" | cut -d: -f2 | tr -d '[:space:]')
    m_nature=$(echo "$trimmed" | cut -d: -f3 | tr -d '[:space:]')
    m_sha=$(echo "$trimmed" | cut -d: -f4 | tr -d '[:space:]')

    MANIFEST_IMAGES="$MANIFEST_IMAGES $m_img ${m_img%.erofs.img}.img"

    # Skip rootfs (already mounted above)
    [ "$m_target" = "/mnt/sysroot" ] && continue

    part_name=$(basename "$m_target")
    resolved_img=$(get_img "$m_img")
    [ -n "$resolved_img" ] || resolved_img=$(get_img "${m_img%.erofs.img}.img")

    if [ "$m_nature" = "mandatory" ]; then
        [ -n "$resolved_img" ] || fatal "Mandatory image $m_img for $m_target not found in /mnt or /tmp!"
    else
        if [ -z "$resolved_img" ]; then
            echo "[STAGE2] Optional image $m_img not present, skipping." > /dev/kmsg
            continue
        fi
    fi

    if [ -n "$m_sha" ] && [ -f "$resolved_img" ]; then
        actual_sha=$(/system/bin/toybox sha256sum "$resolved_img" | awk '{print $1}')
        if [ "$actual_sha" != "$m_sha" ]; then
            fatal "SHA-256 mismatch on $resolved_img ($actual_sha != $m_sha)!"
        fi
    fi

    mount_partition "$part_name" "$resolved_img" 1

    case "$m_target" in
        /mnt/sysroot/product|/mnt/sysroot/my_product)
            ACTIVE_PRODUCT_MOUNTS="$ACTIVE_PRODUCT_MOUNTS $m_target"
            ;;
    esac
done < "$MAP_FILE"

# Verify duplicate image content if both product and my_product are mounted
PROD_IMG=$(get_img "product.img")
MY_PROD_IMG=$(get_img "my_product.img")
if [ -n "$PROD_IMG" ] && [ -n "$MY_PROD_IMG" ]; then
    P_SHA=$(/system/bin/toybox sha256sum "$PROD_IMG" | awk '{print $1}')
    MP_SHA=$(/system/bin/toybox sha256sum "$MY_PROD_IMG" | awk '{print $1}')
    if [ "$P_SHA" = "$MP_SHA" ]; then
        fatal "CRITICAL DUPLICATION ERROR: $PROD_IMG and $MY_PROD_IMG have identical content! Refusing duplicate mount."
    fi
fi

# Reject any unmapped partition image in /mnt (excluding APEX payload images)
for staged_img in /mnt/*.img; do
    [ -f "$staged_img" ] || continue
    base_staged=$(basename "$staged_img")
    case "$base_staged" in
        runtime_apex.img|art_apex.img|i18n_apex.img|tzdata_apex.img) continue ;;
    esac
    case " $MANIFEST_IMAGES " in
        *" $base_staged "*) ;;
        *) fatal "Unmapped partition image detected in /mnt: $base_staged is NOT in PARTITION_MAP!" ;;
    esac
done

# 8. Strict Android 16 Bootstrap APEX Handling & Canonical Versioned Mounts
echo "[STAGE2] Preparing Android 16 bootstrap APEX environments on tmpfs..." > /dev/kmsg
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/apex

populate_apex() {
    local mod_name="$1"
    local img_name="$2"
    local mandatory="${3:-1}"

    local img_path=$(get_img "$img_name")
    if [ "$mandatory" -eq 1 ]; then
        if [ -z "$img_path" ] || [ ! -s "$img_path" ]; then
            fatal "Mandatory APEX image $img_name is missing or 0 bytes!"
        fi
    fi

    local version=""
    if [ -f "/mnt/${img_name%.img}.version" ]; then
        version=$(cat "/mnt/${img_name%.img}.version" | tr -d '[:space:]')
    elif [ -f "/tmp/${img_name%.img}.version" ]; then
        version=$(cat "/tmp/${img_name%.img}.version" | tr -d '[:space:]')
    fi

    if [ "$mandatory" -eq 1 ]; then
        if [ -z "$version" ]; then
            fatal "Mandatory APEX metadata .version for $mod_name ($img_name) is missing or empty!"
        fi
        if ! echo "$version" | grep -qE '^[1-9][0-9]*$'; then
            fatal "Mandatory APEX $mod_name has invalid non-numeric or non-positive version code: '$version'!"
        fi
    else
        [ -z "$version" ] && version="1"
    fi

    local fstype=""
    if [ -f "/mnt/${img_name%.img}.fstype" ]; then
        fstype=$(cat "/mnt/${img_name%.img}.fstype" | tr -d '[:space:]')
    elif [ -f "/tmp/${img_name%.img}.fstype" ]; then
        fstype=$(cat "/tmp/${img_name%.img}.fstype" | tr -d '[:space:]')
    fi

    if [ "$mandatory" -eq 1 ]; then
        if [ -z "$fstype" ]; then
            fatal "Mandatory APEX metadata .fstype for $mod_name ($img_name) is missing or empty!"
        fi
        if [ "$fstype" != "erofs" ] && [ "$fstype" != "ext4" ]; then
            fatal "Mandatory APEX $mod_name has unsupported filesystem type '$fstype' (must be erofs or ext4)!"
        fi
    else
        [ -z "$fstype" ] && fstype="erofs"
    fi

    local base_name="${img_name%.img}"
    local mod_pkg="$mod_name"
    if [ -f "/mnt/${base_name}.package" ]; then
        mod_pkg=$(cat "/mnt/${base_name}.package" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.package" ]; then
        mod_pkg=$(cat "/tmp/${base_name}.package" | tr -d '[:space:]')
    fi

    local mod_ver="$version"
    local mod_ver_name=""
    if [ -f "/mnt/${base_name}.version_name" ]; then
        mod_ver_name=$(cat "/mnt/${base_name}.version_name" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.version_name" ]; then
        mod_ver_name=$(cat "/tmp/${base_name}.version_name" | tr -d '[:space:]')
    fi

    local mod_preinstalled="/system/apex/${mod_pkg}.apex"
    if [ -f "/mnt/${base_name}.preinstalled_path" ]; then
        mod_preinstalled=$(cat "/mnt/${base_name}.preinstalled_path" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.preinstalled_path" ]; then
        mod_preinstalled=$(cat "/tmp/${base_name}.preinstalled_path" | tr -d '[:space:]')
    fi

    local mod_shared_libs="false"
    if [ -f "/mnt/${base_name}.provide_shared_libs" ]; then
        mod_shared_libs=$(cat "/mnt/${base_name}.provide_shared_libs" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.provide_shared_libs" ]; then
        mod_shared_libs=$(cat "/tmp/${base_name}.provide_shared_libs" | tr -d '[:space:]')
    fi

    local mod_part="SYSTEM"
    if [ -f "/mnt/${base_name}.partition" ]; then
        mod_part=$(cat "/mnt/${base_name}.partition" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.partition" ]; then
        mod_part=$(cat "/tmp/${base_name}.partition" | tr -d '[:space:]')
    fi

    [ -n "$mod_pkg" ] && mod_name="$mod_pkg"
    [ -n "$mod_ver" ] && version="$mod_ver"

    # Canonical AOSP structure:
    # Versioned payload directory: /mnt/sysroot/apex/${mod_name}@${version}
    # Active APEX mountpoint:      /mnt/sysroot/apex/${mod_name} (bind-mounted to versioned dir)
    local versioned_dir="/mnt/sysroot/apex/${mod_name}@${version}"
    local active_mount="/mnt/sysroot/apex/${mod_name}"

    /system/bin/toybox mkdir -p "$versioned_dir" "$active_mount"

    echo "[STAGE2] Direct loop mounting $mod_name payload to $versioned_dir from $img_path (fstype: $fstype, version: $version)..." > /dev/kmsg
    if ! try_mount -t "$fstype" -o ro,loop "$img_path" "$versioned_dir"; then
        fatal "Failed to mount $mod_name payload image from $img_path with filesystem $fstype!"
    fi

    # Verify versioned mount in /proc/mounts
    if ! /system/bin/toybox grep -q " $versioned_dir " /proc/mounts 2>/dev/null; then
        fatal "Direct loop mount verification failed for $versioned_dir in /proc/mounts!"
    fi

    # Establish canonical active bind mount (Android 13+ standard)
    mount_or_fail --bind "$versioned_dir" "$active_mount"
    if ! /system/bin/toybox grep -q " $active_mount " /proc/mounts 2>/dev/null; then
        fatal "Active APEX mount verification failed for $active_mount in /proc/mounts!"
    fi

    # Establish backward-compatibility convenience link @1 if version != 1
    if [ "$mod_ver" != "1" ]; then
        /system/bin/toybox rm -rf "/mnt/sysroot/apex/${mod_pkg}@1" 2>/dev/null || true
        (cd /mnt/sysroot/apex && /system/bin/toybox ln -sfn "${mod_pkg}@${mod_ver}" "${mod_pkg}@1" 2>/dev/null || true)
    fi

    echo "[STAGE2] Verified authentic active APEX loop mount: $active_mount -> $versioned_dir (version: $mod_ver)" > /dev/kmsg
}

# Helper to read APEX metadata or use defaults
get_apex_meta() {
    local base="$1"
    local ext="$2"
    local def="$3"
    local f="/mnt/${base}.${ext}"
    [ -f "$f" ] || f="/tmp/${base}.${ext}"
    if [ -f "$f" ]; then
        local v
        v=$(cat "$f" 2>/dev/null | /system/bin/toybox tr -d '[:space:]')
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    echo "$def"
}

# Populate All 4 Mandatory Bootstrap APEX Modules
populate_apex "com.android.runtime" "runtime_apex.img" 1
populate_apex "com.android.art" "art_apex.img" 1
populate_apex "com.android.i18n" "i18n_apex.img" 1
populate_apex "com.android.tzdata" "tzdata_apex.img" 1

# Generate canonical active APEX info list for Android 16 userspace strictly adhering to ApexInfoList.xsd
cat > /mnt/sysroot/apex/apex-info-list.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<apex-info-list>
  <apex-info moduleName="$(get_apex_meta runtime_apex package com.android.runtime)" modulePath="/apex/$(get_apex_meta runtime_apex package com.android.runtime)@$(get_apex_meta runtime_apex version 1)" preinstalledModulePath="$(get_apex_meta runtime_apex preinstalled_path /system/apex/com.android.runtime.apex)" versionCode="$(get_apex_meta runtime_apex version 1)" versionName="$(get_apex_meta runtime_apex version_name "")" isFactory="true" isActive="true" provideSharedApexLibs="$(get_apex_meta runtime_apex provide_shared_libs false)" partition="$(get_apex_meta runtime_apex partition SYSTEM)" />
  <apex-info moduleName="$(get_apex_meta art_apex package com.android.art)" modulePath="/apex/$(get_apex_meta art_apex package com.android.art)@$(get_apex_meta art_apex version 361501120)" preinstalledModulePath="$(get_apex_meta art_apex preinstalled_path /system/apex/com.google.android.art_compressed.apex)" versionCode="$(get_apex_meta art_apex version 361501120)" versionName="$(get_apex_meta art_apex version_name "")" isFactory="true" isActive="true" provideSharedApexLibs="$(get_apex_meta art_apex provide_shared_libs false)" partition="$(get_apex_meta art_apex partition SYSTEM)" />
  <apex-info moduleName="$(get_apex_meta i18n_apex package com.android.i18n)" modulePath="/apex/$(get_apex_meta i18n_apex package com.android.i18n)@$(get_apex_meta i18n_apex version 1)" preinstalledModulePath="$(get_apex_meta i18n_apex preinstalled_path /system/apex/com.android.i18n.apex)" versionCode="$(get_apex_meta i18n_apex version 1)" versionName="$(get_apex_meta i18n_apex version_name "")" isFactory="true" isActive="true" provideSharedApexLibs="$(get_apex_meta i18n_apex provide_shared_libs false)" partition="$(get_apex_meta i18n_apex partition SYSTEM)" />
  <apex-info moduleName="$(get_apex_meta tzdata_apex package com.android.tzdata)" modulePath="/apex/$(get_apex_meta tzdata_apex package com.android.tzdata)@$(get_apex_meta tzdata_apex version 361157000)" preinstalledModulePath="$(get_apex_meta tzdata_apex preinstalled_path /system/apex/com.google.android.tzdata6.apex)" versionCode="$(get_apex_meta tzdata_apex version 361157000)" versionName="$(get_apex_meta tzdata_apex version_name "")" isFactory="true" isActive="true" provideSharedApexLibs="$(get_apex_meta tzdata_apex provide_shared_libs false)" partition="$(get_apex_meta tzdata_apex partition SYSTEM)" />
</apex-info-list>
EOF
chmod 0644 /mnt/sysroot/apex/apex-info-list.xml
cp /mnt/sysroot/apex/apex-info-list.xml /mnt/sysroot/apex/.bootstrap-apex-info-list.xml 2>/dev/null || true

# Validate apex-info-list.xml against ApexInfoList.xsd schema and active mounts
if command -v python3 >/dev/null 2>&1 && [ -f /system/bin/extract_apex_info.py ]; then
    python3 /system/bin/extract_apex_info.py --validate-xml /mnt/sysroot/apex/apex-info-list.xml --active-mounts-from /proc/mounts || fatal "Generated apex-info-list.xml failed AOSP schema or active mount validation!"
    echo "[STAGE2] apex-info-list.xml verified compliant with Android 16 ApexInfoList.xsd." > /dev/kmsg
fi

# Strict Validation of Authentic ART, I18N, and TZDATA Modules
[ -f /mnt/sysroot/apex/com.android.art/lib64/libart.so ] || fatal "ART libart.so is MISSING from art APEX!"
[ -f /mnt/sysroot/apex/com.android.i18n/lib64/libandroidicu.so ] || [ -f /mnt/sysroot/apex/com.android.i18n/lib64/libicuuc.so ] || fatal "ICU libraries MISSING from i18n APEX!"
[ -f /mnt/sysroot/apex/com.android.tzdata/etc/tz/tzdata ] || [ -f /mnt/sysroot/apex/com.android.tzdata/etc/icu/icu_tzdata.dat ] || fatal "Timezone data MISSING from tzdata APEX!"

echo "[STAGE2] Strict verification passed: Authentic Bionic, ART, I18N, and TZDATA APEX environments ready." > /dev/kmsg

# 9. Linker Configuration & Runtime Directories
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/linkerconfig
/system/bin/toybox mkdir -p /mnt/sysroot/linkerconfig/bootstrap /mnt/sysroot/linkerconfig/default
echo "#" > /mnt/sysroot/linkerconfig/bootstrap/ld.config.txt
echo "#" > /mnt/sysroot/linkerconfig/default/ld.config.txt
echo "#" > /mnt/sysroot/linkerconfig/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/bootstrap/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/default/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/ld.config.txt

mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/mnt
/system/bin/toybox mkdir -p /mnt/sysroot/mnt/vendor/persist

# 10. Ephemeral /data (1024 MB RAM tmpfs)
echo "[STAGE2] Initializing RAM tmpfs for /data (1024 MB)..." > /dev/kmsg
mount_or_fail -t tmpfs -o rw,nosuid,nodev,noatime,mode=0771,size=1024M tmpfs /mnt/sysroot/data
/system/bin/toybox mkdir -p /mnt/sysroot/data/system /mnt/sysroot/data/misc /mnt/sysroot/data/user /mnt/sysroot/data/user_de /mnt/sysroot/data/local /mnt/sysroot/data/local/tmp /mnt/sysroot/data/media /mnt/sysroot/data/persist_log
chmod 0775 /mnt/sysroot/data/local/tmp
chmod 0700 /mnt/sysroot/data/system
chmod 01771 /mnt/sysroot/data/misc

# 11. Bind Core Kernel Interfaces & Fail-Closed SELinux Initialization
mount_or_fail --bind /dev /mnt/sysroot/dev
mount_or_fail -t devpts devpts /mnt/sysroot/dev/pts
mount_or_fail -t proc proc /mnt/sysroot/proc
mount_or_fail --bind /sys /mnt/sysroot/sys

/system/bin/toybox mkdir -p /sys/fs/selinux /mnt/sysroot/sys/fs/selinux
if ! /system/bin/toybox grep -q " /sys/fs/selinux selinuxfs " /proc/mounts 2>/dev/null && \
   ! /system/bin/toybox grep -q " /mnt/sysroot/sys/fs/selinux selinuxfs " /proc/mounts 2>/dev/null; then
    if /system/bin/toybox grep -q "selinuxfs" /proc/filesystems 2>/dev/null; then
        mount_or_fail -t selinuxfs selinuxfs /mnt/sysroot/sys/fs/selinux
    elif [ "${STAGE2_TEST_MODE:-0}" != "1" ]; then
        fatal "Kernel /proc/filesystems does not list selinuxfs! SELinux kernel subsystem missing."
    fi
fi

# Verify kernel SELinux interface accessibility
if [ "${STAGE2_TEST_MODE:-0}" != "1" ]; then
    if [ ! -d /mnt/sysroot/sys/fs/selinux ] && [ ! -d /sys/fs/selinux ]; then
        fatal "SELinux kernel interface directory /sys/fs/selinux is not accessible!"
    fi
fi

# Verify mandatory SELinux CIL policies across partitions
if [ "${STAGE2_TEST_MODE:-0}" != "1" ] || [ -d /mnt/sysroot/system/etc/selinux ]; then
    [ -f /mnt/sysroot/system/etc/selinux/plat_sepolicy.cil ] || fatal "Mandatory plat_sepolicy.cil missing from system partition!"
    [ -f /mnt/sysroot/system_ext/etc/selinux/system_ext_sepolicy.cil ] || fatal "Mandatory system_ext_sepolicy.cil missing from system_ext partition!"
    [ -f /mnt/sysroot/vendor/etc/selinux/vendor_sepolicy.cil ] || fatal "Mandatory vendor_sepolicy.cil missing from vendor partition!"
    [ -f /mnt/sysroot/odm/etc/selinux/odm_sepolicy.cil ] || fatal "Mandatory odm_sepolicy.cil missing from odm partition!"
    [ -f /mnt/sysroot/system/etc/selinux/plat_sepolicy_and_mapping.sha256 ] || fatal "Mandatory plat_sepolicy_and_mapping.sha256 missing from system partition!"

    # Detect precompiled policy hash mismatch
    local plat_sha
    plat_sha=$(cat /mnt/sysroot/system/etc/selinux/plat_sepolicy_and_mapping.sha256 2>/dev/null | /system/bin/toybox tr -d '[:space:]')
    local precompiled_sha=""
    if [ -f /mnt/sysroot/odm/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256 ]; then
        precompiled_sha=$(cat /mnt/sysroot/odm/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256 2>/dev/null | /system/bin/toybox tr -d '[:space:]')
    elif [ -f /mnt/sysroot/vendor/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256 ]; then
        precompiled_sha=$(cat /mnt/sysroot/vendor/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256 2>/dev/null | /system/bin/toybox tr -d '[:space:]')
    fi

    if [ -n "$precompiled_sha" ] && [ "$plat_sha" != "$precompiled_sha" ]; then
        echo "[STAGE2] SELinux precompiled policy hash mismatch detected (platform: ${plat_sha:0:16}... vs precompiled: ${precompiled_sha:0:16}...). Runtime CIL compilation required via secilc." > /dev/kmsg
        if [ ! -x /mnt/sysroot/system/bin/secilc ]; then
            fatal "SELinux policy hash mismatch requires runtime CIL compilation, but /system/bin/secilc is missing or not executable!"
        fi
        echo "[STAGE2] Verified /system/bin/secilc compiler is present and executable for runtime policy compilation." > /dev/kmsg
    fi
fi

# Isolate property workspace and socket dirs to eliminate SIGSEGV Code 139
/system/bin/toybox mkdir -p /mnt/sysroot/dev/__properties__ /mnt/sysroot/dev/socket
mount_or_fail -t tmpfs tmpfs /mnt/sysroot/dev/__properties__
mount_or_fail -t tmpfs tmpfs /mnt/sysroot/dev/socket

# Ensure property workspace is accessible to root-namespace watchdog and diagnostics
/system/bin/toybox mkdir -p /dev/__properties__ /dev/socket
/system/bin/toybox mount --bind /mnt/sysroot/dev/__properties__ /dev/__properties__ 2>/dev/null || true
/system/bin/toybox mount --bind /mnt/sysroot/dev/socket /dev/socket 2>/dev/null || true

# Graphics compatibility node
/system/bin/toybox mkdir -p /mnt/sysroot/dev/graphics
/system/bin/toybox ln -s /dev/dri/card0 /mnt/sysroot/dev/graphics/fb0 2>/dev/null || true

# 12. Display Subsystem Diagnostics & AMOLED Configuration
echo "[STAGE2] Running display subsystem diagnostics..." > /dev/kmsg
if [ -c /mnt/sysroot/dev/dri/card0 ] || [ -c /dev/dri/card0 ]; then
    echo "[STAGE2] DRM display controller verified: /dev/dri/card0 present." > /dev/kmsg
else
    echo "[STAGE2 WARNING] DRM /dev/dri/card0 node missing! SurfaceFlinger display composition may fail." > /dev/kmsg
fi

if [ -c /mnt/sysroot/dev/kgsl-3d0 ] || [ -c /dev/kgsl-3d0 ]; then
    echo "[STAGE2] Adreno 640 GPU accelerator verified: /dev/kgsl-3d0 present." > /dev/kmsg
else
    echo "[STAGE2 WARNING] Adreno /dev/kgsl-3d0 node missing! 3D GPU acceleration may fall back to swiftshader." > /dev/kmsg
fi

# AMOLED Backlight status
if [ -f /sys/class/backlight/panel0-backlight/brightness ]; then
    echo 200 > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null || true
    echo "[STAGE2] Samsung AMOLED DSI panel backlight set to 200." > /dev/kmsg
fi

# Verify SurfaceFlinger binary presence
if [ -f /mnt/sysroot/system/bin/surfaceflinger ]; then
    echo "[STAGE2] SurfaceFlinger binary verified: /system/bin/surfaceflinger." > /dev/kmsg
fi
if [ -f /mnt/sysroot/vendor/bin/hw/android.hardware.graphics.composer@2.4-service ] || \
   [ -f /mnt/sysroot/vendor/bin/hw/vendor.qti.hardware.display.composer-service ]; then
    echo "[STAGE2] Hardware Composer service binary verified in vendor partition." > /dev/kmsg
fi

# 13. Final Mount Layout Verification
echo "[STAGE2] Verifying complete mount layout in /proc/mounts..." > /dev/kmsg
MANDATORY_MOUNTS="/mnt/sysroot /mnt/sysroot/system_ext /mnt/sysroot/vendor /mnt/sysroot/odm $ACTIVE_PRODUCT_MOUNTS /mnt/sysroot/apex /mnt/sysroot/data /mnt/sysroot/dev /mnt/sysroot/proc /mnt/sysroot/sys /mnt/sysroot/linkerconfig"
for target in $MANDATORY_MOUNTS; do
    if ! /system/bin/toybox grep -q " $target " /proc/mounts 2>/dev/null; then
        fatal "Final mount layout verification failed: $target is NOT mounted in /proc/mounts!"
    fi
done
echo "[STAGE2] All mandatory filesystems verified in /proc/mounts." > /dev/kmsg

# 14. Stage-2 Completion & Watchdog Handover
echo "[STAGE2] Signaling Stage-2 bringup completion to watchdog (/mnt/stage2_done)..." > /dev/kmsg
echo "done" > /mnt/stage2_done 2>/dev/null || true
echo "done" > /tmp/stage2_done 2>/dev/null || true
kill -9 "$STAGE2_HB_PID" 2>/dev/null || true

# Optional explicit disarm override
if [ "${DISARM_WATCHDOG:-0}" = "1" ]; then
    echo "cancel" > /mnt/watchdog_cancel 2>/dev/null || true
    echo "cancel" > /tmp/watchdog_cancel 2>/dev/null || true
fi

echo "[STAGE2] Handing over to Android init health monitor (watching sys.boot_completed=1)..." > /dev/kmsg

# 15. Android Init Handover (PID 1 preserved via exec)
echo "[STAGE2] ALL RAM FILESYSTEMS READY. EXECUTING ANDROID 16 INIT SELINUX_SETUP AS PID 1..." > /dev/kmsg

# Stop Stage-1 adbd and unbind USB gadget controller cleanly
killall adbd 2>/dev/null || true
echo "" > /config/usb_gadget/g1/UDC 2>/dev/null || true
/system/bin/toybox umount /dev/usb-ffs/adb 2>/dev/null || true

export PATH=/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
export ANDROID_STORAGE=/storage
export ANDROID_ART_ROOT=/apex/com.android.art
export ANDROID_I18N_ROOT=/apex/com.android.i18n
export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
export SELINUX_STARTED_AT="$(/system/bin/toybox date +%s%N 2>/dev/null || echo 0)"

if [ ! -x /mnt/sysroot/system/bin/init ]; then
    fatal "Target Android 16 init binary (/mnt/sysroot/system/bin/init) is missing or not executable!"
fi

# Hand over execution to Android init selinux_setup as PID 1
# Android 16 AOSP init executes SetupSelinux, compiles/loads the policy, sets PID 1 context to u:r:init:s0,
# and then calls execv("/system/bin/init", {"/system/bin/init", "second_stage", nullptr}).
exec /system/bin/chroot /mnt/sysroot /system/bin/init "${INIT_ENTRY_STAGE:-selinux_setup}"
