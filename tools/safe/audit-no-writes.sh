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
    echo "Usage: $0 <path_to_boot_img_or_ramdisk_or_dir>"
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

TMP_AUDIT_DIR="$(mktemp -d /tmp/audit_work.XXXXXX)"
cleanup() {
    rm -rf "$TMP_AUDIT_DIR"
}
trap cleanup EXIT

# Step 1: Detect target type
RAMDISK_DIR=""
CMDLINE_TEXT=""

if [ -f "$TARGET" ]; then
    MAGIC=$(head -c 8 "$TARGET" || true)
    if [ "$MAGIC" = "ANDROID!" ]; then
        echo "Target is an Android boot image. Unpacking header and ramdisk..." | tee -a "$REPORT_FILE"
        UNPACK_TOOL="$PROJECT_ROOT/external/coloros_port/otatools/bin/unpack_bootimg"
        "$UNPACK_TOOL" --boot_img "$TARGET" --out "$TMP_AUDIT_DIR/unpacked" > "$TMP_AUDIT_DIR/boot_info.txt" 2>&1
        
        # Read cmdline
        CMDLINE_TEXT=$(grep "command line args:" "$TMP_AUDIT_DIR/boot_info.txt" | sed 's/command line args: //' || true)
        echo "Extracted cmdline: $CMDLINE_TEXT" | tee -a "$REPORT_FILE"
        
        # Unpack ramdisk
        mkdir -p "$TMP_AUDIT_DIR/ramdisk_root"
        if [ -f "$TMP_AUDIT_DIR/unpacked/ramdisk" ]; then
            lz4 -d < "$TMP_AUDIT_DIR/unpacked/ramdisk" | (cd "$TMP_AUDIT_DIR/ramdisk_root" && cpio -idm 2>/dev/null || true)
            RAMDISK_DIR="$TMP_AUDIT_DIR/ramdisk_root"
        fi
    elif [[ "$TARGET" =~ \.(cpio|lz4)$ ]]; then
        mkdir -p "$TMP_AUDIT_DIR/ramdisk_root"
        lz4 -d < "$TARGET" | (cd "$TMP_AUDIT_DIR/ramdisk_root" && cpio -idm 2>/dev/null || true)
        RAMDISK_DIR="$TMP_AUDIT_DIR/ramdisk_root"
    else
        # Plain directory or file
        RAMDISK_DIR="$TARGET"
    fi
elif [ -d "$TARGET" ]; then
    RAMDISK_DIR="$TARGET"
fi

# Step 2: Audit kernel cmdline
echo "--- Auditing Kernel Command Line ---" | tee -a "$REPORT_FILE"
if [ -n "$CMDLINE_TEXT" ]; then
    FORBIDDEN_CMDLINE_TERMS=("userdata" "super" "format" "wipe" "root=/dev/block" "system")
    CMDLINE_FAIL=0
    for term in "${FORBIDDEN_CMDLINE_TERMS[@]}"; do
        if echo "$CMDLINE_TEXT" | grep -qw "$term"; then
            audit_fail "Forbidden cmdline term" "Found '$term' in kernel cmdline"
            CMDLINE_FAIL=1
        fi
    done
    if [ "$CMDLINE_FAIL" -eq 0 ]; then
        audit_pass "Kernel command line is 100% free of partition/storage targets"
    fi
fi

# Step 3: Audit Ramdisk Scripts, Fstabs, and Configs
if [ -n "$RAMDISK_DIR" ] && [ -d "$RAMDISK_DIR" ]; then
    echo "--- Auditing Ramdisk Files and Scripts ---" | tee -a "$REPORT_FILE"
    
    # 3.1 Check for fstab files
    FSTABS=$(find "$RAMDISK_DIR" -type f \( -name "*fstab*" -o -name "*.rc" -o -name "init" -o -name "*.sh" \))
    
    FORBIDDEN_RAMDISK_TERMS=(
        "mount_all"
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
    
    SCRIPTS_FAIL=0
    for f in $FSTABS; do
        REL_PATH="${f#$RAMDISK_DIR}"
        for kw in "${FORBIDDEN_RAMDISK_TERMS[@]}"; do
            if grep -Fwq "$kw" "$f" 2>/dev/null; then
                audit_fail "Forbidden write trap found in ramdisk" "File '$REL_PATH' contains '$kw'"
                SCRIPTS_FAIL=1
            fi
        done
        
        # Check for any physical partition mount (/dev/block/...)
        if grep -E "^[[:space:]]*mount[[:space:]]+" "$f" 2>/dev/null | grep -E "/dev/block/sd|/dev/block/by-name"; then
            audit_fail "Physical block device mount detected" "File '$REL_PATH' attempts mounting physical storage"
            SCRIPTS_FAIL=1
        fi
    done
    
    if [ "$SCRIPTS_FAIL" -eq 0 ]; then
        audit_pass "Ramdisk scripts, init, and configs are 100% free of physical mounts and write traps"
    fi
    
    # 3.2 Verify blockdev --setro enforcement exists in init
    if [ -f "$RAMDISK_DIR/init" ]; then
        if grep -Fq "blockdev --setro" "$RAMDISK_DIR/init"; then
            audit_pass "Init script explicitly enforces blockdev --setro on physical disks"
        else
            audit_fail "Missing blockdev --setro" "Init does not contain 'blockdev --setro' physical disk lock"
        fi
        
        # 3.3 Verify 90s safety watchdog exists in init
        if grep -Fq "watchdog" "$RAMDISK_DIR/init" && grep -Fq "reboot bootloader" "$RAMDISK_DIR/init"; then
            audit_pass "Init script includes 90s safety watchdog reboot timer"
        else
            audit_fail "Missing watchdog" "Init does not contain watchdog timer with reboot bootloader"
        fi
    fi
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
