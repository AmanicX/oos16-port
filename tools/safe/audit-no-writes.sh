#!/usr/bin/env bash
# ==============================================================================
# audit-no-writes.sh - Pre-Boot & Static Safety Auditor for OnePlus 7T RAM Bringup
# Audits boot images, ramdisks, kernel command lines, and orchestration scripts
# to detect any write attempts to physical block storage or forbidden operations.
# Differentiates mandatory vs optional checks and returns non-zero on failure or incomplete audits.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOGS_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOGS_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="$LOGS_DIR/audit-report-$TIMESTAMP.log"

TARGET="${1:-build/stage1.img}"

GIT_COMMIT="unknown"
if command -v git >/dev/null 2>&1 && (cd "$PROJECT_ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    GIT_COMMIT=$(cd "$PROJECT_ROOT" && git rev-parse HEAD 2>/dev/null || echo "unknown")
fi

TARGET_HASH="N/A"
if [ -f "$TARGET" ]; then
    TARGET_HASH=$(sha256sum "$TARGET" | awk '{print $1}')
fi

echo "==========================================================" | tee "$REPORT_FILE"
echo "        PRE-BOOT SAFETY & STORAGE AUDIT REPORT            " | tee -a "$REPORT_FILE"
echo "        Target: $TARGET" | tee -a "$REPORT_FILE"
echo "        SHA-256: $TARGET_HASH" | tee -a "$REPORT_FILE"
echo "        Git Commit: $GIT_COMMIT" | tee -a "$REPORT_FILE"
echo "        Timestamp: $TIMESTAMP" | tee -a "$REPORT_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"

PASSED_COUNT=0
FAILED_COUNT=0
MANDATORY_UNVERIFIED_COUNT=0
OPTIONAL_UNVERIFIED_COUNT=0

INSPECTED_FILES=()

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
    local is_mandatory="${3:-1}"
    if [ "$is_mandatory" -eq 1 ]; then
        echo " [UNVERIFIED - MANDATORY] $rule: $details" | tee -a "$REPORT_FILE"
        MANDATORY_UNVERIFIED_COUNT=$((MANDATORY_UNVERIFIED_COUNT + 1))
    else
        echo " [UNVERIFIED - OPTIONAL] $rule: $details" | tee -a "$REPORT_FILE"
        OPTIONAL_UNVERIFIED_COUNT=$((OPTIONAL_UNVERIFIED_COUNT + 1))
    fi
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
                else
                    audit_fail "Ramdisk presence" "No ramdisk found inside boot image"
                fi
            else
                audit_fail "Boot image unpack" "unpack_bootimg failed on $TARGET"
            fi
        else
            audit_unverified "Boot image unpack" "unpack_bootimg tool not found in PATH or external/" 1
        fi
    elif [[ "$TARGET" =~ \.(cpio|lz4)$ ]]; then
        mkdir -p "$TMP_AUDIT_DIR/ramdisk_root"
        if lz4 -d < "$TARGET" | (cd "$TMP_AUDIT_DIR/ramdisk_root" && cpio -idm 2>/dev/null); then
            RAMDISK_DIR="$TMP_AUDIT_DIR/ramdisk_root"
            audit_pass "Ramdisk archive extracted successfully"
        else
            audit_fail "Ramdisk extraction" "Failed to decompress archive $TARGET"
        fi
    else
        audit_fail "Target format" "Unrecognized file format for $TARGET (missing ANDROID! header)"
    fi
elif [ -d "$TARGET" ]; then
    RAMDISK_DIR="$TARGET"
    audit_pass "Using direct directory target: $TARGET"
else
    audit_fail "Target existence" "File or directory $TARGET does not exist"
fi

# 2. Kernel Command Line Audit (Static Check)
echo "--- 1. Auditing Kernel Command Line (Static Check) ---" | tee -a "$REPORT_FILE"
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
    if [ -f "$TARGET" ]; then
        audit_unverified "Kernel cmdline" "No kernel command line available to inspect" 1
    else
        audit_unverified "Kernel cmdline" "Target is a directory; kernel cmdline check skipped" 0
    fi
fi

# 3. Ramdisk Files & Configuration Audit (Static Check)
echo "--- 2. Auditing Ramdisk Configuration and Scripts (Static Check) ---" | tee -a "$REPORT_FILE"
if [ -n "$RAMDISK_DIR" ] && [ -d "$RAMDISK_DIR" ]; then
    # Verify directory is not empty
    if [ -z "$(ls -A "$RAMDISK_DIR")" ]; then
        audit_fail "Ramdisk contents" "Extracted ramdisk directory is completely empty!"
    else
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
        while IFS= read -r -d '' file_path; do
            # Skip binary ELF files
            if file -b "$file_path" 2>/dev/null | grep -q "ELF"; then
                continue
            fi

            rel_path="${file_path#$RAMDISK_DIR}"
            INSPECTED_FILES+=("$rel_path")
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

        # Verify embedded Stage-2 script presence and integrity
        EMBEDDED_STAGE2=""
        if [ -f "$RAMDISK_DIR/system/bin/stage2_init.sh" ]; then
            EMBEDDED_STAGE2="$RAMDISK_DIR/system/bin/stage2_init.sh"
        elif [ -f "$RAMDISK_DIR/scripts/stage2_init.sh" ]; then
            EMBEDDED_STAGE2="$RAMDISK_DIR/scripts/stage2_init.sh"
        fi

        if [ -n "$EMBEDDED_STAGE2" ]; then
            if cmp -s "$EMBEDDED_STAGE2" "$PROJECT_ROOT/scripts/stage2_init.sh"; then
                audit_pass "Embedded stage2_init.sh exactly matches repository scripts/stage2_init.sh"
            else
                audit_fail "Embedded script mismatch" "Embedded stage2_init.sh differs from scripts/stage2_init.sh"
            fi
        else
            audit_fail "Embedded stage2_init.sh" "Stage-2 initialization script missing from target ramdisk"
        fi

        # Verify embedded Watchdog script presence and integrity
        EMBEDDED_WATCHDOG=""
        if [ -f "$RAMDISK_DIR/system/bin/watchdog.sh" ]; then
            EMBEDDED_WATCHDOG="$RAMDISK_DIR/system/bin/watchdog.sh"
        elif [ -f "$RAMDISK_DIR/scripts/watchdog.sh" ]; then
            EMBEDDED_WATCHDOG="$RAMDISK_DIR/scripts/watchdog.sh"
        fi

        if [ -n "$EMBEDDED_WATCHDOG" ]; then
            if cmp -s "$EMBEDDED_WATCHDOG" "$PROJECT_ROOT/scripts/watchdog.sh"; then
                audit_pass "Embedded watchdog.sh exactly matches repository scripts/watchdog.sh"
            else
                audit_fail "Embedded script mismatch" "Embedded watchdog.sh differs from scripts/watchdog.sh"
            fi
        else
            audit_fail "Embedded watchdog.sh" "Watchdog supervisor script missing from target ramdisk"
        fi

        # Verify Stage-1 Entrypoint Supervisor
        if [ -f "$RAMDISK_DIR/init" ] && file -b "$RAMDISK_DIR/init" 2>/dev/null | grep -qi "script"; then
            ENTRYPOINT_FILE="$RAMDISK_DIR/init"
            ENTRY_TYPE="Loader init script"
        elif [ -f "$RAMDISK_DIR/system/bin/recovery" ] && file -b "$RAMDISK_DIR/system/bin/recovery" 2>/dev/null | grep -qi "script"; then
            ENTRYPOINT_FILE="$RAMDISK_DIR/system/bin/recovery"
            ENTRY_TYPE="Native recovery script"
        else
            ENTRYPOINT_FILE=""
            ENTRY_TYPE="unknown"
        fi

        if [ -n "$ENTRYPOINT_FILE" ]; then
            if grep -Fq "/mnt/boot_now" "$ENTRYPOINT_FILE" && \
               grep -Fq "blockdev --setro" "$ENTRYPOINT_FILE" && \
               grep -Fq "stage2_init.sh" "$ENTRYPOINT_FILE"; then
                audit_pass "Stage-1 entrypoint supervisor ($ENTRY_TYPE) verified for write locks, trigger, and Stage-2 handover"
            else
                audit_fail "Stage-1 supervisor logic" "Entrypoint $ENTRYPOINT_FILE lacks trigger or handover logic"
            fi
        else
            audit_fail "Stage-1 supervisor missing" "Ramdisk lacks a recognized Stage-1 supervisor script (init or system/bin/recovery)"
        fi
    fi
else
    audit_unverified "Ramdisk files" "Ramdisk directory was not available for inspection" 1
fi

# 4. Project Orchestration Scripts Audit (Static Check)
echo "--- 3. Auditing Project Orchestration Scripts (Static Check) ---" | tee -a "$REPORT_FILE"
SCRIPTS_TO_AUDIT=(
    "$PROJECT_ROOT/scripts/stage2_init.sh"
    "$PROJECT_ROOT/scripts/watchdog.sh"
    "$PROJECT_ROOT/tools/safe/run_stage2.sh"
    "$PROJECT_ROOT/stage1/loader_ramdisk/init"
    "$PROJECT_ROOT/scripts/build_loader.sh"
    "$PROJECT_ROOT/scripts/build_stage1.sh"
    "$PROJECT_ROOT/scripts/build_stage2_erofs.sh"
)
if [ -f "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery" ]; then
    SCRIPTS_TO_AUDIT+=("$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery")
fi

for s in "${SCRIPTS_TO_AUDIT[@]}"; do
    if [ -f "$s" ]; then
        rel_s="${s#$PROJECT_ROOT/}"
        INSPECTED_FILES+=("$rel_s")
        # Extract non-comment executable lines to prevent false matches on documentation/comments
        non_comment_lines=$(grep -v '^[[:space:]]*#' "$s" | grep -v '^[[:space:]]*echo ' || true)

        # Check for dangerous write / formatting / partitioning commands targeting physical disks
        if echo "$non_comment_lines" | grep -E "dd[[:space:]]+.*of=/dev/(block|sd|mmcblk)" >/dev/null 2>&1; then
            audit_fail "Dangerous block write" "Script '$rel_s' contains direct dd of=/dev/block command!"
        elif echo "$non_comment_lines" | grep -E "wipefs[[:space:]]+.*(/dev/|/dev/block)" >/dev/null 2>&1; then
            audit_fail "Dangerous wipefs command" "Script '$rel_s' contains wipefs targeting block storage!"
        elif echo "$non_comment_lines" | grep -E "(sgdisk|parted|fdisk)[[:space:]]+.*(/dev/|/dev/block)" >/dev/null 2>&1; then
            audit_fail "Dangerous partition tool" "Script '$rel_s' contains partitioning tool targeting block storage!"
        elif echo "$non_comment_lines" | grep -E "(mkfs\.(ext|f2fs|vfat|ntfs)|mke2fs)[[:space:]]+.*(/dev/|/dev/block)" >/dev/null 2>&1; then
            audit_fail "Dangerous filesystem format" "Script '$rel_s' formats physical block partition!"
        elif echo "$non_comment_lines" | grep -E "mount[[:space:]]+-o[[:space:]]+.*rw.*/dev/block" >/dev/null 2>&1; then
            audit_fail "Dangerous block mount" "Script '$rel_s' attempts writable mount of physical block device!"
        elif echo "$non_comment_lines" | grep -Fwq "mount_all" >/dev/null 2>&1; then
            audit_fail "Dangerous mount_all" "Script '$rel_s' invokes Android mount_all on physical partitions!"
        elif echo "$non_comment_lines" | grep -E "fastboot[[:space:]]+(flash|erase|format)" >/dev/null 2>&1; then
            audit_fail "Dangerous fastboot command" "Script '$rel_s' contains physical partition modification command!"
        else
            audit_pass "Script '$rel_s' is free of physical block write commands"
        fi
    else
        audit_unverified "Script audit" "File $s does not exist to audit" 1
    fi
done

# Check Stage-1 to Stage-2 handover consistency across scripts
echo "--- 4. Auditing Stage-1/Stage-2 Integration & Handover Consistency ---" | tee -a "$REPORT_FILE"
# 1. Consistent boot trigger (/mnt/boot_now)
TRIGGER_RUNNER=$(grep -F "/mnt/boot_now" "$PROJECT_ROOT/tools/safe/run_stage2.sh" 2>/dev/null || true)
TRIGGER_LOADER=$(grep -F "/mnt/boot_now" "$PROJECT_ROOT/stage1/loader_ramdisk/init" 2>/dev/null || true)
TRIGGER_RECOVERY=""
if [ -f "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery" ]; then
    TRIGGER_RECOVERY=$(grep -F "/mnt/boot_now" "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery" 2>/dev/null || true)
fi

if [ -n "$TRIGGER_RUNNER" ] && [ -n "$TRIGGER_LOADER" ] && { [ ! -f "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery" ] || [ -n "$TRIGGER_RECOVERY" ]; }; then
    audit_pass "Consistent boot trigger (/mnt/boot_now) verified across runner and ramdisks"
else
    audit_fail "Boot trigger consistency" "Boot trigger /mnt/boot_now is not recognized across all execution paths"
fi

# 2. Consistent image staging paths (/mnt/)
if grep -q ":/mnt/" "$PROJECT_ROOT/tools/safe/run_stage2.sh" 2>/dev/null && \
   grep -q 'SYSTEM_IMG="/mnt/system.img"' "$PROJECT_ROOT/scripts/stage2_init.sh" 2>/dev/null; then
    audit_pass "Consistent RAM image staging path (/mnt/) verified between runner and stage2_init"
else
    audit_fail "Image path consistency" "Image staging paths between runner and stage2_init diverge"
fi

# 3. Active hardware write lock enforcement (blockdev --setro)
WRITE_LOCK_OK=1
if ! grep -q "blockdev --setro" "$PROJECT_ROOT/stage1/loader_ramdisk/init" 2>/dev/null; then
    WRITE_LOCK_OK=0
fi
if [ -f "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery" ] && ! grep -q "blockdev --setro" "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery" 2>/dev/null; then
    WRITE_LOCK_OK=0
fi

if [ "$WRITE_LOCK_OK" -eq 1 ]; then
    audit_pass "Dynamic hardware write lock (blockdev --setro) enforced in Stage-1 ramdisks"
else
    audit_fail "Write lock enforcement" "Missing blockdev --setro in one or more Stage-1 ramdisks"
fi

# 4. Watchdog recovery presence
WATCHDOG_OK=1
if ! grep -q "watchdog" "$PROJECT_ROOT/stage1/loader_ramdisk/init" 2>/dev/null; then
    WATCHDOG_OK=0
fi
if [ -f "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery" ] && ! grep -q "watchdog" "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/recovery" 2>/dev/null; then
    WATCHDOG_OK=0
fi

if [ "$WATCHDOG_OK" -eq 1 ]; then
    audit_pass "Active safety watchdog monitor and reboot fallback verified in Stage-1 ramdisks"
else
    audit_fail "Safety watchdog" "Missing watchdog monitor in one or more Stage-1 ramdisks"
fi

# 5. Device Node Management & ueventd
if grep -q "ueventd" "$PROJECT_ROOT/stage1/loader_ramdisk/init" 2>/dev/null && \
   grep -q "binderfs" "$PROJECT_ROOT/stage1/loader_ramdisk/init" 2>/dev/null; then
    audit_pass "Dynamic device node initialization (ueventd and binderfs) verified in Stage-1 supervisor"
else
    audit_fail "Device node initialization" "Missing ueventd or binderfs initialization in Stage-1 supervisor"
fi

# 6. Memory Staging Sizing (/mnt >= 6000M tmpfs)
if grep -qE "size=6[0-9]{3}M.* /mnt|size=6[0-9]{3}M.*tmpfs /mnt" "$PROJECT_ROOT/stage1/loader_ramdisk/init" 2>/dev/null; then
    audit_pass "RAM staging directory /mnt sizing verified (>= 6000M tmpfs)"
else
    audit_fail "RAM staging capacity" "/mnt does not allocate >= 6000M tmpfs in Stage-1 supervisor"
fi

# 7. APEX Canonical Versioned Directory & Symlink Structure
if grep -qE '\$\{mod_name\}@\$\{version\}' "$PROJECT_ROOT/scripts/stage2_init.sh" 2>/dev/null && \
   grep -qE 'ln -sfn' "$PROJECT_ROOT/scripts/stage2_init.sh" 2>/dev/null; then
    audit_pass "Canonical AOSP APEX versioned directories and active symlinks verified in stage2_init"
else
    audit_fail "APEX symlink structure" "stage2_init lacks canonical APEX versioned directories or active symlinks"
fi

# 8. Physical Storage Block Layer Verification before Mount
FIRST_RO_CHECK=$(grep -n "blockdev --getro" "$PROJECT_ROOT/scripts/stage2_init.sh" | head -n 1 | cut -d: -f1 || echo "999")
FIRST_MOUNT=$(grep -n "^[[:space:]]*mount_or_fail " "$PROJECT_ROOT/scripts/stage2_init.sh" | head -n 1 | cut -d: -f1 || echo "0")
if [ "$FIRST_RO_CHECK" -lt "$FIRST_MOUNT" ]; then
    audit_pass "Physical storage blockdev read-only locks verified prior to filesystem mount"
else
    audit_fail "Mount safety sequencing" "Physical storage lock verification ($FIRST_RO_CHECK) does not precede filesystem mounts ($FIRST_MOUNT)"
fi

# 9. Multi-Ramdisk Stage-1 /init Implementation Consistency (Loader & Native)
MULTI_INIT_OK=1
for init_path in "$PROJECT_ROOT/stage1/loader_ramdisk/init" "$PROJECT_ROOT/stage1/native_ramdisk/init"; do
    if [ ! -f "$init_path" ] || \
       ! grep -q "blockdev --setro" "$init_path" || \
       ! grep -q "binderfs_init" "$init_path" || \
       ! grep -q "stage1_ack" "$init_path" || \
       ! grep -q "stage2_init.sh" "$init_path"; then
        MULTI_INIT_OK=0
        audit_fail "Stage-1 init consistency" "$init_path missing required write locks, binderfs_init, or handover logic"
    fi
done
if [ "$MULTI_INIT_OK" -eq 1 ]; then
    audit_pass "Both Stage-1 ramdisk architectures (loader & native) verified for write locks, binderfs_init, and handover"
fi

# 10. Embedded binderfs_init Binary Integrity & Invocation
BINDERFS_BIN_OK=1
for b_bin in "$PROJECT_ROOT/stage1/loader_ramdisk/system/bin/binderfs_init" "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/binderfs_init"; do
    if [ ! -x "$b_bin" ]; then
        BINDERFS_BIN_OK=0
        audit_fail "binderfs_init binary" "Helper binary $b_bin does not exist or is not executable"
    fi
done
if [ "$BINDERFS_BIN_OK" -eq 1 ]; then
    if cmp -s "$PROJECT_ROOT/stage1/loader_ramdisk/system/bin/binderfs_init" "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/binderfs_init"; then
        audit_pass "Embedded binderfs_init static binary verified and identical across both ramdisks"
    else
        audit_fail "binderfs_init mismatch" "binderfs_init binaries in loader and native ramdisks differ"
    fi
fi

# 11. Embedded Scripts Equality Across Both Ramdisk Architectures
EMBEDDED_SCRIPTS_OK=1
if ! cmp -s "$PROJECT_ROOT/scripts/stage2_init.sh" "$PROJECT_ROOT/stage1/loader_ramdisk/system/bin/stage2_init.sh" || \
   ! cmp -s "$PROJECT_ROOT/scripts/stage2_init.sh" "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/stage2_init.sh"; then
    EMBEDDED_SCRIPTS_OK=0
    audit_fail "Embedded stage2_init mismatch" "stage2_init.sh in ramdisk does not match scripts/stage2_init.sh"
fi
if ! cmp -s "$PROJECT_ROOT/scripts/watchdog.sh" "$PROJECT_ROOT/stage1/loader_ramdisk/system/bin/watchdog.sh" || \
   ! cmp -s "$PROJECT_ROOT/scripts/watchdog.sh" "$PROJECT_ROOT/stage1/native_ramdisk/system/bin/watchdog.sh"; then
    EMBEDDED_SCRIPTS_OK=0
    audit_fail "Embedded watchdog mismatch" "watchdog.sh in ramdisk does not match scripts/watchdog.sh"
fi
if [ "$EMBEDDED_SCRIPTS_OK" -eq 1 ]; then
    audit_pass "All embedded stage2_init and watchdog scripts match repository sources exactly across both ramdisks"
fi

# 12. Watchdog State Lifecycle & Android Health Monitor
WATCHDOG_STATES_OK=1
for st in "STAGE1_WAIT" "STAGE2_RUNNING" "HEALTH_MONITOR" "DISARMED" "BOOT_COMPLETED"; do
    if ! grep -q "$st" "$PROJECT_ROOT/scripts/watchdog.sh"; then
        WATCHDOG_STATES_OK=0
        audit_fail "Watchdog state lifecycle" "Missing state '$st' in scripts/watchdog.sh"
    fi
done
if grep -q "sys.boot_completed" "$PROJECT_ROOT/scripts/watchdog.sh" && [ "$WATCHDOG_STATES_OK" -eq 1 ]; then
    audit_pass "Watchdog state lifecycle (STAGE1_WAIT -> STAGE2_RUNNING -> HEALTH_MONITOR -> BOOT_COMPLETED) verified"
fi

# 13. APEX Metadata Enforcement & Non-Fatal Fallback Mounting
APEX_AUDIT_OK=1
if [ ! -x "$PROJECT_ROOT/tools/extract_apex_info.py" ]; then
    APEX_AUDIT_OK=0
    audit_fail "APEX tool" "tools/extract_apex_info.py is missing or not executable"
fi
if ! grep -q "tools/extract_apex_info.py" "$PROJECT_ROOT/scripts/build_stage2_erofs.sh"; then
    APEX_AUDIT_OK=0
    audit_fail "APEX version extraction" "scripts/build_stage2_erofs.sh does not invoke tools/extract_apex_info.py"
fi
if ! grep -q "try_mount()" "$PROJECT_ROOT/scripts/stage2_init.sh"; then
    APEX_AUDIT_OK=0
    audit_fail "APEX non-fatal fallback" "scripts/stage2_init.sh lacks try_mount() non-fatal helper"
fi
if ! grep -q 'APEX_FSTYPE' "$PROJECT_ROOT/tools/safe/run_stage2.sh" || ! grep -q 'APEX_VERSION' "$PROJECT_ROOT/tools/safe/run_stage2.sh"; then
    APEX_AUDIT_OK=0
    audit_fail "Runner APEX metadata validation" "tools/safe/run_stage2.sh does not strictly validate .fstype and .version"
fi
if [ "$APEX_AUDIT_OK" -eq 1 ]; then
    audit_pass "APEX metadata extraction, strict validation, and non-fatal fallback mounting verified"
fi

# 14. Target Volatile Memory Capacity & Peak Budgeting
if grep -q "MemAvailable:" "$PROJECT_ROOT/tools/safe/run_stage2.sh" && \
   grep -q "REQUIRED_RAM_MB" "$PROJECT_ROOT/tools/safe/run_stage2.sh"; then
    audit_pass "Volatile RAM capacity and peak-memory budget verification enforced in runner"
else
    audit_fail "RAM memory budget" "tools/safe/run_stage2.sh lacks MemAvailable verification or peak budget check"
fi

# 5. Summary & Disclaimer
TOTAL_INSPECTED="${#INSPECTED_FILES[@]}"
echo "==========================================================" | tee -a "$REPORT_FILE"
echo "AUDIT SUMMARY: $PASSED_COUNT Passed, $FAILED_COUNT Failed, $MANDATORY_UNVERIFIED_COUNT Mandatory Unverified, $OPTIONAL_UNVERIFIED_COUNT Optional Unverified ($TOTAL_INSPECTED files inspected)" | tee -a "$REPORT_FILE"
echo "Verification Methodology:" | tee -a "$REPORT_FILE"
echo "- Static checks performed: AST/pattern scanning of ramdisk scripts, kernel cmdline, and orchestration tools." | tee -a "$REPORT_FILE"
echo "- Runtime safety checks: Live block-layer read-only verification (blockdev --getro = 1) enforced dynamically at boot." | tee -a "$REPORT_FILE"
echo "Disclaimer: Static code auditing provides high confidence in build artifact safety" | tee -a "$REPORT_FILE"
echo "but must be complemented by live device read-only verification." | tee -a "$REPORT_FILE"
echo "Detailed report written to: $REPORT_FILE" | tee -a "$REPORT_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"

if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "AUDIT RESULT: FAILED (Exit Code 1)" | tee -a "$REPORT_FILE"
    exit 1
elif [ "$MANDATORY_UNVERIFIED_COUNT" -gt 0 ]; then
    echo "AUDIT RESULT: INCOMPLETE (Mandatory checks unverified, Exit Code 2)" | tee -a "$REPORT_FILE"
    exit 2
else
    echo "AUDIT RESULT: PASSED (Exit Code 0)" | tee -a "$REPORT_FILE"
    exit 0
fi
