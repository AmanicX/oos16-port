#!/system/bin/sh
# ==============================================================================
# scripts/watchdog.sh - State-Based Safety Watchdog & Health Monitor
# OxygenOS 16 RAM Bringup on OnePlus 7T (HD1901 / hotdogb)
#
# Implements robust multi-state lifecycle:
#   1. STAGE1_WAIT    : Monitors host heartbeat while awaiting Stage-1 /mnt/boot_now
#   2. STAGE2_RUNNING : Monitors both device-side and host-side heartbeats during bringup
#   3. HEALTH_MONITOR : Monitors Android init until sys.boot_completed=1
#   4. BOOT_COMPLETED : Clean exit 0 upon verified Android boot
#   5. DISARMED       : Atomic, explicit disarm via cancellation flag
#
# Configurable via environment variables for production & test isolation.
# ==============================================================================

# Helper for logging to kmsg and stderr
log_msg() {
    [ -w /dev/kmsg ] && echo "$1" > /dev/kmsg 2>/dev/null || true
    echo "$1" >&2
}

# 1. Configuration Validation & Safe Fallbacks
validate_timeout() {
    local var_name="$1"
    local raw_val="$2"
    local default_val="$3"
    local min_val="$4"
    local max_val="$5"

    case "$raw_val" in
        ''|*[!0-9]*)
            log_msg "[WATCHDOG WARN] Invalid $var_name '$raw_val'. Falling back to safe default (${default_val}s)."
            echo "$default_val"
            return 0
            ;;
    esac

    # Guard against shell arithmetic overflow with large digit strings (> 5 digits exceeds 86400)
    if [ "${#raw_val}" -gt 5 ]; then
        log_msg "[WATCHDOG WARN] $var_name '$raw_val' exceeds maximum (${max_val}s). Falling back to safe default (${default_val}s)."
        echo "$default_val"
        return 0
    fi

    if [ "$raw_val" -le 0 ]; then
        log_msg "[WATCHDOG WARN] Non-positive $var_name '$raw_val'. Falling back to safe default (${default_val}s)."
        echo "$default_val"
    elif [ "$raw_val" -lt "$min_val" ]; then
        log_msg "[WATCHDOG WARN] $var_name '$raw_val' is below minimum (${min_val}s). Falling back to safe default (${default_val}s)."
        echo "$default_val"
    elif [ "$raw_val" -gt "$max_val" ]; then
        log_msg "[WATCHDOG WARN] $var_name '$raw_val' exceeds maximum (${max_val}s). Falling back to safe default (${default_val}s)."
        echo "$default_val"
    else
        echo "$raw_val"
    fi
}

TIMEOUT=$(validate_timeout "WATCHDOG_TIMEOUT" "${WATCHDOG_TIMEOUT-60}" 60 1 86400)
STAGE2_TIMEOUT=$(validate_timeout "WATCHDOG_STAGE2_TIMEOUT" "${WATCHDOG_STAGE2_TIMEOUT-120}" 120 1 86400)
# Default first boot health timeout: 600s (10 minutes)
HEALTH_TIMEOUT=$(validate_timeout "WATCHDOG_HEALTH_TIMEOUT" "${WATCHDOG_HEALTH_TIMEOUT-600}" 600 1 86400)

RAW_SLEEP="${WATCHDOG_SLEEP_INTERVAL-1}"
validate_sleep_interval() {
    local raw="$1"
    case "$raw" in
        ''|*[!0-9.]*)
            log_msg "[WATCHDOG WARN] Invalid non-numeric WATCHDOG_SLEEP_INTERVAL '$raw'. Falling back to default (1s)."
            echo "1"
            return 0
            ;;
        *.*.*)
            log_msg "[WATCHDOG WARN] Malformed WATCHDOG_SLEEP_INTERVAL '$raw' (multiple decimal points). Falling back to default (1s)."
            echo "1"
            return 0
            ;;
        .*)
            log_msg "[WATCHDOG WARN] Malformed WATCHDOG_SLEEP_INTERVAL '$raw' (leading decimal point prohibited). Falling back to default (1s)."
            echo "1"
            return 0
            ;;
        *.)
            log_msg "[WATCHDOG WARN] Malformed WATCHDOG_SLEEP_INTERVAL '$raw' (trailing decimal point prohibited). Falling back to default (1s)."
            echo "1"
            return 0
            ;;
    esac

    local int_part="${raw%%.*}"
    local frac_part=""
    case "$raw" in
        *.*) frac_part="${raw#*.}" ;;
    esac

    if [ "${#int_part}" -gt 2 ]; then
        log_msg "[WATCHDOG WARN] WATCHDOG_SLEEP_INTERVAL '$raw' exceeds maximum (60s). Falling back to default (1s)."
        echo "1"
        return 0
    fi

    local all_zero=1
    case "$int_part" in
        *[!0]*) all_zero=0 ;;
    esac
    if [ "$all_zero" -eq 1 ] && [ -n "$frac_part" ]; then
        case "$frac_part" in
            *[!0]*) all_zero=0 ;;
        esac
    fi

    if [ "$all_zero" -eq 1 ]; then
        log_msg "[WATCHDOG WARN] Zero WATCHDOG_SLEEP_INTERVAL '$raw' prohibited. Falling back to default (1s)."
        echo "1"
        return 0
    fi

    local clean_int="${int_part#"${int_part%%[!0]*}"}"
    local int_num="${clean_int:-0}"

    if [ "$int_num" -gt 60 ]; then
        log_msg "[WATCHDOG WARN] WATCHDOG_SLEEP_INTERVAL '$raw' exceeds maximum (60s). Falling back to default (1s)."
        echo "1"
        return 0
    elif [ "$int_num" -eq 60 ] && [ -n "$frac_part" ]; then
        case "$frac_part" in
            *[!0]*)
                log_msg "[WATCHDOG WARN] WATCHDOG_SLEEP_INTERVAL '$raw' exceeds maximum (60s). Falling back to default (1s)."
                echo "1"
                return 0
                ;;
        esac
    fi

    echo "$raw"
}
SLEEP_INTERVAL=$(validate_sleep_interval "$RAW_SLEEP")

RAW_MAX_TICKS="${WATCHDOG_MAX_TICKS:-0}"
case "$RAW_MAX_TICKS" in
    ''|*[!0-9]*)
        log_msg "[WATCHDOG WARN] Invalid non-numeric WATCHDOG_MAX_TICKS '$RAW_MAX_TICKS'. Falling back to safe default (0)."
        MAX_TICKS=0
        ;;
    *)
        if [ "${#RAW_MAX_TICKS}" -gt 7 ]; then
            log_msg "[WATCHDOG WARN] WATCHDOG_MAX_TICKS '$RAW_MAX_TICKS' exceeds 1000000. Falling back to default (0)."
            MAX_TICKS=0
        elif [ "$RAW_MAX_TICKS" -gt 1000000 ]; then
            log_msg "[WATCHDOG WARN] WATCHDOG_MAX_TICKS '$RAW_MAX_TICKS' exceeds 1000000. Falling back to default (0)."
            MAX_TICKS=0
        else
            MAX_TICKS="$RAW_MAX_TICKS"
        fi
        ;;
esac

HEARTBEAT_FILE="${WATCHDOG_HEARTBEAT_FILE:-/mnt/watchdog_heartbeat}"
DEVICE_HEARTBEAT_FILE="${WATCHDOG_DEVICE_HEARTBEAT_FILE:-/mnt/stage2_heartbeat}"
ACK_FILE="${WATCHDOG_ACK_FILE:-/mnt/stage1_ack}"
DONE_FILE="${WATCHDOG_DONE_FILE:-/mnt/stage2_done}"
CANCEL_FILE="${WATCHDOG_CANCEL_FILE:-/mnt/watchdog_cancel}"
STATE_FILE="${WATCHDOG_STATE_FILE:-/mnt/watchdog_state}"
REBOOT_BIN="${REBOOT_BIN:-/system/bin/reboot}"
GETPROP_BIN="${GETPROP_BIN:-/system/bin/getprop}"
CHROOT_BIN="${CHROOT_BIN:-/system/bin/chroot}"
STAT_BIN="${STAT_BIN:-}"
WATCHDOG_INVENTORY_FILE="${WATCHDOG_INVENTORY_FILE:-}"
WATCHDOG_INVENTORY_FILE_TMP="${WATCHDOG_INVENTORY_FILE_TMP:-}"
WATCHDOG_INVENTORY_MNT="${WATCHDOG_INVENTORY_MNT:-}"
WATCHDOG_INVENTORY_TMP="${WATCHDOG_INVENTORY_TMP:-}"
SYS_BLOCK_DIR="${SYS_BLOCK_DIR:-/sys/block}"
DEV_BLOCK_DIR="${DEV_BLOCK_DIR:-/dev/block}"
WATCHDOG_TEST_MODE="${WATCHDOG_TEST_MODE:-0}"

# Atomic state writer using temp file and rename
set_state() {
    local new_state="$1"
    CURRENT_STATE="$new_state"
    local tmp_file="${STATE_FILE}.tmp.$$"
    if echo "$new_state" > "$tmp_file" 2>/dev/null; then
        mv -f "$tmp_file" "$STATE_FILE" 2>/dev/null || echo "$new_state" > "$STATE_FILE" 2>/dev/null || true
    else
        echo "$new_state" > "$STATE_FILE" 2>/dev/null || true
    fi
}

# Helper to validate and consume a heartbeat file
check_and_consume_heartbeat() {
    local target="$1"
    if [ -L "$target" ]; then
        log_msg "[WATCHDOG WARN] Malformed heartbeat: '$target' is a symlink! Rejected."
        return 1
    elif [ -d "$target" ]; then
        log_msg "[WATCHDOG WARN] Malformed heartbeat: '$target' is a directory! Rejected."
        return 1
    elif [ -f "$target" ]; then
        rm -f "$target" 2>/dev/null || true
        return 0
    fi
    return 2
}

# Helper to query Android's actual sys.boot_completed property
query_boot_completed() {
    local val=""
    # 1. Check via chroot into /mnt/sysroot if available
    if [ -d /mnt/sysroot ] && [ -x "$CHROOT_BIN" ] && [ -x /mnt/sysroot/system/bin/getprop ]; then
        val=$("$CHROOT_BIN" /mnt/sysroot /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d '[:space:]')
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    fi

    # 2. Check via direct getprop binary
    if [ -x "$GETPROP_BIN" ]; then
        val=$("$GETPROP_BIN" sys.boot_completed 2>/dev/null | tr -d '[:space:]')
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    elif command -v getprop >/dev/null 2>&1; then
        val=$(getprop sys.boot_completed 2>/dev/null | tr -d '[:space:]')
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
    fi

    echo ""
    return 1
}

# Critical Safety Emergency Trigger: Record violation, update state, trigger reboot, and exit 1
trigger_storage_violation() {
    local reason="$1"
    log_msg "[WATCHDOG FATAL] Storage safety violation: $reason! Emergency rebooting!"
    set_state "STORAGE_VIOLATION"
    if [ -x "$REBOOT_BIN" ]; then
        "$REBOOT_BIN" bootloader || true
    elif command -v reboot >/dev/null 2>&1; then
        reboot bootloader 2>/dev/null || true
    else
        /system/bin/reboot bootloader 2>/dev/null || true
    fi
    exit 1
}

# Helper to strictly verify block device node identity and fail-closed
verify_block_node_identity() {
    local check_node="$1"
    local exp_maj="$2"
    local exp_min="$3"
    local dev_name="$4"

    # 1. Device node existence
    if [ ! -e "$check_node" ]; then
        trigger_storage_violation "Block device node '$dev_name' does not exist"
    fi

    # 2. Block special device enforcement (fail-closed in production)
    if [ "$WATCHDOG_TEST_MODE" = "1" ]; then
        if [ ! -b "$check_node" ] && [ ! -f "$check_node" ]; then
            trigger_storage_violation "Device node '$dev_name' is neither block special nor test mock file"
        fi
    else
        if [ ! -b "$check_node" ]; then
            trigger_storage_violation "Device node '$dev_name' is NOT a block device"
        fi
    fi

    # 3. Stat identity verification
    # Required for real block-special devices, and for test mocks when explicitly verifying stat
    local should_verify_stat=0
    if [ -b "$check_node" ]; then
        should_verify_stat=1
    elif [ "$WATCHDOG_TEST_MODE" = "1" ]; then
        if [ "${WATCHDOG_TEST_VERIFY_STAT:-0}" = "1" ] || [ -n "${STAT_RAW_OUTPUT+x}" ] || [ "${STAT_FAIL:-0}" = "1" ]; then
            should_verify_stat=1
        fi
    fi

    if [ "$should_verify_stat" -eq 1 ]; then
        local stat_out=""
        local stat_st=0
        if [ -n "${STAT_BIN:-}" ] && [ -x "$STAT_BIN" ]; then
            stat_out=$("$STAT_BIN" -L -c "%t:%T" "$check_node" 2>&1) || stat_st=$?
        elif [ -x /system/bin/toybox ]; then
            stat_out=$(/system/bin/toybox stat -L -c "%t:%T" "$check_node" 2>&1) || stat_st=$?
        elif command -v stat >/dev/null 2>&1; then
            stat_out=$(stat -L -c "%t:%T" "$check_node" 2>&1) || stat_st=$?
        else
            trigger_storage_violation "No stat binary available to verify block device node identity for '$dev_name'"
        fi

        if [ "$stat_st" -ne 0 ]; then
            trigger_storage_violation "stat -L -c '%t:%T' failed on block node '$dev_name' with exit code $stat_st ($stat_out)"
        fi

        local clean_stat
        clean_stat=$(echo "$stat_out" | tr -d '[:space:]')
        if [ -z "$clean_stat" ]; then
            trigger_storage_violation "Empty stat output for block node '$dev_name'"
        fi

        # Require exactly 2 fields separated by 1 colon
        local num_colons
        num_colons=$(echo "$clean_stat" | tr -cd ':' | wc -c)
        if [ "$num_colons" -ne 1 ]; then
            trigger_storage_violation "Malformed stat output '$clean_stat' for block node '$dev_name' (expected 2 colon-separated fields)"
        fi

        local hex_maj="${clean_stat%%:*}"
        local hex_min="${clean_stat##*:}"
        if [ -z "$hex_maj" ] || [ -z "$hex_min" ]; then
            trigger_storage_violation "Malformed stat output '$clean_stat' for block node '$dev_name' (empty major or minor)"
        fi

        case "$hex_maj" in
            ''|*[!0-9a-fA-F]*)
                trigger_storage_violation "Non-hexadecimal major '$hex_maj' in stat output for '$dev_name'"
                ;;
        esac
        case "$hex_min" in
            ''|*[!0-9a-fA-F]*)
                trigger_storage_violation "Non-hexadecimal minor '$hex_min' in stat output for '$dev_name'"
                ;;
        esac

        # POSIX-compliant conversion of hexadecimal to decimal
        local dec_maj dec_min
        dec_maj=$(printf "%d" "0x$hex_maj" 2>/dev/null) || trigger_storage_violation "Failed to convert major '0x$hex_maj' to decimal"
        dec_min=$(printf "%d" "0x$hex_min" 2>/dev/null) || trigger_storage_violation "Failed to convert minor '0x$hex_min' to decimal"

        # Reject unexpected zero identity values (0:0 is invalid for physical storage devices)
        if [ "$dec_maj" -eq 0 ] && [ "$dec_min" -eq 0 ]; then
            trigger_storage_violation "Unexpected zero device identity (0:0) for physical block node '$dev_name'"
        fi

        # Compare resulting decimal values with expected sysfs dev
        if [ "$dec_maj" != "$exp_maj" ] || [ "$dec_min" != "$exp_min" ]; then
            trigger_storage_violation "Block node '$dev_name' major:minor ($dec_maj:$dec_min) does not match sysfs ($exp_maj:$exp_min)"
        fi
    fi
}

# Reusable watchdog inventory-update function enforcing two-copy synchronization
watchdog_atomic_update_inventory() {
    local record="$1"
    local inv_mnt="$INV_MNT"
    local inv_tmp="$INV_TMP"

    # Reject duplicate record or device
    local dev_node="${record%%:*}"
    if grep -q -F "$record" "$inv_mnt" 2>/dev/null || grep -q "^${dev_node}:" "$inv_mnt" 2>/dev/null; then
        trigger_storage_violation "Duplicate record '$record' already exists in inventory '$inv_mnt'"
    fi
    if grep -q -F "$record" "$inv_tmp" 2>/dev/null || grep -q "^${dev_node}:" "$inv_tmp" 2>/dev/null; then
        trigger_storage_violation "Duplicate record '$record' already exists in inventory '$inv_tmp'"
    fi

    # Verify both source inventories exist, are readable, non-empty, and byte-identical
    if [ ! -f "$inv_mnt" ]; then
        trigger_storage_violation "Cannot update inventory: '$inv_mnt' missing"
    fi
    if [ ! -f "$inv_tmp" ]; then
        trigger_storage_violation "Cannot update inventory: '$inv_tmp' missing"
    fi
    if [ ! -r "$inv_mnt" ]; then
        trigger_storage_violation "Cannot update inventory: '$inv_mnt' is not readable"
    fi
    if [ ! -r "$inv_tmp" ]; then
        trigger_storage_violation "Cannot update inventory: '$inv_tmp' is not readable"
    fi
    if [ ! -s "$inv_mnt" ]; then
        trigger_storage_violation "Cannot update inventory: '$inv_mnt' is empty (0 bytes)"
    fi
    if [ ! -s "$inv_tmp" ]; then
        trigger_storage_violation "Cannot update inventory: '$inv_tmp' is empty (0 bytes)"
    fi
    if ! cmp -s "$inv_mnt" "$inv_tmp"; then
        trigger_storage_violation "Cannot update inventory: '$inv_mnt' and '$inv_tmp' are not byte-identical prior to update"
    fi

    # Determine staging paths on each target filesystem
    local mnt_dir tmp_dir m_staging t_staging
    mnt_dir=$(dirname "$inv_mnt")
    tmp_dir=$(dirname "$inv_tmp")
    m_staging="$mnt_dir/inventory.staging.$$.$RANDOM"
    t_staging="$tmp_dir/inventory.staging.$$.$RANDOM"

    # Copy to staging
    if ! cp -f "$inv_mnt" "$m_staging" 2>/dev/null; then
        rm -f "$m_staging" "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Failed to copy '$inv_mnt' to staging '$m_staging'"
    fi
    if ! cp -f "$inv_tmp" "$t_staging" 2>/dev/null; then
        rm -f "$m_staging" "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Failed to copy '$inv_tmp' to staging '$t_staging'"
    fi

    # Append record
    if ! echo "$record" >> "$m_staging"; then
        rm -f "$m_staging" "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Failed to append record to staging '$m_staging'"
    fi
    if ! echo "$record" >> "$t_staging"; then
        rm -f "$m_staging" "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Failed to append record to staging '$t_staging'"
    fi

    # Verify record appears exactly once in m_staging
    local m_count t_count
    m_count=$(grep -c -F "$record" "$m_staging" 2>/dev/null || echo "0")
    if [ "$m_count" -ne 1 ]; then
        rm -f "$m_staging" "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Record count verification failed in '$m_staging' (count=$m_count, expected 1)"
    fi

    # Verify record appears exactly once in t_staging
    t_count=$(grep -c -F "$record" "$t_staging" 2>/dev/null || echo "0")
    if [ "$t_count" -ne 1 ]; then
        rm -f "$m_staging" "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Record count verification failed in '$t_staging' (count=$t_count, expected 1)"
    fi

    # Verify both staged files are byte-identical
    if ! cmp -s "$m_staging" "$t_staging"; then
        rm -f "$m_staging" "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Staged inventory files are not byte-identical prior to publication"
    fi

    # Publish both updated inventories via rename
    local m_mv_st=0 t_mv_st=0
    mv -f "$m_staging" "$inv_mnt" 2>/dev/null || m_mv_st=$?
    if [ "$m_mv_st" -ne 0 ]; then
        rm -f "$m_staging" "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Failed to publish staged inventory to '$inv_mnt' (mv exit code $m_mv_st)"
    fi

    mv -f "$t_staging" "$inv_tmp" 2>/dev/null || t_mv_st=$?
    if [ "$t_mv_st" -ne 0 ]; then
        rm -f "$t_staging" 2>/dev/null || true
        trigger_storage_violation "Failed to publish staged inventory to '$inv_tmp' (mv exit code $t_mv_st)"
    fi

    # Verify final byte identity
    if ! cmp -s "$inv_mnt" "$inv_tmp"; then
        trigger_storage_violation "Published inventories byte-identity mismatch after update between '$inv_mnt' and '$inv_tmp'"
    fi
}

# Helper to verify physical storage read-only state continuously & fail-closed
check_storage_inventory_safety() {
    INV_MNT="${WATCHDOG_INVENTORY_MNT:-${WATCHDOG_INVENTORY_FILE:-/mnt/physical_storage_inventory}}"
    INV_TMP="${WATCHDOG_INVENTORY_TMP:-${WATCHDOG_INVENTORY_FILE_TMP:-/tmp/physical_storage_inventory}}"

    if [ "${WATCHDOG_TEST_MODE:-0}" != "1" ]; then
        if [ ! -f "$INV_MNT" ]; then
            trigger_storage_violation "Physical storage inventory missing at mandatory production path '$INV_MNT'"
        fi
        if [ ! -f "$INV_TMP" ]; then
            trigger_storage_violation "Physical storage inventory missing at mandatory production path '$INV_TMP'"
        fi
        if [ ! -r "$INV_MNT" ]; then
            trigger_storage_violation "Physical storage inventory '$INV_MNT' is not readable"
        fi
        if [ ! -r "$INV_TMP" ]; then
            trigger_storage_violation "Physical storage inventory '$INV_TMP' is not readable"
        fi
        if [ ! -s "$INV_MNT" ]; then
            trigger_storage_violation "Physical storage inventory '$INV_MNT' is empty (0 bytes)"
        fi
        if [ ! -s "$INV_TMP" ]; then
            trigger_storage_violation "Physical storage inventory '$INV_TMP' is empty (0 bytes)"
        fi
        if ! cmp -s "$INV_MNT" "$INV_TMP"; then
            trigger_storage_violation "Initial physical storage inventory byte-identity mismatch between '$INV_MNT' and '$INV_TMP'"
        fi
    else
        if [ ! -f "$INV_MNT" ]; then
            trigger_storage_violation "Physical storage inventory missing at '$INV_MNT'"
        fi
        if [ ! -f "$INV_TMP" ]; then
            trigger_storage_violation "Physical storage inventory missing at '$INV_TMP'"
        fi
        if [ ! -r "$INV_MNT" ]; then
            trigger_storage_violation "Physical storage inventory '$INV_MNT' is not readable"
        fi
        if [ ! -r "$INV_TMP" ]; then
            trigger_storage_violation "Physical storage inventory '$INV_TMP' is not readable"
        fi
        if [ ! -s "$INV_MNT" ]; then
            trigger_storage_violation "Physical storage inventory '$INV_MNT' is empty (0 bytes)"
        fi
        if [ ! -s "$INV_TMP" ]; then
            trigger_storage_violation "Physical storage inventory '$INV_TMP' is empty (0 bytes)"
        fi
        if ! cmp -s "$INV_MNT" "$INV_TMP"; then
            trigger_storage_violation "Initial physical storage inventory byte-identity mismatch between '$INV_MNT' and '$INV_TMP'"
        fi
    fi

    local inv="$INV_MNT"

    local sys_block_root="${SYS_BLOCK_DIR:-/sys/block}"
    local dev_block_root="${DEV_BLOCK_DIR:-/dev/block}"

    local seen_devs=" "
    local valid_entries=0

    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading and trailing whitespace
        local trimmed
        trimmed=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$trimmed" in ''|\#*) continue ;; esac

        # Verify exactly 4 colon-separated fields (3 colons)
        local num_colons
        num_colons=$(echo "$trimmed" | tr -cd ':' | wc -c)
        if [ "$num_colons" -ne 3 ]; then
            trigger_storage_violation "Malformed inventory entry '$trimmed' in $inv (expected 4 colon-separated fields)"
        fi

        local dev maj min sdir
        dev=$(echo "$trimmed" | cut -d: -f1 | tr -d '[:space:]')
        maj=$(echo "$trimmed" | cut -d: -f2 | tr -d '[:space:]')
        min=$(echo "$trimmed" | cut -d: -f3 | tr -d '[:space:]')
        sdir=$(echo "$trimmed" | cut -d: -f4 | tr -d '[:space:]')

        if [ -z "$dev" ] || [ -z "$maj" ] || [ -z "$min" ] || [ -z "$sdir" ]; then
            trigger_storage_violation "Malformed inventory entry '$trimmed' in $inv (empty field detected)"
        fi

        case "$maj" in ''|*[!0-9]*) trigger_storage_violation "Non-numeric major number '$maj' in $inv" ;; esac
        case "$min" in ''|*[!0-9]*) trigger_storage_violation "Non-numeric minor number '$min' in $inv" ;; esac

        # Check duplicate entries in inventory
        case "$seen_devs" in
            *" $dev "*)
                trigger_storage_violation "Duplicate device '$dev' found in inventory $inv" ;;
        esac
        seen_devs="$seen_devs$dev "

        # Resolve paths for test isolation
        local check_dev="$dev"
        if [ -n "${DEV_BLOCK_DIR:-}" ]; then
            local rel_dev="${dev#/dev/block/}"
            if [ "$rel_dev" != "$dev" ]; then
                check_dev="$dev_block_root/$rel_dev"
            fi
        fi

        local check_sdir="$sdir"
        if [ -n "${SYS_BLOCK_DIR:-}" ]; then
            local rel_sdir="${sdir#/sys/block/}"
            if [ "$rel_sdir" != "$sdir" ]; then
                check_sdir="$sys_block_root/$rel_sdir"
            fi
        fi

        # 1. Device node existence and strict block-node identity verification
        verify_block_node_identity "$check_dev" "$maj" "$min" "$dev"

        # 3. Sysfs directory and dev file existence (disappearing detection)
        if [ ! -d "$check_sdir" ] || [ ! -f "$check_sdir/dev" ]; then
            trigger_storage_violation "Sysfs directory or dev file for '$dev' ($sdir) disappeared or does not exist"
        fi

        # 4. Major:minor match against sysfs
        local sys_mm
        sys_mm=$(cat "$check_sdir/dev" 2>/dev/null | tr -d '[:space:]')
        if [ "$sys_mm" != "$maj:$min" ]; then
            trigger_storage_violation "Major:minor mismatch for '$dev' ($sys_mm != $maj:$min)"
        fi

        # 5. Query blockdev --getro (MUST succeed with exit 0 and output == 1; NO fallback to 1)
        local ro_out=""
        local ro_status=0
        if [ -x /system/bin/toybox ]; then
            ro_out=$(/system/bin/toybox blockdev --getro "$check_dev" 2>&1) || ro_status=$?
        elif command -v blockdev >/dev/null 2>&1; then
            ro_out=$(blockdev --getro "$check_dev" 2>&1) || ro_status=$?
        else
            trigger_storage_violation "No blockdev binary available to query read-only state"
        fi

        if [ "$ro_status" -ne 0 ]; then
            trigger_storage_violation "blockdev --getro failed on '$dev' with exit code $ro_status ($ro_out)"
        fi

        local clean_ro
        clean_ro=$(echo "$ro_out" | tr -d '[:space:]')
        if [ "$clean_ro" != "1" ]; then
            trigger_storage_violation "Block device '$dev' is NOT read-only (ro=$clean_ro, expected 1)"
        fi

        valid_entries=$((valid_entries + 1))
    done < "$inv"

    if [ "$valid_entries" -eq 0 ]; then
        trigger_storage_violation "Physical storage inventory '$inv' contains zero valid device records"
    fi

    # 6. Completeness: independently scan sysfs to detect newly appearing devices
    if [ -d "$sys_block_root" ]; then
        for bdir in "$sys_block_root"/*; do
            [ -d "$bdir" ] || continue
            local bname
            bname=$(basename "$bdir")
            case "$bname" in loop*|ram*|zram*|dm-*) continue ;; esac

            if [ -e "$bdir/device" ] || case "$bname" in sd*|mmcblk*) true ;; *) false ;; esac; then
                local disk_dev="/dev/block/$bname"
                case "$seen_devs" in
                    *" $disk_dev "*) ;;
                    *)
                        log_msg "[WATCHDOG WARNING] Detected newly appearing physical disk: $disk_dev"
                        if [ ! -f "$bdir/dev" ]; then
                            trigger_storage_violation "Newly appearing physical disk '$disk_dev' lacks sysfs dev file"
                        fi
                        local d_mm
                        d_mm=$(cat "$bdir/dev" 2>/dev/null | tr -d '[:space:]')
                        case "$d_mm" in ''|*[!0-9:]*|*:*[:]*|*:|:*)
                            trigger_storage_violation "Newly appearing disk '$disk_dev' has malformed dev file '$d_mm'" ;;
                        esac
                        local d_maj="${d_mm%%:*}"
                        local d_min="${d_mm##*:}"
                        local check_dnode="$disk_dev"
                        [ -n "${DEV_BLOCK_DIR:-}" ] && check_dnode="$dev_block_root/$bname"

                        if [ ! -e "$check_dnode" ]; then
                            local d_mknod_err=""
                            local d_mknod_st=0
                            if [ -x /system/bin/toybox ]; then
                                d_mknod_err=$(/system/bin/toybox mknod "$check_dnode" b "$d_maj" "$d_min" 2>&1) || d_mknod_st=$?
                            elif command -v mknod >/dev/null 2>&1; then
                                d_mknod_err=$(mknod "$check_dnode" b "$d_maj" "$d_min" 2>&1) || d_mknod_st=$?
                            else
                                trigger_storage_violation "No mknod binary available to create device node for newly appearing disk '$disk_dev'"
                            fi
                            if [ "$d_mknod_st" -ne 0 ]; then
                                trigger_storage_violation "mknod failed for newly appearing disk '$disk_dev' with exit code $d_mknod_st ($d_mknod_err)"
                            fi
                        fi
                        # Strict block node identity verification
                        verify_block_node_identity "$check_dnode" "$d_maj" "$d_min" "$disk_dev"

                        # Lock read-only
                        local setro_status=0
                        local setro_err=""
                        if [ -x /system/bin/toybox ]; then
                            setro_err=$(/system/bin/toybox blockdev --setro "$check_dnode" 2>&1) || setro_status=$?
                        elif command -v blockdev >/dev/null 2>&1; then
                            setro_err=$(blockdev --setro "$check_dnode" 2>&1) || setro_status=$?
                        else
                            trigger_storage_violation "No blockdev binary available to set read-only on newly appearing disk '$disk_dev'"
                        fi
                        if [ "$setro_status" -ne 0 ]; then
                            trigger_storage_violation "Failed to execute blockdev --setro on newly appearing disk '$disk_dev' (exit code $setro_status: $setro_err)"
                        fi

                        local d_ro=""
                        local d_ro_st=0
                        if [ -x /system/bin/toybox ]; then
                            d_ro=$(/system/bin/toybox blockdev --getro "$check_dnode" 2>&1) || d_ro_st=$?
                        elif command -v blockdev >/dev/null 2>&1; then
                            d_ro=$(blockdev --getro "$check_dnode" 2>&1) || d_ro_st=$?
                        else
                            trigger_storage_violation "No blockdev binary available to query read-only on newly appearing disk '$disk_dev'"
                        fi
                        if [ "$d_ro_st" -ne 0 ]; then
                            trigger_storage_violation "blockdev --getro failed on newly appearing disk '$disk_dev' with exit code $d_ro_st ($d_ro)"
                        fi
                        local clean_d_ro
                        clean_d_ro=$(echo "$d_ro" | tr -d '[:space:]')
                        if [ "$clean_d_ro" != "1" ]; then
                            trigger_storage_violation "Newly appearing disk '$disk_dev' could not be locked read-only (ro=$clean_d_ro, expected 1)"
                        fi

                        # Synchronize two-copy inventory atomically
                        watchdog_atomic_update_inventory "$disk_dev:$d_maj:$d_min:$bdir"
                        seen_devs="$seen_devs$disk_dev "
                        log_msg "[WATCHDOG] Locked newly appearing disk read-only: $disk_dev (ro=1) and appended to inventory."
                        ;;
                esac

                # Check child partitions of this disk
                for pdir in "$bdir"/"$bname"*; do
                    [ -d "$pdir" ] || continue
                    local pname
                    pname=$(basename "$pdir")
                    local part_dev="/dev/block/$pname"
                    case "$seen_devs" in
                        *" $part_dev "*) ;;
                        *)
                            log_msg "[WATCHDOG WARNING] Detected newly appearing physical partition: $part_dev"
                            if [ ! -f "$pdir/dev" ]; then
                                trigger_storage_violation "Newly appearing physical partition '$part_dev' lacks sysfs dev file"
                            fi
                            local p_mm
                            p_mm=$(cat "$pdir/dev" 2>/dev/null | tr -d '[:space:]')
                            case "$p_mm" in ''|*[!0-9:]*|*:*[:]*|*:|:*)
                                trigger_storage_violation "Newly appearing partition '$part_dev' has malformed dev file '$p_mm'" ;;
                            esac
                            local p_maj="${p_mm%%:*}"
                            local p_min="${p_mm##*:}"
                            local check_pnode="$part_dev"
                            [ -n "${DEV_BLOCK_DIR:-}" ] && check_pnode="$dev_block_root/$pname"

                            if [ ! -e "$check_pnode" ]; then
                                local p_mknod_err=""
                                local p_mknod_st=0
                                if [ -x /system/bin/toybox ]; then
                                    p_mknod_err=$(/system/bin/toybox mknod "$check_pnode" b "$p_maj" "$p_min" 2>&1) || p_mknod_st=$?
                                elif command -v mknod >/dev/null 2>&1; then
                                    p_mknod_err=$(mknod "$check_pnode" b "$p_maj" "$p_min" 2>&1) || p_mknod_st=$?
                                else
                                    trigger_storage_violation "No mknod binary available to create device node for newly appearing partition '$part_dev'"
                                fi
                                if [ "$p_mknod_st" -ne 0 ]; then
                                    trigger_storage_violation "mknod failed for newly appearing partition '$part_dev' with exit code $p_mknod_st ($p_mknod_err)"
                                fi
                            fi

                            # Strict block node identity verification
                            verify_block_node_identity "$check_pnode" "$p_maj" "$p_min" "$part_dev"

                            local p_setro_st=0
                            local p_setro_err=""
                            if [ -x /system/bin/toybox ]; then
                                p_setro_err=$(/system/bin/toybox blockdev --setro "$check_pnode" 2>&1) || p_setro_st=$?
                            elif command -v blockdev >/dev/null 2>&1; then
                                p_setro_err=$(blockdev --setro "$check_pnode" 2>&1) || p_setro_st=$?
                            else
                                trigger_storage_violation "No blockdev binary available to set read-only on newly appearing partition '$part_dev'"
                            fi
                            if [ "$p_setro_st" -ne 0 ]; then
                                trigger_storage_violation "Failed to execute blockdev --setro on newly appearing partition '$part_dev' (exit code $p_setro_st: $p_setro_err)"
                            fi

                            local p_ro=""
                            local p_ro_st=0
                            if [ -x /system/bin/toybox ]; then
                                p_ro=$(/system/bin/toybox blockdev --getro "$check_pnode" 2>&1) || p_ro_st=$?
                            elif command -v blockdev >/dev/null 2>&1; then
                                p_ro=$(blockdev --getro "$check_pnode" 2>&1) || p_ro_st=$?
                            else
                                trigger_storage_violation "No blockdev binary available to query read-only on newly appearing partition '$part_dev'"
                            fi
                            if [ "$p_ro_st" -ne 0 ]; then
                                trigger_storage_violation "blockdev --getro failed on newly appearing partition '$part_dev' with exit code $p_ro_st ($p_ro)"
                            fi
                            local clean_p_ro
                            clean_p_ro=$(echo "$p_ro" | tr -d '[:space:]')
                            if [ "$clean_p_ro" != "1" ]; then
                                trigger_storage_violation "Newly appearing partition '$part_dev' could not be locked read-only (ro=$clean_p_ro, expected 1)"
                            fi

                            # Synchronize two-copy inventory atomically
                            watchdog_atomic_update_inventory "$part_dev:$p_maj:$p_min:$pdir"
                            seen_devs="$seen_devs$part_dev "
                            log_msg "[WATCHDOG] Locked newly appearing partition read-only: $part_dev (ro=1) and appended to inventory."
                            ;;
                    esac
                done
            fi
        done
    fi

    # 7. Check live mounts for writable physical storage
    local mounts_f="/proc/mounts"
    [ -n "${PROC_MOUNTS_FILE:-}" ] && mounts_f="$PROC_MOUNTS_FILE"
    if [ -f "$mounts_f" ]; then
        if grep -E "^/dev/block/(sd|mmcblk)" "$mounts_f" 2>/dev/null | grep -E "([ ,(]rw[ ,)]|,rw$)" >/dev/null 2>&1; then
            trigger_storage_violation "Detected writable physical mount in $mounts_f"
        fi
    fi
}

set_state "STAGE1_WAIT"
log_msg "[WATCHDOG] Active safety monitor armed (state: $CURRENT_STATE, timeout: ${TIMEOUT}s, heartbeat: $HEARTBEAT_FILE)"

REMAINING=$TIMEOUT
TICKS=0

while true; do
    # Check for cancellation signal (atomic explicit disarm)
    if [ -L "$CANCEL_FILE" ]; then
        log_msg "[WATCHDOG WARN] Cancellation target '$CANCEL_FILE' is a symlink! Ignoring."
    elif [ -f "$CANCEL_FILE" ]; then
        log_msg "[WATCHDOG] Safety cancellation flag detected. Watchdog disarmed."
        set_state "DISARMED"
        exit 0
    fi

    # Continuous physical storage read-only monitoring
    check_storage_inventory_safety

    case "$CURRENT_STATE" in
        STAGE1_WAIT)
            # Check for Stage-1 acknowledgement marker (/mnt/stage1_ack)
            if [ -L "$ACK_FILE" ]; then
                log_msg "[WATCHDOG WARN] Acknowledgement file '$ACK_FILE' is a symlink! Ignoring."
            elif [ -f "$ACK_FILE" ]; then
                set_state "STAGE2_RUNNING"
                REMAINING=$STAGE2_TIMEOUT
                log_msg "[WATCHDOG] Stage-1 acknowledgement detected. Transitioned to STAGE2_RUNNING (timer reset to ${STAGE2_TIMEOUT}s)."
            else
                # Check host heartbeat
                check_and_consume_heartbeat "$HEARTBEAT_FILE"
                hb_res=$?
                if [ "$hb_res" -eq 0 ]; then
                    REMAINING=$TIMEOUT
                    log_msg "[WATCHDOG] Valid heartbeat received. Timer reset to ${TIMEOUT}s."
                elif [ "$HEARTBEAT_FILE" = "/mnt/watchdog_heartbeat" ]; then
                    check_and_consume_heartbeat "/tmp/watchdog_heartbeat"
                    if [ $? -eq 0 ]; then
                        REMAINING=$TIMEOUT
                        log_msg "[WATCHDOG] Valid /tmp heartbeat received. Timer reset to ${TIMEOUT}s."
                    fi
                fi
            fi
            ;;

        STAGE2_RUNNING)
            # Check for Stage-2 completion marker (/mnt/stage2_done)
            if [ -L "$DONE_FILE" ]; then
                log_msg "[WATCHDOG WARN] Stage-2 completion marker '$DONE_FILE' is a symlink! Ignoring."
            elif [ -f "$DONE_FILE" ]; then
                set_state "HEALTH_MONITOR"
                REMAINING=$HEALTH_TIMEOUT
                log_msg "[WATCHDOG] Stage-2 handover complete. Transitioned to HEALTH_MONITOR (timer reset to ${HEALTH_TIMEOUT}s)."
            else
                # Accept either device-side heartbeat or host-side heartbeat without conflict
                hb_consumed=0

                check_and_consume_heartbeat "$DEVICE_HEARTBEAT_FILE"
                if [ $? -eq 0 ]; then
                    hb_consumed=1
                elif [ "$DEVICE_HEARTBEAT_FILE" = "/mnt/stage2_heartbeat" ]; then
                    check_and_consume_heartbeat "/tmp/stage2_heartbeat"
                    [ $? -eq 0 ] && hb_consumed=1
                fi

                check_and_consume_heartbeat "$HEARTBEAT_FILE"
                if [ $? -eq 0 ]; then
                    hb_consumed=1
                elif [ "$HEARTBEAT_FILE" = "/mnt/watchdog_heartbeat" ]; then
                    check_and_consume_heartbeat "/tmp/watchdog_heartbeat"
                    [ $? -eq 0 ] && hb_consumed=1
                fi

                if [ "$hb_consumed" -eq 1 ]; then
                    REMAINING=$STAGE2_TIMEOUT
                    log_msg "[WATCHDOG] Heartbeat received during Stage-2 bringup. Timer reset to ${STAGE2_TIMEOUT}s."
                fi
            fi
            ;;

        HEALTH_MONITOR)
            # Query Android property service for sys.boot_completed=1
            BOOT_COMPLETED=$(query_boot_completed)

            if [ "$BOOT_COMPLETED" = "1" ]; then
                log_msg "[WATCHDOG] Android boot completed successfully (sys.boot_completed=1). Health monitor verified and exiting cleanly."
                set_state "BOOT_COMPLETED"
                exit 0
            fi

            # Check if host or external monitoring sent a heartbeat to pet the timer
            check_and_consume_heartbeat "$HEARTBEAT_FILE"
            if [ $? -eq 0 ]; then
                REMAINING=$HEALTH_TIMEOUT
                log_msg "[WATCHDOG] Host heartbeat received during health monitoring. Timer reset to ${HEALTH_TIMEOUT}s."
            elif [ "$HEARTBEAT_FILE" = "/mnt/watchdog_heartbeat" ]; then
                check_and_consume_heartbeat "/tmp/watchdog_heartbeat"
                if [ $? -eq 0 ]; then
                    REMAINING=$HEALTH_TIMEOUT
                    log_msg "[WATCHDOG] Host /tmp heartbeat received during health monitoring. Timer reset to ${HEALTH_TIMEOUT}s."
                fi
            fi
            ;;
    esac

    REMAINING=$((REMAINING - 1))
    TICKS=$((TICKS + 1))

    if [ "$REMAINING" -le 0 ]; then
        log_msg "[WATCHDOG FATAL] Safety heartbeat lost / timeout reached (0s remaining in state $CURRENT_STATE)!"
        log_msg "[WATCHDOG FATAL] State at failure: $CURRENT_STATE"
        log_msg "[WATCHDOG FATAL] Initiating safe emergency reboot to bootloader..."
        set_state "TIMEOUT_${CURRENT_STATE}"
        if [ -x "$REBOOT_BIN" ]; then
            "$REBOOT_BIN" bootloader
        else
            /system/bin/reboot bootloader 2>/dev/null || true
        fi
        exit 1
    fi

    if [ "$MAX_TICKS" -gt 0 ] && [ "$TICKS" -ge "$MAX_TICKS" ]; then
        log_msg "[WATCHDOG] Reached maximum ticks ($MAX_TICKS). Exiting monitor loop."
        exit 0
    fi

    sleep "$SLEEP_INTERVAL"
done
