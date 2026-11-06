#!/system/bin/sh
# Stage-2 Android 16 Bringup in RAM on OnePlus 7T (HD1901)
# 100% RAM resident, 0 physical storage writes.

set -e

echo "=== STAGE-2 RAM BRINGUP STARTING ===" > /dev/kmsg

# 1. Cancel watchdog timer
touch /tmp/watchdog_cancel
echo "[STAGE2] Safety watchdog timer disarmed." > /dev/kmsg

# 2. Strict read-only verification of physical UFS block devices
for lun in /dev/block/sda /dev/block/sdb /dev/block/sdc /dev/block/sdd /dev/block/sde /dev/block/sdf; do
    if [ -b "$lun" ]; then
        ro=$(/system/bin/toybox blockdev --getro "$lun")
        if [ "$ro" != "1" ]; then
            echo "[STAGE2 FATAL] $lun is NOT read-only (ro=$ro)! Halting." > /dev/kmsg
            exit 1
        fi
    fi
done
echo "[STAGE2] Verified all physical block devices sda-sdf are strictly read-only." > /dev/kmsg

# 3. Create sysroot mount directory structure
mkdir -p /mnt/sysroot
mkdir -p /mnt/sysroot/system
mkdir -p /mnt/sysroot/system_ext
mkdir -p /mnt/sysroot/product
mkdir -p /mnt/sysroot/my_product
mkdir -p /mnt/sysroot/my_region
mkdir -p /mnt/sysroot/vendor
mkdir -p /mnt/sysroot/odm
mkdir -p /mnt/sysroot/data
mkdir -p /mnt/sysroot/dev
mkdir -p /mnt/sysroot/proc
mkdir -p /mnt/sysroot/sys
mkdir -p /mnt/sysroot/apex
mkdir -p /mnt/sysroot/linkerconfig
mkdir -p /mnt/sysroot/tmp

# 4. Mount EROFS images to their respective mountpoints
echo "[STAGE2] Mounting EROFS system images..." > /dev/kmsg
/system/bin/toybox mount -t erofs -o ro,loop /tmp/system.img /mnt/sysroot
/system/bin/toybox mount -t erofs -o ro,loop /tmp/system_ext.img /mnt/sysroot/system_ext
/system/bin/toybox mount -t erofs -o ro,loop /tmp/my_product.img /mnt/sysroot/my_product
/system/bin/toybox mount -t erofs -o ro,loop /tmp/my_region.img /mnt/sysroot/my_region
/system/bin/toybox mount -t erofs -o ro,loop /tmp/vendor.img /mnt/sysroot/vendor
/system/bin/toybox mount -t erofs -o ro,loop /tmp/odm.img /mnt/sysroot/odm

# 5. Mount RAM-backed ephemeral /data
echo "[STAGE2] Initializing RAM tmpfs for /data (1024 MB)..." > /dev/kmsg
/system/bin/toybox mount -t tmpfs -o rw,nosuid,nodev,noatime,mode=0771,size=1024M tmpfs /mnt/sysroot/data
mkdir -p /mnt/sysroot/data/system /mnt/sysroot/data/misc /mnt/sysroot/data/user /mnt/sysroot/data/user_de /mnt/sysroot/data/local /mnt/sysroot/data/local/tmp /mnt/sysroot/data/media
chmod 0775 /mnt/sysroot/data/local/tmp
chmod 0700 /mnt/sysroot/data/system

# 6. Bind core kernel filesystems
/system/bin/toybox mount --bind /dev /mnt/sysroot/dev
/system/bin/toybox mount --bind /proc /mnt/sysroot/proc
/system/bin/toybox mount --bind /sys /mnt/sysroot/sys

echo "[STAGE2] RAM Filesystems mounted successfully. Transitioning to Android init..." > /dev/kmsg

# 7. Start second-stage Android init via chroot
exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage
