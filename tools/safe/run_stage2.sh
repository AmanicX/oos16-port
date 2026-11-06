#!/usr/bin/env bash
set -euo pipefail

# run_stage2.sh
# Host-side orchestrator for Stage-2 RAM-resident OxygenOS 16 bringup.
# Verifies zero physical writes, pushes EROFS images to phone RAM (/tmp/),
# and executes the Stage-2 RAM transition.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SAFE_ADB="$PROJECT_ROOT/tools/safe/adb"
IMAGES_DIR="$PROJECT_ROOT/build/images"
STAGE2_SCRIPT="$PROJECT_ROOT/scripts/stage2_init.sh"

echo "=========================================================="
echo "      STAGE-2 RAM RESIDENT BOOT ORCHESTRATOR             "
echo "      OxygenOS 16 on OnePlus 7T (HD1901)                 "
echo "=========================================================="

# 1. Verify phone connection
echo "1. Checking phone ADB connection in RAM..."
if ! "$SAFE_ADB" get-state 2>/dev/null | grep -q "device"; then
    echo "Error: Phone is not connected in Stage-1 ADB mode."
    echo "Please boot Stage-1 first using: tools/safe/fastboot boot build/stage1.img"
    exit 1
fi
echo "Phone connected successfully."

# 2. Immediately disarm safety watchdog
echo "2. Disarming Stage-1 90s safety watchdog..."
"$SAFE_ADB" shell touch /tmp/watchdog_cancel
echo "Watchdog disarmed."

# 3. Verify block layer read-only status on all physical disks
echo "3. Verifying block-layer read-only status on physical storage..."
LUNS=$("$SAFE_ADB" shell "/system/bin/toybox blockdev --getro /dev/block/sd[a-f]")
for ro_val in $LUNS; do
    if [ "$ro_val" != "1" ]; then
        echo "CRITICAL SAFETY VIOLATION: A physical block device is not read-only ($ro_val)!"
        echo "Aborting immediately to protect physical storage."
        exit 1
    fi
done
echo "Verified: All physical UFS block devices (sda-sdf) are read-only (100% write-locked)."

# 4. Check available RAM on phone
echo "4. Checking phone free RAM headroom..."
"$SAFE_ADB" shell "/system/bin/toybox free -m"

# 5. Push EROFS images to RAM tmpfs (/tmp/)
echo "5. Pushing optimized EROFS partition images to phone RAM..."
IMAGES=("odm.erofs.img:odm.img" "vendor.erofs.img:vendor.img" "my_region.erofs.img:my_region.img" "system.erofs.img:system.img" "system_ext.erofs.img:system_ext.img" "my_product.erofs.img:my_product.img")

for pair in "${IMAGES[@]}"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"
    SRC_PATH="$IMAGES_DIR/$SRC"
    if [ ! -f "$SRC_PATH" ]; then
        echo "Error: Missing required image: $SRC_PATH"
        exit 1
    fi
    SIZE=$(ls -lh "$SRC_PATH" | awk '{print $5}')
    echo " -> Pushing $SRC ($SIZE) to /tmp/$DST..."
    "$SAFE_ADB" push "$SRC_PATH" "/tmp/$DST"
done

# 6. Push Stage-2 init script
echo "6. Pushing Stage-2 init transition script..."
"$SAFE_ADB" push "$STAGE2_SCRIPT" "/tmp/stage2_init.sh"
"$SAFE_ADB" shell chmod +x /tmp/stage2_init.sh

# 7. Execute Stage-2 Bringup
echo "7. Executing Stage-2 Android Init Transition in RAM..."
echo "Starting Stage-2..."
"$SAFE_ADB" shell /tmp/stage2_init.sh
