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
#   * Play Integrity Fix (pif.json)
#   * SELinux duplicate property prefix resolution (system_ext_property_contexts)
#   * 60Hz AMOLED replacement panel optimizations (dsi_samsung_s6e3fc2x01_cmd_display)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$PROJECT_ROOT/work"
OUT_DIR="$PROJECT_ROOT/build/images"
MKFS_EROFS="$PROJECT_ROOT/external/coloros_port/bin/Linux/x86_64/mkfs.erofs"
FSCK_EROFS="$PROJECT_ROOT/external/coloros_port/bin/Linux/x86_64/fsck.erofs"

if [ ! -x "$MKFS_EROFS" ]; then
    MKFS_EROFS="mkfs.erofs"
fi
if [ ! -x "$FSCK_EROFS" ]; then
    FSCK_EROFS="fsck.erofs"
fi

mkdir -p "$OUT_DIR"

echo "=========================================================="
echo "      STAGE-2 EROFS PARTITION REPACK & FEATURE INJECTION   "
echo "=========================================================="

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

# 2. Fix Executable Permissions on Vendor & ODM binaries
echo "[2/6] Fixing execute permissions (0755) on vendor and ODM binaries..."
if [ -d "$WORK_DIR/vendor/vendor/bin" ]; then
    chmod -R 0755 "$WORK_DIR/vendor/vendor/bin"
fi
if [ -d "$WORK_DIR/odm/bin" ]; then
    chmod -R 0755 "$WORK_DIR/odm/bin"
fi

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
    # Ensure conflicting duplicate prefixes are commented out
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

# 5. Build EROFS Partition Images
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
    
    if [ -x "$FSCK_EROFS" ]; then
        "$FSCK_EROFS" "$OUT_IMG" >/dev/null 2>&1 && echo "    Verified: $NAME.erofs.img passed fsck."
    fi
done

# 6. Extract / Build Runtime APEX Image
echo "[6/6] Packaging Bionic runtime APEX payload..."
APEX_SRC="$WORK_DIR/system/system/apex/com.android.runtime.apex"
if [ -f "$APEX_SRC" ]; then
    UNZIP_TMP="/tmp/runtime_apex_unpack"
    rm -rf "$UNZIP_TMP"
    mkdir -p "$UNZIP_TMP"
    unzip -q "$APEX_SRC" "apex_payload.img" -d "$UNZIP_TMP"
    if [ -f "$UNZIP_TMP/apex_payload.img" ]; then
        cp -v "$UNZIP_TMP/apex_payload.img" "$OUT_DIR/runtime_apex.erofs.img"
    fi
    rm -rf "$UNZIP_TMP"
fi

echo "=========================================================="
echo "Stage-2 EROFS images successfully generated in:"
echo "$OUT_DIR"
ls -lh "$OUT_DIR"/*.erofs.img
