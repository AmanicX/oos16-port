#!/system/bin/sh
# ==============================================================================
# scripts/watchdog.sh - Stage-1 Safety Watchdog & Heartbeat Monitor
# OxygenOS 16 RAM Bringup on OnePlus 7T (HD1901)
#
# Monitors $WATCHDOG_HEARTBEAT_FILE. If host connection is lost and heartbeat
# ceases for $WATCHDOG_TIMEOUT seconds, triggers safe emergency reboot.
# Configurable via environment variables for production & test isolation.
# ==============================================================================

# Helper for logging
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

HEARTBEAT_FILE="${WATCHDOG_HEARTBEAT_FILE:-/mnt/watchdog_heartbeat}"
CANCEL_FILE="${WATCHDOG_CANCEL_FILE:-/mnt/watchdog_cancel}"
REBOOT_BIN="${REBOOT_BIN:-/system/bin/reboot}"
SLEEP_INTERVAL="${WATCHDOG_SLEEP_INTERVAL:-1}"
MAX_TICKS="${WATCHDOG_MAX_TICKS:-0}"

log_msg "[WATCHDOG] Active safety monitor armed (timeout: ${TIMEOUT}s, heartbeat: $HEARTBEAT_FILE)"

REMAINING=$TIMEOUT
TICKS=0

while true; do
    # Check for cancellation signal (disarms watchdog)
    if [ -L "$CANCEL_FILE" ]; then
        log_msg "[WATCHDOG WARN] Cancellation target '$CANCEL_FILE' is a symlink! Ignoring."
    elif [ -f "$CANCEL_FILE" ]; then
        log_msg "[WATCHDOG] Safety cancellation flag detected. Watchdog disarmed."
        REMAINING=86400
    fi

    # Check for heartbeat file
    if [ -L "$HEARTBEAT_FILE" ]; then
        log_msg "[WATCHDOG WARN] Malformed heartbeat: '$HEARTBEAT_FILE' is a symlink! Rejected."
    elif [ -d "$HEARTBEAT_FILE" ]; then
        log_msg "[WATCHDOG WARN] Malformed heartbeat: '$HEARTBEAT_FILE' is a directory! Rejected."
    elif [ -f "$HEARTBEAT_FILE" ]; then
        # Valid regular heartbeat file (empty or token-bearing).
        # Race-safe consumption: remove file so stale state does not persist.
        rm -f "$HEARTBEAT_FILE" 2>/dev/null || true
        REMAINING=$TIMEOUT
        log_msg "[WATCHDOG] Valid heartbeat received. Timer reset to ${TIMEOUT}s."
    fi

    # Check also fallback /tmp locations if default /mnt is checked and /tmp file exists
    if [ "$HEARTBEAT_FILE" = "/mnt/watchdog_heartbeat" ]; then
        if [ -L "/tmp/watchdog_heartbeat" ]; then
            log_msg "[WATCHDOG WARN] Malformed /tmp heartbeat: symlink rejected."
        elif [ -d "/tmp/watchdog_heartbeat" ]; then
            log_msg "[WATCHDOG WARN] Malformed /tmp heartbeat: directory rejected."
        elif [ -f "/tmp/watchdog_heartbeat" ]; then
            rm -f "/tmp/watchdog_heartbeat" 2>/dev/null || true
            REMAINING=$TIMEOUT
            log_msg "[WATCHDOG] Valid /tmp heartbeat received. Timer reset to ${TIMEOUT}s."
        fi
    fi

    REMAINING=$((REMAINING - 1))
    TICKS=$((TICKS + 1))

    if [ "$REMAINING" -le 0 ]; then
        log_msg "[WATCHDOG FATAL] Safety heartbeat lost for ${TIMEOUT}s! Host connection lost."
        log_msg "[WATCHDOG FATAL] Initiating safe emergency reboot to bootloader..."
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
