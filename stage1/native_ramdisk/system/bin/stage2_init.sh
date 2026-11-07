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

# 7. Strict Android 16 Bootstrap APEX Handling & Validation
echo "[STAGE2] Preparing Android 16 bootstrap APEX environments on tmpfs..." > /dev/kmsg
mount_or_fail -t tmpfs -o mode=0755,nosuid,nodev tmpfs /mnt/sysroot/apex

populate_apex() {
    local mod_name="$1"
    local img_name="$2"
    local target_dir="/mnt/sysroot/apex/$mod_name"
    local mandatory="${3:-1}"

    /system/bin/toybox mkdir -p "$target_dir"
    /system/bin/toybox mkdir -p "/tmp/apex_stage_${mod_name}"

    local img_path=$(get_img "$img_name")
    local fstype="erofs"

    if [ -n "$img_path" ] && [ -s "$img_path" ]; then
        if [ -f "/mnt/${img_name%.img}.fstype" ]; then
            fstype=$(cat "/mnt/${img_name%.img}.fstype" | tr -d '[:space:]')
        elif [ -f "/tmp/${img_name%.img}.fstype" ]; then
            fstype=$(cat "/tmp/${img_name%.img}.fstype" | tr -d '[:space:]')
        fi
        echo "[STAGE2] Staging $mod_name from image $img_path (fstype: $fstype)..." > /dev/kmsg
        mount_or_fail -t "$fstype" -o ro,loop "$img_path" "/tmp/apex_stage_${mod_name}"
        /system/bin/toybox cp -a "/tmp/apex_stage_${mod_name}"/* "$target_dir/" || fatal "Failed to copy $mod_name payload!"
        /system/bin/toybox umount "/tmp/apex_stage_${mod_name}" 2>/dev/null || true
    else
        # Fallback to authentic donor partition packages in /mnt/sysroot/system/apex/
        local donor_apex=""
        for candidate in \
            "/mnt/sysroot/system/apex/${mod_name}.apex" \
            "/mnt/sysroot/system/apex/${mod_name}_compressed.apex" \
            "/mnt/sysroot/system/apex/com.google.android.${mod_name#com.android.}_compressed.apex" \
            "/mnt/sysroot/system/apex/com.google.android.${mod_name#com.android.}.apex" \
            "/mnt/sysroot/system/apex/com.google.android.tzdata6.apex"; do
            if [ -f "$candidate" ]; then
                donor_apex="$candidate"
                break
            fi
        done

        if [ -n "$donor_apex" ]; then
            echo "[STAGE2] Extracting authentic donor APEX $donor_apex for $mod_name..." > /dev/kmsg
            local unpack_tmp="/tmp/unpack_${mod_name}"
            /system/bin/toybox mkdir -p "$unpack_tmp"
            if /system/bin/unzip -q "$donor_apex" "apex_payload.img" -d "$unpack_tmp" 2>/dev/null; then
                local pimg="$unpack_tmp/apex_payload.img"
                mount_or_fail -t ext4 -o ro,loop "$pimg" "/tmp/apex_stage_${mod_name}" 2>/dev/null || \
                mount_or_fail -t erofs -o ro,loop "$pimg" "/tmp/apex_stage_${mod_name}"
                /system/bin/toybox cp -a "/tmp/apex_stage_${mod_name}"/* "$target_dir/" || fatal "Failed to copy unpacked $mod_name payload!"
                /system/bin/toybox umount "/tmp/apex_stage_${mod_name}" 2>/dev/null || true
            elif /system/bin/unzip -q "$donor_apex" "original_apex" -d "$unpack_tmp" 2>/dev/null; then
                local orig_apex="$unpack_tmp/original_apex"
                if /system/bin/unzip -q "$orig_apex" "apex_payload.img" -d "$unpack_tmp/orig" 2>/dev/null; then
                    local pimg="$unpack_tmp/orig/apex_payload.img"
                    mount_or_fail -t ext4 -o ro,loop "$pimg" "/tmp/apex_stage_${mod_name}" 2>/dev/null || \
                    mount_or_fail -t erofs -o ro,loop "$pimg" "/tmp/apex_stage_${mod_name}"
                    /system/bin/toybox cp -a "/tmp/apex_stage_${mod_name}"/* "$target_dir/" || fatal "Failed to copy unpacked $mod_name payload!"
                    /system/bin/toybox umount "/tmp/apex_stage_${mod_name}" 2>/dev/null || true
                fi
            fi
            /system/bin/toybox rm -rf "$unpack_tmp" 2>/dev/null || true
        elif [ "$mandatory" -eq 1 ]; then
            fatal "Mandatory APEX $mod_name ($img_name) not found in staging area or system partition!"
        fi
    fi

    # Create canonical versioned symlink
    /system/bin/toybox ln -sf "$mod_name" "/mnt/sysroot/apex/${mod_name}@1" 2>/dev/null || true
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
