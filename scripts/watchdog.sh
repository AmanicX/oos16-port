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
RAW_TIMEOUT="${WATCHDOG_TIMEOUT:-60}"
case "$RAW_TIMEOUT" in
    ''|*[!0-9]*)
        log_msg "[WATCHDOG WARN] Invalid WATCHDOG_TIMEOUT '$RAW_TIMEOUT'. Falling back to safe default (60s)."
        TIMEOUT=60
        ;;
    *)
        if [ "$RAW_TIMEOUT" -le 0 ]; then
            log_msg "[WATCHDOG WARN] Non-positive WATCHDOG_TIMEOUT '$RAW_TIMEOUT'. Falling back to safe default (60s)."
            TIMEOUT=60
        else
            TIMEOUT="$RAW_TIMEOUT"
        fi
        ;;
esac

STAGE2_TIMEOUT="${WATCHDOG_STAGE2_TIMEOUT:-120}"
# Default first boot health timeout: 600s (10 minutes)
HEALTH_TIMEOUT="${WATCHDOG_HEALTH_TIMEOUT:-600}"

HEARTBEAT_FILE="${WATCHDOG_HEARTBEAT_FILE:-/mnt/watchdog_heartbeat}"
DEVICE_HEARTBEAT_FILE="${WATCHDOG_DEVICE_HEARTBEAT_FILE:-/mnt/stage2_heartbeat}"
ACK_FILE="${WATCHDOG_ACK_FILE:-/mnt/stage1_ack}"
DONE_FILE="${WATCHDOG_DONE_FILE:-/mnt/stage2_done}"
CANCEL_FILE="${WATCHDOG_CANCEL_FILE:-/mnt/watchdog_cancel}"
STATE_FILE="${WATCHDOG_STATE_FILE:-/mnt/watchdog_state}"
REBOOT_BIN="${REBOOT_BIN:-/system/bin/reboot}"
GETPROP_BIN="${GETPROP_BIN:-/system/bin/getprop}"
CHROOT_BIN="${CHROOT_BIN:-/system/bin/chroot}"
SLEEP_INTERVAL="${WATCHDOG_SLEEP_INTERVAL:-1}"
MAX_TICKS="${WATCHDOG_MAX_TICKS:-0}"

# Atomic state writer using temp file and rename
set_state() {
    local new_state="$1"
    CURRENT_STATE="$new_state"
    local tmp_file="${STATE_FILE}.tmp.$$"
    echo "$new_state" > "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$STATE_FILE" 2>/dev/null || true
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
