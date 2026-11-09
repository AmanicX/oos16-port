#!/usr/bin/env bash
# ==============================================================================
# build_loader.sh - Rebuilds the First-Stage RAM Loader Boot Image (build/loader.img)
# Uses authentic OnePlus 7T kernel 4.14.357, SM8150 DTB, and recovery DTBO.
# Enforces dynamic block-level read-only locks, active safety watchdog,
# and hands over execution to Stage-2 via /mnt/boot_now trigger.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Building First-Stage RAM Loader Boot Image ==="

STAGE1_DIR="$PROJECT_ROOT/stage1"
LOADER_RAMDISK="$STAGE1_DIR/loader_ramdisk"
KERNEL_SRC="$STAGE1_DIR/kernel_src"
BUILD_DIR="$PROJECT_ROOT/build"
if [ -n "${OTATOOLS:-}" ]; then
    if [ -d "$OTATOOLS/bin" ]; then
        export PATH="$OTATOOLS/bin:$OTATOOLS:$PATH"
    elif [ -d "$OTATOOLS" ]; then
        export PATH="$OTATOOLS:$PATH"
    fi
fi
OTATOOLS="${OTATOOLS:-$PROJECT_ROOT/external/coloros_port/otatools/bin}"

mkdir -p "$BUILD_DIR"

TMP_IMG="$BUILD_DIR/loader.img.tmp.$$"
RAMDISK_ARCHIVE="$STAGE1_DIR/stage1_loader_ramdisk.cpio.lz4"

cleanup() {
    rm -f "$TMP_IMG" 2>/dev/null || true
}
trap cleanup EXIT ERR INT TERM

# 1. Dependency Validation: Host Tools
echo "1. Checking required host build tools..."

MKBOOTFS_BIN=""
if command -v mkbootfs >/dev/null 2>&1; then
    MKBOOTFS_BIN="$(command -v mkbootfs)"
elif [ -x "$OTATOOLS/mkbootfs" ]; then
    MKBOOTFS_BIN="$OTATOOLS/mkbootfs"
else
    echo "ERROR: 'mkbootfs' not found in PATH or external/coloros_port/otatools/bin!" >&2
    echo "Please install android-tools or run: git clone https://github.com/toraidl/coloros_port external/coloros_port" >&2
    echo "See docs/BUILD_DEPENDENCIES.md for setup instructions." >&2
    exit 1
fi

MKBOOTIMG_BIN=""
if command -v mkbootimg >/dev/null 2>&1; then
    MKBOOTIMG_BIN="$(command -v mkbootimg)"
elif [ -x "$OTATOOLS/mkbootimg" ]; then
    MKBOOTIMG_BIN="$OTATOOLS/mkbootimg"
else
    echo "ERROR: 'mkbootimg' not found in PATH or external/coloros_port/otatools/bin!" >&2
    echo "See docs/BUILD_DEPENDENCIES.md for setup instructions." >&2
    exit 1
fi

if ! command -v lz4 >/dev/null 2>&1; then
    echo "ERROR: 'lz4' compression utility is not installed on this host!" >&2
    echo "Please install lz4 (e.g. sudo apt install lz4 or pacman -S lz4)." >&2
    exit 1
fi

echo "  mkbootfs: $MKBOOTFS_BIN"
echo "  mkbootimg: $MKBOOTIMG_BIN"
echo "  lz4: $(command -v lz4)"

# 2. Dependency Validation: Kernel & Hardware Assets
validate_hardware_assets() {
    local k_src="$KERNEL_SRC"
    echo "2. Validating authentic OnePlus 7T hardware kernel assets..."

    local EXP_KERNEL_SHA="c32e3a267b1e44e92f0bdb909358e1c95fa900cb8219076581cdbb4084cc9129"
    local EXP_DTB_SHA="e4faf7c553f88246077343de51487d90517bb534e345ee44893d2e4fb348df3c"
    local EXP_DTBO_SHA="7cfdd1984a7be7edd8ef4e761540cf32e69f1cba6a844afe6ba6780dd12223c1"

    [ -f "$k_src/kernel" ] || { echo "ERROR: Missing $k_src/kernel" >&2; exit 1; }
    [ -f "$k_src/dtb" ] || { echo "ERROR: Missing $k_src/dtb" >&2; exit 1; }
    [ -f "$k_src/recovery_dtbo" ] || { echo "ERROR: Missing $k_src/recovery_dtbo" >&2; exit 1; }

    local act_k_sha
    act_k_sha=$(sha256sum "$k_src/kernel" | awk '{print $1}')
    if [ "$act_k_sha" != "$EXP_KERNEL_SHA" ]; then
        echo "ERROR: Kernel SHA-256 mismatch ($act_k_sha != $EXP_KERNEL_SHA)!" >&2
        exit 1
    fi

    local act_dtb_sha
    act_dtb_sha=$(sha256sum "$k_src/dtb" | awk '{print $1}')
    if [ "$act_dtb_sha" != "$EXP_DTB_SHA" ]; then
        echo "ERROR: DTB SHA-256 mismatch ($act_dtb_sha != $EXP_DTB_SHA)!" >&2
        exit 1
    fi

    local act_dtbo_sha
    act_dtbo_sha=$(sha256sum "$k_src/recovery_dtbo" | awk '{print $1}')
    if [ "$act_dtbo_sha" != "$EXP_DTBO_SHA" ]; then
        echo "ERROR: Recovery DTBO SHA-256 mismatch ($act_dtbo_sha != $EXP_DTBO_SHA)!" >&2
        exit 1
    fi

    # Verify kernel version banner
    if ! strings "$k_src/kernel" | grep -F "4.14.357-perf-gcd3073fb68f1" >/dev/null 2>&1; then
        echo "ERROR: Kernel does not match expected banner 4.14.357-perf-gcd3073fb68f1!" >&2
        exit 1
    fi

    # Verify DTB target platform
    if ! strings "$k_src/dtb" | grep -F "qcom,sm8150" >/dev/null 2>&1; then
        echo "ERROR: DTB is not compatible with Qualcomm SM8150 (Snapdragon 855+)!" >&2
        exit 1
    fi

    # Verify Recovery DTBO display compatibility
    if ! strings "$k_src/recovery_dtbo" | grep -F "samsung_oneplus" >/dev/null 2>&1; then
        echo "ERROR: Recovery DTBO lacks OnePlus Samsung AMOLED panel definitions!" >&2
        exit 1
    fi

    echo "  Hardware assets verified: Kernel 4.14.357-perf-gcd3073fb68f1, SM8150 DTB, Samsung AMOLED DTBO."
}

validate_hardware_assets

if [ ! -d "$LOADER_RAMDISK" ]; then
    echo "ERROR: Loader ramdisk directory $LOADER_RAMDISK does not exist!" >&2
    exit 1
fi

# 3. Embed Host ADB Key if Available
if [ -f "$HOME/.android/adbkey.pub" ]; then
    echo "Embedding host adbkey.pub for authorized root ADB connection..."
    cp "$HOME/.android/adbkey.pub" "$LOADER_RAMDISK/adb_keys"
    chmod 644 "$LOADER_RAMDISK/adb_keys"
fi

# 4. Build Reproducible ARM64 Helper & Embed Scripts into Loader Ramdisk
echo "3. Building reproducible static ARM64 binderfs_init from source..."
if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: 'go' compiler is required to build binderfs_init ARM64 binary!" >&2
    exit 1
fi
(cd "$PROJECT_ROOT/src" && make clean && make arm64 verify install)

echo "4. Embedding Stage-2 bringup and watchdog scripts into loader ramdisk..."
mkdir -p "$LOADER_RAMDISK/system/bin"
cp "$PROJECT_ROOT/scripts/stage2_init.sh" "$LOADER_RAMDISK/system/bin/stage2_init.sh"
chmod 0755 "$LOADER_RAMDISK/system/bin/stage2_init.sh"
cp "$PROJECT_ROOT/scripts/watchdog.sh" "$LOADER_RAMDISK/system/bin/watchdog.sh"
chmod 0755 "$LOADER_RAMDISK/system/bin/watchdog.sh"

# Verify embedded binary presence, executability, and byte-equality with source build
if [ ! -x "$LOADER_RAMDISK/system/bin/binderfs_init" ]; then
    echo "ERROR: $LOADER_RAMDISK/system/bin/binderfs_init is missing or not executable!" >&2
    exit 1
fi
cmp -s "$PROJECT_ROOT/src/binderfs_init_arm64" "$LOADER_RAMDISK/system/bin/binderfs_init" || {
    echo "ERROR: Embedded binderfs_init does not match freshly built source binary!" >&2
    exit 1
}

# 5. Packaging Loader Ramdisk
echo "5. Packaging Loader Ramdisk with mkbootfs..."
"$MKBOOTFS_BIN" "$LOADER_RAMDISK" | lz4 -l -12 --favor-decSpeed > "$RAMDISK_ARCHIVE"

# 6. Assembling Loader Boot Image with mkbootimg (Atomic Publication)
echo "6. Assembling Loader Boot Image with mkbootimg..."
"$MKBOOTIMG_BIN" \
    --kernel "$KERNEL_SRC/kernel" \
    --ramdisk "$RAMDISK_ARCHIVE" \
    --dtb "$KERNEL_SRC/dtb" \
    --recovery_dtbo "$KERNEL_SRC/recovery_dtbo" \
    --cmdline "androidboot.hardware=qcom androidboot.memcg=1 androidboot.usbcontroller=a600000.dwc3 kpti=off loop.max_part=7 lpm_levels.sleep_disabled=1 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=2048 androidboot.selinux=permissive enforcing=0 panic=5 androidboot.mode=normal" \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --dtb_offset 0x01f00000 \
    --os_version 16.0.0 \
    --os_patch_level 2026-07 \
    --header_version 2 \
    --pagesize 4096 \
    -o "$TMP_IMG"

# Verify generated image before publishing
if [ ! -s "$TMP_IMG" ]; then
    echo "ERROR: mkbootimg generated an empty or missing image file!" >&2
    exit 1
fi

mv -f "$TMP_IMG" "$BUILD_DIR/loader.img"

# 7. Run Pre-Boot Static Security Audit
echo "7. Running Pre-Boot Static Security Audit..."
"$PROJECT_ROOT/tools/safe/audit-no-writes.sh" "$BUILD_DIR/loader.img"

SHA=$(sha256sum "$BUILD_DIR/loader.img" | awk '{print $1}')
echo "=== First-Stage RAM Loader Build Complete ==="
echo "Output: $BUILD_DIR/loader.img"
echo "SHA-256: $SHA"
