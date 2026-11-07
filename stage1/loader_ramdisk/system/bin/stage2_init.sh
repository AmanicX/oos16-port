#!/system/bin/sh
# ==============================================================================
# stage2_init.sh - Stage-2 Android 16 Bringup in RAM on OnePlus 7T (HD1901)
# 100% Volatile RAM resident, Zero Physical Storage Writes.
# Handles strict OverlayFS root, mandatory partition verification,
# strict Bionic runtime APEX validation, and single PID 1 Android init handover.
# ==============================================================================

set -e

# Disable kernel printk ratelimiting so no init diagnostic lines are suppressed
echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null || true

echo "=== STAGE-2 RAM BRINGUP STARTING ===" > /dev/kmsg

# Tactile feedback: haptic vibration pulse
echo 300 > /sys/class/leds/vibrator/duration 2>/dev/null || true
echo 1 > /sys/class/leds/vibrator/activate 2>/dev/null || true

# Helper for fatal errors - logs to kmsg and halts safely
fatal() {
    echo "[STAGE2 FATAL] $1" > /dev/kmsg
    echo "[STAGE2 FATAL] $1" >&2
    while true; do
        /system/bin/toybox sleep 60
    done
}

# Helper to execute and verify mount
mount_or_fail() {
    echo "[STAGE2] Mounting: $*" > /dev/kmsg
    /system/bin/toybox mount "$@" || fatal "Failed mandatory mount: mount $*"
}

# 1. Heartbeat check
if [ -f /mnt/watchdog_heartbeat ] || [ -f /tmp/watchdog_heartbeat ]; then
    echo "[STAGE2] Active host heartbeat signal verified." > /dev/kmsg
fi

# 2. Strict read-only verification of physical block devices
echo "[STAGE2] Verifying physical block devices are write-locked read-only..." > /dev/kmsg
DISCOVERED_PHYSICAL=0
for bdir in /sys/block/*; do
    [ -d "$bdir" ] || continue
    bname=$(basename "$bdir")
    case "$bname" in
        loop*|ram*|zram*|dm-*) continue ;;
    esac

    if [ -e "$bdir/device" ] || case "$bname" in sd*|mmcblk*) true ;; *) false ;; esac; then
        dev_node="/dev/block/$bname"
        if [ -b "$dev_node" ]; then
            DISCOVERED_PHYSICAL=$((DISCOVERED_PHYSICAL + 1))
            ro=$(/system/bin/toybox blockdev --getro "$dev_node" 2>/dev/null || echo "0")
            if [ "$ro" != "1" ]; then
                fatal "$dev_node is NOT read-only (ro=$ro)! Halting to protect physical storage."
            fi
        fi
    fi
done

if [ "$DISCOVERED_PHYSICAL" -eq 0 ]; then
    fatal "No physical block devices detected. Cannot verify physical disk write locks!"
fi
echo "[STAGE2] Verified: All physical storage devices are strictly locked read-only (ro=1)." > /dev/kmsg

# 3. Clean up any previous mounts
/system/bin/toybox umount -R /mnt/sysroot 2>/dev/null || true
/system/bin/toybox umount /mnt/system_ro 2>/dev/null || true
/system/bin/toybox mkdir -p /mnt/sysroot /mnt/system_ro /mnt/overlay_upper /mnt/overlay_work

# 4. Resolve Base System Image
SYSTEM_IMG="/mnt/system.img"
[ -f "$SYSTEM_IMG" ] || SYSTEM_IMG="/tmp/system.img"
[ -f "$SYSTEM_IMG" ] && [ -s "$SYSTEM_IMG" ] || fatal "Required system image /mnt/system.img not found or 0 bytes!"

# Mount base system image to /mnt/system_ro (read-only EROFS loop mount)
mount_or_fail -t erofs -o ro,loop "$SYSTEM_IMG" /mnt/system_ro

# Mount OverlayFS on /mnt/sysroot with upper and work directories on RAM tmpfs (/mnt)
# Both upperdir and workdir reside on the exact same writable tmpfs filesystem.
mount_or_fail -t overlay overlay -o lowerdir=/mnt/system_ro,upperdir=/mnt/overlay_upper,workdir=/mnt/overlay_work /mnt/sysroot

# Verify OverlayFS is active in /proc/mounts; never continue with partial fallback
if ! /system/bin/toybox grep -q " /mnt/sysroot overlay " /proc/mounts 2>/dev/null; then
    fatal "OverlayFS mount verification failed for /mnt/sysroot! Halting."
fi
echo "[STAGE2] Mounted writable OverlayFS root at /mnt/sysroot." > /dev/kmsg

# 5. Pre-Create and Validate Every Required Child Mountpoint on Rootfs
REQUIRED_MOUNTPOINTS="system_ext vendor odm product my_product my_region apex data dev proc sys linkerconfig mnt"
for mp in $REQUIRED_MOUNTPOINTS; do
    /system/bin/toybox mkdir -p "/mnt/sysroot/$mp"
    if [ ! -d "/mnt/sysroot/$mp" ]; then
        fatal "Failed to establish required mountpoint directory /mnt/sysroot/$mp!"
    fi
done
echo "[STAGE2] All child mountpoints verified on rootfs." > /dev/kmsg

# 6. Mount Child Partition Images with Source and Mountpoint Validation
mount_partition() {
    local name="$1"
    local img_path="$2"
    local target="/mnt/sysroot/$name"
    local mandatory="${3:-1}"

    if [ ! -f "$img_path" ] || [ ! -s "$img_path" ]; then
        if [ "$mandatory" -eq 1 ]; then
            fatal "Mandatory partition image $img_path does not exist or is 0 bytes!"
        else
            echo "[STAGE2] Optional partition image $img_path not present, skipping." > /dev/kmsg
            return 0
        fi
    fi

    if [ ! -d "$target" ]; then
        if [ "$mandatory" -eq 1 ]; then
            fatal "Mountpoint directory $target does not exist!"
        else
            echo "[STAGE2] Optional mountpoint $target missing, skipping." > /dev/kmsg
            return 0
        fi
    fi

    mount_or_fail -t erofs -o ro,loop "$img_path" "$target"
    
    # Verify mount in /proc/mounts
    if ! /system/bin/toybox grep -q " $target erofs " /proc/mounts 2>/dev/null; then
        if [ "$mandatory" -eq 1 ]; then
            fatal "Verification failed: $target is not mounted as erofs in /proc/mounts!"
        fi
    fi
    echo "[STAGE2] Successfully mounted and verified $name at $target." > /dev/kmsg
}

# Resolve image paths preferring /mnt/ over /tmp/
get_img() {
    local name="$1"
    if [ -f "/mnt/$name" ] && [ -s "/mnt/$name" ]; then
        echo "/mnt/$name"
    elif [ -f "/tmp/$name" ] && [ -s "/tmp/$name" ]; then
        echo "/tmp/$name"
    else
        echo ""
    fi
}

SYSTEM_EXT_IMG=$(get_img "system_ext.img")
[ -n "$SYSTEM_EXT_IMG" ] || fatal "Mandatory system_ext.img not found in /mnt/ or /tmp/!"
mount_partition "system_ext" "$SYSTEM_EXT_IMG" 1

PRODUCT_IMG=$(get_img "product.img")
[ -z "$PRODUCT_IMG" ] && PRODUCT_IMG=$(get_img "my_product.img")
[ -n "$PRODUCT_IMG" ] || fatal "Mandatory product.img (or my_product.img) not found in /mnt/ or /tmp/!"
mount_partition "product" "$PRODUCT_IMG" 1

if [ -d /mnt/sysroot/my_product ]; then
    MY_PROD_IMG=$(get_img "my_product.img")
    [ -z "$MY_PROD_IMG" ] && MY_PROD_IMG="$PRODUCT_IMG"
    mount_partition "my_product" "$MY_PROD_IMG" 0
fi

REGION_IMG=$(get_img "my_region.img")
if [ -n "$REGION_IMG" ] && [ -d /mnt/sysroot/my_region ]; then
    mount_partition "my_region" "$REGION_IMG" 0
fi

VENDOR_IMG=$(get_img "vendor.img")
[ -n "$VENDOR_IMG" ] || fatal "Mandatory vendor.img not found in /mnt/ or /tmp/!"
mount_partition "vendor" "$VENDOR_IMG" 1

ODM_IMG=$(get_img "odm.img")
[ -n "$ODM_IMG" ] || fatal "Mandatory odm.img not found in /mnt/ or /tmp/!"
mount_partition "odm" "$ODM_IMG" 1

# 7. Strict Runtime APEX Filesystem Handling & Dynamic Linker Validation
echo "[STAGE2] Preparing Bionic runtime APEX on tmpfs..." > /dev/kmsg
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/apex

/system/bin/toybox mkdir -p /mnt/sysroot/apex/com.android.runtime
/system/bin/toybox mkdir -p /tmp/apex_payload_staging

RUNTIME_IMG=$(get_img "runtime_apex.img")
[ -z "$RUNTIME_IMG" ] && RUNTIME_IMG=$(get_img "runtime_apex.erofs.img")
[ -n "$RUNTIME_IMG" ] || fatal "Mandatory runtime_apex.img not found in /mnt/ or /tmp/!"

APEX_FSTYPE="erofs"
if [ -f /mnt/runtime_apex.fstype ]; then
    APEX_FSTYPE=$(cat /mnt/runtime_apex.fstype | tr -d '[:space:]')
elif [ -f /tmp/runtime_apex.fstype ]; then
    APEX_FSTYPE=$(cat /tmp/runtime_apex.fstype | tr -d '[:space:]')
fi

# Loop mount runtime APEX payload without error suppression
mount_or_fail -t "$APEX_FSTYPE" -o ro,loop "$RUNTIME_IMG" /tmp/apex_payload_staging

# Copy all payload contents into writable runtime APEX hierarchy
echo "[STAGE2] Populating /mnt/sysroot/apex/com.android.runtime from payload..." > /dev/kmsg
/system/bin/toybox cp -a /tmp/apex_payload_staging/* /mnt/sysroot/apex/com.android.runtime/ || fatal "Failed to copy runtime APEX payload!"
/system/bin/toybox umount /tmp/apex_payload_staging || true

# Strict Validation of Authentic Runtime Bionic Binaries & Libraries (No invented placeholders)
[ -f /mnt/sysroot/apex/com.android.runtime/bin/linker64 ] || fatal "Bionic linker64 is MISSING from runtime APEX!"
[ -x /mnt/sysroot/apex/com.android.runtime/bin/linker64 ] || fatal "Bionic linker64 is not executable in runtime APEX!"
[ -f /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libc.so ] || fatal "Bionic libc.so is MISSING from runtime APEX!"
[ -f /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libm.so ] || fatal "Bionic libm.so is MISSING from runtime APEX!"
[ -f /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libdl.so ] || fatal "Bionic libdl.so is MISSING from runtime APEX!"

echo "[STAGE2] Strict verification passed: Authentic Bionic runtime APEX and linker64 are ready." > /dev/kmsg

# 8. Linker Configuration & Runtime Directories
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/linkerconfig
/system/bin/toybox mkdir -p /mnt/sysroot/linkerconfig/bootstrap /mnt/sysroot/linkerconfig/default
echo "#" > /mnt/sysroot/linkerconfig/bootstrap/ld.config.txt
echo "#" > /mnt/sysroot/linkerconfig/default/ld.config.txt
echo "#" > /mnt/sysroot/linkerconfig/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/bootstrap/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/default/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/ld.config.txt

mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/mnt
/system/bin/toybox mkdir -p /mnt/sysroot/mnt/vendor/persist

# 9. Ephemeral /data (1024 MB RAM tmpfs)
echo "[STAGE2] Initializing RAM tmpfs for /data (1024 MB)..." > /dev/kmsg
mount_or_fail -t tmpfs -o rw,nosuid,nodev,noatime,mode=0771,size=1024M tmpfs /mnt/sysroot/data
/system/bin/toybox mkdir -p /mnt/sysroot/data/system /mnt/sysroot/data/misc /mnt/sysroot/data/user /mnt/sysroot/data/user_de /mnt/sysroot/data/local /mnt/sysroot/data/local/tmp /mnt/sysroot/data/media /mnt/sysroot/data/persist_log
chmod 0775 /mnt/sysroot/data/local/tmp
chmod 0700 /mnt/sysroot/data/system
chmod 01771 /mnt/sysroot/data/misc

# 10. Bind Core Kernel Interfaces
mount_or_fail --bind /dev /mnt/sysroot/dev
mount_or_fail -t devpts devpts /mnt/sysroot/dev/pts
mount_or_fail -t proc proc /mnt/sysroot/proc
mount_or_fail --bind /sys /mnt/sysroot/sys
/system/bin/toybox mkdir -p /mnt/sysroot/sys/fs/selinux
/system/bin/toybox mount -t selinuxfs selinuxfs /mnt/sysroot/sys/fs/selinux 2>/dev/null || true

# Isolate property workspace and socket dirs to eliminate SIGSEGV Code 139
/system/bin/toybox mkdir -p /mnt/sysroot/dev/__properties__ /mnt/sysroot/dev/socket
mount_or_fail -t tmpfs tmpfs /mnt/sysroot/dev/__properties__
mount_or_fail -t tmpfs tmpfs /mnt/sysroot/dev/socket

# Graphics compatibility node
/system/bin/toybox mkdir -p /mnt/sysroot/dev/graphics
/system/bin/toybox ln -s /dev/dri/card0 /mnt/sysroot/dev/graphics/fb0 2>/dev/null || true

# 11. Final Mount Layout Verification
echo "[STAGE2] Verifying complete mount layout in /proc/mounts..." > /dev/kmsg
MANDATORY_MOUNTS="/mnt/sysroot /mnt/sysroot/system_ext /mnt/sysroot/vendor /mnt/sysroot/odm /mnt/sysroot/product /mnt/sysroot/apex /mnt/sysroot/data /mnt/sysroot/dev /mnt/sysroot/proc /mnt/sysroot/sys /mnt/sysroot/linkerconfig"
for target in $MANDATORY_MOUNTS; do
    if ! /system/bin/toybox grep -q " $target " /proc/mounts 2>/dev/null; then
        fatal "Final mount layout verification failed: $target is NOT mounted in /proc/mounts!"
    fi
done
echo "[STAGE2] All mandatory filesystems verified in /proc/mounts." > /dev/kmsg

# 12. Android Init Handover
echo "[STAGE2] ALL RAM FILESYSTEMS READY. EXECUTING ANDROID 16 INIT SECOND_STAGE AS PID 1..." > /dev/kmsg

# Stop Stage-1 adbd and unbind USB gadget controller cleanly
killall adbd 2>/dev/null || true
echo "" > /config/usb_gadget/g1/UDC 2>/dev/null || true
/system/bin/toybox umount /dev/usb-ffs/adb 2>/dev/null || true

export PATH=/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
export ANDROID_STORAGE=/storage
export ANDROID_ART_ROOT=/apex/com.android.art
export ANDROID_I18N_ROOT=/apex/com.android.i18n
export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata

exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage
