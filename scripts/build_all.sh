#!/usr/bin/env bash
# ==============================================================================
# scripts/build_all.sh - Master Build & Independent Verification Orchestrator
# Target: OnePlus 7T HD1901 (hotdogb), Snapdragon 855+ / SM8150-AC, 8 GB RAM
# Operating System: OxygenOS 16 RAM-Only Port (fastboot boot only)
#
# NON-NEGOTIABLE SAFETY INVARIANTS:
# 1. Strictly RAM-only execution via 'fastboot boot'.
# 2. Never execute fastboot flash, erase, format, or set_active.
# 3. Never write to, format, or modify physical UFS block devices (/dev/block/*).
# 4. Never execute automated physical hardware boots during builds or testing.
# 5. Fail closed immediately on any missing dependency, checksum failure, or
#    audit violation.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure external and user bin paths are available in PATH
export PATH="$PROJECT_ROOT/external/coloros_port/otatools/bin:$HOME/.local/bin:$PATH"

# Prioritize user-provided OTATOOLS if configured in environment
if [ -n "${OTATOOLS:-}" ]; then
    if [ -d "$OTATOOLS/bin" ]; then
        export PATH="$OTATOOLS/bin:$OTATOOLS:$PATH"
    elif [ -d "$OTATOOLS" ]; then
        export PATH="$OTATOOLS:$PATH"
    fi
    export OTATOOLS
fi

# Mode flags
SKIP_STAGE2=0
STAGE2_ONLY=0
BOOT_ONLY=0
VERIFY_ONLY=0
CHECK_TOOLS_ONLY=0
CHECK_DONOR_ONLY=0

usage() {
    cat << 'EOF'
Usage: scripts/build_all.sh [OPTIONS]

Master build and verification orchestrator for the OxygenOS 16 RAM-only port
on OnePlus 7T HD1901 (hotdogb).

Options:
  --skip-stage2    Skip packaging Stage-2 EROFS images (reuse existing build/images/)
  --stage2-only    Only build Stage-2 EROFS partition images and APEX modules
  --boot-only      Only compile ARM64 helper and package Stage-1 boot images
  --verify-only    Run independent verification and static audits without rebuilding
  --check-tools    Validate host and Android tool dependencies and exit
  --check-donor    Validate donor partition trees and APEX modules and exit
  -h, --help       Show this help message and exit

Environment Variables:
  WORK_DIR         Directory containing donor partition trees (default: $PROJECT_ROOT/work)
  OTATOOLS         Directory containing mkbootfs, mkfs.erofs, etc. (optional)
EOF
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-stage2)
            SKIP_STAGE2=1
            shift
            ;;
        --stage2-only)
            STAGE2_ONLY=1
            shift
            ;;
        --boot-only)
            BOOT_ONLY=1
            shift
            ;;
        --verify-only)
            VERIFY_ONLY=1
            shift
            ;;
        --check-tools)
            CHECK_TOOLS_ONLY=1
            shift
            ;;
        --check-donor)
            CHECK_DONOR_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Mutual exclusion checks
ACTIVE_MODES=0
[ "$STAGE2_ONLY" -eq 1 ] && ACTIVE_MODES=$((ACTIVE_MODES + 1))
[ "$BOOT_ONLY" -eq 1 ] && ACTIVE_MODES=$((ACTIVE_MODES + 1))
[ "$VERIFY_ONLY" -eq 1 ] && ACTIVE_MODES=$((ACTIVE_MODES + 1))
[ "$CHECK_TOOLS_ONLY" -eq 1 ] && ACTIVE_MODES=$((ACTIVE_MODES + 1))
[ "$CHECK_DONOR_ONLY" -eq 1 ] && ACTIVE_MODES=$((ACTIVE_MODES + 1))

if [ "$ACTIVE_MODES" -gt 1 ]; then
    echo "Error: Options --stage2-only, --boot-only, --verify-only, --check-tools, and --check-donor are mutually exclusive." >&2
    exit 1
fi

if [ "$SKIP_STAGE2" -eq 1 ] && [ "$STAGE2_ONLY" -eq 1 ]; then
    echo "Error: Cannot combine --skip-stage2 with --stage2-only." >&2
    exit 1
fi

echo "=========================================================="
echo "    OnePlus 7T (HD1901) OxygenOS 16 RAM-Only Port"
echo "    Master Build & Verification Orchestrator"
echo "=========================================================="
echo "Project Root: $PROJECT_ROOT"
echo "Execution Mode:"
if [ "$CHECK_TOOLS_ONLY" -eq 1 ]; then
    echo "  [CHECK-TOOLS] Validating host and Android tool dependencies"
elif [ "$CHECK_DONOR_ONLY" -eq 1 ]; then
    echo "  [CHECK-DONOR] Validating donor partition trees and APEX modules"
elif [ "$VERIFY_ONLY" -eq 1 ]; then
    echo "  [VERIFY-ONLY] Validating existing artifacts & static safety"
elif [ "$STAGE2_ONLY" -eq 1 ]; then
    echo "  [STAGE2-ONLY] Building EROFS partitions & APEX modules"
elif [ "$BOOT_ONLY" -eq 1 ]; then
    echo "  [BOOT-ONLY] Building ARM64 helper & Stage-1 boot images"
elif [ "$SKIP_STAGE2" -eq 1 ]; then
    echo "  [SKIP-STAGE2] Reusing existing EROFS images, rebuilding boot images"
else
    echo "  [FULL-BUILD] Rebuilding all components and running verification"
fi
echo ""

# ------------------------------------------------------------------------------
# 1. Host Tool & Environment Dependency Checks
# ------------------------------------------------------------------------------
echo "--- Step 1: Checking Host Tools and Dependencies ---"

REQUIRED_HOST_TOOLS=(
    "python3:--version"
    "go:version"
    "sha256sum:--version"
    "stat:--version"
    "cpio:--version"
    "lz4:--version"
    "unzip:-v"
    "file:--version"
)

for tool_entry in "${REQUIRED_HOST_TOOLS[@]}"; do
    tool="${tool_entry%%:*}"
    test_arg="${tool_entry##*:}"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: Required host tool '$tool' is not installed or not in PATH." >&2
        exit 1
    fi
    if ! "$tool" $test_arg >/dev/null 2>&1; then
        echo "Error: Required host tool '$tool' failed execution test with '$test_arg'." >&2
        exit 1
    fi
    echo "  [OK] Host tool: $tool ($(command -v "$tool"))"
done

# 7-Zip check with functionality test
if command -v 7z >/dev/null 2>&1 && 7z --help >/dev/null 2>&1; then
    echo "  [OK] 7-Zip archive tool: 7z ($(command -v 7z))"
elif command -v 7za >/dev/null 2>&1 && 7za --help >/dev/null 2>&1; then
    echo "  [OK] 7-Zip archive tool: 7za ($(command -v 7za))"
else
    echo "Error: 7-Zip (7z or 7za) is required for APEX extraction and not found or non-functional." >&2
    exit 1
fi

# Android Packaging Tools (mkbootfs, mkbootimg, unpack_bootimg, mkfs.erofs, fsck.erofs)
if [ "$CHECK_DONOR_ONLY" -eq 0 ]; then
    ANDROID_TOOLS=(
        "mkbootfs:-h"
        "mkbootimg:--help"
        "unpack_bootimg:--help"
        "mkfs.erofs:--help"
        "fsck.erofs:-V"
    )

    for atool_entry in "${ANDROID_TOOLS[@]}"; do
        atool="${atool_entry%%:*}"
        atest_arg="${atool_entry##*:}"
        if ! command -v "$atool" >/dev/null 2>&1; then
            echo "Error: Required Android tool '$atool' was not found in PATH or external/coloros_port/otatools/bin." >&2
            exit 1
        fi
        if ! "$atool" $atest_arg >/dev/null 2>&1; then
            echo "Error: Required Android tool '$atool' failed execution test with '$atest_arg'." >&2
            exit 1
        fi
        echo "  [OK] Android tool: $atool ($(command -v "$atool"))"
    done
fi

if [ "$CHECK_TOOLS_ONLY" -eq 1 ]; then
    echo ""
    echo "[OK] All required host and Android tool dependencies are verified."
    exit 0
fi

# ------------------------------------------------------------------------------
# Helper: Donor ROM Partition Directories & APEX Validation
# ------------------------------------------------------------------------------
validate_donor_rom() {
    WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/work}"
    echo ""
    echo "--- Validating Donor ROM Partition Directories & APEX Modules ---"
    if [ ! -d "$WORK_DIR" ]; then
        echo "Error: Work directory '$WORK_DIR' does not exist." >&2
        exit 1
    fi

    local mandatory_partitions=("system" "system_ext" "vendor" "odm" "my_product")
    for part in "${mandatory_partitions[@]}"; do
        if [ ! -d "$WORK_DIR/$part" ]; then
            echo "Error: Mandatory donor partition directory '$WORK_DIR/$part' does not exist." >&2
            exit 1
        fi
        echo "  [OK] Partition source: $part ($(du -sh "$WORK_DIR/$part" 2>/dev/null | awk '{print $1}' || echo "present"))"
    done

    # Resolve authoritative APEX directory in donor tree
    APEX_DIR=""
    if [ -d "$WORK_DIR/system/system/apex" ]; then
        APEX_DIR="$WORK_DIR/system/system/apex"
    elif [ -d "$WORK_DIR/system/apex" ]; then
        APEX_DIR="$WORK_DIR/system/apex"
    elif [ -d "$WORK_DIR/apex" ]; then
        APEX_DIR="$WORK_DIR/apex"
    fi

    if [ -z "$APEX_DIR" ] || [ ! -d "$APEX_DIR" ]; then
        echo "Error: Authoritative APEX directory not found under '$WORK_DIR' (expected system/system/apex or system/apex)." >&2
        exit 1
    fi
    echo "  [OK] Authoritative APEX source directory: $APEX_DIR"

    # 1. Validate Runtime APEX
    FOUND_RUNTIME=""
    for cand in "$APEX_DIR/com.android.runtime.apex" "$APEX_DIR/com.google.android.runtime.apex"; do
        if [ -f "$cand" ] && [ -s "$cand" ]; then FOUND_RUNTIME="$cand"; break; fi
    done
    if [ -z "$FOUND_RUNTIME" ]; then
        echo "Error: Mandatory runtime APEX module (com.android.runtime.apex or com.google.android.runtime.apex) missing in $APEX_DIR." >&2
        exit 1
    fi
    if [ -f "$PROJECT_ROOT/tools/extract_apex_info.py" ] && command -v python3 >/dev/null 2>&1; then
        if ! python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$FOUND_RUNTIME" --expect-package "com.android.runtime,com.google.android.runtime" >/dev/null 2>&1; then
            echo "Error: Mandatory runtime APEX manifest validation failed for $(basename "$FOUND_RUNTIME")." >&2
            exit 1
        fi
    fi
    echo "  [OK] Runtime APEX: $(basename "$FOUND_RUNTIME")"

    # 2. Validate ART APEX
    FOUND_ART=""
    for cand in "$APEX_DIR/com.google.android.art_compressed.apex" \
                "$APEX_DIR/com.android.art_compressed.apex" \
                "$APEX_DIR/com.android.art.apex" \
                "$APEX_DIR/com.google.android.art.apex"; do
        if [ -f "$cand" ] && [ -s "$cand" ]; then FOUND_ART="$cand"; break; fi
    done
    if [ -z "$FOUND_ART" ]; then
        echo "Error: Mandatory ART APEX module (com.google.android.art_compressed.apex or com.android.art.apex) missing in $APEX_DIR." >&2
        exit 1
    fi
    if [ -f "$PROJECT_ROOT/tools/extract_apex_info.py" ] && command -v python3 >/dev/null 2>&1; then
        if ! python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$FOUND_ART" --expect-package "com.android.art,com.google.android.art" >/dev/null 2>&1; then
            echo "Error: Mandatory ART APEX manifest validation failed for $(basename "$FOUND_ART")." >&2
            exit 1
        fi
    fi
    echo "  [OK] ART APEX: $(basename "$FOUND_ART")"

    # 3. Validate i18n APEX
    FOUND_I18N=""
    for cand in "$APEX_DIR/com.android.i18n.apex" \
                "$APEX_DIR/com.google.android.i18n.apex" \
                "$APEX_DIR/com.google.android.i18n_compressed.apex"; do
        if [ -f "$cand" ] && [ -s "$cand" ]; then FOUND_I18N="$cand"; break; fi
    done
    if [ -z "$FOUND_I18N" ]; then
        echo "Error: Mandatory i18n APEX module (com.android.i18n.apex) missing in $APEX_DIR." >&2
        exit 1
    fi
    if [ -f "$PROJECT_ROOT/tools/extract_apex_info.py" ] && command -v python3 >/dev/null 2>&1; then
        if ! python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$FOUND_I18N" --expect-package "com.android.i18n,com.google.android.i18n" >/dev/null 2>&1; then
            echo "Error: Mandatory i18n APEX manifest validation failed for $(basename "$FOUND_I18N")." >&2
            exit 1
        fi
    fi
    echo "  [OK] i18n APEX: $(basename "$FOUND_I18N")"

    # 4. Validate Timezone APEX
    FOUND_TZDATA=""
    for cand in "$APEX_DIR/com.google.android.tzdata6.apex" \
                "$APEX_DIR/com.google.android.tzdata.apex" \
                "$APEX_DIR/com.android.tzdata.apex"; do
        if [ -f "$cand" ] && [ -s "$cand" ]; then FOUND_TZDATA="$cand"; break; fi
    done
    if [ -z "$FOUND_TZDATA" ]; then
        echo "Error: Mandatory Timezone APEX module (com.google.android.tzdata6.apex or com.android.tzdata.apex) missing in $APEX_DIR." >&2
        exit 1
    fi
    if [ -f "$PROJECT_ROOT/tools/extract_apex_info.py" ] && command -v python3 >/dev/null 2>&1; then
        if ! python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$FOUND_TZDATA" --expect-package "com.android.tzdata,com.google.android.tzdata,com.google.android.tzdata6" >/dev/null 2>&1; then
            echo "Error: Mandatory Timezone APEX manifest validation failed for $(basename "$FOUND_TZDATA")." >&2
            exit 1
        fi
    fi
    echo "  [OK] Timezone APEX: $(basename "$FOUND_TZDATA")"
}

if [ "$CHECK_DONOR_ONLY" -eq 1 ]; then
    validate_donor_rom
    echo ""
    echo "[OK] All donor ROM partitions and APEX modules are verified."
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Hardware Asset Cryptographic & Architectural Validation
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 2: Validating Authentic OnePlus 7T Hardware Assets ---"

KERNEL_IMG="$PROJECT_ROOT/stage1/kernel_src/kernel"
DTB_IMG="$PROJECT_ROOT/stage1/kernel_src/dtb"
RECOVERY_DTBO_IMG="$PROJECT_ROOT/stage1/kernel_src/recovery_dtbo"

EXPECTED_KERNEL_SHA="c32e3a267b1e44e92f0bdb909358e1c95fa900cb8219076581cdbb4084cc9129"
EXPECTED_KERNEL_SIZE=48713752
EXPECTED_DTB_SHA="e4faf7c553f88246077343de51487d90517bb534e345ee44893d2e4fb348df3c"
EXPECTED_DTB_SIZE=9055368
EXPECTED_RECOVERY_DTBO_SHA="7cfdd1984a7be7edd8ef4e761540cf32e69f1cba6a844afe6ba6780dd12223c1"
EXPECTED_RECOVERY_DTBO_SIZE=3219456

# Kernel validation
if [ ! -f "$KERNEL_IMG" ]; then
    echo "Error: Hardware kernel image missing: $KERNEL_IMG" >&2
    exit 1
fi
ACTUAL_KERNEL_SIZE=$(stat -c "%s" "$KERNEL_IMG" 2>/dev/null || stat -f "%z" "$KERNEL_IMG")
if [ "$ACTUAL_KERNEL_SIZE" -ne "$EXPECTED_KERNEL_SIZE" ]; then
    echo "Error: Kernel size mismatch: $ACTUAL_KERNEL_SIZE != $EXPECTED_KERNEL_SIZE" >&2
    exit 1
fi
ACTUAL_KERNEL_SHA=$(sha256sum "$KERNEL_IMG" | awk '{print $1}')
if [ "$ACTUAL_KERNEL_SHA" != "$EXPECTED_KERNEL_SHA" ]; then
    echo "Error: Kernel SHA-256 mismatch: $ACTUAL_KERNEL_SHA != $EXPECTED_KERNEL_SHA" >&2
    exit 1
fi
if ! grep -a -F "4.14.357-perf-gcd3073fb68f1" "$KERNEL_IMG" >/dev/null 2>&1; then
    echo "Error: Kernel does not contain expected banner 4.14.357-perf-gcd3073fb68f1" >&2
    exit 1
fi
echo "  [OK] Kernel verified (SHA: ${ACTUAL_KERNEL_SHA:0:16}..., size: $ACTUAL_KERNEL_SIZE B, 4.14.357)"

# DTB validation
if [ ! -f "$DTB_IMG" ]; then
    echo "Error: Device Tree Blob missing: $DTB_IMG" >&2
    exit 1
fi
ACTUAL_DTB_SIZE=$(stat -c "%s" "$DTB_IMG" 2>/dev/null || stat -f "%z" "$DTB_IMG")
if [ "$ACTUAL_DTB_SIZE" -ne "$EXPECTED_DTB_SIZE" ]; then
    echo "Error: DTB size mismatch: $ACTUAL_DTB_SIZE != $EXPECTED_DTB_SIZE" >&2
    exit 1
fi
ACTUAL_DTB_SHA=$(sha256sum "$DTB_IMG" | awk '{print $1}')
if [ "$ACTUAL_DTB_SHA" != "$EXPECTED_DTB_SHA" ]; then
    echo "Error: DTB SHA-256 mismatch: $ACTUAL_DTB_SHA != $EXPECTED_DTB_SHA" >&2
    exit 1
fi
if ! grep -a -F "qcom,sm8150" "$DTB_IMG" >/dev/null 2>&1; then
    echo "Error: DTB does not match Qualcomm SM8150 platform" >&2
    exit 1
fi
echo "  [OK] DTB verified (SHA: ${ACTUAL_DTB_SHA:0:16}..., size: $ACTUAL_DTB_SIZE B, qcom,sm8150)"

# Recovery DTBO validation
if [ ! -f "$RECOVERY_DTBO_IMG" ]; then
    echo "Error: Recovery DTBO missing: $RECOVERY_DTBO_IMG" >&2
    exit 1
fi
ACTUAL_RECOVERY_DTBO_SIZE=$(stat -c "%s" "$RECOVERY_DTBO_IMG" 2>/dev/null || stat -f "%z" "$RECOVERY_DTBO_IMG")
if [ "$ACTUAL_RECOVERY_DTBO_SIZE" -ne "$EXPECTED_RECOVERY_DTBO_SIZE" ]; then
    echo "Error: Recovery DTBO size mismatch: $ACTUAL_RECOVERY_DTBO_SIZE != $EXPECTED_RECOVERY_DTBO_SIZE" >&2
    exit 1
fi
ACTUAL_RECOVERY_DTBO_SHA=$(sha256sum "$RECOVERY_DTBO_IMG" | awk '{print $1}')
if [ "$ACTUAL_RECOVERY_DTBO_SHA" != "$EXPECTED_RECOVERY_DTBO_SHA" ]; then
    echo "Error: Recovery DTBO SHA-256 mismatch: $ACTUAL_RECOVERY_DTBO_SHA != $EXPECTED_RECOVERY_DTBO_SHA" >&2
    exit 1
fi
if ! grep -a -F "samsung_oneplus" "$RECOVERY_DTBO_IMG" >/dev/null 2>&1; then
    echo "Error: Recovery DTBO does not match OnePlus Samsung AMOLED panel" >&2
    exit 1
fi
echo "  [OK] Recovery DTBO verified (SHA: ${ACTUAL_RECOVERY_DTBO_SHA:0:16}..., size: $ACTUAL_RECOVERY_DTBO_SIZE B, samsung_oneplus)"

# ------------------------------------------------------------------------------
# 3. Partition Input Verification (Donor ROM Extraction)
# ------------------------------------------------------------------------------
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$BOOT_ONLY" -eq 0 ] && [ "$SKIP_STAGE2" -eq 0 ]; then
    validate_donor_rom
fi

# ------------------------------------------------------------------------------
# 4. Build Static ARM64 Helper Binary (binderfs_init)
# ------------------------------------------------------------------------------
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$STAGE2_ONLY" -eq 0 ]; then
    echo ""
    echo "--- Step 4: Compiling Static ARM64 Helper (binderfs_init) ---"
    make -C "$PROJECT_ROOT/src" install
    echo "  [OK] binderfs_init compiled and installed across Stage-1 ramdisks"
fi

# ------------------------------------------------------------------------------
# 5. Build Stage-2 EROFS Partition Images & Bootstrap APEX Modules
# ------------------------------------------------------------------------------
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$BOOT_ONLY" -eq 0 ] && [ "$SKIP_STAGE2" -eq 0 ]; then
    echo ""
    echo "--- Step 5: Packaging Stage-2 EROFS Partition Images ---"
    "$PROJECT_ROOT/scripts/build_stage2_erofs.sh"
    echo "  [OK] Stage-2 EROFS partitions and APEX modules generated successfully"
fi

# ------------------------------------------------------------------------------
# 6. Build Stage-1 Boot Images (loader.img and stage1.img)
# ------------------------------------------------------------------------------
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$STAGE2_ONLY" -eq 0 ]; then
    echo ""
    echo "--- Step 6: Packaging Stage-1 Android Boot Images ---"
    "$PROJECT_ROOT/scripts/build_loader.sh"
    "$PROJECT_ROOT/scripts/build_stage1.sh"
    echo "  [OK] Stage-1 boot images packaged successfully"
fi

# ------------------------------------------------------------------------------
# 7. Independent Cryptographic & Architectural Verification
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 7: Performing Independent Verification & Safety Audits ---"

if [ "$STAGE2_ONLY" -eq 0 ]; then
    # Verify loader.img
    echo "1. Verifying build/loader.img..."
    "$PROJECT_ROOT/scripts/verify_boot_image.sh" "$PROJECT_ROOT/build/loader.img"

    # Verify stage1.img
    echo "2. Verifying build/stage1.img..."
    "$PROJECT_ROOT/scripts/verify_boot_image.sh" "$PROJECT_ROOT/build/stage1.img"
fi

if [ "$BOOT_ONLY" -eq 0 ]; then
    # Verify build/images/
    echo "3. Verifying Stage-2 partition images and APEX modules manifest..."
    if [ ! -d "$PROJECT_ROOT/build/images" ] || [ ! -f "$PROJECT_ROOT/build/images/SHA256SUMS" ]; then
        echo "Error: Stage-2 images directory or SHA256SUMS manifest is missing: $PROJECT_ROOT/build/images" >&2
        exit 1
    fi
    (cd "$PROJECT_ROOT/build/images" && sha256sum -c SHA256SUMS --status)
    echo "  [OK] All Stage-2 images match build/images/SHA256SUMS"

    # Verify PARTITION_MAP schema
    MAP_FILE="$PROJECT_ROOT/build/images/PARTITION_MAP"
    if [ ! -f "$MAP_FILE" ] || [ ! -s "$MAP_FILE" ]; then
        echo "Error: Authoritative PARTITION_MAP is missing or empty!" >&2
        exit 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$trimmed" in ''|\#*) continue ;; esac
        num_colons=$(echo "$trimmed" | tr -cd ':' | wc -c)
        if [ "$num_colons" -ne 3 ]; then
            echo "Error: Malformed PARTITION_MAP record: '$trimmed' (expected 4 fields)" >&2
            exit 1
        fi
        sha_field=$(echo "$trimmed" | cut -d: -f4)
        if ! echo "$sha_field" | grep -qE '^[0-9a-fA-F]{64}$'; then
            echo "Error: Invalid SHA-256 field in PARTITION_MAP: '$trimmed'" >&2
            exit 1
        fi
    done < "$MAP_FILE"
    echo "  [OK] PARTITION_MAP schema and checksum contract validated"
fi

# Run static safety audit
echo "4. Running global pre-boot static safety audit..."
"$PROJECT_ROOT/tools/safe/audit-no-writes.sh"
echo "  [OK] Global static safety audit PASSED (zero disk writes, fail-closed enforcement)"

# ------------------------------------------------------------------------------
# 8. Final Build Summary Report
# ------------------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "    ONEPLUS 7T OXYGENOS 16 BUILD & VERIFICATION SUMMARY"
echo "=========================================================="

if [ -f "$PROJECT_ROOT/build/loader.img" ]; then
    LOADER_SIZE=$(stat -c "%s" "$PROJECT_ROOT/build/loader.img" 2>/dev/null || stat -f "%z" "$PROJECT_ROOT/build/loader.img")
    LOADER_SHA=$(sha256sum "$PROJECT_ROOT/build/loader.img" | awk '{print $1}')
    echo "Bootloader Image (Interactive ADB Diagnostic):"
    echo "  Path:    build/loader.img"
    echo "  Size:    $LOADER_SIZE bytes ($(ls -lh "$PROJECT_ROOT/build/loader.img" | awk '{print $5}'))"
    echo "  SHA-256: $LOADER_SHA"
fi

if [ -f "$PROJECT_ROOT/build/stage1.img" ]; then
    STAGE1_SIZE=$(stat -c "%s" "$PROJECT_ROOT/build/stage1.img" 2>/dev/null || stat -f "%z" "$PROJECT_ROOT/build/stage1.img")
    STAGE1_SHA=$(sha256sum "$PROJECT_ROOT/build/stage1.img" | awk '{print $1}')
    echo "Stage-1 Boot Image (Autonomous RAM Supervisor):"
    echo "  Path:    build/stage1.img"
    echo "  Size:    $STAGE1_SIZE bytes ($(ls -lh "$PROJECT_ROOT/build/stage1.img" | awk '{print $5}'))"
    echo "  SHA-256: $STAGE1_SHA"
fi

if [ -d "$PROJECT_ROOT/build/images" ] && [ -f "$PROJECT_ROOT/build/images/PARTITION_MAP" ]; then
    TOTAL_IMAGES=$(grep -vE '^[[:space:]]*(#|$)' "$PROJECT_ROOT/build/images/PARTITION_MAP" | wc -l)
    TOTAL_EROFS_BYTES=$(du -sb "$PROJECT_ROOT/build/images" 2>/dev/null | awk '{print $1}' || du -sk "$PROJECT_ROOT/build/images" | awk '{print $1 * 1024}')
    echo "Stage-2 Partition Images:"
    echo "  Directory: build/images/"
    echo "  Count:     $TOTAL_IMAGES partition images and APEX modules"
    echo "  Total:     $TOTAL_EROFS_BYTES bytes ($(du -sh "$PROJECT_ROOT/build/images" | awk '{print $1}'))"
    echo "  Manifest:  build/images/PARTITION_MAP (authoritative 4-field contract)"
    echo "  Checksums: build/images/SHA256SUMS (cryptographically verified)"
fi

echo "----------------------------------------------------------"
echo "HARDWARE EXECUTION STATUS:"
echo "  Current Phase: PRE-BOOT VERIFICATION IN PROGRESS"
echo "  Physical Boot: NOT APPROVED (Testing limited to fastboot boot)"
echo "  Safety Policy: ZERO FLASHING, ZERO PHYSICAL DISK WRITES"
echo ""
echo "Safe Testing Procedure for OnePlus 7T HD1901:"
echo "  1. Enter bootloader on device (Volume Down + Power)"
echo "  2. Boot Stage-1 to volatile RAM (NEVER flash):"
echo "       tools/safe/fastboot boot build/stage1.img"
echo "  3. Stage images and initiate Stage-2 handover:"
echo "       tools/safe/run_stage2.sh"
echo "=========================================================="
exit 0
