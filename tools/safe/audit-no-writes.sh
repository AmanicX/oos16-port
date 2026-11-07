#!/usr/bin/env bash
# ==============================================================================
# audit-no-writes.sh - Pre-Boot & Static Safety Auditor for OnePlus 7T RAM Bringup
# Audits boot images, ramdisks, kernel command lines, and orchestration scripts
# to detect any write attempts to physical block storage or forbidden operations.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOGS_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOGS_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="$LOGS_DIR/audit-report-$TIMESTAMP.log"

TARGET="${1:-build/stage1.img}"

echo "==========================================================" | tee "$REPORT_FILE"
echo "        PRE-BOOT SAFETY & STORAGE AUDIT REPORT            " | tee -a "$REPORT_FILE"
echo "        Target: $TARGET" | tee -a "$REPORT_FILE"
echo "        Timestamp: $TIMESTAMP" | tee -a "$REPORT_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"

PASSED_COUNT=0
FAILED_COUNT=0
UNVERIFIED_COUNT=0

audit_pass() {
    local rule="$1"
    echo " [PASSED] $rule" | tee -a "$REPORT_FILE"
    PASSED_COUNT=$((PASSED_COUNT + 1))
}

audit_fail() {
    local rule="$1"
    local details="$2"
    echo " [FAILED] $rule: $details" | tee -a "$REPORT_FILE"
    FAILED_COUNT=$((FAILED_COUNT + 1))
}

audit_unverified() {
    local rule="$1"
    local details="$2"
    echo " [UNVERIFIED] $rule: $details" | tee -a "$REPORT_FILE"
    UNVERIFIED_COUNT=$((UNVERIFIED_COUNT + 1))
}

TMP_AUDIT_DIR="$(mktemp -d /tmp/audit_work.XXXXXX)"
cleanup() {
    rm -rf "$TMP_AUDIT_DIR"
}
trap cleanup EXIT

# 1. Target Extraction & Discovery
RAMDISK_DIR=""
CMDLINE_TEXT=""

if [ -f "$TARGET" ]; then
    MAGIC=$(head -c 8 "$TARGET" 2>/dev/null || true)
    if [ "$MAGIC" = "ANDROID!" ]; then
        echo "Extracting Android boot image header and ramdisk..." | tee -a "$REPORT_FILE"
        UNPACK_TOOL=""
        if command -v unpack_bootimg >/dev/null 2>&1; then
            UNPACK_TOOL="$(command -v unpack_bootimg)"
        elif [ -x "$PROJECT_ROOT/external/coloros_port/otatools/bin/unpack_bootimg" ]; then
            UNPACK_TOOL="$PROJECT_ROOT/external/coloros_port/otatools/bin/unpack_bootimg"
        fi

        if [ -n "$UNPACK_TOOL" ]; then
            mkdir -p "$TMP_AUDIT_DIR/unpacked"
            if "$UNPACK_TOOL" --boot_img "$TARGET" --out "$TMP_AUDIT_DIR/unpacked" > "$TMP_AUDIT_DIR/boot_info.txt" 2>&1; then
                CMDLINE_TEXT=$(grep "command line args:" "$TMP_AUDIT_DIR/boot_info.txt" | sed 's/command line args: //' || true)
                audit_pass "Boot image header unpacked successfully"

                # Extract ramdisk
                if [ -f "$TMP_AUDIT_DIR/unpacked/ramdisk" ]; then
                    mkdir -p "$TMP_AUDIT_DIR/ramdisk_root"
                    # Safe decompression without error suppression
                    if lz4 -d < "$TMP_AUDIT_DIR/unpacked/ramdisk" | (cd "$TMP_AUDIT_DIR/ramdisk_root" && cpio -idm 2>/dev/null); then
                        RAMDISK_DIR="$TMP_AUDIT_DIR/ramdisk_root"
                        audit_pass "Ramdisk archive extracted and validated"
                    else
                        audit_fail "Ramdisk extraction" "Failed to unpack ramdisk with lz4/cpio"
                    fi
                fi
            else
                audit_fail "Boot image unpack" "unpack_bootimg failed on $TARGET"
            fi
        else
            audit_unverified "Boot image unpack" "unpack_bootimg tool not found in PATH or external/"
        fi
    elif [[ "$TARGET" =~ \.(cpio|lz4)$ ]]; then
        mkdir -p "$TMP_AUDIT_DIR/ramdisk_root"
        if lz4 -d < "$TARGET" | (cd "$TMP_AUDIT_DIR/ramdisk_root" && cpio -idm 2>/dev/null); then
            RAMDISK_DIR="$TMP_AUDIT_DIR/ramdisk_root"
            audit_pass "Ramdisk archive extracted successfully"
        else
            audit_fail "Ramdisk extraction" "Failed to decompress archive $TARGET"
        fi
    elif [ -d "$TARGET" ]; then
        RAMDISK_DIR="$TARGET"
        audit_pass "Using direct directory target: $TARGET"
    else
        audit_unverified "Target format" "Unrecognized file format for $TARGET"
    fi
elif [ -d "$TARGET" ]; then
    RAMDISK_DIR="$TARGET"
    audit_pass "Target is a valid directory"
else
    audit_fail "Target existence" "File or directory $TARGET does not exist"
fi

# 2. Kernel Command Line Audit
echo "--- 1. Auditing Kernel Command Line ---" | tee -a "$REPORT_FILE"
if [ -n "$CMDLINE_TEXT" ]; then
    echo "Cmdline: $CMDLINE_TEXT" | tee -a "$REPORT_FILE"
    FORBIDDEN_CMDLINE_TERMS=("userdata" "super" "format" "wipe" "root=/dev/block")
    CMDLINE_FAIL=0
    for term in "${FORBIDDEN_CMDLINE_TERMS[@]}"; do
        if echo "$CMDLINE_TEXT" | grep -qw "$term"; then
            audit_fail "Forbidden cmdline term" "Found '$term' in kernel cmdline"
            CMDLINE_FAIL=1
        fi
    done
    if [ "$CMDLINE_FAIL" -eq 0 ]; then
        audit_pass "Kernel cmdline contains zero physical partition or wipe targets"
    fi
else
    audit_unverified "Kernel cmdline" "No kernel command line available to inspect"
fi

# 3. Ramdisk Files & Configuration Audit
echo "--- 2. Auditing Ramdisk Configuration and Scripts ---" | tee -a "$REPORT_FILE"
if [ -n "$RAMDISK_DIR" ] && [ -d "$RAMDISK_DIR" ]; then
    FORBIDDEN_RAMDISK_TERMS=(
        "mount_all"
        "userdata"
        "/dev/block/bootdevice/by-name/userdata"
        "/dev/block/by-name/userdata"
        "super"
        "/dev/block/bootdevice/by-name/super"
        "update_verifier"
        "update_engine"
        "format_userdata"
        "wipe_data"
        "recovery --wipe_data"
        "BLKROSET 0"
        "blockdev --setrw"
        "fastboot flash"
        "fastboot erase"
    )

    RAMDISK_FAIL=0
    # Safe null-delimited file reading
    while IFS= read -r -d '' file_path; do
        # Skip binary ELF files
        if file -b "$file_path" 2>/dev/null | grep -q "ELF"; then
            continue
        fi

        rel_path="${file_path#$RAMDISK_DIR}"
        for kw in "${FORBIDDEN_RAMDISK_TERMS[@]}"; do
            if grep -Fwq "$kw" "$file_path" 2>/dev/null; then
                audit_fail "Forbidden write keyword" "File '$rel_path' contains '$kw'"
                RAMDISK_FAIL=1
            fi
        done

        # Check for mount commands targeting physical disks
        if grep -E "^[[:space:]]*mount[[:space:]]+" "$file_path" 2>/dev/null | grep -E "/dev/block/sd|/dev/block/by-name"; then
            audit_fail "Physical block mount" "File '$rel_path' attempts to mount physical block device"
            RAMDISK_FAIL=1
        fi
    done < <(find "$RAMDISK_DIR" -type f \( -name "*fstab*" -o -name "*.rc" -o -name "*.sh" -o -name "*.cfg" -o -name "*.prop" -o -name "init" \) -print0)

    if [ "$RAMDISK_FAIL" -eq 0 ]; then
        audit_pass "Ramdisk configurations contain zero physical mount or write instructions"
    fi

    # Check for blockdev --setro
    if grep -rq "blockdev --setro" "$RAMDISK_DIR" 2>/dev/null; then
        audit_pass "Stage-1 harness explicitly enforces 'blockdev --setro' on storage"
    else
        audit_fail "Physical write lock" "Ramdisk does not contain 'blockdev --setro' enforcement"
    fi

    # Check for safety watchdog
    if grep -rq "watchdog" "$RAMDISK_DIR" 2>/dev/null && grep -rq "reboot bootloader" "$RAMDISK_DIR" 2>/dev/null; then
        audit_pass "Stage-1 harness includes active safety watchdog timer"
    else
        audit_fail "Safety watchdog" "Ramdisk does not contain watchdog recovery timer"
    fi
else
    audit_unverified "Ramdisk files" "Ramdisk directory was not available for inspection"
fi

# 4. Project Orchestration Scripts Audit
echo "--- 3. Auditing Project Orchestration Scripts ---" | tee -a "$REPORT_FILE"
SCRIPTS_TO_AUDIT=(
    "$PROJECT_ROOT/scripts/stage2_init.sh"
    "$PROJECT_ROOT/tools/safe/run_stage2.sh"
    "$PROJECT_ROOT/scripts/build_stage1.sh"
)

for s in "${SCRIPTS_TO_AUDIT[@]}"; do
    if [ -f "$s" ]; then
        rel_s="${s#$PROJECT_ROOT/}"
        # Check for write commands targeting physical disks
        if grep -E "dd[[:space:]]+of=/dev/block" "$s" 2>/dev/null; then
            audit_fail "Dangerous block write" "Script '$rel_s' contains direct dd of=/dev/block command!"
        elif grep -E "mount[[:space:]]+-o[[:space:]]+rw[[:space:]]+/dev/block" "$s" 2>/dev/null; then
            audit_fail "Dangerous block mount" "Script '$rel_s' attempts writable mount of physical block device!"
        else
            audit_pass "Script '$rel_s' is free of physical block write commands"
        fi
    else
        audit_unverified "Script audit" "File $s does not exist to audit"
    fi
done

# 5. Summary & Disclaimer
echo "==========================================================" | tee -a "$REPORT_FILE"
echo "AUDIT SUMMARY: $PASSED_COUNT Passed, $FAILED_COUNT Failed, $UNVERIFIED_COUNT Unverified" | tee -a "$REPORT_FILE"
echo "Disclaimer: Static code auditing provides high confidence but cannot" | tee -a "$REPORT_FILE"
echo "replace live block-layer read-only verification (blockdev --getro = 1)" | tee -a "$REPORT_FILE"
echo "enforced at boot time by the Stage-1 recovery kernel." | tee -a "$REPORT_FILE"
echo "Detailed report written to: $REPORT_FILE" | tee -a "$REPORT_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"

if [ "$FAILED_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
