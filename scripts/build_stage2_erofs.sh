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
WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/work}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/build/images}"

# Safe temporary build directory with cleanup trap
TMP_BUILD_DIR="$(mktemp -d /tmp/erofs_build.XXXXXX)"
cleanup() {
    rm -rf "$TMP_BUILD_DIR"
}
trap cleanup EXIT

STAGING_DIR="$TMP_BUILD_DIR/staged_images"
mkdir -p "$STAGING_DIR"
mkdir -p "$OUT_DIR"

echo "=========================================================="
echo "      STAGE-2 EROFS PARTITION REPACK & FEATURE INJECTION   "
echo "=========================================================="

# 0. Tool Discovery & Validation
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

# 1. Validate Mandatory Inputs
echo "Validating mandatory input directories and assets..."
MANDATORY_DIRS=(
    "system:$WORK_DIR/system"
    "system_ext:$WORK_DIR/system_ext"
    "vendor:$WORK_DIR/vendor"
    "odm:$WORK_DIR/odm"
    "my_product:$WORK_DIR/my_product"
)

MISSING_MANDATORY=()
for m in "${MANDATORY_DIRS[@]}"; do
    NAME="${m%%:*}"
    SRC="${m##*:}"
    if [ ! -d "$SRC" ]; then
        MISSING_MANDATORY+=("$NAME ($SRC)")
    fi
done

APEX_SRC="$WORK_DIR/system/system/apex/com.android.runtime.apex"
if [ ! -f "$APEX_SRC" ] || [ ! -s "$APEX_SRC" ]; then
    MISSING_MANDATORY+=("runtime_apex ($APEX_SRC)")
fi

if [ "${#MISSING_MANDATORY[@]}" -gt 0 ]; then
    echo "CRITICAL BUILD ERROR: Missing mandatory inputs for Stage-2 build:" >&2
    for item in "${MISSING_MANDATORY[@]}"; do
        echo "  - $item" >&2
    done
    echo "Halting immediately to prevent stale or incomplete image generation." >&2
    exit 1
fi
echo "All mandatory source directories and runtime APEX verified."

# 2. Apply Feature Injections
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

# 3. Targeted Permission Corrections
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

# 4. Configure Display Properties for 60Hz Replacement AMOLED Panel
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

# 5. Resolve SELinux Property Context Prefix Conflicts
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

# 6. Build and Strictly Validate EROFS Partition Images into Temporary Staging
echo "[5/6] Building high-compression EROFS partition images in clean staging area..."
PARTITIONS=(
    "odm:$WORK_DIR/odm:1"
    "vendor:$WORK_DIR/vendor:1"
    "my_region:$WORK_DIR/my_region:0"
    "system:$WORK_DIR/system:1"
    "system_ext:$WORK_DIR/system_ext:1"
    "my_product:$WORK_DIR/my_product:1"
)

for part_def in "${PARTITIONS[@]}"; do
    NAME=$(echo "$part_def" | cut -d: -f1)
    SRC=$(echo "$part_def" | cut -d: -f2)
    MANDATORY=$(echo "$part_def" | cut -d: -f3)
    STAGE_IMG="$STAGING_DIR/$NAME.erofs.img"

    if [ ! -d "$SRC" ]; then
        if [ "$MANDATORY" -eq 1 ]; then
            echo "ERROR: Mandatory source directory $SRC missing!" >&2
            exit 1
        else
            echo "Note: Optional source directory $SRC not found, skipping $NAME."
            continue
        fi
    fi

    echo " -> Packaging $NAME.erofs.img from $SRC..."
    "$MKFS_EROFS" -z lz4 -x -1 "$STAGE_IMG" "$SRC"

    # Mandatory fsck verification: stop immediately on error
    echo "    Verifying integrity with fsck.erofs..."
    if ! "$FSCK_EROFS" "$STAGE_IMG"; then
        echo "ERROR: fsck.erofs reported integrity failure for $STAGE_IMG!" >&2
        exit 1
    fi

    # Verify generated image has valid EROFS magic bytes (0xe0f5e1e2 at offset 1024)
    magic=$(od -j 1024 -N 4 -t x4 -An "$STAGE_IMG" 2>/dev/null | tr -d ' ' || true)
    if [ "$magic" != "e0f5e1e2" ]; then
        echo "ERROR: $STAGE_IMG does not have valid EROFS magic bytes ($magic)!" >&2
        exit 1
    fi
    echo "    Integrity verified: $NAME.erofs.img is valid EROFS."
done

# 7. Extract and Detect Runtime APEX Payload
echo "[6/6] Packaging Bionic runtime APEX payload..."
UNZIP_TMP="$TMP_BUILD_DIR/runtime_apex_unpack"
mkdir -p "$UNZIP_TMP"
if ! unzip -q "$APEX_SRC" "apex_payload.img" -d "$UNZIP_TMP"; then
    echo "CRITICAL ERROR: Failed to unpack apex_payload.img from $APEX_SRC!" >&2
    exit 1
fi

PAYLOAD="$UNZIP_TMP/apex_payload.img"
if [ ! -f "$PAYLOAD" ] || [ ! -s "$PAYLOAD" ]; then
    echo "CRITICAL ERROR: Extracted apex_payload.img is missing or 0 bytes!" >&2
    exit 1
fi

# Detect filesystem type dynamically via magic numbers
PAYLOAD_FSTYPE="unknown"
magic_erofs=$(od -j 1024 -N 4 -t x4 -An "$PAYLOAD" 2>/dev/null | tr -d ' ' || true)
magic_ext4=$(od -j 1080 -N 2 -t x2 -An "$PAYLOAD" 2>/dev/null | tr -d ' ' || true)

if [ "$magic_erofs" = "e0f5e1e2" ]; then
    PAYLOAD_FSTYPE="erofs"
elif [ "$magic_ext4" = "ef53" ]; then
    PAYLOAD_FSTYPE="ext4"
else
    f_out=$(file -b "$PAYLOAD" 2>/dev/null || true)
    if echo "$f_out" | grep -qi "erofs"; then
        PAYLOAD_FSTYPE="erofs"
    elif echo "$f_out" | grep -qi "ext4"; then
        PAYLOAD_FSTYPE="ext4"
    fi
fi

echo "Detected runtime APEX payload filesystem: $PAYLOAD_FSTYPE"
if [ "$PAYLOAD_FSTYPE" = "unknown" ]; then
    echo "CRITICAL ERROR: Unable to detect filesystem type of $PAYLOAD" >&2
    exit 1
fi

# If EROFS, verify with fsck.erofs
if [ "$PAYLOAD_FSTYPE" = "erofs" ]; then
    if ! "$FSCK_EROFS" "$PAYLOAD"; then
        echo "CRITICAL ERROR: fsck.erofs failed on runtime APEX payload!" >&2
        exit 1
    fi
fi

cp "$PAYLOAD" "$STAGING_DIR/runtime_apex.img"
echo "$PAYLOAD_FSTYPE" > "$STAGING_DIR/runtime_apex.fstype"
echo "Runtime APEX payload verified and staged (fstype: $PAYLOAD_FSTYPE)."

# 8. Atomically Publish Verified Images (Prevents Stale Image Reuse)
echo "Atomically publishing newly verified images to $OUT_DIR..."
# Remove old build artifacts so no stale images remain
rm -f "$OUT_DIR"/*.erofs.img "$OUT_DIR"/runtime_apex.* "$OUT_DIR"/SHA256SUMS

cp "$STAGING_DIR"/* "$OUT_DIR/"

# Generate SHA256 checksums
(cd "$OUT_DIR" && sha256sum *.img > SHA256SUMS)

# Verify all mandatory output images exist
MANDATORY_OUTPUTS=("system.erofs.img" "system_ext.erofs.img" "vendor.erofs.img" "odm.erofs.img" "my_product.erofs.img" "runtime_apex.img")
for out in "${MANDATORY_OUTPUTS[@]}"; do
    if [ ! -f "$OUT_DIR/$out" ] || [ ! -s "$OUT_DIR/$out" ]; then
        echo "CRITICAL BUILD ERROR: Expected output image $OUT_DIR/$out was not generated!" >&2
        exit 1
    fi
done

echo "=========================================================="
echo "Stage-2 images successfully generated, verified, and published in:"
echo "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS"
