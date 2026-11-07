#!/usr/bin/env bash
# ==============================================================================
# build_stage2_erofs.sh - Build and Repack EROFS Partitions for Stage-2 RAM Boot
# OxygenOS 16 (Android 16 / SDK 36 / Baklava) on OnePlus 7T (HD1901 / hotdogb)
#
# Provenance:
# - Donor ROM: OnePlus 9 Pro OxygenOS 16 (ota_full-LE2113_16.0.10.500.zip)
# - Device Base: LineageOS 23.2 (hotdogb) / crDroid 12.x vendor/odm
# - Injections:
#   * Google Photos Unlimited Original Quality Backup (pixel_2016_experience.xml)
#   * Play Integrity Fix template (pif.json)
#   * SELinux duplicate property prefix resolution (system_ext_property_contexts)
#   * 60Hz AMOLED replacement panel optimizations (dsi_samsung_s6e3fc2x01_cmd_display)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$PROJECT_ROOT/work"
OUT_DIR="$PROJECT_ROOT/build/images"

# Safe temporary build directory with cleanup trap
TMP_BUILD_DIR="$(mktemp -d /tmp/erofs_build.XXXXXX)"
cleanup() {
    rm -rf "$TMP_BUILD_DIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

echo "=========================================================="
echo "      STAGE-2 EROFS PARTITION REPACK & FEATURE INJECTION   "
echo "=========================================================="

# Tool Discovery & Validation
MKFS_EROFS=""
FSCK_EROFS=""

if command -v mkfs.erofs >/dev/null 2>&1; then
    MKFS_EROFS="$(command -v mkfs.erofs)"
elif [ -x "$PROJECT_ROOT/external/coloros_port/bin/Linux/x86_64/mkfs.erofs" ]; then
    MKFS_EROFS="$PROJECT_ROOT/external/coloros_port/bin/Linux/x86_64/mkfs.erofs"
elif [ -x "$PROJECT_ROOT/external/coloros_port/otatools/bin/mkfs.erofs" ]; then
    MKFS_EROFS="$PROJECT_ROOT/external/coloros_port/otatools/bin/mkfs.erofs"
else
    echo "ERROR: mkfs.erofs could not be found in PATH or external/coloros_port!" >&2
    exit 1
fi

if command -v fsck.erofs >/dev/null 2>&1; then
    FSCK_EROFS="$(command -v fsck.erofs)"
elif [ -x "$PROJECT_ROOT/external/coloros_port/bin/Linux/x86_64/fsck.erofs" ]; then
    FSCK_EROFS="$PROJECT_ROOT/external/coloros_port/bin/Linux/x86_64/fsck.erofs"
elif [ -x "$PROJECT_ROOT/external/coloros_port/otatools/bin/fsck.erofs" ]; then
    FSCK_EROFS="$PROJECT_ROOT/external/coloros_port/otatools/bin/fsck.erofs"
else
    echo "ERROR: fsck.erofs could not be found in PATH or external/coloros_port!" >&2
    exit 1
fi

echo "Using mkfs.erofs: $MKFS_EROFS"
echo "Using fsck.erofs: $FSCK_EROFS"

# Validate tools can run
"$MKFS_EROFS" -V >/dev/null 2>&1 || { echo "ERROR: mkfs.erofs failed verification test" >&2; exit 1; }
"$FSCK_EROFS" -V >/dev/null 2>&1 || { echo "ERROR: fsck.erofs failed verification test" >&2; exit 1; }

# 1. Apply Feature Injections
echo "[1/6] Injecting Google Photos Unlimited Backup and PIF..."
CONFIGS_DIR="$PROJECT_ROOT/configs"

if [ -f "$CONFIGS_DIR/pixel_2016_experience.xml" ]; then
    for target in "$WORK_DIR/my_product/etc/permissions" "$WORK_DIR/system/system/etc/permissions" "$WORK_DIR/system_ext/etc/permissions"; do
        if [ -d "$target" ]; then
            cp -v "$CONFIGS_DIR/pixel_2016_experience.xml" "$target/"
        fi
    done
fi

if [ -f "$CONFIGS_DIR/pif.json" ]; then
    for target in "$WORK_DIR/my_product/etc" "$WORK_DIR/system/system/etc" "$WORK_DIR/system_ext/etc"; do
        if [ -d "$target" ]; then
            cp -v "$CONFIGS_DIR/pif.json" "$target/"
        fi
    done
fi

# 2. Targeted Permission Corrections (Preserve existing permissions)
echo "[2/6] Applying targeted execute permission corrections..."
fix_executable_permissions() {
    local dir="$1"
    if [ ! -d "$dir" ]; then return 0; fi
    echo "  Scanning $dir for missing executable flags on binaries/scripts..."
    find "$dir" -type f | while IFS= read -r file; do
        local magic
        magic=$(head -c 4 "$file" 2>/dev/null || true)
        if [ "$magic" = $'\x7fELF' ]; then
            if [ ! -x "$file" ]; then
                chmod +x "$file"
                echo "    Added +x to ELF executable: $(basename "$file")"
            fi
        elif head -c 2 "$file" 2>/dev/null | grep -q '^#!'; then
            if [ ! -x "$file" ]; then
                chmod +x "$file"
                echo "    Added +x to shell script: $(basename "$file")"
            fi
        fi
    done
}

fix_executable_permissions "$WORK_DIR/vendor/vendor/bin"
fix_executable_permissions "$WORK_DIR/odm/bin"

# 3. Configure Display Properties for 60Hz Replacement AMOLED Panel
echo "[3/6] Setting fixed 60Hz display properties in vendor build.prop..."
VENDOR_PROP="$WORK_DIR/vendor/vendor/build.prop"
if [ -f "$VENDOR_PROP" ]; then
    for prop in \
        "ro.surface_flinger.game_default_frame_rate_override=60" \
        "ro.surface_flinger.enable_frame_rate_override=false" \
        "persist.sys.sf.native_mode=0" \
        "vendor.display.enable_optimize_refresh=1"; do
        key="${prop%%=*}"
        if grep -q "^$key=" "$VENDOR_PROP"; then
            sed -i "s|^$key=.*|$prop|" "$VENDOR_PROP"
        else
            echo "$prop" >> "$VENDOR_PROP"
        fi
    done
fi

# 4. Resolve SELinux Property Context Prefix Conflicts
echo "[4/6] Verifying SELinux system_ext_property_contexts..."
PROP_CTX="$WORK_DIR/system_ext/etc/selinux/system_ext_property_contexts"
if [ -f "$PROP_CTX" ]; then
    for prefix in \
        "ro.bootimage.build.fingerprint" \
        "ro.build.date" \
        "ro.build.date.utc" \
        "ro.build.version.incremental" \
        "ro.build.product" \
        "ro.build.version.base_os" \
        "ro.build.display.id" \
        "ro.product.brand" \
        "ro.product.model" \
        "ro.product.device" \
        "ro.product.name" \
        "vendor.oplus.video.dump.output" \
        "ro.build.flavor" \
        "camera.disable_zsl_mode" \
        "persist.vendor.side.fp.near.feature.support" \
        "persist.vendor.rpmb.enable.state" \
        "ro.cdma.home.operator.numeric" \
        "ro.cdma.home.operator.alpha"; do
        sed -i "s|^\($prefix .*\)|# [CONFLICT-FIX] \1|" "$PROP_CTX"
    done
fi

# 5. Build and Strictly Validate EROFS Partition Images
echo "[5/6] Building high-compression EROFS partition images..."
PARTITIONS=(
    "odm:$WORK_DIR/odm"
    "vendor:$WORK_DIR/vendor"
    "my_region:$WORK_DIR/my_region"
    "system:$WORK_DIR/system"
    "system_ext:$WORK_DIR/system_ext"
    "my_product:$WORK_DIR/my_product"
)

for part_def in "${PARTITIONS[@]}"; do
    NAME="${part_def%%:*}"
    SRC="${part_def##*:}"
    OUT_IMG="$OUT_DIR/$NAME.erofs.img"

    if [ ! -d "$SRC" ]; then
        echo "Warning: Source directory $SRC not found, skipping $NAME."
        continue
    fi

    echo " -> Packaging $NAME.erofs.img from $SRC..."
    "$MKFS_EROFS" -z lz4 -x -1 "$OUT_IMG" "$SRC"

    # Mandatory fsck verification: stop immediately on error
    echo "    Verifying integrity with fsck.erofs..."
    if ! "$FSCK_EROFS" "$OUT_IMG"; then
        echo "ERROR: fsck.erofs reported integrity failure for $OUT_IMG!" >&2
        exit 1
    fi

    # Verify generated image is valid EROFS
    magic=$(od -j 1024 -N 4 -t x4 -An "$OUT_IMG" 2>/dev/null | tr -d ' ' || true)
    if [ "$magic" != "e0f5e1e2" ]; then
        echo "ERROR: $OUT_IMG does not have valid EROFS magic bytes ($magic)!" >&2
        exit 1
    fi
    echo "    Integrity verified: $NAME.erofs.img is valid EROFS."
done

# 6. Extract and Detect Runtime APEX Payload Filesystem Type
echo "[6/6] Packaging Bionic runtime APEX payload..."
APEX_SRC="$WORK_DIR/system/system/apex/com.android.runtime.apex"
if [ -f "$APEX_SRC" ]; then
    UNZIP_TMP="$TMP_BUILD_DIR/runtime_apex_unpack"
    mkdir -p "$UNZIP_TMP"
    unzip -q "$APEX_SRC" "apex_payload.img" -d "$UNZIP_TMP"

    PAYLOAD="$UNZIP_TMP/apex_payload.img"
    if [ -f "$PAYLOAD" ]; then
        # Detect filesystem type dynamically via magic numbers
        PAYLOAD_FSTYPE="unknown"
        magic_erofs=$(od -j 1024 -N 4 -t x4 -An "$PAYLOAD" 2>/dev/null | tr -d ' ' || true)
        magic_ext4=$(od -j 1080 -N 2 -t x2 -An "$PAYLOAD" 2>/dev/null | tr -d ' ' || true)

        if [ "$magic_erofs" = "e0f5e1e2" ]; then
            PAYLOAD_FSTYPE="erofs"
        elif [ "$magic_ext4" = "ef53" ]; then
            PAYLOAD_FSTYPE="ext4"
        else
            # Fallback to file command
            f_out=$(file -b "$PAYLOAD" 2>/dev/null || true)
            if echo "$f_out" | grep -qi "erofs"; then
                PAYLOAD_FSTYPE="erofs"
            elif echo "$f_out" | grep -qi "ext4"; then
                PAYLOAD_FSTYPE="ext4"
            fi
        fi

        echo "Detected runtime APEX payload filesystem: $PAYLOAD_FSTYPE"
        if [ "$PAYLOAD_FSTYPE" = "unknown" ]; then
            echo "ERROR: Unable to detect filesystem type of $PAYLOAD" >&2
            exit 1
        fi

        cp "$PAYLOAD" "$OUT_DIR/runtime_apex.img"
        echo "$PAYLOAD_FSTYPE" > "$OUT_DIR/runtime_apex.fstype"
        echo "Runtime APEX payload staged as $OUT_DIR/runtime_apex.img (fstype: $PAYLOAD_FSTYPE)"
    else
        echo "ERROR: apex_payload.img not found inside $APEX_SRC" >&2
        exit 1
    fi
fi

echo "=========================================================="
echo "Stage-2 images successfully generated and verified in:"
echo "$OUT_DIR"
ls -lh "$OUT_DIR"/*.img
