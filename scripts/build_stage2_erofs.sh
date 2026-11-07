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

BUILD_PARENT="$(dirname "$OUT_DIR")"
mkdir -p "$BUILD_PARENT"
STAGING_DIR="$BUILD_PARENT/.staging_erofs_$$"
BACKUP_OUT_DIR="$BUILD_PARENT/.backup_images_$$"
TMP_BUILD_DIR="$(mktemp -d /tmp/erofs_build.XXXXXX)"

BUILD_SUCCESS=0
INJECTED_FILES=()
MODIFIED_BACKUPS=()

cleanup() {
    local exit_code=$?
    if [ "$BUILD_SUCCESS" -ne 1 ]; then
        echo "Build did not complete successfully. Reverting modifications and cleaning up..." >&2
        # 1. Remove newly injected files
        for f in "${INJECTED_FILES[@]:-}"; do
            [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
        done
        # 2. Restore modified files from .orig backups
        for f in "${MODIFIED_BACKUPS[@]:-}"; do
            if [ -n "$f" ] && [ -f "$f.orig" ]; then
                mv -f "$f.orig" "$f" 2>/dev/null || true
            fi
        done
        # 3. Rollback output directory if backup exists
        if [ -d "$BACKUP_OUT_DIR" ]; then
            echo "Rolling back to previous valid build output..." >&2
            rm -rf "$OUT_DIR" 2>/dev/null || true
            mv "$BACKUP_OUT_DIR" "$OUT_DIR" 2>/dev/null || true
        fi
    else
        # On success, clean up backups
        for f in "${MODIFIED_BACKUPS[@]:-}"; do
            [ -n "$f" ] && rm -f "$f.orig" 2>/dev/null || true
        done
        rm -rf "$BACKUP_OUT_DIR" 2>/dev/null || true
    fi

    rm -rf "$STAGING_DIR" "$TMP_BUILD_DIR" 2>/dev/null || true
    exit "$exit_code"
}
trap cleanup EXIT ERR INT TERM

mkdir -p "$STAGING_DIR"

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

# 2. Apply Feature Injections with Reversible Backups
echo "[1/6] Injecting Google Photos Unlimited Backup and PIF..."
CONFIGS_DIR="$PROJECT_ROOT/configs"

inject_file() {
    local src_file="$1"
    local dest_file="$2"
    if [ -f "$dest_file" ]; then
        if [ ! -f "$dest_file.orig" ]; then
            cp -a "$dest_file" "$dest_file.orig"
            MODIFIED_BACKUPS+=("$dest_file")
        fi
    else
        INJECTED_FILES+=("$dest_file")
    fi
    cp "$src_file" "$dest_file"
}

if [ -f "$CONFIGS_DIR/pixel_2016_experience.xml" ]; then
    for target in "$WORK_DIR/my_product/etc/permissions" "$WORK_DIR/system/system/etc/permissions" "$WORK_DIR/system_ext/etc/permissions"; do
        if [ -d "$target" ]; then
            inject_file "$CONFIGS_DIR/pixel_2016_experience.xml" "$target/pixel_2016_experience.xml"
        fi
    done
fi

if [ -f "$CONFIGS_DIR/pif.json" ]; then
    for target in "$WORK_DIR/my_product/etc" "$WORK_DIR/system/system/etc" "$WORK_DIR/system_ext/etc"; do
        if [ -d "$target" ]; then
            inject_file "$CONFIGS_DIR/pif.json" "$target/pif.json"
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
    if [ ! -f "$VENDOR_PROP.orig" ]; then
        cp -a "$VENDOR_PROP" "$VENDOR_PROP.orig"
        MODIFIED_BACKUPS+=("$VENDOR_PROP")
    fi
    for prop in \
        "ro.surface_flinger.game_default_frame_rate_override=60" \
        "ro.surface_flinger.enable_frame_rate_override=false" \
        "persist.sys.sf.native_mode=0" \
        "vendor.display.enable_optimize_refresh=1" \
        "debug.sf.frame_rate_multiple_threshold=60" \
        "ro.vendor.display.default_fps=60"; do
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
    if [ ! -f "$PROP_CTX.orig" ]; then
        cp -a "$PROP_CTX" "$PROP_CTX.orig"
        MODIFIED_BACKUPS+=("$PROP_CTX")
    fi
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

# 7. Extract and Stage All Required Bootstrap APEX Packages
echo "[6/6] Packaging Android 16 Bootstrap APEX Modules (runtime, art, i18n, tzdata)..."

extract_and_stage_apex() {
    local apex_id="$1"
    local output_base="$2"
    local mandatory="${3:-1}"
    local apex_dir="$WORK_DIR/system/system/apex"
    local target_pkg=""

    case "$apex_id" in
        runtime)
            for cand in "$apex_dir/com.android.runtime.apex" "$apex_dir/com.google.android.runtime.apex"; do
                if [ -f "$cand" ]; then target_pkg="$cand"; break; fi
            done
            ;;
        art)
            for cand in "$apex_dir/com.google.android.art_compressed.apex" \
                        "$apex_dir/com.android.art_compressed.apex" \
                        "$apex_dir/com.android.art.apex" \
                        "$apex_dir/com.google.android.art.apex"; do
                if [ -f "$cand" ]; then target_pkg="$cand"; break; fi
            done
            ;;
        i18n)
            for cand in "$apex_dir/com.android.i18n.apex" \
                        "$apex_dir/com.google.android.i18n.apex" \
                        "$apex_dir/com.google.android.i18n_compressed.apex"; do
                if [ -f "$cand" ]; then target_pkg="$cand"; break; fi
            done
            ;;
        tzdata)
            for cand in "$apex_dir/com.google.android.tzdata6.apex" \
                        "$apex_dir/com.google.android.tzdata.apex" \
                        "$apex_dir/com.android.tzdata.apex"; do
                if [ -f "$cand" ]; then target_pkg="$cand"; break; fi
            done
            ;;
    esac

    if [ -z "$target_pkg" ] || [ ! -f "$target_pkg" ]; then
        if [ "$mandatory" -eq 1 ]; then
            echo "CRITICAL ERROR: Mandatory APEX package for '$apex_id' not found in $apex_dir!" >&2
            exit 1
        else
            echo "Note: Optional APEX package for '$apex_id' not found, skipping."
            return 0
        fi
    fi

    echo " -> Extracting payload from $(basename "$target_pkg")..."
    local unpack_dir="$TMP_BUILD_DIR/apex_unpack_${apex_id}"
    mkdir -p "$unpack_dir"

    local payload=""
    if unzip -q "$target_pkg" "apex_payload.img" -d "$unpack_dir" 2>/dev/null; then
        payload="$unpack_dir/apex_payload.img"
    elif unzip -q "$target_pkg" "original_apex" -d "$unpack_dir" 2>/dev/null; then
        mkdir -p "$unpack_dir/orig"
        if unzip -q "$unpack_dir/original_apex" "apex_payload.img" -d "$unpack_dir/orig" 2>/dev/null; then
            payload="$unpack_dir/orig/apex_payload.img"
        fi
    fi

    if [ -z "$payload" ] || [ ! -f "$payload" ] || [ ! -s "$payload" ]; then
        echo "CRITICAL ERROR: Failed to extract apex_payload.img from $target_pkg!" >&2
        exit 1
    fi

    local fstype="unknown"
    local magic_erofs
    magic_erofs=$(od -j 1024 -N 4 -t x4 -An "$payload" 2>/dev/null | tr -d ' ' || true)
    local magic_ext4
    magic_ext4=$(od -j 1080 -N 2 -t x2 -An "$payload" 2>/dev/null | tr -d ' ' || true)

    if [ "$magic_erofs" = "e0f5e1e2" ]; then
        fstype="erofs"
    elif [ "$magic_ext4" = "ef53" ]; then
        fstype="ext4"
    else
        local f_out
        f_out=$(file -b "$payload" 2>/dev/null || true)
        if echo "$f_out" | grep -qi "erofs"; then
            fstype="erofs"
        elif echo "$f_out" | grep -qi "ext4"; then
            fstype="ext4"
        fi
    fi

    echo "    $output_base payload detected filesystem: $fstype"
    if [ "$fstype" = "unknown" ]; then
        echo "CRITICAL ERROR: Unable to detect filesystem type of $payload ($target_pkg)!" >&2
        exit 1
    fi

    if [ "$fstype" = "erofs" ]; then
        if ! "$FSCK_EROFS" "$payload" >/dev/null 2>&1; then
            echo "CRITICAL ERROR: fsck.erofs failed on $output_base payload!" >&2
            exit 1
        fi
    fi

    # Validate supported filesystem type
    if [ "$fstype" != "erofs" ] && [ "$fstype" != "ext4" ]; then
        echo "CRITICAL BUILD ERROR: APEX payload filesystem '$fstype' is unsupported (must be erofs or ext4)!" >&2
        exit 1
    fi

    # Extract authentic APEX version code from manifest without silent fallback
    local expected_pkg="com.android.${apex_id}"
    echo " -> Extracting and validating manifest metadata via tools/extract_apex_info.py..."
    local pkg_version
    if ! pkg_version=$(python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$target_pkg" --expect-package "$expected_pkg" --version-only); then
        echo "CRITICAL BUILD ERROR: APEX manifest extraction failed for $target_pkg ($expected_pkg)!" >&2
        exit 1
    fi

    pkg_version=$(echo "$pkg_version" | tr -d '[:space:]')
    if [ -z "$pkg_version" ] || ! echo "$pkg_version" | grep -qE '^[1-9][0-9]*$'; then
        echo "CRITICAL BUILD ERROR: APEX version code for $target_pkg is invalid or non-numeric: '$pkg_version'!" >&2
        exit 1
    fi

    cp "$payload" "$STAGING_DIR/${output_base}.img"
    echo "$fstype" > "$STAGING_DIR/${output_base}.fstype"
    echo "$pkg_version" > "$STAGING_DIR/${output_base}.version"
    echo "    Staged ${output_base}.img, ${output_base}.fstype ($fstype), and ${output_base}.version ($pkg_version)."
}

extract_and_stage_apex "runtime" "runtime_apex" 1
extract_and_stage_apex "art" "art_apex" 1
extract_and_stage_apex "i18n" "i18n_apex" 1
extract_and_stage_apex "tzdata" "tzdata_apex" 1

# 8. Staging Verification & Pre-Publish Validation
echo "Verifying staged images before atomic publication..."
MANDATORY_OUTPUTS=(
    "system.erofs.img"
    "system_ext.erofs.img"
    "vendor.erofs.img"
    "odm.erofs.img"
    "my_product.erofs.img"
    "runtime_apex.img"
    "art_apex.img"
    "i18n_apex.img"
    "tzdata_apex.img"
)

for out in "${MANDATORY_OUTPUTS[@]}"; do
    if [ ! -f "$STAGING_DIR/$out" ] || [ ! -s "$STAGING_DIR/$out" ]; then
        echo "CRITICAL BUILD ERROR: Expected output image $STAGING_DIR/$out was not generated or is 0 bytes!" >&2
        exit 1
    fi
done

# Generate SHA256 checksums in staging directory
echo "Generating and verifying SHA256SUMS in staging..."
(cd "$STAGING_DIR" && sha256sum *.img *.fstype *.version > SHA256SUMS)
(cd "$STAGING_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || {
    echo "CRITICAL BUILD ERROR: Checksum validation failed in staging!" >&2
    exit 1
}

# 9. Atomic Publishing with Rollback Protection
echo "Atomically publishing newly verified images to $OUT_DIR..."
# Backup existing OUT_DIR if it contains files
if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
    rm -rf "$BACKUP_OUT_DIR" 2>/dev/null || true
    mv "$OUT_DIR" "$BACKUP_OUT_DIR"
fi

mkdir -p "$OUT_DIR"
if ! cp -a "$STAGING_DIR"/* "$OUT_DIR/"; then
    echo "CRITICAL BUILD ERROR: Failed to copy staged files to $OUT_DIR!" >&2
    exit 1
fi

# Verify publication integrity in OUT_DIR
for out in "${MANDATORY_OUTPUTS[@]}"; do
    if [ ! -f "$OUT_DIR/$out" ] || [ ! -s "$OUT_DIR/$out" ]; then
        echo "CRITICAL BUILD ERROR: Published image $OUT_DIR/$out is missing or empty!" >&2
        exit 1
    fi
done

(cd "$OUT_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || {
    echo "CRITICAL BUILD ERROR: Published SHA256 checksum verification failed in $OUT_DIR!" >&2
    exit 1
}

BUILD_SUCCESS=1

echo "=========================================================="
echo "Stage-2 images successfully generated, verified, and published in:"
echo "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS"
