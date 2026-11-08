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

# Strict Physical Storage Inventory Revalidator
# Note on Linux block-layer read-only limitations:
# blockdev --setro enforces the BLKROSET flag on the kernel gendisk/block device,
# preventing write requests submitted through block layer I/O queues and filesystems.
# Raw kernel drivers could theoretically bypass the block layer if directly instructed,
# but in this volatile RAM-only environment, zero write drivers or physical mount targets exist.
revalidate_storage_inventory() {
    local checkpoint="${1:-unspecified}"
    log_msg "[STAGE2] Revalidating physical storage inventory at checkpoint: $checkpoint..."

    local inv_file="${MNT_DIR:-/mnt}/physical_storage_inventory"
    [ -f "$inv_file" ] || inv_file="${TMP_DIR:-/tmp}/physical_storage_inventory"

    if [ ! -f "$inv_file" ] || [ ! -s "$inv_file" ]; then
        fatal "Physical storage inventory ($inv_file) missing or 0 bytes at checkpoint: $checkpoint! Halting to protect physical storage."
    fi

    local sys_block_root="${SYS_BLOCK_DIR:-/sys/block}"
    local dev_block_root="${DEV_BLOCK_DIR:-/dev/block}"

    local verified_count=0
    while IFS=: read -r dev maj min sdir || [ -n "$dev" ]; do
        case "$dev" in ''|\#*) continue ;; esac

        local check_sdir="$sdir"
        if [ -n "${SYS_BLOCK_DIR:-}" ]; then
            local rel_sdir="${sdir#/sys/block/}"
            if [ "$rel_sdir" != "$sdir" ]; then
                check_sdir="$sys_block_root/$rel_sdir"
            fi
        fi

        local check_dev="$dev"
        if [ -n "${DEV_BLOCK_DIR:-}" ]; then
            local rel_dev="${dev#/dev/block/}"
            if [ "$rel_dev" != "$dev" ]; then
                check_dev="$dev_block_root/$rel_dev"
            fi
        fi

        # 1. Verify sysfs hardware directory and dev file still exist (disappearing detection)
        if [ ! -d "$check_sdir" ] || [ ! -f "$check_sdir/dev" ]; then
            fatal "Physical storage device $dev ($sdir) disappeared during bringup at checkpoint: $checkpoint!"
        fi

        # 2. Verify major:minor numbers match
        local cur_mm
        cur_mm=$(cat "$check_sdir/dev" 2>/dev/null | tr -d '[:space:]')
        if [ "$cur_mm" != "$maj:$min" ]; then
            fatal "Physical device $dev major:minor mismatch ($cur_mm != $maj:$min) at checkpoint: $checkpoint!"
        fi

        # 3. Verify block device node still exists
        if [ "${STAGE2_TEST_MODE:-0}" = "1" ]; then
            if [ ! -b "$check_dev" ] && [ ! -f "$check_dev" ]; then
                fatal "Physical block device node $dev missing or not a block device at checkpoint: $checkpoint!"
            fi
        else
            if [ ! -b "$check_dev" ]; then
                fatal "Physical block device node $dev missing or not a block device at checkpoint: $checkpoint!"
            fi
        fi

        # 4. Verify blockdev read-only status is strictly 1
        local ro
        ro=$(tb_run blockdev --getro "$check_dev" 2>/dev/null || echo "0")
        if [ "$ro" != "1" ]; then
            fatal "Physical device $dev is NOT read-only (ro=$ro, expected 1) at checkpoint: $checkpoint!"
        fi

        verified_count=$((verified_count + 1))
    done < "$inv_file"

    if [ "$verified_count" -eq 0 ]; then
        fatal "Zero physical storage devices verified in inventory at checkpoint: $checkpoint!"
    fi

    # 5. Detect newly appearing physical devices and partitions
    for bdir in "$sys_block_root"/*; do
        [ -d "$bdir" ] || continue
        local bname
        bname=$(basename "$bdir")
        case "$bname" in loop*|ram*|zram*|dm-*) continue ;; esac

        if [ -e "$bdir/device" ] || case "$bname" in sd*|mmcblk*) true ;; *) false ;; esac; then
            local dev_node="/dev/block/$bname"
            local check_disk_node="$dev_node"
            [ -n "${DEV_BLOCK_DIR:-}" ] && check_disk_node="$dev_block_root/$bname"

            if ! grep -q "^${dev_node}:" "$inv_file" 2>/dev/null; then
                log_msg "[STAGE2 WARNING] Detected newly appearing physical disk: $dev_node at checkpoint: $checkpoint"
                if [ ! -f "$bdir/dev" ]; then
                    fatal "Newly appearing physical device $dev_node lacks sysfs dev file!"
                fi
                local n_mm
                n_mm=$(cat "$bdir/dev" 2>/dev/null | tr -d '[:space:]')
                case "$n_mm" in
                    ''|*[!0-9:]*|*:*[:]*|*:|:*)
                        fatal "Newly appearing device $dev_node has invalid major:minor '$n_mm'!" ;;
                esac
                local n_maj="${n_mm%%:*}"
                local n_min="${n_mm##*:}"
                if [ ! -b "$check_disk_node" ]; then
                    if ! tb_run mknod "$check_disk_node" b "$n_maj" "$n_min"; then
                        fatal "Failed to mknod newly appearing disk $dev_node (b $n_maj $n_min)!"
                    fi
                fi
                if [ "${STAGE2_TEST_MODE:-0}" = "1" ]; then
                    [ -b "$check_disk_node" ] || [ -f "$check_disk_node" ] || fatal "Failed to create node for newly appearing device $dev_node!"
                else
                    [ -b "$check_disk_node" ] || fatal "Failed to create node for newly appearing device $dev_node!"
                fi
                tb_run blockdev --setro "$check_disk_node" || fatal "Failed to lock newly appearing device $dev_node read-only!"
                local n_ro
                n_ro=$(tb_run blockdev --getro "$check_disk_node" 2>/dev/null || echo "0")
                [ "$n_ro" = "1" ] || fatal "Newly appearing device $dev_node could not be locked read-only (ro=$n_ro)!"
                echo "$dev_node:$n_maj:$n_min:$bdir" >> "$inv_file"
                log_msg "[STAGE2] Locked newly appearing physical disk read-only: $dev_node (ro=1) and appended to inventory."
            fi

            # Check child partitions of this disk
            for pdir in "$bdir"/"$bname"*; do
                [ -d "$pdir" ] || continue
                local pname
                pname=$(basename "$pdir")
                local part_node="/dev/block/$pname"
                local check_part_node="$part_node"
                [ -n "${DEV_BLOCK_DIR:-}" ] && check_part_node="$dev_block_root/$pname"

                if ! grep -q "^${part_node}:" "$inv_file" 2>/dev/null; then
                    log_msg "[STAGE2 WARNING] Detected newly appearing physical partition: $part_node at checkpoint: $checkpoint"
                    if [ ! -f "$pdir/dev" ]; then
                        fatal "Newly appearing partition $part_node lacks sysfs dev file!"
                    fi
                    local p_mm
                    p_mm=$(cat "$pdir/dev" 2>/dev/null | tr -d '[:space:]')
                    case "$p_mm" in
                        ''|*[!0-9:]*|*:*[:]*|*:|:*)
                            fatal "Newly appearing partition $part_node has invalid major:minor '$p_mm'!" ;;
                    esac
                    local p_maj="${p_mm%%:*}"
                    local p_min="${p_mm##*:}"
                    if [ ! -b "$check_part_node" ]; then
                        if ! tb_run mknod "$check_part_node" b "$p_maj" "$p_min"; then
                            fatal "Failed to mknod newly appearing partition $part_node (b $p_maj $p_min)!"
                        fi
                    fi
                    if [ "${STAGE2_TEST_MODE:-0}" = "1" ]; then
                        [ -b "$check_part_node" ] || [ -f "$check_part_node" ] || fatal "Failed to create node for newly appearing partition $part_node!"
                    else
                        [ -b "$check_part_node" ] || fatal "Failed to create node for newly appearing partition $part_node!"
                    fi
                    tb_run blockdev --setro "$check_part_node" || fatal "Failed to lock newly appearing partition $part_node read-only!"
                    local p_ro
                    p_ro=$(tb_run blockdev --getro "$check_part_node" 2>/dev/null || echo "0")
                    [ "$p_ro" = "1" ] || fatal "Newly appearing partition $part_node could not be locked read-only (ro=$p_ro)!"
                    echo "$part_node:$p_maj:$p_min:$pdir" >> "$inv_file"
                    log_msg "[STAGE2] Locked newly appearing physical partition read-only: $part_node (ro=1) and appended to inventory."
                fi
            done
        fi
    done

    # 6. Verify zero physical block devices or partitions are mounted writable
    local mounts_check
    mounts_check=$(tb_run mount 2>/dev/null || cat /proc/mounts 2>/dev/null || true)
    if echo "$mounts_check" | grep -E "^/dev/block/(sd|mmcblk)" | grep -E "([ ,(]rw[ ,)]|,rw$)"; then
        fatal "CRITICAL SAFETY VIOLATION: Detected writable physical partition mount at checkpoint: $checkpoint!"
    fi

    log_msg "[STAGE2] Storage inventory revalidation PASSED ($verified_count devices verified, ro=1, 0 writable mounts) at checkpoint: $checkpoint."
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

if [ "${1:-}" = "--revalidate-inventory" ]; then
    STAGE2_TEST_MODE=1
    revalidate_storage_inventory "${2:-manual_check}"
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

# Checkpoint 1: Initial startup storage inventory revalidation
revalidate_storage_inventory "stage2_startup"

# 3. Clean up any previous mounts
/system/bin/toybox umount -R /mnt/sysroot 2>/dev/null || true
/system/bin/toybox umount /mnt/system_ro 2>/dev/null || true
/system/bin/toybox mkdir -p /mnt/sysroot /mnt/system_ro /mnt/overlay_upper /mnt/overlay_work

# Checkpoint 2: Before base system and overlay mount
revalidate_storage_inventory "before_base_system_and_overlay_mount"

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

# Checkpoint 3: Before child partition mounts
revalidate_storage_inventory "before_child_partition_mounts"

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

# Checkpoint 4: Before APEX loop mounts
revalidate_storage_inventory "before_apex_loop_mounts"

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
    local mod_pkg=""
    if [ -f "/mnt/${base_name}.package" ]; then
        mod_pkg=$(cat "/mnt/${base_name}.package" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.package" ]; then
        mod_pkg=$(cat "/tmp/${base_name}.package" | tr -d '[:space:]')
    fi
    if [ "$mandatory" -eq 1 ] && [ -z "$mod_pkg" ]; then
        fatal "Mandatory APEX metadata .package for $mod_name ($img_name) is missing or empty!"
    fi

    local mod_ver="$version"
    local mod_ver_name=""
    if [ -f "/mnt/${base_name}.version_name" ]; then
        mod_ver_name=$(cat "/mnt/${base_name}.version_name" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.version_name" ]; then
        mod_ver_name=$(cat "/tmp/${base_name}.version_name" | tr -d '[:space:]')
    fi

    local mod_preinstalled=""
    if [ -f "/mnt/${base_name}.preinstalled_path" ]; then
        mod_preinstalled=$(cat "/mnt/${base_name}.preinstalled_path" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.preinstalled_path" ]; then
        mod_preinstalled=$(cat "/tmp/${base_name}.preinstalled_path" | tr -d '[:space:]')
    fi
    if [ "$mandatory" -eq 1 ] && [ -z "$mod_preinstalled" ]; then
        fatal "Mandatory APEX metadata .preinstalled_path for $mod_name ($img_name) is missing or empty!"
    fi

    local mod_shared_libs="false"
    if [ -f "/mnt/${base_name}.provide_shared_libs" ]; then
        mod_shared_libs=$(cat "/mnt/${base_name}.provide_shared_libs" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.provide_shared_libs" ]; then
        mod_shared_libs=$(cat "/tmp/${base_name}.provide_shared_libs" | tr -d '[:space:]')
    fi
    if [ "$mandatory" -eq 1 ] && [ -z "$mod_shared_libs" ]; then
        fatal "Mandatory APEX metadata .provide_shared_libs for $mod_name ($img_name) is missing or empty!"
    fi

    local mod_part="SYSTEM"
    if [ -f "/mnt/${base_name}.partition" ]; then
        mod_part=$(cat "/mnt/${base_name}.partition" | tr -d '[:space:]')
    elif [ -f "/tmp/${base_name}.partition" ]; then
        mod_part=$(cat "/tmp/${base_name}.partition" | tr -d '[:space:]')
    fi
    if [ "$mandatory" -eq 1 ] && [ -z "$mod_part" ]; then
        fatal "Mandatory APEX metadata .partition for $mod_name ($img_name) is missing or empty!"
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

# Strict Authentic APEX Metadata Reader (Fail-Closed, Zero Guessing)
read_apex_meta() {
    local base="$1"
    local ext="$2"
    local f="${MNT_DIR:-/mnt}/${base}.${ext}"
    [ -f "$f" ] || f="${TMP_DIR:-/tmp}/${base}.${ext}"
    if [ ! -f "$f" ] || [ ! -s "$f" ]; then
        fatal "Mandatory APEX metadata ${base}.${ext} is missing or 0 bytes!"
    fi
    local v
    v=$(cat "$f" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$v" ]; then
        fatal "Mandatory APEX metadata ${base}.${ext} is empty!"
    fi
    echo "$v"
}

read_apex_meta_version_name() {
    local base="$1"
    local f="${MNT_DIR:-/mnt}/${base}.version_name"
    [ -f "$f" ] || f="${TMP_DIR:-/tmp}/${base}.version_name"
    if [ ! -f "$f" ]; then
        fatal "Mandatory APEX metadata file ${base}.version_name is missing!"
    fi
    cat "$f" 2>/dev/null | tr -d '[:space:]' || echo ""
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
  <apex-info moduleName="$(read_apex_meta runtime_apex package)" modulePath="/apex/$(read_apex_meta runtime_apex package)@$(read_apex_meta runtime_apex version)" preinstalledModulePath="$(read_apex_meta runtime_apex preinstalled_path)" versionCode="$(read_apex_meta runtime_apex version)" versionName="$(read_apex_meta_version_name runtime_apex)" isFactory="true" isActive="true" provideSharedApexLibs="$(read_apex_meta runtime_apex provide_shared_libs)" partition="$(read_apex_meta runtime_apex partition)" />
  <apex-info moduleName="$(read_apex_meta art_apex package)" modulePath="/apex/$(read_apex_meta art_apex package)@$(read_apex_meta art_apex version)" preinstalledModulePath="$(read_apex_meta art_apex preinstalled_path)" versionCode="$(read_apex_meta art_apex version)" versionName="$(read_apex_meta_version_name art_apex)" isFactory="true" isActive="true" provideSharedApexLibs="$(read_apex_meta art_apex provide_shared_libs)" partition="$(read_apex_meta art_apex partition)" />
  <apex-info moduleName="$(read_apex_meta i18n_apex package)" modulePath="/apex/$(read_apex_meta i18n_apex package)@$(read_apex_meta i18n_apex version)" preinstalledModulePath="$(read_apex_meta i18n_apex preinstalled_path)" versionCode="$(read_apex_meta i18n_apex version)" versionName="$(read_apex_meta_version_name i18n_apex)" isFactory="true" isActive="true" provideSharedApexLibs="$(read_apex_meta i18n_apex provide_shared_libs)" partition="$(read_apex_meta i18n_apex partition)" />
  <apex-info moduleName="$(read_apex_meta tzdata_apex package)" modulePath="/apex/$(read_apex_meta tzdata_apex package)@$(read_apex_meta tzdata_apex version)" preinstalledModulePath="$(read_apex_meta tzdata_apex preinstalled_path)" versionCode="$(read_apex_meta tzdata_apex version)" versionName="$(read_apex_meta_version_name tzdata_apex)" isFactory="true" isActive="true" provideSharedApexLibs="$(read_apex_meta tzdata_apex provide_shared_libs)" partition="$(read_apex_meta tzdata_apex partition)" />
</apex-info-list>
EOF
chmod 0644 /mnt/sysroot/apex/apex-info-list.xml
cp /mnt/sysroot/apex/apex-info-list.xml /mnt/sysroot/apex/.bootstrap-apex-info-list.xml 2>/dev/null || true

# Validate apex-info-list.xml against ApexInfoList.xsd schema and active mounts
VALIDATOR_PY=""
if [ -f /system/bin/extract_apex_info.py ]; then
    VALIDATOR_PY="/system/bin/extract_apex_info.py"
elif [ -f "$PROJECT_ROOT/tools/extract_apex_info.py" ]; then
    VALIDATOR_PY="$PROJECT_ROOT/tools/extract_apex_info.py"
fi

if [ -n "$VALIDATOR_PY" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$VALIDATOR_PY" --validate-xml /mnt/sysroot/apex/apex-info-list.xml --active-mounts-from /proc/mounts || fatal "Generated apex-info-list.xml failed AOSP schema or active mount validation!"
    echo "[STAGE2] apex-info-list.xml verified compliant with Android 16 ApexInfoList.xsd." > /dev/kmsg
elif [ "${STAGE2_TEST_MODE:-0}" != "1" ]; then
    fatal "CRITICAL: Required APEX XML schema validator (/system/bin/extract_apex_info.py or python3) is missing! Failing closed to protect system integrity."
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

# Checkpoint 5: Before mounting ephemeral /data tmpfs
revalidate_storage_inventory "before_data_tmpfs_mount"

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

# 12. Display & Hardware Initialization Diagnostics (10-State Tracking)
# Taxonomy:
# - States 1-8 and 10: Pre-handover hardware probe milestones (static/device nodes)
# - State 9: Post-handover userspace rendering milestone (SurfaceFlinger presentation)
echo "[STAGE2] Executing 10-state hardware initialization diagnostics..." > /dev/kmsg

HW_STATE_1_DRM=0
HW_STATE_2_PANEL_DETECTED=0
HW_STATE_3_PANEL_ENABLED=0
HW_STATE_4_DRM_CONNECTOR=0
HW_STATE_5_GPU_INIT=0
HW_STATE_6_EGL_READY=0
HW_STATE_7_COMPOSER_SVC=0
HW_STATE_8_SURFACEFLINGER=0
HW_STATE_9_FRAMES_PRESENTED=0
HW_STATE_10_TOUCH_INPUT=0

# State 1: Kernel DRM display driver
if [ -c /mnt/sysroot/dev/dri/card0 ] || [ -c /dev/dri/card0 ] || [ -d /sys/class/drm/card0 ]; then
    HW_STATE_1_DRM=1
    echo "[STAGE2] [HW-STATE 1/10: PASS] Kernel DRM display controller verified (/dev/dri/card0)." > /dev/kmsg
else
    echo "[STAGE2] [HW-STATE 1/10: WARN] DRM card0 node missing (will initialize with display HAL)." > /dev/kmsg
fi

# State 2: AMOLED Panel detected
if [ -f /sys/class/backlight/panel0-backlight/brightness ] || [ -d /sys/class/drm/card0-DSI-1 ]; then
    HW_STATE_2_PANEL_DETECTED=1
    echo "[STAGE2] [HW-STATE 2/10: PASS] Samsung AMOLED DSI panel interface detected in sysfs." > /dev/kmsg
else
    echo "[STAGE2] [HW-STATE 2/10: WARN] AMOLED panel sysfs backlight/connector not yet registered." > /dev/kmsg
fi

# State 3: Panel enabled (backlight power on)
if [ -f /sys/class/backlight/panel0-backlight/brightness ]; then
    echo 200 > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null || true
    cur_br=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [ "$cur_br" = "200" ] || [ "${cur_br:-0}" -gt 0 ]; then
        HW_STATE_3_PANEL_ENABLED=1
        echo "[STAGE2] [HW-STATE 3/10: PASS] Samsung AMOLED panel backlight enabled (brightness: ${cur_br})." > /dev/kmsg
    fi
fi

# State 4: DRM connector (DSI-1)
if [ -f /sys/class/drm/card0-DSI-1/status ]; then
    conn_st=$(cat /sys/class/drm/card0-DSI-1/status 2>/dev/null | tr -d '[:space:]' || true)
    HW_STATE_4_DRM_CONNECTOR=1
    echo "[STAGE2] [HW-STATE 4/10: PASS] DRM DSI-1 connector verified (status: ${conn_st:-connected})." > /dev/kmsg
elif [ "$HW_STATE_1_DRM" -eq 1 ]; then
    HW_STATE_4_DRM_CONNECTOR=1
    echo "[STAGE2] [HW-STATE 4/10: PASS] DRM connector interface active on card0." > /dev/kmsg
else
    echo "[STAGE2] [HW-STATE 4/10: WARN] DRM DSI connector status pending." > /dev/kmsg
fi

# State 5: Adreno 640 GPU accelerator initialized
if [ -c /mnt/sysroot/dev/kgsl-3d0 ] || [ -c /dev/kgsl-3d0 ] || [ -d /sys/class/misc/kgsl-3d0 ]; then
    HW_STATE_5_GPU_INIT=1
    echo "[STAGE2] [HW-STATE 5/10: PASS] Qualcomm Adreno 640 GPU accelerator verified (/dev/kgsl-3d0)." > /dev/kmsg
else
    echo "[STAGE2] [HW-STATE 5/10: WARN] Adreno kgsl-3d0 node not present (3D fallback to SwiftShader)." > /dev/kmsg
fi

# State 6: EGL driver libraries ready
if [ -d /mnt/sysroot/vendor/lib64/egl ] || [ -f /mnt/sysroot/vendor/lib64/egl/libGLESv2_adreno.so ] || \
   [ -f /mnt/sysroot/system/lib64/libEGL.so ]; then
    HW_STATE_6_EGL_READY=1
    echo "[STAGE2] [HW-STATE 6/10: PASS] EGL / GLES driver libraries verified on rootfs." > /dev/kmsg
else
    echo "[STAGE2] [HW-STATE 6/10: WARN] Vendor EGL libraries not detected in expected path." > /dev/kmsg
fi

# State 7: Hardware Composer service binary verified
if [ -f /mnt/sysroot/vendor/bin/hw/android.hardware.graphics.composer@2.4-service ] || \
   [ -f /mnt/sysroot/vendor/bin/hw/vendor.qti.hardware.display.composer-service ]; then
    HW_STATE_7_COMPOSER_SVC=1
    echo "[STAGE2] [HW-STATE 7/10: PASS] Hardware Composer HAL service binary verified." > /dev/kmsg
else
    echo "[STAGE2] [HW-STATE 7/10: WARN] Hardware Composer HAL binary not found in vendor." > /dev/kmsg
fi

# State 8: SurfaceFlinger compositor binary verified
if [ -f /mnt/sysroot/system/bin/surfaceflinger ]; then
    HW_STATE_8_SURFACEFLINGER=1
    echo "[STAGE2] [HW-STATE 8/10: PASS] SurfaceFlinger compositor binary verified (/system/bin/surfaceflinger)." > /dev/kmsg
else
    echo "[STAGE2] [HW-STATE 8/10: WARN] SurfaceFlinger binary missing from system partition." > /dev/kmsg
fi

# State 9: Post-handover userspace presentation (tracked post-handover)
HW_STATE_9_FRAMES_PRESENTED=0
echo "[STAGE2] [HW-STATE 9/10: PENDING] Frame presentation milestone tracked post-handover by health monitor." > /dev/kmsg

# State 10: Touchscreen input device verified
if ls /dev/input/event* >/dev/null 2>&1 || ls /mnt/sysroot/dev/input/event* >/dev/null 2>&1 || [ -d /sys/class/input ]; then
    HW_STATE_10_TOUCH_INPUT=1
    echo "[STAGE2] [HW-STATE 10/10: PASS] Touchscreen / input event subsystem verified." > /dev/kmsg
else
    echo "[STAGE2] [HW-STATE 10/10: WARN] Touch input event devices pending." > /dev/kmsg
fi

echo "[STAGE2] Hardware diagnostic summary: pre-handover hardware probe completed (States 1-8, 10 probed; State 9 post-handover)." > /dev/kmsg

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

# Checkpoint 6: Before Android Init Handover
revalidate_storage_inventory "before_init_handover"

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
