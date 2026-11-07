#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Building First-Stage RAM Loader Boot Image ==="

STAGE1_DIR="$PROJECT_ROOT/stage1"
LOADER_RAMDISK="$STAGE1_DIR/loader_ramdisk"
BUILD_DIR="$PROJECT_ROOT/build"
OTATOOLS="$PROJECT_ROOT/external/coloros_port/otatools/bin"

mkdir -p "$BUILD_DIR"

if [ ! -d "$LOADER_RAMDISK" ]; then
    echo "Error: $LOADER_RAMDISK does not exist!"
    exit 1
fi

echo "1. Building reproducible static ARM64 binderfs_init from source..."
if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: 'go' compiler is required to build binderfs_init ARM64 binary!" >&2
    exit 1
fi
(cd "$PROJECT_ROOT/src" && make clean && make arm64 verify install)

echo "2. Embedding Stage-2 bringup and watchdog scripts into loader ramdisk..."
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

echo "3. Packaging Loader Ramdisk with mkbootfs..."
"$OTATOOLS/mkbootfs" "$LOADER_RAMDISK" | lz4 -l -12 --favor-decSpeed > "$STAGE1_DIR/stage1_loader_ramdisk.cpio.lz4"

echo "3. Assembling Loader Boot Image with mkbootimg..."
"$OTATOOLS/mkbootimg" \
    --kernel "$STAGE1_DIR/kernel_src/kernel" \
    --ramdisk "$STAGE1_DIR/stage1_loader_ramdisk.cpio.lz4" \
    --dtb "$STAGE1_DIR/kernel_src/dtb" \
    --recovery_dtbo "$STAGE1_DIR/kernel_src/recovery_dtbo" \
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
    -o "$BUILD_DIR/loader.img"

echo "3. Running Pre-Boot Static Security Audit..."
"$PROJECT_ROOT/tools/safe/audit-no-writes.sh" "$BUILD_DIR/loader.img"

SHA=$(sha256sum "$BUILD_DIR/loader.img" | awk '{print $1}')
echo "=== First-Stage RAM Loader Build Complete ==="
echo "Output: $BUILD_DIR/loader.img"
echo "SHA-256: $SHA"
