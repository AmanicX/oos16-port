#!/system/bin/sh
# Stage-2 Android 16 Bringup in RAM on OnePlus 7T (HD1901)
# 100% RAM resident, 0 physical storage writes.

set -e

# Disable kernel printk ratelimiting so zero init output lines are suppressed
echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null || true

echo "=== STAGE-2 RAM BRINGUP STARTING ===" > /dev/kmsg

# Tactile feedback: haptic vibration pulse
echo 300 > /sys/class/leds/vibrator/duration 2>/dev/null || true
echo 1 > /sys/class/leds/vibrator/activate 2>/dev/null || true

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

# Log memory before mounts
echo "[STAGE2-MEM] Initial: $(grep MemAvailable /proc/meminfo)" > /dev/kmsg

# 3. Create sysroot mount directory structure
/system/bin/toybox umount -R /mnt/sysroot 2>/dev/null || true
mkdir -p /mnt/sysroot

# 4. Mount EROFS system images to their respective mountpoints
echo "[STAGE2] Mounting EROFS system images..." > /dev/kmsg
/system/bin/toybox mount -t erofs -o ro,loop /tmp/system.img /mnt/sysroot
/system/bin/toybox mount -t erofs -o ro,loop /tmp/system_ext.img /mnt/sysroot/system_ext
if [ -f /mnt/my_product.img ]; then
    /system/bin/toybox mount -t erofs -o ro,loop /mnt/my_product.img /mnt/sysroot/my_product
    /system/bin/toybox mount -t erofs -o ro,loop /mnt/my_product.img /mnt/sysroot/product
else
    /system/bin/toybox mount -t erofs -o ro,loop /tmp/my_product.img /mnt/sysroot/my_product
    /system/bin/toybox mount -t erofs -o ro,loop /tmp/my_product.img /mnt/sysroot/product
fi
if [ -f /tmp/my_region.img ]; then
    /system/bin/toybox mount -t erofs -o ro,loop /tmp/my_region.img /mnt/sysroot/my_region
fi
/system/bin/toybox mount -t erofs -o ro,loop /tmp/vendor.img /mnt/sysroot/vendor
/system/bin/toybox mount -t erofs -o ro,loop /tmp/odm.img /mnt/sysroot/odm

# Mount RAM tmpfs on /mnt/sysroot/apex to allow runtime creation and APEX mounts
/system/bin/toybox mount -t tmpfs -o mode=0755 tmpfs /mnt/sysroot/apex
mkdir -p /mnt/sysroot/apex/com.android.runtime
if [ -f /tmp/runtime_apex.img ]; then
    echo "[STAGE2] Mounting Bionic Runtime APEX payload..." > /dev/kmsg
    /system/bin/toybox mount -t erofs -o ro,loop /tmp/runtime_apex.img /mnt/sysroot/apex/com.android.runtime
fi

# CRITICAL FIX: Ensure dynamic linker /apex/com.android.runtime/bin/linker64 is present
mkdir -p /mnt/sysroot/apex/com.android.runtime/bin
/system/bin/toybox ln -sf /system/bin/bootstrap/linker64 /mnt/sysroot/apex/com.android.runtime/bin/linker64 2>/dev/null || true
/system/bin/toybox ln -sf /system/bin/bootstrap/linker /mnt/sysroot/apex/com.android.runtime/bin/linker 2>/dev/null || true

# Secondary fallback symlinks for Bionic libraries
mkdir -p /mnt/sysroot/apex/com.android.runtime/lib64/bionic /mnt/sysroot/apex/com.android.runtime/lib/bionic
/system/bin/toybox ln -sf /system/lib64/bootstrap/libc.so /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libc.so 2>/dev/null || true
/system/bin/toybox ln -sf /system/lib64/bootstrap/libm.so /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libm.so 2>/dev/null || true
/system/bin/toybox ln -sf /system/lib64/bootstrap/libdl.so /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libdl.so 2>/dev/null || true
/system/bin/toybox ln -sf /system/lib/bootstrap/libc.so /mnt/sysroot/apex/com.android.runtime/lib/bionic/libc.so 2>/dev/null || true
/system/bin/toybox ln -sf /system/lib/bootstrap/libm.so /mnt/sysroot/apex/com.android.runtime/lib/bionic/libm.so 2>/dev/null || true
/system/bin/toybox ln -sf /system/lib/bootstrap/libdl.so /mnt/sysroot/apex/com.android.runtime/lib/bionic/libdl.so 2>/dev/null || true

# Ephemeral RAM tmpfs for mnt, my_company, and oem to allow runtime creation
/system/bin/toybox mount -t tmpfs -o mode=0755 tmpfs /mnt/sysroot/mnt
mkdir -p /mnt/sysroot/mnt/vendor/persist

/system/bin/toybox mount -t tmpfs -o mode=0755 tmpfs /mnt/sysroot/my_company
mkdir -p /mnt/sysroot/my_company/etc
/system/bin/toybox mount -t tmpfs -o mode=0755 tmpfs /mnt/sysroot/oem
mkdir -p /mnt/sysroot/oem/etc

# Mount RAM tmpfs on /mnt/sysroot/linkerconfig so dynamic linker finds configuration
/system/bin/toybox mount -t tmpfs -o mode=0755 tmpfs /mnt/sysroot/linkerconfig
mkdir -p /mnt/sysroot/linkerconfig/bootstrap /mnt/sysroot/linkerconfig/default
echo "#" > /mnt/sysroot/linkerconfig/bootstrap/ld.config.txt
echo "#" > /mnt/sysroot/linkerconfig/default/ld.config.txt
echo "#" > /mnt/sysroot/linkerconfig/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/bootstrap/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/default/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/ld.config.txt

# 5. Mount RAM-backed ephemeral /data
echo "[STAGE2] Initializing RAM tmpfs for /data (1024 MB)..." > /dev/kmsg
/system/bin/toybox mount -t tmpfs -o rw,nosuid,nodev,noatime,mode=0771,size=1024M tmpfs /mnt/sysroot/data
mkdir -p /mnt/sysroot/data/system /mnt/sysroot/data/misc /mnt/sysroot/data/user /mnt/sysroot/data/user_de /mnt/sysroot/data/local /mnt/sysroot/data/local/tmp /mnt/sysroot/data/media /mnt/sysroot/data/persist_log
chmod 0775 /mnt/sysroot/data/local/tmp
chmod 0700 /mnt/sysroot/data/system

# 6. Bind core kernel filesystems
/system/bin/toybox mount --bind /dev /mnt/sysroot/dev
/system/bin/toybox mount -t devpts devpts /mnt/sysroot/dev/pts || true

# CRITICAL FIX: Mount private procfs inside sysroot so /proc/self/exe resolves cleanly to /system/bin/init
/system/bin/toybox mount -t proc proc /mnt/sysroot/proc
/system/bin/toybox mount --bind /sys /mnt/sysroot/sys
mkdir -p /mnt/sysroot/sys/fs/selinux 2>/dev/null || true
/system/bin/toybox mount -t selinuxfs selinuxfs /mnt/sysroot/sys/fs/selinux || true

# Graphics nodes compatibility
mkdir -p /mnt/sysroot/dev/graphics
/system/bin/toybox ln -s /dev/dri/card0 /mnt/sysroot/dev/graphics/fb0 2>/dev/null || true

# CRITICAL FIX: Isolate property workspace and socket dirs to eliminate SIGSEGV Code 139
mkdir -p /mnt/sysroot/dev/__properties__
mkdir -p /mnt/sysroot/dev/socket
/system/bin/toybox mount -t tmpfs tmpfs /mnt/sysroot/dev/__properties__
/system/bin/toybox mount -t tmpfs tmpfs /mnt/sysroot/dev/socket

# Recursive sysroot mirror so both /system/bin/init and /mnt/sysroot/system/bin/init resolve with all submounts
mkdir -p /mnt/sysroot/mnt/sysroot
/system/bin/toybox mount --rbind /mnt/sysroot /mnt/sysroot/mnt/sysroot

# Log memory after mounts
echo "[STAGE2-MEM] Mounted: $(grep MemAvailable /proc/meminfo)" > /dev/kmsg

# Pre-execution verification of executable paths inside sysroot
echo "[STAGE2-VERIFY] Verifying init paths inside sysroot:" > /dev/kmsg
/system/bin/chroot /mnt/sysroot /system/bin/toybox ls -la /system/bin/init /mnt/sysroot/system/bin/init /init > /dev/kmsg 2>&1 || true
echo "[STAGE2-VERIFY] Verifying linker configuration:" > /dev/kmsg
/system/bin/chroot /mnt/sysroot /system/bin/toybox ls -la /linkerconfig /linkerconfig/ld.config.txt > /dev/kmsg 2>&1 || true
echo "[STAGE2-VERIFY] Verifying Bionic runtime libc.so:" > /dev/kmsg
/system/bin/chroot /mnt/sysroot /system/bin/toybox ls -la /apex/com.android.runtime/lib64/bionic/libc.so > /dev/kmsg 2>&1 || true

# Background resource and service monitor (reads Stage-2 properties inside chroot)
(
    while true; do
        avail=$(/system/bin/toybox grep MemAvailable /proc/meminfo 2>/dev/null || true)
        hwc=$(/system/bin/chroot /mnt/sysroot /system/bin/toybox getprop init.svc.vendor.hwcomposer-2-4 2>/dev/null || true)
        alloc=$(/system/bin/chroot /mnt/sysroot /system/bin/toybox getprop init.svc.vendor.qti.hardware.display.allocator 2>/dev/null || true)
        sf=$(/system/bin/chroot /mnt/sysroot /system/bin/toybox getprop init.svc.surfaceflinger 2>/dev/null || true)
        ba=$(/system/bin/chroot /mnt/sysroot /system/bin/toybox getprop init.svc.bootanim 2>/dev/null || true)
        vinit=$(/system/bin/chroot /mnt/sysroot /system/bin/toybox getprop init.svc.vendor_init 2>/dev/null || true)
        echo "[STAGE2-MONITOR] $avail | vinit=$vinit hwc=$hwc alloc=$alloc sf=$sf ba=$ba" > /dev/kmsg
        /system/bin/toybox sleep 5
    done
) &

echo "[STAGE2] RAM Filesystems mounted successfully. Transitioning to Android init..." > /dev/kmsg

# 7. Start second-stage Android init via chroot
export PATH=/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
export ANDROID_STORAGE=/storage
export ANDROID_ART_ROOT=/apex/com.android.art
export ANDROID_I18N_ROOT=/apex/com.android.i18n
export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata

exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage
