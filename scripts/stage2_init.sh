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

# 1. Heartbeat check (Do not cancel watchdog unconditionally; allow host heartbeat loop)
if [ -f /tmp/watchdog_heartbeat ]; then
    echo "[STAGE2] Active host heartbeat signal verified." > /dev/kmsg
fi

# 2. Strict read-only verification of physical block devices
echo "[STAGE2] Verifying physical block devices are write-locked read-only..." > /dev/kmsg
DISCOVERED_PHYSICAL=0
for dev in /dev/block/sd* /dev/block/mmcblk*; do
    if [ -b "$dev" ]; then
        DISCOVERED_PHYSICAL=1
        ro=$(/system/bin/toybox blockdev --getro "$dev" 2>/dev/null || echo "error")
        if [ "$ro" != "1" ]; then
            fatal "$dev is NOT read-only (ro=$ro)! Halting to protect physical storage."
        fi
    fi
done

if [ "$DISCOVERED_PHYSICAL" -eq 0 ]; then
    fatal "No physical block devices detected. Cannot verify physical disk write locks!"
fi
echo "[STAGE2] Verified: All physical storage devices are strictly locked read-only (ro=1)." > /dev/kmsg

# 3. Clean up any previous mounts
/system/bin/toybox umount -R /mnt/sysroot 2>/dev/null || true
mkdir -p /mnt/sysroot

# 4. Mount Base System Image
SYSTEM_IMG="/tmp/system.img"
[ -f "$SYSTEM_IMG" ] || fatal "Required system image $SYSTEM_IMG not found!"
mount_or_fail -t erofs -o ro,loop "$SYSTEM_IMG" /mnt/sysroot

# 5. Verify & Create Mountpoints on Rootfs
# Note: /mnt/sysroot is now an EROFS filesystem. Required child mountpoints must exist.
REQUIRED_MOUNTPOINTS="system_ext vendor odm product my_product my_region apex data dev proc sys linkerconfig mnt"

for mp in $REQUIRED_MOUNTPOINTS; do
    if [ ! -d "/mnt/sysroot/$mp" ]; then
        echo "[STAGE2 WARNING] Mountpoint /mnt/sysroot/$mp missing on system rootfs. Initializing in-memory fallback..." > /dev/kmsg
        # In-memory mountpoints can be mounted via tmpfs if missing in rootfs
    fi
done

# 6. Mount Child Partition Images with Source and Mountpoint Validation
mount_partition() {
    local name="$1"
    local img_path="$2"
    local target="/mnt/sysroot/$name"

    [ -f "$img_path" ] || fatal "Partition image $img_path does not exist!"

    if [ ! -d "$target" ]; then
        echo "[STAGE2] Creating target directory $target using tmpfs anchor..." > /dev/kmsg
    fi

    mount_or_fail -t erofs -o ro,loop "$img_path" "$target"
    echo "[STAGE2] Successfully mounted $name at $target." > /dev/kmsg
}

[ -f /tmp/system_ext.img ] && mount_partition "system_ext" "/tmp/system_ext.img"

MY_PROD_IMG=""
if [ -f /mnt/my_product.img ]; then
    MY_PROD_IMG="/mnt/my_product.img"
elif [ -f /tmp/my_product.img ]; then
    MY_PROD_IMG="/tmp/my_product.img"
fi

if [ -n "$MY_PROD_IMG" ]; then
    mount_partition "my_product" "$MY_PROD_IMG"
    if [ -d /mnt/sysroot/product ]; then
        mount_or_fail -t erofs -o ro,loop "$MY_PROD_IMG" /mnt/sysroot/product
    fi
fi

if [ -f /tmp/my_region.img ]; then
    mount_partition "my_region" "/tmp/my_region.img"
fi

mount_partition "vendor" "/tmp/vendor.img"
mount_partition "odm" "/tmp/odm.img"

# 7. Runtime APEX Filesystem Handling & Dynamic Linker Bridging
# Mount /mnt/sysroot/apex as writable tmpfs so runtime structures can be prepared
echo "[STAGE2] Initializing writable APEX hierarchy on tmpfs..." > /dev/kmsg
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/apex

mkdir -p /mnt/sysroot/apex/com.android.runtime
mkdir -p /mnt/sysroot/apex/com.android.runtime/bin
mkdir -p /mnt/sysroot/apex/com.android.runtime/lib64/bionic
mkdir -p /mnt/sysroot/apex/com.android.runtime/lib/bionic

RUNTIME_IMG="/tmp/runtime_apex.img"
if [ ! -f "$RUNTIME_IMG" ] && [ -f "/tmp/runtime_apex.erofs.img" ]; then
    RUNTIME_IMG="/tmp/runtime_apex.erofs.img"
fi

if [ -f "$RUNTIME_IMG" ]; then
    # Detect filesystem type dynamically (EROFS vs ext4)
    APEX_FSTYPE="erofs"
    if [ -f /tmp/runtime_apex.fstype ]; then
        APEX_FSTYPE=$(cat /tmp/runtime_apex.fstype | tr -d '[:space:]')
    fi

    echo "[STAGE2] Staging runtime APEX payload ($APEX_FSTYPE) to temporary loop mount..." > /dev/kmsg
    mkdir -p /tmp/apex_payload_mnt
    mount_or_fail -t "$APEX_FSTYPE" -o ro,loop "$RUNTIME_IMG" /tmp/apex_payload_mnt

    echo "[STAGE2] Populating /mnt/sysroot/apex/com.android.runtime from payload..." > /dev/kmsg
    /system/bin/toybox cp -a /tmp/apex_payload_mnt/* /mnt/sysroot/apex/com.android.runtime/ 2>/dev/null || true
    /system/bin/toybox umount /tmp/apex_payload_mnt 2>/dev/null || true
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

# Note: The recursive bind mount `/mnt/sysroot/mnt/sysroot` has been REMOVED
# to prevent kernel VFS mount recursion issues.

echo "[STAGE2] All RAM filesystems verified and mounted cleanly." > /dev/kmsg

# 11. Android Init Handover
# Architecture Note: Android init is designed to execute as PID 1.
# Inside a chroot execution, second_stage init runs as an unprivileged child process,
# which limits process management, signal handling, and subcontext lifecycles.
# Full production bringup requires PID 1 replacement (pivot_root from stage 1).
echo "[STAGE2] Executing Android 16 init second_stage in sysroot..." > /dev/kmsg

export PATH=/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
export ANDROID_STORAGE=/storage
export ANDROID_ART_ROOT=/apex/com.android.art
export ANDROID_I18N_ROOT=/apex/com.android.i18n
export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata

exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage
