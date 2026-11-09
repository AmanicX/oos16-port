#!/usr/bin/env bash
# ==============================================================================
# build_stage2_erofs.sh - Build and Repack EROFS Partitions for Stage-2 RAM Boot
# OxygenOS 16 (Android 16 / SDK 36 / Baklava) on OnePlus 7T (HD1901 / hotdogb)
#
# Provenance:
# - Donor ROM: OnePlus 9 (lemonade / LE2113) OxygenOS 16 (ota_full-LE2113_16.0.10.500.zip)
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

# Prioritize user-provided OTATOOLS if configured in environment
export PATH="$PROJECT_ROOT/external/coloros_port/otatools/bin:$HOME/.local/bin:$PATH"
if [ -n "${OTATOOLS:-}" ]; then
    if [ -d "$OTATOOLS/bin" ]; then
        export PATH="$OTATOOLS/bin:$OTATOOLS:$PATH"
    elif [ -d "$OTATOOLS" ]; then
        export PATH="$OTATOOLS:$PATH"
    fi
fi

WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/work}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/build/images}"

BUILD_PARENT="$(dirname "$OUT_DIR")"
mkdir -p "$BUILD_PARENT"
STAGING_DIR="$BUILD_PARENT/.staging_erofs_$$"
BACKUP_OUT_DIR="$BUILD_PARENT/.backup_images_$$"
BUILD_WORK_DIR="$BUILD_PARENT/.staging_work_$$"
TMP_BUILD_DIR="$(mktemp -d /tmp/erofs_build.XXXXXX)"

BUILD_SUCCESS=0

cleanup() {
    local exit_code=$?
    if [ "$BUILD_SUCCESS" -ne 1 ]; then
        echo "Build did not complete successfully. Reverting modifications and cleaning up..." >&2
        # Rollback output directory if backup exists
        if [ -d "$BACKUP_OUT_DIR" ]; then
            echo "Rolling back to previous valid build output..." >&2
            rm -rf "$OUT_DIR" 2>/dev/null || true
            mv "$BACKUP_OUT_DIR" "$OUT_DIR" 2>/dev/null || true
        fi
    else
        # On success, clean up backups
        rm -rf "$BACKUP_OUT_DIR" 2>/dev/null || true
    fi

    rm -rf "$STAGING_DIR" "$TMP_BUILD_DIR" "$BUILD_WORK_DIR" 2>/dev/null || true
    exit "$exit_code"
}
trap cleanup EXIT ERR INT TERM

mkdir -p "$STAGING_DIR" "$BUILD_WORK_DIR"

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

"$MKFS_EROFS" --help >/dev/null 2>&1 || { echo "ERROR: mkfs.erofs failed verification test" >&2; exit 1; }
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

APEX_DIR=""
if [ -d "$WORK_DIR/system/system/apex" ]; then
    APEX_DIR="$WORK_DIR/system/system/apex"
elif [ -d "$WORK_DIR/system/apex" ]; then
    APEX_DIR="$WORK_DIR/system/apex"
elif [ -d "$WORK_DIR/apex" ]; then
    APEX_DIR="$WORK_DIR/apex"
fi

if [ -z "$APEX_DIR" ]; then
    MISSING_MANDATORY+=("apex_dir ($WORK_DIR/system/system/apex or $WORK_DIR/system/apex)")
else
    FOUND_RUNTIME=""
    for cand in "$APEX_DIR/com.android.runtime.apex" "$APEX_DIR/com.google.android.runtime.apex"; do
        if [ -f "$cand" ] && [ -s "$cand" ]; then FOUND_RUNTIME="$cand"; break; fi
    done
    if [ -z "$FOUND_RUNTIME" ]; then
        MISSING_MANDATORY+=("runtime_apex ($APEX_DIR/com.android.runtime.apex)")
    fi
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

# 2. Stage Partition Trees into Isolated Disposable Workspace
echo "Staging partition trees into isolated disposable workspace: $BUILD_WORK_DIR..."
ALL_PARTITIONS=("system" "system_ext" "vendor" "odm" "my_product" "my_region")
for part_name in "${ALL_PARTITIONS[@]}"; do
    if [ -d "$WORK_DIR/$part_name" ]; then
        mkdir -p "$BUILD_WORK_DIR/$part_name"
        if cp -al "$WORK_DIR/$part_name/." "$BUILD_WORK_DIR/$part_name/" 2>/dev/null; then
            echo "  Staged $part_name via hardlinks."
        else
            cp -a "$WORK_DIR/$part_name/." "$BUILD_WORK_DIR/$part_name/"
            echo "  Staged $part_name via copy."
        fi
    fi
done

# Resolve APEX directory in staged workspace or source
if [ -d "$BUILD_WORK_DIR/system/system/apex" ]; then
    APEX_DIR="$BUILD_WORK_DIR/system/system/apex"
elif [ -d "$BUILD_WORK_DIR/system/apex" ]; then
    APEX_DIR="$BUILD_WORK_DIR/system/apex"
fi

# 3. Apply Feature Injections in Isolated Workspace
echo "[1/6] Injecting Google Photos Unlimited Backup and PIF..."
CONFIGS_DIR="$PROJECT_ROOT/configs"

inject_file() {
    local src_file="$1"
    local dest_file="$2"
    rm -f "$dest_file" 2>/dev/null || true
    cp "$src_file" "$dest_file"
}

if [ -f "$CONFIGS_DIR/pixel_2016_experience.xml" ]; then
    for target in "$BUILD_WORK_DIR/my_product/etc/permissions" "$BUILD_WORK_DIR/system/system/etc/permissions" "$BUILD_WORK_DIR/system_ext/etc/permissions"; do
        if [ -d "$target" ]; then
            inject_file "$CONFIGS_DIR/pixel_2016_experience.xml" "$target/pixel_2016_experience.xml"
        fi
    done
fi

if [ -f "$CONFIGS_DIR/pif.json" ]; then
    for target in "$BUILD_WORK_DIR/my_product/etc" "$BUILD_WORK_DIR/system/system/etc" "$BUILD_WORK_DIR/system_ext/etc"; do
        if [ -d "$target" ]; then
            inject_file "$CONFIGS_DIR/pif.json" "$target/pif.json"
        fi
    done
fi

# 4. Targeted Permission Corrections
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
                local tmp_f="${file}.mode_tmp_$$"
                cp -a "$file" "$tmp_f"
                mv -f "$tmp_f" "$file"
                chmod +x "$file"
                echo "    Added +x to ELF executable: $(basename "$file")"
            fi
        elif head -c 2 "$file" 2>/dev/null | grep -q '^#!'; then
            if [ ! -x "$file" ]; then
                local tmp_f="${file}.mode_tmp_$$"
                cp -a "$file" "$tmp_f"
                mv -f "$tmp_f" "$file"
                chmod +x "$file"
                echo "    Added +x to shell script: $(basename "$file")"
            fi
        fi
    done
}

fix_executable_permissions "$BUILD_WORK_DIR/vendor/vendor/bin"
fix_executable_permissions "$BUILD_WORK_DIR/odm/bin"

# 5. Configure Display Properties for 60Hz Replacement AMOLED Panel
echo "[3/6] Setting fixed 60Hz display properties in vendor build.prop..."
VENDOR_PROP="$BUILD_WORK_DIR/vendor/vendor/build.prop"
if [ -f "$VENDOR_PROP" ]; then
    tmp_prop="${VENDOR_PROP}.tmp_$$"
    cp "$VENDOR_PROP" "$tmp_prop"
    mv -f "$tmp_prop" "$VENDOR_PROP"
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

# 6. Resolve SELinux Property Context Prefix Conflicts
echo "[4/6] Verifying SELinux system_ext_property_contexts..."
PROP_CTX="$BUILD_WORK_DIR/system_ext/etc/selinux/system_ext_property_contexts"
if [ -f "$PROP_CTX" ]; then
    tmp_ctx="${PROP_CTX}.tmp_$$"
    cp "$PROP_CTX" "$tmp_ctx"
    mv -f "$tmp_ctx" "$PROP_CTX"
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

# 7. Build and Strictly Validate EROFS Partition Images into Temporary Staging
echo "[5/6] Building high-compression EROFS partition images in clean staging area..."
PARTITIONS=(
    "odm:$BUILD_WORK_DIR/odm:1"
    "vendor:$BUILD_WORK_DIR/vendor:1"
    "my_region:$BUILD_WORK_DIR/my_region:0"
    "system:$BUILD_WORK_DIR/system:1"
    "system_ext:$BUILD_WORK_DIR/system_ext:1"
    "my_product:$BUILD_WORK_DIR/my_product:1"
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
    local apex_dir="${APEX_DIR:-$BUILD_WORK_DIR/system/system/apex}"
    if [ ! -d "$apex_dir" ] && [ -d "$BUILD_WORK_DIR/system/apex" ]; then
        apex_dir="$BUILD_WORK_DIR/system/apex"
    elif [ ! -d "$apex_dir" ] && [ -d "$WORK_DIR/system/system/apex" ]; then
        apex_dir="$WORK_DIR/system/system/apex"
    elif [ ! -d "$apex_dir" ] && [ -d "$WORK_DIR/system/apex" ]; then
        apex_dir="$WORK_DIR/system/apex"
    elif [ ! -d "$apex_dir" ] && [ -d "$WORK_DIR/apex" ]; then
        apex_dir="$WORK_DIR/apex"
    fi
    local target_pkg=""
    local expected_pkgs=""

    case "$apex_id" in
        runtime)
            expected_pkgs="com.android.runtime,com.google.android.runtime"
            for cand in "$apex_dir/com.android.runtime.apex" "$apex_dir/com.google.android.runtime.apex"; do
                if [ -f "$cand" ]; then target_pkg="$cand"; break; fi
            done
            ;;
        art)
            expected_pkgs="com.android.art,com.google.android.art"
            for cand in "$apex_dir/com.google.android.art_compressed.apex" \
                        "$apex_dir/com.android.art_compressed.apex" \
                        "$apex_dir/com.android.art.apex" \
                        "$apex_dir/com.google.android.art.apex"; do
                if [ -f "$cand" ]; then target_pkg="$cand"; break; fi
            done
            ;;
        i18n)
            expected_pkgs="com.android.i18n,com.google.android.i18n"
            for cand in "$apex_dir/com.android.i18n.apex" \
                        "$apex_dir/com.google.android.i18n.apex" \
                        "$apex_dir/com.google.android.i18n_compressed.apex"; do
                if [ -f "$cand" ]; then target_pkg="$cand"; break; fi
            done
            ;;
        tzdata)
            expected_pkgs="com.android.tzdata,com.google.android.tzdata,com.google.android.tzdata6"
            for cand in "$apex_dir/com.google.android.tzdata6.apex" \
                        "$apex_dir/com.google.android.tzdata.apex" \
                        "$apex_dir/com.android.tzdata.apex"; do
                if [ -f "$cand" ]; then target_pkg="$cand"; break; fi
            done
            ;;
        *)
            expected_pkgs="com.android.${apex_id}"
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
    echo " -> Extracting and validating manifest metadata via tools/extract_apex_info.py..."
    local pkg_name
    if ! pkg_name=$(python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$target_pkg" --name-only); then
        echo "CRITICAL BUILD ERROR: APEX package name extraction failed for $target_pkg!" >&2
        exit 1
    fi
    pkg_name=$(echo "$pkg_name" | tr -d '[:space:]')

    local pkg_version
    if ! pkg_version=$(python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$target_pkg" --expect-package "$expected_pkgs" --version-only); then
        echo "CRITICAL BUILD ERROR: APEX manifest extraction failed for $target_pkg ($expected_pkgs)!" >&2
        exit 1
    fi

    pkg_version=$(echo "$pkg_version" | tr -d '[:space:]')
    if [ -z "$pkg_version" ] || ! echo "$pkg_version" | grep -qE '^[1-9][0-9]*$'; then
        echo "CRITICAL BUILD ERROR: APEX version code for $target_pkg is invalid or non-numeric: '$pkg_version'!" >&2
        exit 1
    fi

    # Output authentic extended metadata files
    python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$target_pkg" --output-version-name "$STAGING_DIR/${output_base}.version_name"
    python3 "$PROJECT_ROOT/tools/extract_apex_info.py" --apex "$target_pkg" --output-shared-libs "$STAGING_DIR/${output_base}.provide_shared_libs"
    echo "$pkg_name" > "$STAGING_DIR/${output_base}.package"
    echo "/system/apex/$(basename "$target_pkg")" > "$STAGING_DIR/${output_base}.preinstalled_path"
    echo "SYSTEM" > "$STAGING_DIR/${output_base}.partition"

    # Measure expanded payload uncompressed size for accurate RAM budgeting
    local exp_size=0
    local exp_dir="$unpack_dir/expanded_measure"
    mkdir -p "$exp_dir"
    if [ "$fstype" = "erofs" ]; then
        if ! "$FSCK_EROFS" --extract="$exp_dir" "$payload" >/dev/null 2>&1; then
            echo "CRITICAL BUILD ERROR: fsck.erofs --extract failed on $output_base payload ($payload)!" >&2
            exit 1
        fi
    elif [ "$fstype" = "ext4" ]; then
        if ! command -v 7z >/dev/null 2>&1; then
            echo "CRITICAL BUILD ERROR: '7z' utility required to extract and measure ext4 APEX payload ($payload)!" >&2
            exit 1
        fi
        if ! 7z x -o"$exp_dir" "$payload" >/dev/null 2>&1; then
            echo "CRITICAL BUILD ERROR: 7z extraction failed on $output_base payload ($payload)!" >&2
            exit 1
        fi
    fi

    # Verify extraction directory is non-empty
    if [ -z "$(ls -A "$exp_dir" 2>/dev/null)" ]; then
        echo "CRITICAL BUILD ERROR: Extraction directory for $output_base payload is empty!" >&2
        exit 1
    fi

    exp_size=$(du -sb "$exp_dir" 2>/dev/null | awk '{print $1}' || echo "0")
    rm -rf "$exp_dir"

    # Validate authentic uncompressed measurement (strictly positive numeric, no fallback guessing)
    exp_size=$(echo "$exp_size" | tr -d '[:space:]')
    if [ -z "$exp_size" ] || ! echo "$exp_size" | grep -qE '^[1-9][0-9]*$'; then
        echo "CRITICAL BUILD ERROR: Failed to obtain valid positive byte count for $output_base payload: '$exp_size'!" >&2
        exit 1
    fi
    if [ "$exp_size" -le 0 ]; then
        echo "CRITICAL BUILD ERROR: Measured expanded size for $output_base is non-positive ($exp_size bytes)!" >&2
        exit 1
    fi

    cp "$payload" "$STAGING_DIR/${output_base}.img"
    echo "$fstype" > "$STAGING_DIR/${output_base}.fstype"
    echo "$pkg_version" > "$STAGING_DIR/${output_base}.version"
    echo "$exp_size" > "$STAGING_DIR/${output_base}.expanded_size"
    echo "    Staged ${output_base}.img, ${output_base}.fstype ($fstype), ${output_base}.version ($pkg_version), and expanded_size ($exp_size bytes)."
}

extract_and_stage_apex "runtime" "runtime_apex" 1
extract_and_stage_apex "art" "art_apex" 1
extract_and_stage_apex "i18n" "i18n_apex" 1
extract_and_stage_apex "tzdata" "tzdata_apex" 1

# Generate authoritative partition-to-mountpoint mapping manifest dynamically
echo "Generating authoritative partition-to-mountpoint mapping manifest (PARTITION_MAP)..."
cat > "$STAGING_DIR/PARTITION_MAP" << 'EOF'
# OxygenOS 16 / ColorOS Authoritative Partition Map Manifest
# Format: image_filename:target_mountpoint:nature:sha256
EOF

for part_def in "${PARTITIONS[@]}"; do
    NAME=$(echo "$part_def" | cut -d: -f1)
    MANDATORY=$(echo "$part_def" | cut -d: -f3)
    STAGE_IMG="$STAGING_DIR/$NAME.erofs.img"
    [ -f "$STAGE_IMG" ] || continue

    target_mp=""
    nature="mandatory"
    [ "$MANDATORY" -eq 0 ] && nature="optional"

    case "$NAME" in
        system) target_mp="/mnt/sysroot" ;;
        system_ext) target_mp="/mnt/sysroot/system_ext" ;;
        vendor) target_mp="/mnt/sysroot/vendor" ;;
        odm) target_mp="/mnt/sysroot/odm" ;;
        product) target_mp="/mnt/sysroot/product" ;;
        my_product) target_mp="/mnt/sysroot/my_product" ;;
        my_region) target_mp="/mnt/sysroot/my_region" ;;
        *)
            echo "CRITICAL BUILD ERROR: Unknown partition $NAME has no mapped mountpoint!" >&2
            exit 1
            ;;
    esac

    img_sha=$(sha256sum "$STAGE_IMG" | awk '{print $1}')
    echo "$NAME.erofs.img:$target_mp:$nature:$img_sha" >> "$STAGING_DIR/PARTITION_MAP"
done

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
    "runtime_apex.version"
    "runtime_apex.version_name"
    "runtime_apex.package"
    "runtime_apex.preinstalled_path"
    "runtime_apex.provide_shared_libs"
    "runtime_apex.partition"
    "runtime_apex.expanded_size"
    "art_apex.version"
    "art_apex.version_name"
    "art_apex.package"
    "art_apex.preinstalled_path"
    "art_apex.provide_shared_libs"
    "art_apex.partition"
    "art_apex.expanded_size"
    "i18n_apex.version"
    "i18n_apex.version_name"
    "i18n_apex.package"
    "i18n_apex.preinstalled_path"
    "i18n_apex.provide_shared_libs"
    "i18n_apex.partition"
    "i18n_apex.expanded_size"
    "tzdata_apex.version"
    "tzdata_apex.version_name"
    "tzdata_apex.package"
    "tzdata_apex.preinstalled_path"
    "tzdata_apex.provide_shared_libs"
    "tzdata_apex.partition"
    "tzdata_apex.expanded_size"
    "PARTITION_MAP"
)

for out in "${MANDATORY_OUTPUTS[@]}"; do
    if [ ! -f "$STAGING_DIR/$out" ] || [ ! -s "$STAGING_DIR/$out" ]; then
        echo "CRITICAL BUILD ERROR: Expected output image $STAGING_DIR/$out was not generated or is 0 bytes!" >&2
        exit 1
    fi
done

# Generate SHA256 checksums in staging directory
echo "Generating and verifying SHA256SUMS in staging..."
(cd "$STAGING_DIR" && sha256sum *.img *.fstype *.version *.version_name *.package *.preinstalled_path *.provide_shared_libs *.partition *.expanded_size PARTITION_MAP > SHA256SUMS)
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
