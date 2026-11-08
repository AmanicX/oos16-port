#!/usr/bin/env bash
# ==============================================================================
# build_stage1.sh - Rebuilds the Stage-1 RAM Recovery Boot Image (build/stage1.img)
# Uses native A16 static init, root adbd, and 4.14.357 kernel for OnePlus 7T.
# Detects all dependencies before building and stops early with helpful advice.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Building Stage-1 RAM Boot Image (Native Plumbed) ==="

STAGE1_DIR="$PROJECT_ROOT/stage1"
NATIVE_RAMDISK="$STAGE1_DIR/native_ramdisk"
KERNEL_SRC="$STAGE1_DIR/kernel_src"
BUILD_DIR="$PROJECT_ROOT/build"
OTATOOLS="$PROJECT_ROOT/external/coloros_port/otatools/bin"

mkdir -p "$BUILD_DIR"

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
echo "2. Checking and strictly validating required hardware kernel assets..."
MISSING_ASSETS=()

if [ ! -f "$KERNEL_SRC/kernel" ]; then
    MISSING_ASSETS+=("$KERNEL_SRC/kernel")
fi
if [ ! -f "$KERNEL_SRC/dtb" ]; then
    MISSING_ASSETS+=("$KERNEL_SRC/dtb")
fi
if [ ! -f "$KERNEL_SRC/recovery_dtbo" ]; then
    MISSING_ASSETS+=("$KERNEL_SRC/recovery_dtbo")
fi

if [ "${#MISSING_ASSETS[@]}" -gt 0 ]; then
    echo "ERROR: The following hardware kernel assets are missing:" >&2
    for asset in "${MISSING_ASSETS[@]}"; do
        echo "  - $asset" >&2
    done
    echo "" >&2
    echo "How to acquire missing assets:" >&2
    echo "1. Download official LineageOS 23.2 recovery for OnePlus 7T (hotdogb):" >&2
    echo "   https://download.lineageos.org/devices/hotdogb" >&2
    echo "2. Unpack the recovery image into $KERNEL_SRC:" >&2
    echo "   mkdir -p '$KERNEL_SRC'" >&2
    echo "   unpack_bootimg --boot_img lineage-23.2-recovery-hotdogb.img --out '$KERNEL_SRC'" >&2
    echo "3. Rename dtbo to recovery_dtbo if required." >&2
    echo "See docs/BUILD_DEPENDENCIES.md for complete details and checksums." >&2
    exit 1
fi

EXP_KERNEL_SHA="c32e3a267b1e44e92f0bdb909358e1c95fa900cb8219076581cdbb4084cc9129"
EXP_DTB_SHA="e4faf7c553f88246077343de51487d90517bb534e345ee44893d2e4fb348df3c"
EXP_DTBO_SHA="7cfdd1984a7be7edd8ef4e761540cf32e69f1cba6a844afe6ba6780dd12223c1"

act_k_sha=$(sha256sum "$KERNEL_SRC/kernel" | awk '{print $1}')
if [ "$act_k_sha" != "$EXP_KERNEL_SHA" ]; then
    echo "ERROR: Kernel SHA-256 mismatch ($act_k_sha != $EXP_KERNEL_SHA)!" >&2
    exit 1
fi

act_dtb_sha=$(sha256sum "$KERNEL_SRC/dtb" | awk '{print $1}')
if [ "$act_dtb_sha" != "$EXP_DTB_SHA" ]; then
    echo "ERROR: DTB SHA-256 mismatch ($act_dtb_sha != $EXP_DTB_SHA)!" >&2
    exit 1
fi

act_dtbo_sha=$(sha256sum "$KERNEL_SRC/recovery_dtbo" | awk '{print $1}')
if [ "$act_dtbo_sha" != "$EXP_DTBO_SHA" ]; then
    echo "ERROR: Recovery DTBO SHA-256 mismatch ($act_dtbo_sha != $EXP_DTBO_SHA)!" >&2
    exit 1
fi

if ! strings "$KERNEL_SRC/kernel" | grep -F "4.14.357-perf-gcd3073fb68f1" >/dev/null 2>&1; then
    echo "ERROR: Kernel does not match expected banner 4.14.357-perf-gcd3073fb68f1!" >&2
    exit 1
fi

if ! strings "$KERNEL_SRC/dtb" | grep -F "qcom,sm8150" >/dev/null 2>&1; then
    echo "ERROR: DTB is not compatible with Qualcomm SM8150 (Snapdragon 855+)!" >&2
    exit 1
fi

if ! strings "$KERNEL_SRC/recovery_dtbo" | grep -F "samsung_oneplus" >/dev/null 2>&1; then
    echo "ERROR: Recovery DTBO lacks OnePlus Samsung AMOLED panel definitions!" >&2
    exit 1
fi

echo "  Hardware assets verified: Kernel 4.14.357-perf-gcd3073fb68f1, SM8150 DTB, Samsung AMOLED DTBO."

if [ ! -d "$NATIVE_RAMDISK" ]; then
    echo "ERROR: Native ramdisk directory $NATIVE_RAMDISK does not exist!" >&2
    exit 1
fi

# 3. Embed Host ADB Key if Available
if [ -f "$HOME/.android/adbkey.pub" ]; then
    echo "Embedding host adbkey.pub for authorized root ADB connection..."
    cp "$HOME/.android/adbkey.pub" "$NATIVE_RAMDISK/adb_keys"
    chmod 644 "$NATIVE_RAMDISK/adb_keys"
fi

# 4. Build Reproducible ARM64 Helper & Embed Scripts into Native Ramdisk
echo "4. Building reproducible static ARM64 binderfs_init from source..."
if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: 'go' compiler is required to build binderfs_init ARM64 binary!" >&2
    exit 1
fi
(cd "$PROJECT_ROOT/src" && make clean && make arm64 verify install)

echo "Embedding Stage-2 bringup and watchdog scripts into native ramdisk..."
mkdir -p "$NATIVE_RAMDISK/system/bin"
cp "$PROJECT_ROOT/scripts/stage2_init.sh" "$NATIVE_RAMDISK/system/bin/stage2_init.sh"
chmod 0755 "$NATIVE_RAMDISK/system/bin/stage2_init.sh"
cp "$PROJECT_ROOT/scripts/watchdog.sh" "$NATIVE_RAMDISK/system/bin/watchdog.sh"
chmod 0755 "$NATIVE_RAMDISK/system/bin/watchdog.sh"

# Verify embedded binary presence, executability, and byte-equality with source build
if [ ! -x "$NATIVE_RAMDISK/system/bin/binderfs_init" ]; then
    echo "ERROR: $NATIVE_RAMDISK/system/bin/binderfs_init is missing or not executable!" >&2
    exit 1
fi
cmp -s "$PROJECT_ROOT/src/binderfs_init_arm64" "$NATIVE_RAMDISK/system/bin/binderfs_init" || {
    echo "ERROR: Embedded binderfs_init does not match freshly built source binary!" >&2
    exit 1
}

# 5. Packaging Native Stage-1 Ramdisk
echo "3. Packaging Native Stage-1 Ramdisk with mkbootfs..."
RAMDISK_ARCHIVE="$STAGE1_DIR/stage1_native_ramdisk.cpio.lz4"
"$MKBOOTFS_BIN" "$NATIVE_RAMDISK" | lz4 -l -12 --favor-decSpeed > "$RAMDISK_ARCHIVE"

# 5. Assembling Android Boot Image with mkbootimg
echo "4. Assembling Android Boot Image with mkbootimg..."
"$MKBOOTIMG_BIN" \
    --kernel "$KERNEL_SRC/kernel" \
    --ramdisk "$RAMDISK_ARCHIVE" \
    --dtb "$KERNEL_SRC/dtb" \
    --recovery_dtbo "$KERNEL_SRC/recovery_dtbo" \
    --cmdline "androidboot.hardware=qcom androidboot.memcg=1 androidboot.usbcontroller=a600000.dwc3 kpti=off loop.max_part=7 lpm_levels.sleep_disabled=1 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=2048 androidboot.selinux=permissive enforcing=0 panic=5" \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --dtb_offset 0x01f00000 \
    --os_version 16.0.0 \
    --os_patch_level 2026-07 \
    --header_version 2 \
    --pagesize 4096 \
    -o "$BUILD_DIR/stage1.img"

# 6. Run Pre-Boot Static Security Audit
echo "5. Running Pre-Boot Static Security Audit..."
"$PROJECT_ROOT/tools/safe/audit-no-writes.sh" "$BUILD_DIR/stage1.img"

SHA=$(sha256sum "$BUILD_DIR/stage1.img" | awk '{print $1}')
echo "=== Stage-1 Build Complete ==="
echo "Output: $BUILD_DIR/stage1.img"
echo "SHA-256: $SHA"
