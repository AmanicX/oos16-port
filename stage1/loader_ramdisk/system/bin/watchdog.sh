#!/system/bin/sh
# ==============================================================================
# scripts/watchdog.sh - State-Based Safety Watchdog & Heartbeat Monitor
# OxygenOS 16 RAM Bringup on OnePlus 7T (HD1901 / hotdogb)
#
# Implements robust multi-state lifecycle:
#   1. STAGE1_WAIT    : Monitors host heartbeat while awaiting Stage-1 /mnt/boot_now
#   2. STAGE2_RUNNING : Monitors both device-side and host-side heartbeats during bringup
#   3. HEALTH_MONITOR : Monitors Android init until sys.boot_completed=1
#   4. DISARMED       : Atomic, explicit disarm via cancellation flag
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
HEALTH_TIMEOUT="${WATCHDOG_HEALTH_TIMEOUT:-180}"

HEARTBEAT_FILE="${WATCHDOG_HEARTBEAT_FILE:-/mnt/watchdog_heartbeat}"
DEVICE_HEARTBEAT_FILE="${WATCHDOG_DEVICE_HEARTBEAT_FILE:-/mnt/stage2_heartbeat}"
ACK_FILE="${WATCHDOG_ACK_FILE:-/mnt/stage1_ack}"
DONE_FILE="${WATCHDOG_DONE_FILE:-/mnt/stage2_done}"
CANCEL_FILE="${WATCHDOG_CANCEL_FILE:-/mnt/watchdog_cancel}"
STATE_FILE="${WATCHDOG_STATE_FILE:-/mnt/watchdog_state}"
REBOOT_BIN="${REBOOT_BIN:-/system/bin/reboot}"
GETPROP_BIN="${GETPROP_BIN:-/system/bin/getprop}"
SLEEP_INTERVAL="${WATCHDOG_SLEEP_INTERVAL:-1}"
MAX_TICKS="${WATCHDOG_MAX_TICKS:-0}"

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

CURRENT_STATE="STAGE1_WAIT"
echo "$CURRENT_STATE" > "$STATE_FILE" 2>/dev/null || true

log_msg "[WATCHDOG] Active safety monitor armed (state: $CURRENT_STATE, timeout: ${TIMEOUT}s, heartbeat: $HEARTBEAT_FILE)"

REMAINING=$TIMEOUT
TICKS=0

while true; do
    # Check for cancellation signal (atomic explicit disarm)
    if [ -L "$CANCEL_FILE" ]; then
        log_msg "[WATCHDOG WARN] Cancellation target '$CANCEL_FILE' is a symlink! Ignoring."
    elif [ -f "$CANCEL_FILE" ]; then
        log_msg "[WATCHDOG] Safety cancellation flag detected. Watchdog disarmed."
        CURRENT_STATE="DISARMED"
        echo "$CURRENT_STATE" > "$STATE_FILE" 2>/dev/null || true
        exit 0
    fi

    case "$CURRENT_STATE" in
        STAGE1_WAIT)
            # Check for Stage-1 acknowledgement marker (/mnt/stage1_ack)
            if [ -L "$ACK_FILE" ]; then
                log_msg "[WATCHDOG WARN] Acknowledgement file '$ACK_FILE' is a symlink! Ignoring."
            elif [ -f "$ACK_FILE" ]; then
                CURRENT_STATE="STAGE2_RUNNING"
                echo "$CURRENT_STATE" > "$STATE_FILE" 2>/dev/null || true
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
                CURRENT_STATE="HEALTH_MONITOR"
                echo "$CURRENT_STATE" > "$STATE_FILE" 2>/dev/null || true
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
            # Check Android boot milestone: sys.boot_completed=1
            BOOT_COMPLETED=""
            if [ -x "$GETPROP_BIN" ]; then
                BOOT_COMPLETED=$("$GETPROP_BIN" sys.boot_completed 2>/dev/null | tr -d '[:space:]')
            elif command -v getprop >/dev/null 2>&1; then
                BOOT_COMPLETED=$(getprop sys.boot_completed 2>/dev/null | tr -d '[:space:]')
            fi

            if [ "$BOOT_COMPLETED" = "1" ]; then
                log_msg "[WATCHDOG] Android boot completed successfully (sys.boot_completed=1). Health monitor verified and exiting cleanly."
                CURRENT_STATE="BOOT_COMPLETED"
                echo "$CURRENT_STATE" > "$STATE_FILE" 2>/dev/null || true
                exit 0
            fi

            # Also allow host or device heartbeats to pet timer if monitored externally
            check_and_consume_heartbeat "$HEARTBEAT_FILE"
            if [ $? -eq 0 ]; then
                REMAINING=$HEALTH_TIMEOUT
                log_msg "[WATCHDOG] External heartbeat received during health monitoring. Timer reset to ${HEALTH_TIMEOUT}s."
            fi
            ;;
    esac

    REMAINING=$((REMAINING - 1))
    TICKS=$((TICKS + 1))

    if [ "$REMAINING" -le 0 ]; then
        log_msg "[WATCHDOG FATAL] Safety heartbeat lost for ${TIMEOUT}s! Host connection lost."
        log_msg "[WATCHDOG FATAL] State at failure: $CURRENT_STATE. Initiating safe emergency reboot to bootloader..."
        echo "TIMEOUT_${CURRENT_STATE}" > "$STATE_FILE" 2>/dev/null || true
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
