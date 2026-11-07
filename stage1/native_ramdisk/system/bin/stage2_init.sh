#!/system/bin/sh
# ==============================================================================
# stage2_init.sh - Stage-2 Android 16 Bringup in RAM on OnePlus 7T (HD1901)
# Target: OnePlus 7T HD1901 (hotdogb), Snapdragon 855+ / SM8150, Adreno 640.
# 100% Volatile RAM resident, Zero Physical Storage Writes.
# Handles strict OverlayFS root, mandatory partition verification,
# canonical AOSP APEX versioned directories & active symlinks, display
# diagnostics for 60Hz AMOLED panel, watchdog handover, and single PID 1 handover.
# ==============================================================================

set -e

# Disable kernel printk ratelimiting so no init diagnostic lines are suppressed
echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null || true

echo "=== STAGE-2 RAM BRINGUP STARTING ===" > /dev/kmsg

# Tactile feedback: haptic vibration pulse
echo 300 > /sys/class/leds/vibrator/duration 2>/dev/null || true
echo 1 > /sys/class/leds/vibrator/activate 2>/dev/null || true

# Helper for fatal errors - logs to kmsg and halts safely without disarming watchdog
fatal() {
    echo "[STAGE2 FATAL] $1" > /dev/kmsg
    echo "[STAGE2 FATAL] $1" >&2
    echo "[STAGE2 FATAL] System halted in safe RAM state. Safety watchdog will reboot to bootloader." > /dev/kmsg
    while true; do
        /system/bin/toybox sleep 60
    done
}

# Helper to execute and verify mount
mount_or_fail() {
    echo "[STAGE2] Mounting: $*" > /dev/kmsg
    /system/bin/toybox mount "$@" || fatal "Failed mandatory mount: mount $*"
}

# Helper for non-fatal mount attempt (for multi-filesystem fallback)
try_mount() {
    echo "[STAGE2] Attempting mount: $*" > /dev/kmsg 2>/dev/null || true
    /system/bin/toybox mount "$@" 2>/dev/null
}

# Background device-side heartbeat for Stage-2 watchdog monitoring
(
    while [ ! -f /mnt/stage2_done ] && [ ! -f /tmp/stage2_done ]; do
        echo "heartbeat" > /mnt/stage2_heartbeat 2>/dev/null || true
        /system/bin/toybox sleep 2 2>/dev/null || sleep 2
    done
) &
STAGE2_HB_PID=$!
trap 'kill -9 "$STAGE2_HB_PID" 2>/dev/null || true' EXIT

# 1. Heartbeat check (Validates regular file, rejects symlinks and directories)
if ([ -f /mnt/watchdog_heartbeat ] && [ ! -L /mnt/watchdog_heartbeat ]) || \
   ([ -f /tmp/watchdog_heartbeat ] && [ ! -L /tmp/watchdog_heartbeat ]); then
    echo "[STAGE2] Active host heartbeat signal verified." > /dev/kmsg
fi

# 2. Strict read-only verification of physical block devices and child partitions
echo "[STAGE2] Verifying physical block devices and child partitions are write-locked read-only..." > /dev/kmsg
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

        # Verify all child partitions
        for pdir in "$bdir"/"$bname"*; do
            [ -d "$pdir" ] || continue
            pname=$(basename "$pdir")
            part_node="/dev/block/$pname"
            if [ -b "$part_node" ]; then
                DISCOVERED_PHYSICAL=$((DISCOVERED_PHYSICAL + 1))
                pro=$(/system/bin/toybox blockdev --getro "$part_node" 2>/dev/null || echo "0")
                if [ "$pro" != "1" ]; then
                    fatal "Partition $part_node is NOT read-only (ro=$pro)! Halting to protect physical storage."
                fi
            fi
        done
    fi
done

if [ "$DISCOVERED_PHYSICAL" -eq 0 ]; then
    fatal "No physical block devices detected. Cannot verify physical disk write locks!"
fi

# Verify no physical devices or partitions are mounted writable
if /system/bin/toybox mount | grep -E "^/dev/block/(sd|mmcblk)" | grep -E "([ ,(]rw[ ,)]|,rw$)"; then
    fatal "CRITICAL SAFETY VIOLATION: Detected writable physical partition mount!"
fi

# Verify /mnt and /tmp are mounted as RAM-backed tmpfs
if ! /system/bin/toybox mount | grep -q " /mnt type tmpfs "; then
    fatal "CRITICAL SAFETY FAILURE: Staging directory /mnt is not mounted as RAM tmpfs!"
fi

# Verify /mnt has sufficient capacity for staged images
MNT_FREE_MB=$(/system/bin/toybox df -m /mnt 2>/dev/null | /system/bin/toybox awk 'NR>1 {print $4}' | /system/bin/toybox tr -d '[:space:]')
if [ -n "$MNT_FREE_MB" ] && [ "$MNT_FREE_MB" -lt 6000 ] 2>/dev/null; then
    echo "[STAGE2 WARNING] /mnt has only ${MNT_FREE_MB}MB free space, recommended >= 6000MB." > /dev/kmsg
fi

echo "[STAGE2] Verified: All $DISCOVERED_PHYSICAL physical storage devices and partitions are strictly locked read-only (ro=1)." > /dev/kmsg

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

# 7. Strict Android 16 Bootstrap APEX Handling & Canonical Versioned Directories
echo "[STAGE2] Preparing Android 16 bootstrap APEX environments on tmpfs..." > /dev/kmsg
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/apex

populate_apex() {
    local mod_name="$1"
    local img_name="$2"
    local mandatory="${3:-1}"

    # 1. Resolve image path
    local img_path=$(get_img "$img_name")
    if [ "$mandatory" -eq 1 ]; then
        if [ -z "$img_path" ] || [ ! -s "$img_path" ]; then
            fatal "Mandatory APEX image $img_name is missing or 0 bytes!"
        fi
    fi

    # 2. Extract and strictly validate version code
    local version=""
    if [ -f "/mnt/${img_name%.img}.version" ]; then
        version=$(cat "/mnt/${img_name%.img}.version" | tr -d '[:space:]')
    elif [ -f "/tmp/${img_name%.img}.version" ]; then
        version=$(cat "/tmp/${img_name%.img}.version" | tr -d '[:space:]')
    fi

    if [ "$mandatory" -eq 1 ]; then
        if [ -z "$version" ]; then
            fatal "Mandatory APEX metadata .version for $mod_name ($img_name) is missing or empty!"
        fi
        if ! echo "$version" | grep -qE '^[1-9][0-9]*$'; then
            fatal "Mandatory APEX $mod_name has invalid non-numeric or non-positive version code: '$version'!"
        fi
    else
        [ -z "$version" ] && version="1"
    fi

    # 3. Extract and strictly validate filesystem type
    local fstype=""
    if [ -f "/mnt/${img_name%.img}.fstype" ]; then
        fstype=$(cat "/mnt/${img_name%.img}.fstype" | tr -d '[:space:]')
    elif [ -f "/tmp/${img_name%.img}.fstype" ]; then
        fstype=$(cat "/tmp/${img_name%.img}.fstype" | tr -d '[:space:]')
    fi

    if [ "$mandatory" -eq 1 ]; then
        if [ -z "$fstype" ]; then
            fatal "Mandatory APEX metadata .fstype for $mod_name ($img_name) is missing or empty!"
        fi
        if [ "$fstype" != "erofs" ] && [ "$fstype" != "ext4" ]; then
            fatal "Mandatory APEX $mod_name has unsupported filesystem type '$fstype' (must be erofs or ext4)!"
        fi
    else
        [ -z "$fstype" ] && fstype="erofs"
    fi

    # 4. Canonical AOSP structure:
    # Payload directory: /mnt/sysroot/apex/${mod_name}@${version}
    # Active symlink:    /mnt/sysroot/apex/${mod_name} -> ${mod_name}@${version}
    local versioned_dir="/mnt/sysroot/apex/${mod_name}@${version}"
    local active_symlink="/mnt/sysroot/apex/${mod_name}"

    /system/bin/toybox mkdir -p "$versioned_dir"
    /system/bin/toybox mkdir -p "/tmp/apex_stage_${mod_name}"

    echo "[STAGE2] Staging $mod_name to $versioned_dir from image $img_path (fstype: $fstype, version: $version)..." > /dev/kmsg
    if ! try_mount -t "$fstype" -o ro,loop "$img_path" "/tmp/apex_stage_${mod_name}"; then
        fatal "Failed to mount $mod_name payload image from $img_path with filesystem $fstype!"
    fi

    /system/bin/toybox cp -a "/tmp/apex_stage_${mod_name}"/* "$versioned_dir/" || fatal "Failed to copy $mod_name payload to $versioned_dir!"
    /system/bin/toybox umount "/tmp/apex_stage_${mod_name}" 2>/dev/null || true

    # 5. Establish canonical active symlink pointing to versioned payload directory
    /system/bin/toybox rm -rf "$active_symlink" 2>/dev/null || true
    (cd /mnt/sysroot/apex && /system/bin/toybox ln -sfn "${mod_name}@${version}" "$mod_name")

    # Verify active symlink points to actual versioned directory
    local symlink_target
    symlink_target=$(readlink "$active_symlink" 2>/dev/null || true)
    if [ "$symlink_target" != "${mod_name}@${version}" ]; then
        fatal "Active symlink $active_symlink does not point to ${mod_name}@${version} (points to '$symlink_target')!"
    fi
    if [ ! -d "$active_symlink" ]; then
        fatal "Active symlink $active_symlink does not resolve to a directory!"
    fi

    # Establish backward-compatibility convenience link @1 if version != 1
    if [ "$version" != "1" ]; then
        (cd /mnt/sysroot/apex && /system/bin/toybox ln -sfn "${mod_name}@${version}" "${mod_name}@1" 2>/dev/null || true)
    fi
}

# Populate all 4 required Android bootstrap APEX modules
populate_apex "com.android.runtime" "runtime_apex.img" 1
populate_apex "com.android.art" "art_apex.img" 1
populate_apex "com.android.i18n" "i18n_apex.img" 1
populate_apex "com.android.tzdata" "tzdata_apex.img" 1

# Strict Validation of Authentic Runtime Bionic Binaries & Libraries
[ -f /mnt/sysroot/apex/com.android.runtime/bin/linker64 ] || fatal "Bionic linker64 is MISSING from runtime APEX!"
[ -x /mnt/sysroot/apex/com.android.runtime/bin/linker64 ] || fatal "Bionic linker64 is not executable in runtime APEX!"
[ -f /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libc.so ] || fatal "Bionic libc.so is MISSING from runtime APEX!"
[ -f /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libm.so ] || fatal "Bionic libm.so is MISSING from runtime APEX!"
[ -f /mnt/sysroot/apex/com.android.runtime/lib64/bionic/libdl.so ] || fatal "Bionic libdl.so is MISSING from runtime APEX!"

# Strict Validation of Authentic ART, I18N, and TZDATA Modules
[ -f /mnt/sysroot/apex/com.android.art/lib64/libart.so ] || fatal "ART libart.so is MISSING from art APEX!"
[ -f /mnt/sysroot/apex/com.android.i18n/lib64/libandroidicu.so ] || [ -f /mnt/sysroot/apex/com.android.i18n/lib64/libicuuc.so ] || fatal "ICU libraries MISSING from i18n APEX!"
[ -f /mnt/sysroot/apex/com.android.tzdata/etc/tz/tzdata ] || [ -f /mnt/sysroot/apex/com.android.tzdata/etc/icu/icu_tzdata.dat ] || fatal "Timezone data MISSING from tzdata APEX!"

echo "[STAGE2] Strict verification passed: Authentic Bionic, ART, I18N, and TZDATA APEX environments ready." > /dev/kmsg

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

# Ensure property workspace is accessible to root-namespace watchdog and diagnostics
/system/bin/toybox mkdir -p /dev/__properties__ /dev/socket
/system/bin/toybox mount --bind /mnt/sysroot/dev/__properties__ /dev/__properties__ 2>/dev/null || true
/system/bin/toybox mount --bind /mnt/sysroot/dev/socket /dev/socket 2>/dev/null || true

# Graphics compatibility node
/system/bin/toybox mkdir -p /mnt/sysroot/dev/graphics
/system/bin/toybox ln -s /dev/dri/card0 /mnt/sysroot/dev/graphics/fb0 2>/dev/null || true

# 11. Display Subsystem Diagnostics & AMOLED Configuration
echo "[STAGE2] Running display subsystem diagnostics..." > /dev/kmsg
if [ -c /mnt/sysroot/dev/dri/card0 ] || [ -c /dev/dri/card0 ]; then
    echo "[STAGE2] DRM display controller verified: /dev/dri/card0 present." > /dev/kmsg
else
    echo "[STAGE2 WARNING] DRM /dev/dri/card0 node missing! SurfaceFlinger display composition may fail." > /dev/kmsg
fi

if [ -c /mnt/sysroot/dev/kgsl-3d0 ] || [ -c /dev/kgsl-3d0 ]; then
    echo "[STAGE2] Adreno 640 GPU controller verified: /dev/kgsl-3d0 present." > /dev/kmsg
else
    echo "[STAGE2 WARNING] Adreno /dev/kgsl-3d0 node missing! 3D GPU acceleration may fall back to swiftshader." > /dev/kmsg
fi

# AMOLED Backlight status
if [ -f /sys/class/backlight/panel0-backlight/brightness ]; then
    echo 200 > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null || true
    echo "[STAGE2] Samsung AMOLED DSI panel backlight set to 200." > /dev/kmsg
fi

# Verify SurfaceFlinger binary presence
if [ -f /mnt/sysroot/system/bin/surfaceflinger ]; then
    echo "[STAGE2] SurfaceFlinger binary verified: /system/bin/surfaceflinger." > /dev/kmsg
fi
if [ -f /mnt/sysroot/vendor/bin/hw/android.hardware.graphics.composer@2.4-service ] || \
   [ -f /mnt/sysroot/vendor/bin/hw/vendor.qti.hardware.display.composer-service ]; then
    echo "[STAGE2] Hardware Composer service binary verified in vendor partition." > /dev/kmsg
fi

# 12. Final Mount Layout Verification
echo "[STAGE2] Verifying complete mount layout in /proc/mounts..." > /dev/kmsg
MANDATORY_MOUNTS="/mnt/sysroot /mnt/sysroot/system_ext /mnt/sysroot/vendor /mnt/sysroot/odm /mnt/sysroot/product /mnt/sysroot/apex /mnt/sysroot/data /mnt/sysroot/dev /mnt/sysroot/proc /mnt/sysroot/sys /mnt/sysroot/linkerconfig"
for target in $MANDATORY_MOUNTS; do
    if ! /system/bin/toybox grep -q " $target " /proc/mounts 2>/dev/null; then
        fatal "Final mount layout verification failed: $target is NOT mounted in /proc/mounts!"
    fi
done
echo "[STAGE2] All mandatory filesystems verified in /proc/mounts." > /dev/kmsg

# 13. Stage-2 Completion & Watchdog Handover
echo "[STAGE2] Signaling Stage-2 bringup completion to watchdog (/mnt/stage2_done)..." > /dev/kmsg
echo "done" > /mnt/stage2_done 2>/dev/null || true
echo "done" > /tmp/stage2_done 2>/dev/null || true
kill -9 "$STAGE2_HB_PID" 2>/dev/null || true

# Optional explicit disarm override
if [ "${DISARM_WATCHDOG:-0}" = "1" ]; then
    echo "cancel" > /mnt/watchdog_cancel 2>/dev/null || true
    echo "cancel" > /tmp/watchdog_cancel 2>/dev/null || true
fi

echo "[STAGE2] Handing over to Android init health monitor (watching sys.boot_completed=1)..." > /dev/kmsg

# 14. Android Init Handover (PID 1 preserved via exec)
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
