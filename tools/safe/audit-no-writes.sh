#!/usr/bin/env bash
set -euo pipefail

# audit-no-writes.sh
# Verifies that an image, initramfs, fstab, cmdline, or directory contains
# ZERO references to writable physical partitions, userdata, super, misc,
# boot-control services, format/wipe commands, or storage write traps.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOGS_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOGS_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="$LOGS_DIR/audit-report-$TIMESTAMP.log"

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <path_to_image_or_extracted_dir>"
    exit 1
fi

echo "==========================================================" | tee "$REPORT_FILE"
echo "        PRE-BOOT AUDIT: ZERO PHYSICAL WRITES VERIFICATION " | tee -a "$REPORT_FILE"
echo "        Target: $TARGET" | tee -a "$REPORT_FILE"
echo "        Timestamp: $TIMESTAMP" | tee -a "$REPORT_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"

VIOLATIONS=0

audit_fail() {
    local rule="$1"
    local details="$2"
    echo " [FAILED RULE] $rule" | tee -a "$REPORT_FILE"
    echo "    $details" | tee -a "$REPORT_FILE"
    VIOLATIONS=$((VIOLATIONS + 1))
}

audit_pass() {
    local rule="$1"
    echo " [PASSED] $rule" | tee -a "$REPORT_FILE"
}

# 1. Check if target is a file or directory
TMP_INSPECT_DIR=""
if [ -f "$TARGET" ]; then
    TMP_INSPECT_DIR="$(mktemp -d /tmp/audit_target.XXXXXX)"
    echo "Scanning single file / image: $TARGET" | tee -a "$REPORT_FILE"
    # Search binary string occurrences
    SCAN_PATH="$TARGET"
else
    SCAN_PATH="$TARGET"
fi

# Forbidden strings in fstab, init.rc, cmdline
FORBIDDEN_KEYWORDS=(
    "mount_all /vendor/etc/fstab"
    "mount ext4 /dev/block"
    "mount f2fs /dev/block"
    "userdata"
    "/dev/block/bootdevice/by-name/userdata"
    "/dev/block/by-name/userdata"
    "super"
    "/dev/block/bootdevice/by-name/super"
    "update_verifier"
    "update_engine"
    "android.hardware.boot"
    "bootctl"
    "format_userdata"
    "wipe_data"
    "recovery --wipe_data"
    "BLKROSET 0"
    "blockdev --setrw"
    "fastboot flash"
    "fastboot erase"
)

echo "--- Scanning for forbidden write trap keywords ---" | tee -a "$REPORT_FILE"
for kw in "${FORBIDDEN_KEYWORDS[@]}"; do
    if grep -rInF --binary-files=text "$kw" "$SCAN_PATH" 2>/dev/null; then
        audit_fail "Forbidden keyword found" "Found: '$kw'"
    fi
done

# Check fstab files for writable flags on physical partitions
if [ -d "$SCAN_PATH" ]; then
    FSTABS=$(find "$SCAN_PATH" -type f -name "*fstab*" -o -name "*.rc")
    for f in $FSTABS; do
        if grep -E "^/dev/block" "$f" 2>/dev/null | grep -v -E "tmpfs|ram|loop|zram" | grep -E "rw|formattable|check|latemount"; then
            audit_fail "Writable physical mount in fstab" "File: $f"
        fi
    done
fi

echo "==========================================================" | tee -a "$REPORT_FILE"
if [ "$VIOLATIONS" -eq 0 ]; then
    echo " [AUDIT RESULT: 100% CLEAN - NO WRITES DETECTED]" | tee -a "$REPORT_FILE"
    echo " Image is verified safe for RAM-only fastboot boot." | tee -a "$REPORT_FILE"
    echo " Full audit report: $REPORT_FILE" | tee -a "$REPORT_FILE"
    echo "==========================================================" | tee -a "$REPORT_FILE"
    exit 0
else
    echo " [AUDIT RESULT: REJECTED - $VIOLATIONS SAFETY VIOLATION(S)]" | tee -a "$REPORT_FILE"
    echo " FASTBOOT BOOT IS STRICTLY PROHIBITED UNTIL RESOLVED." | tee -a "$REPORT_FILE"
    echo " Full audit report: $REPORT_FILE" | tee -a "$REPORT_FILE"
    echo "==========================================================" | tee -a "$REPORT_FILE"
    exit 1
fi
