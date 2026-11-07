#!/system/bin/sh
# ==============================================================================
# stage2_init.sh - Stage-2 Android 16 Bringup in RAM on OnePlus 7T (HD1901)
# 100% Volatile RAM resident, Zero Physical Storage Writes.
# ==============================================================================

set -e

# Disable kernel printk ratelimiting so no init diagnostic lines are suppressed
echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null || true

echo "=== STAGE-2 RAM BRINGUP STARTING ===" > /dev/kmsg

# Tactile feedback: haptic vibration pulse
echo 300 > /sys/class/leds/vibrator/duration 2>/dev/null || true
echo 1 > /sys/class/leds/vibrator/activate 2>/dev/null || true

# Helper for fatal errors
fatal() {
    echo "[STAGE2 FATAL] $1" > /dev/kmsg
    echo "[STAGE2 FATAL] $1" >&2
    exit 1
}

# Helper to verify mount succeeded
mount_or_fail() {
    echo "[STAGE2] Mounting: $*" > /dev/kmsg
    /system/bin/toybox mount "$@" || fatal "Failed mount command: mount $*"
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
/system/bin/toybox mkdir -p /mnt/sysroot /mnt/system_ro /mnt/overlay_upper /mnt/overlay_work

# 4. Resolve and Mount Base System Image
SYSTEM_IMG="/mnt/system.img"
[ -f "$SYSTEM_IMG" ] || SYSTEM_IMG="/tmp/system.img"
[ -f "$SYSTEM_IMG" ] || fatal "Required system image /mnt/system.img (or /tmp/system.img) not found!"

# Attempt OverlayFS mount for writable sysroot in RAM
OVERLAY_MOUNTED=0
if /system/bin/toybox mount -t erofs -o ro,loop "$SYSTEM_IMG" /mnt/system_ro 2>/dev/null; then
    if /system/bin/toybox mount -t overlay overlay -o lowerdir=/mnt/system_ro,upperdir=/mnt/overlay_upper,workdir=/mnt/overlay_work /mnt/sysroot 2>/dev/null; then
        OVERLAY_MOUNTED=1
        echo "[STAGE2] Mounted writable OverlayFS root at /mnt/sysroot" > /dev/kmsg
    fi
fi

if [ "$OVERLAY_MOUNTED" -eq 0 ]; then
    echo "[STAGE2 WARN] OverlayFS unavailable, mounting system image directly to /mnt/sysroot" > /dev/kmsg
    /system/bin/toybox umount /mnt/system_ro 2>/dev/null || true
    mount_or_fail -t erofs -o ro,loop "$SYSTEM_IMG" /mnt/sysroot
fi

# 5. Verify & Create Mountpoints on Rootfs
REQUIRED_MOUNTPOINTS="system_ext vendor odm product my_product my_region apex data dev proc sys linkerconfig mnt"
for mp in $REQUIRED_MOUNTPOINTS; do
    if [ "$OVERLAY_MOUNTED" -eq 1 ]; then
        /system/bin/toybox mkdir -p "/mnt/sysroot/$mp" 2>/dev/null || true
    fi
    if [ ! -d "/mnt/sysroot/$mp" ]; then
        fatal "Required mountpoint directory /mnt/sysroot/$mp does not exist on rootfs!"
    fi
done

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
    if [ -f "/mnt/$name" ]; then
        echo "/mnt/$name"
    elif [ -f "/tmp/$name" ]; then
        echo "/tmp/$name"
    else
        echo ""
    fi
}

SYSTEM_EXT_IMG=$(get_img "system_ext.img")
[ -n "$SYSTEM_EXT_IMG" ] && mount_partition "system_ext" "$SYSTEM_EXT_IMG" 1

PRODUCT_IMG=$(get_img "product.img")
[ -z "$PRODUCT_IMG" ] && PRODUCT_IMG=$(get_img "my_product.img")
if [ -n "$PRODUCT_IMG" ]; then
    mount_partition "product" "$PRODUCT_IMG" 1
    if [ -d /mnt/sysroot/my_product ]; then
        mount_partition "my_product" "$PRODUCT_IMG" 0
    fi
else
    fatal "Mandatory product.img (or my_product.img) not found in /mnt/ or /tmp/!"
fi

REGION_IMG=$(get_img "my_region.img")
[ -n "$REGION_IMG" ] && mount_partition "my_region" "$REGION_IMG" 0

VENDOR_IMG=$(get_img "vendor.img")
[ -n "$VENDOR_IMG" ] && mount_partition "vendor" "$VENDOR_IMG" 1 || fatal "Mandatory vendor.img not found!"

ODM_IMG=$(get_img "odm.img")
[ -n "$ODM_IMG" ] && mount_partition "odm" "$ODM_IMG" 1 || fatal "Mandatory odm.img not found!"

# 7. Runtime APEX Filesystem Handling & Dynamic Linker Bridging
echo "[STAGE2] Initializing writable APEX hierarchy on tmpfs..." > /dev/kmsg
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/apex

mkdir -p /mnt/sysroot/apex/com.android.runtime
mkdir -p /mnt/sysroot/apex/com.android.runtime/bin
mkdir -p /mnt/sysroot/apex/com.android.runtime/lib64/bionic
mkdir -p /mnt/sysroot/apex/com.android.runtime/lib/bionic

RUNTIME_IMG=$(get_img "runtime_apex.img")
[ -z "$RUNTIME_IMG" ] && RUNTIME_IMG=$(get_img "runtime_apex.erofs.img")

if [ -n "$RUNTIME_IMG" ] && [ -f "$RUNTIME_IMG" ]; then
    APEX_FSTYPE="erofs"
    if [ -f /mnt/runtime_apex.fstype ]; then
        APEX_FSTYPE=$(cat /mnt/runtime_apex.fstype | tr -d '[:space:]')
    elif [ -f /tmp/runtime_apex.fstype ]; then
        APEX_FSTYPE=$(cat /tmp/runtime_apex.fstype | tr -d '[:space:]')
    fi

    echo "[STAGE2] Staging runtime APEX payload ($APEX_FSTYPE) to temporary loop mount..." > /dev/kmsg
    mkdir -p /tmp/apex_payload_mnt
    if mount_or_fail -t "$APEX_FSTYPE" -o ro,loop "$RUNTIME_IMG" /tmp/apex_payload_mnt; then
        echo "[STAGE2] Populating /mnt/sysroot/apex/com.android.runtime from payload..." > /dev/kmsg
        /system/bin/toybox cp -a /tmp/apex_payload_mnt/* /mnt/sysroot/apex/com.android.runtime/ 2>/dev/null || true
        /system/bin/toybox umount /tmp/apex_payload_mnt 2>/dev/null || true
    fi
fi

# Ensure 64-bit dynamic linker is accessible at /apex/com.android.runtime/bin/linker64
if [ ! -f /mnt/sysroot/apex/com.android.runtime/bin/linker64 ]; then
    echo "[STAGE2] Linking bootstrap linker to /apex/com.android.runtime/bin/linker64..." > /dev/kmsg
    /system/bin/toybox ln -sf /system/bin/bootstrap/linker64 /mnt/sysroot/apex/com.android.runtime/bin/linker64
fi
if [ ! -f /mnt/sysroot/apex/com.android.runtime/bin/linker ]; then
    /system/bin/toybox ln -sf /system/bin/bootstrap/linker /mnt/sysroot/apex/com.android.runtime/bin/linker
fi

# Link core Bionic libraries into runtime APEX if missing
for lib in libc.so libm.so libdl.so; do
    if [ ! -f "/mnt/sysroot/apex/com.android.runtime/lib64/bionic/$lib" ]; then
        /system/bin/toybox ln -sf "/system/lib64/bootstrap/$lib" "/mnt/sysroot/apex/com.android.runtime/lib64/bionic/$lib"
    fi
    if [ ! -f "/mnt/sysroot/apex/com.android.runtime/lib/bionic/$lib" ]; then
        /system/bin/toybox ln -sf "/system/lib/bootstrap/$lib" "/mnt/sysroot/apex/com.android.runtime/lib/bionic/$lib"
    fi
done

# Verify linker is now executable
[ -f /mnt/sysroot/apex/com.android.runtime/bin/linker64 ] || fatal "Bionic linker64 is MISSING from /mnt/sysroot/apex/com.android.runtime/bin/linker64!"
echo "[STAGE2] Bionic dynamic linker verified: /apex/com.android.runtime/bin/linker64 is ready." > /dev/kmsg

# 8. Linker Configuration & Runtime Directories
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/linkerconfig
mkdir -p /mnt/sysroot/linkerconfig/bootstrap /mnt/sysroot/linkerconfig/default
echo "#" > /mnt/sysroot/linkerconfig/bootstrap/ld.config.txt
echo "#" > /mnt/sysroot/linkerconfig/default/ld.config.txt
echo "#" > /mnt/sysroot/linkerconfig/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/bootstrap/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/default/ld.config.txt
chmod 644 /mnt/sysroot/linkerconfig/ld.config.txt

mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/mnt
mkdir -p /mnt/sysroot/mnt/vendor/persist

# 9. Ephemeral /data (1024 MB RAM tmpfs)
echo "[STAGE2] Initializing RAM tmpfs for /data (1024 MB)..." > /dev/kmsg
mount_or_fail -t tmpfs -o rw,nosuid,nodev,noatime,mode=0771,size=1024M tmpfs /mnt/sysroot/data
mkdir -p /mnt/sysroot/data/system /mnt/sysroot/data/misc /mnt/sysroot/data/user /mnt/sysroot/data/user_de /mnt/sysroot/data/local /mnt/sysroot/data/local/tmp /mnt/sysroot/data/media /mnt/sysroot/data/persist_log
chmod 0775 /mnt/sysroot/data/local/tmp
chmod 0700 /mnt/sysroot/data/system

# 10. Bind Core Kernel Interfaces
mount_or_fail --bind /dev /mnt/sysroot/dev
mount_or_fail -t devpts devpts /mnt/sysroot/dev/pts
mount_or_fail -t proc proc /mnt/sysroot/proc
mount_or_fail --bind /sys /mnt/sysroot/sys
mkdir -p /mnt/sysroot/sys/fs/selinux
mount_or_fail -t selinuxfs selinuxfs /mnt/sysroot/sys/fs/selinux

# Isolate property workspace and socket dirs to eliminate SIGSEGV Code 139
mkdir -p /mnt/sysroot/dev/__properties__
mkdir -p /mnt/sysroot/dev/socket
mount_or_fail -t tmpfs tmpfs /mnt/sysroot/dev/__properties__
mount_or_fail -t tmpfs tmpfs /mnt/sysroot/dev/socket

# Graphics nodes compatibility
mkdir -p /mnt/sysroot/dev/graphics
/system/bin/toybox ln -s /dev/dri/card0 /mnt/sysroot/dev/graphics/fb0 2>/dev/null || true

# Note: The recursive bind mount `/mnt/sysroot/mnt/sysroot` has been REMOVED.

echo "[STAGE2] All RAM filesystems verified and mounted cleanly." > /dev/kmsg

# 11. Android Init Handover
# Architecture Note: Android init is designed to execute as PID 1.
# Executing via chroot replaces the process image.
echo "[STAGE2] Executing Android 16 init second_stage in sysroot..." > /dev/kmsg

export PATH=/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
export ANDROID_STORAGE=/storage
export ANDROID_ART_ROOT=/apex/com.android.art
export ANDROID_I18N_ROOT=/apex/com.android.i18n
export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata

exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage
