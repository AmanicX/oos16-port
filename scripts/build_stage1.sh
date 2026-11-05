#!/usr/bin/env bash
set -euo pipefail

# build_stage1.sh
# Rebuilds the minimal Stage-1 RAM harness boot image (build/stage1.img)
# Uses the stock A16 kernel from partitions/boot_b.img and minimal tools from recovery_b.img.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Building Stage-1 RAM Boot Image ==="

STAGE1_DIR="$PROJECT_ROOT/stage1"
RAMDISK_ROOT="$STAGE1_DIR/ramdisk_root"
BUILD_DIR="$PROJECT_ROOT/build"
OTATOOLS="$PROJECT_ROOT/external/coloros_port/otatools/bin"

mkdir -p "$BUILD_DIR"

if [ ! -d "$RAMDISK_ROOT" ]; then
    echo "Error: $RAMDISK_ROOT does not exist!"
    exit 1
fi

echo "1. Packaging Stage-1 Initramfs with mkbootfs..."
"$OTATOOLS/mkbootfs" "$RAMDISK_ROOT" | lz4 -l -12 --favor-decSpeed > "$STAGE1_DIR/stage1_ramdisk.cpio.lz4"

echo "2. Assembling Android Boot Image with mkbootimg..."
"$OTATOOLS/mkbootimg" \
    --kernel "$STAGE1_DIR/kernel_src/kernel" \
    --ramdisk "$STAGE1_DIR/stage1_ramdisk.cpio.lz4" \
    --dtb "$STAGE1_DIR/kernel_src/dtb" \
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

echo "3. Running Pre-Boot Static Security Audit..."
"$PROJECT_ROOT/tools/safe/audit-no-writes.sh" "$BUILD_DIR/stage1.img"

SHA=$(sha256sum "$BUILD_DIR/stage1.img" | awk '{print $1}')
echo "=== Stage-1 Build Complete ==="
echo "Output: $BUILD_DIR/stage1.img"
echo "SHA-256: $SHA"
