#!/usr/bin/env bash
set -euo pipefail

# build_stage1.sh
# Rebuilds the Stage-1 RAM harness boot image (build/stage1.img)
# Uses the phone's native A16 static init, adbd, toybox, and kernel.
# Strips all fstabs, disables recovery wipe, locks physical disks read-only.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Building Stage-1 RAM Boot Image (Native Plumbed) ==="

STAGE1_DIR="$PROJECT_ROOT/stage1"
NATIVE_RAMDISK="$STAGE1_DIR/native_ramdisk"
BUILD_DIR="$PROJECT_ROOT/build"
OTATOOLS="$PROJECT_ROOT/external/coloros_port/otatools/bin"

mkdir -p "$BUILD_DIR"

if [ ! -d "$NATIVE_RAMDISK" ]; then
    echo "Error: $NATIVE_RAMDISK does not exist!"
    exit 1
fi

echo "1. Packaging Native Stage-1 Ramdisk with mkbootfs..."
"$OTATOOLS/mkbootfs" "$NATIVE_RAMDISK" | lz4 -l -12 --favor-decSpeed > "$STAGE1_DIR/stage1_native_ramdisk.cpio.lz4"

echo "2. Assembling Android Boot Image with mkbootimg..."
"$OTATOOLS/mkbootimg" \
    --kernel "$STAGE1_DIR/kernel_src/kernel" \
    --ramdisk "$STAGE1_DIR/stage1_native_ramdisk.cpio.lz4" \
    --dtb "$STAGE1_DIR/kernel_src/dtb" \
    --recovery_dtbo "/tmp/unpack_recovery/recovery_dtbo" \
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
