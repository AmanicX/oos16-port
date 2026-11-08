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
WATCHDOG_INVENTORY_FILE="${WATCHDOG_INVENTORY_FILE:-}"
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

# Helper to verify physical storage read-only state continuously & fail-closed
check_storage_inventory_safety() {
    local inv=""
    if [ -n "$WATCHDOG_INVENTORY_FILE" ] && [ -f "$WATCHDOG_INVENTORY_FILE" ]; then
        inv="$WATCHDOG_INVENTORY_FILE"
    elif [ -f "/mnt/physical_storage_inventory" ]; then
        inv="/mnt/physical_storage_inventory"
    elif [ -f "/tmp/physical_storage_inventory" ]; then
        inv="/tmp/physical_storage_inventory"
    else
        trigger_storage_violation "Physical storage inventory missing (neither /mnt nor /tmp found)"
    fi

    if [ ! -r "$inv" ]; then
        trigger_storage_violation "Physical storage inventory '$inv' is not readable"
    fi

    if [ ! -s "$inv" ]; then
        trigger_storage_violation "Physical storage inventory '$inv' is empty (0 bytes)"
    fi

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

        # 1. Device node existence
        if [ ! -e "$check_dev" ]; then
            trigger_storage_violation "Block device node '$dev' does not exist"
        fi

        # 2. Device node type: must be block special
        if [ "$WATCHDOG_TEST_MODE" = "1" ]; then
            if [ ! -b "$check_dev" ] && [ ! -f "$check_dev" ]; then
                trigger_storage_violation "Device node '$dev' is neither block special nor test mock file"
            fi
        else
            if [ ! -b "$check_dev" ]; then
                trigger_storage_violation "Device node '$dev' is NOT a block device"
            fi
        fi

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
                            if [ -x /system/bin/toybox ]; then
                                /system/bin/toybox mknod "$check_dnode" b "$d_maj" "$d_min" 2>/dev/null || true
                            elif command -v mknod >/dev/null 2>&1; then
                                mknod "$check_dnode" b "$d_maj" "$d_min" 2>/dev/null || true
                            fi
                        fi
                        if [ "$WATCHDOG_TEST_MODE" != "1" ] && [ ! -b "$check_dnode" ]; then
                            trigger_storage_violation "Failed to create block node for newly appearing disk '$disk_dev'"
                        fi

                        # Lock read-only
                        local setro_status=0
                        if [ -x /system/bin/toybox ]; then
                            /system/bin/toybox blockdev --setro "$check_dnode" >/dev/null 2>&1 || setro_status=$?
                        elif command -v blockdev >/dev/null 2>&1; then
                            blockdev --setro "$check_dnode" >/dev/null 2>&1 || setro_status=$?
                        fi
                        if [ "$setro_status" -ne 0 ]; then
                            trigger_storage_violation "Failed to execute blockdev --setro on newly appearing disk '$disk_dev'"
                        fi

                        local d_ro=""
                        local d_ro_st=0
                        if [ -x /system/bin/toybox ]; then
                            d_ro=$(/system/bin/toybox blockdev --getro "$check_dnode" 2>&1) || d_ro_st=$?
                        elif command -v blockdev >/dev/null 2>&1; then
                            d_ro=$(blockdev --getro "$check_dnode" 2>&1) || d_ro_st=$?
                        fi
                        if [ "$d_ro_st" -ne 0 ] || [ "$(echo "$d_ro" | tr -d '[:space:]')" != "1" ]; then
                            trigger_storage_violation "Newly appearing disk '$disk_dev' could not be locked read-only (ro=$d_ro)"
                        fi

                        echo "$disk_dev:$d_maj:$d_min:$bdir" >> "$inv" || trigger_storage_violation "Failed to append newly appearing disk to inventory $inv"
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
                                if [ -x /system/bin/toybox ]; then
                                    /system/bin/toybox mknod "$check_pnode" b "$p_maj" "$pmin" 2>/dev/null || true
                                elif command -v mknod >/dev/null 2>&1; then
                                    mknod "$check_pnode" b "$p_maj" "$pmin" 2>/dev/null || true
                                fi
                            fi
                            if [ "$WATCHDOG_TEST_MODE" != "1" ] && [ ! -b "$check_pnode" ]; then
                                trigger_storage_violation "Failed to create block node for newly appearing partition '$part_dev'"
                            fi

                            local p_setro_st=0
                            if [ -x /system/bin/toybox ]; then
                                /system/bin/toybox blockdev --setro "$check_pnode" >/dev/null 2>&1 || p_setro_st=$?
                            elif command -v blockdev >/dev/null 2>&1; then
                                blockdev --setro "$check_pnode" >/dev/null 2>&1 || p_setro_st=$?
                            fi
                            if [ "$p_setro_st" -ne 0 ]; then
                                trigger_storage_violation "Failed to execute blockdev --setro on newly appearing partition '$part_dev'"
                            fi

                            local p_ro=""
                            local p_ro_st=0
                            if [ -x /system/bin/toybox ]; then
                                p_ro=$(/system/bin/toybox blockdev --getro "$check_pnode" 2>&1) || p_ro_st=$?
                            elif command -v blockdev >/dev/null 2>&1; then
                                p_ro=$(blockdev --getro "$check_pnode" 2>&1) || p_ro_st=$?
                            fi
                            if [ "$p_ro_st" -ne 0 ] || [ "$(echo "$p_ro" | tr -d '[:space:]')" != "1" ]; then
                                trigger_storage_violation "Newly appearing partition '$part_dev' could not be locked read-only (ro=$p_ro)"
                            fi

                            echo "$part_dev:$p_maj:$p_min:$pdir" >> "$inv" || trigger_storage_violation "Failed to append newly appearing partition to inventory $inv"
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
