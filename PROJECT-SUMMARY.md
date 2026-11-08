# OxygenOS 16 Port to OnePlus 7T (HD1901) — Project Summary

> **Document Version**: 2.12.0 (Stage-2 Independent Block-Node Identity Verification, Watchdog Two-Copy Inventory Synchronization, Atomic Stage-2 Updates, Disposable Loop & Block-Device Test Tier, Fail-Closed Storage Audit & Protection, 6-Checkpoint Revalidation, Automated Test Suite: 234 Passed, 1 Skipped Locally [219 Simulated Python Pass + 1 Unprivileged Loop Class Skipped, 15 Go Pass; 224 Defined Python Test Methods + 15 Go = 239 Total Test Methods], Rebuilt Boot Images Passing 36/36 Static Safety Auditor Checks, Ramdisks Passing 34/34)  
> **Target Device**: OnePlus 7T (`HD1901` / `hotdogb`, Snapdragon 855+ / SM8150-AC, 8 GB RAM)  
> **Source ROM**: OxygenOS 16 / Android 16 (`BP2A.250605.015`, SDK 36 / `Baklava`, OnePlus 9 `lemonade` / `LE2113_16.0.10.500(EX01)` EEA donor, `ota_full-LE2113_16.0.10.500.zip`, SHA-256 `5ea5f120a2bce5eb98bd2a5d1aca872f5888903825861142bd0900772b8d0844`)  
> **Base OS on Device**: crDroid (Android 16 / LineageOS 23.2 base, FBE Encrypted)  
> **Primary Safety Mandate**: **Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to device-level verification.**

---

## 1. Executive Summary & Core Mandate

The objective of this project is to port and run OxygenOS 16 (Android 16 / SDK 36) on the OnePlus 7T purely in volatile memory (RAM) via `fastboot boot`, featuring:
1. **Google Photos Unlimited Original Backup Spoof** (`pixel_2016_experience.xml` + `NEXUS_PRELOAD`).
2. **Play Integrity Profile Template** (`pif.json` release-keys profile for `HD1901`).
3. **Display Hardware Handover** (`SurfaceFlinger` + Qualcomm DRM `msm_drm` compositor on AMOLED display with fixed 60Hz replacement panel configuration).
4. **Android 16 Bootstrap APEX Architecture** (`com.android.runtime`, `com.android.art`, `com.android.i18n`, `com.android.tzdata`).

### The Non-Negotiable Safety Directive
Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to device-level verification:
* **Absolute Command Banning**: No `fastboot flash`, `erase`, `format`, `wipe`, `set_active`, logical partition modification, or raw block writes (`dd of=`, `mount -o rw`).
* **Hardware-Level Write Locks**: Every physical block device (`/sys/block/*`) and child partition (`sda1`..`sda32`) is dynamically write-locked read-only (`blockdev --setro`) before staging begins, and continuously monitored by a background guard loop.
* **Ephemeral Volatile State**: `/data`, `/mnt`, and `/tmp` reside strictly in RAM `tmpfs` and vanish upon reboot, keeping crDroid and user data 100% intact.

---

## 2. Completed Critical Repairs & Architectural Enhancements

### 1. Watchdog Heartbeat Protocol Harmonization
* **Problem**: The runner touched `/mnt/watchdog_heartbeat` (0 bytes), while Stage-1 checked `[ -s "$FILE" ]` (requiring non-empty files), causing valid heartbeats to be ignored.
* **Solution**: Implemented `scripts/watchdog.sh` modular supervisor. It accepts valid regular files (`[ -f ] && [ ! -L ]`), whether empty or token-bearing, and immediately consumes them (`rm -f`) to prevent stale heartbeat retention.
* **Security**: Strictly rejects directory and symlink heartbeat objects without resetting the timer.
* **Disarm**: Recognizes regular file `/mnt/watchdog_cancel`, extending countdown to 86400s.
* **Verification**: Created dedicated test suite `tests/test_watchdog.py` covering all 10 protocol scenarios (10/10 PASS).

### 2. Android 16 Bootstrap APEX Architecture
* **Problem**: Stage-2 previously copied only `com.android.runtime`, leaving mandatory ART, I18N, and TZDATA environments missing while exporting their paths.
* **Solution**:
  * Implemented `extract_and_stage_apex()` in `scripts/build_stage2_erofs.sh` to extract all 4 bootstrap APEX modules from authentic donor packages in `work/system/system/apex/`:
    * `com.android.runtime.apex` -> `runtime_apex.img` (EROFS)
    * `com.google.android.art_compressed.apex` -> `art_apex.img` (EXT4, extracted from nested `original_apex`)
    * `com.android.i18n.apex` -> `i18n_apex.img` (EROFS)
    * `com.google.android.tzdata6.apex` -> `tzdata_apex.img` (EXT4)
  * Generated corresponding `.fstype` metadata files.
  * In `scripts/stage2_init.sh`, implemented `populate_apex()` supporting image staging and fallback extraction directly from donor packages.
  * Strictly validated authentic Bionic binaries (`linker64`, `libc.so`, `libm.so`, `libdl.so`), ART (`libart.so`), I18N (`libandroidicu.so`/`libicuuc.so`), and TZDATA (`tzdata`/`icu_tzdata.dat`), creating canonical `@1` symlinks.

### 3. Safety Auditor Repair (`tools/safe/audit-no-writes.sh`)
* **Problem**: Auditor previously referenced non-existent paths, risking false passes or failures.
* **Solution**:
  * Added dynamic entrypoint inspection: differentiates Loader ramdisk (`/init` shell script) and Native recovery ramdisk (`/system/bin/recovery`).
  * Enforces embedded script binary equality: verifies that `$RAMDISK_DIR/system/bin/stage2_init.sh` and `$RAMDISK_DIR/system/bin/watchdog.sh` match repository sources via `cmp -s`.
  * Audits all orchestration scripts and boot images for forbidden write commands, partition mounts, and watchdog supervision.
  * Returns strictly clean exit codes: 0 (`PASSED`), 1 (`FAILED`), 2 (`INCOMPLETE`).
  * Both `build/loader.img` and `build/stage1.img` pass 21/21 audit checks.

### 4. Physical Storage Partition-Level Protection
* **Problem**: Whole-disk protection (`/dev/block/sda`) left child partitions (`sda1`..`sda32`) without verified partition-level write locks.
* **Solution**:
  * In `stage1/loader_ramdisk/init`, `stage1/native_ramdisk/system/bin/recovery`, `scripts/stage2_init.sh`, and `tools/safe/run_stage2.sh`:
  * Dynamically scans `/sys/block/*` and all child partitions (`$bdir/$bname*`).
  * Applies `blockdev --setro` to both whole disks and child partitions.
  * Confirms `blockdev --getro == 1` across all discovered nodes.
  * Background guard loop in `recovery` periodically audits write-locks and executes `reboot bootloader` if any partition becomes writable.
  * Confirms live `/proc/mounts` table contains zero writable physical mounts.

### 5. ADB Safety Wrapper Hardening (`tools/safe/adb`)
* **Problem**: Arbitrary `REAL_ADB_BIN` overrides could potentially bypass restrictions in production.
* **Solution**:
  * Restricted `REAL_ADB_BIN` overrides: requires `OOS16_TEST_MODE=1` to allow non-standard binary paths; without it, only approved system directories (`/usr/bin`, `/bin`, `/usr/local/bin`) are permitted.
  * Added device-side symlink escape probe on push operations (`readlink -f <dest>`), rejecting destinations resolving outside approved RAM directories (`/tmp`, `/mnt`).
  * Implemented recursion check preventing wrapper self-invocation.

### 6. Atomic EROFS Publishing with Rollback Protection
* **Problem**: Interrupted builds could delete previous valid outputs, leaving an empty or corrupt directory.
* **Solution**:
  * `scripts/build_stage2_erofs.sh` builds all images in a temporary staging directory on the same filesystem.
  * Saves `.orig` backups of modified files (`build.prop`, `system_ext_property_contexts`) and tracks injected files, automatically reverting changes on failure via cleanup trap.
  * Generates and verifies `SHA256SUMS` in staging before publishing.
  * Atomically backs up existing `$OUT_DIR` to `.backup_images_$$` and restores it if publication fails.

### 7. Android PID 1 Preservation Chain
* **Problem**: Native recovery launched `/system/bin/recovery` as a child service (PID ~250), which ran `chroot /mnt/sysroot /system/bin/init second_stage`. This violated Android's `getpid() == 1` check and left recovery init running as a competing init process.
* **Solution**:
  * Unified both `loader_ramdisk` and `native_ramdisk` to run the Stage-1 supervisor directly as PID 1 (`/init`).
  * Used `exec /system/bin/sh /system/bin/stage2_init.sh` for Stage-1 to Stage-2 handover (preserving PID 1).
  * Used `exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage` for Android bringup (preserving PID 1).
  * Guaranteed zero competing init processes and authentic Android init lifecycle.

### 8. Dynamic Device Node Initialization via `ueventd` & `binderfs`
* **Problem**: The Stage-1 loader ramdisk mounted tmpfs on `/dev` with only 6 hardcoded nodes, omitting `ueventd` and `binderfs`, which left DRM graphics (`/dev/dri/card0`), Adreno 640 GPU (`/dev/kgsl-3d0`), and Binder nodes unpopulated.
* **Solution**:
  * Mount `/dev` with `devtmpfs` (with `tmpfs` fallback).
  * Mount `/dev/binderfs` and establish `/dev/binder`, `/dev/hwbinder`, `/dev/vndbinder` symlinks.
  * Establish canonical `/ueventd.rc` symlink to `/system/etc/ueventd.rc`.
  * Start `/system/bin/ueventd &` in background.
  * Trigger coldboot uevents across `/sys/bus/*/devices/*/uevent` and `/sys/class/*/*/uevent`.
  * Provide dynamic sysfs fallback scanner inspecting `dev` major:minor files to mknod `/dev/dri/card0`, `/dev/kgsl-3d0`, fb0, input event nodes.
  * Add explicit verification and diagnostic logging for critical nodes.

### 9. Canonical AOSP APEX Versioned Directory Structure
* **Problem**: Previous code staged files into `/apex/<mod>` and created backwards symlink `/apex/<mod>@1 -> <mod>`.
* **Solution**:
  * Corrected layout to authentic AOSP convention:
    * Payload directory: `/mnt/sysroot/apex/${mod_name}@${version}`
    * Active symlink: `/mnt/sysroot/apex/${mod_name} -> ${mod_name}@${version}`
  * Extracted authentic version codes directly from package manifests:
    * `com.android.runtime` -> version 1
    * `com.android.art` -> version 361501120
    * `com.android.i18n` -> version 1
    * `com.android.tzdata` -> version 361157000
  * Generated `${output_base}.version` metadata in build pipeline and staged onto device.

### 10. Display Bringup & Fixed 60Hz AMOLED Panel Support
* **Problem**: Replacement AMOLED display panel (`dsi_samsung_s6e3fc2x01_cmd_display`) requires fixed 60Hz refresh rate and backlight power-on.
* **Solution**:
  * Added panel backlight power-on in Stage 1 and Stage 2 (`echo 200 > /sys/class/backlight/panel0-backlight/brightness`).
  * Injected fixed 60Hz display properties into `vendor/vendor/build.prop`:
    * `ro.surface_flinger.game_default_frame_rate_override=60`
    * `ro.surface_flinger.enable_frame_rate_override=false`
    * `persist.sys.sf.native_mode=0`
    * `vendor.display.enable_optimize_refresh=1`
    * `debug.sf.frame_rate_multiple_threshold=60`
    * `ro.vendor.display.default_fps=60`
  * Added runtime diagnostics in `stage2_init.sh` for DRM card0, Adreno 640 KGSL, SurfaceFlinger, and Hardware Composer HAL.

### 11. Watchdog Lifecycle Transition & Handover
* **Problem**: Host runner previously exited immediately upon touching `/mnt/boot_now`, terminating the heartbeat loop while watchdog countdown continued without cancellation.
* **Solution**:
  * `run_stage2.sh` maintains active heartbeat until Stage-1 supervisor acknowledges and consumes the trigger.
  * `stage2_init.sh` disarms watchdog via regular file `/mnt/watchdog_cancel` only upon successful mounting and preparation immediately prior to Android init handover.
  * On any failure, `fatal()` halts without creating `watchdog_cancel`, guaranteeing automated reboot to bootloader.

### 12. Dynamic BinderFS Device Allocation (`binderfs_init`) & Standard Linux `dev_t` Encoding
* **Problem**: Fresh BinderFS mount points only create `/dev/binderfs/binder-control`. IPC devices (`binder`, `hwbinder`, `vndbinder`) do not exist automatically, causing Binder-dependent services to crash. Furthermore, naive bitshift `(maj << 8) | min` fails for major or minor device numbers $> 255$.
* **Solution**:
  * Implemented static ARM64 executable `src/binderfs_init` (with Go and C implementations in `src/`).
  * Implemented standard Linux 64-bit `dev_t` encoding matching glibc/sysmacros ABI:
    `(maj & 0xfff) << 8 | (min & 0xff) | ((maj & ~0xfff) << 32) | ((min & ~0xff) << 12)`.
  * Validated major and minor boundaries (`maj <= 0xfffff`), rejecting empty, non-numeric, or malformed sysfs device strings.
  * Checked every syscall return value (`Mknod`, `Chmod`, `Symlink`, `Remove`), refusing to overwrite existing unrelated files or directories.
  * Embedded into both `stage1/loader_ramdisk` and `stage1/native_ramdisk` at `/system/bin/binderfs_init`.

### 13. Watchdog 4-State Lifecycle Protocol & Health Monitoring
* **Problem**: Two-tier watchdog did not actively guard Stage 2 in RAM or monitor whether Android completed booting after `exec init second_stage`. Additionally, the 180s static timeout was insufficient for first-boot optimization.
* **Solution**:
  * Implemented atomic 4-state state machine in `scripts/watchdog.sh`:
    * `STAGE1_WAIT` (60s): Monitors host heartbeats until Stage-1 consumes `/mnt/boot_now` and touches `/mnt/stage1_ack`.
    * `STAGE2_RUNNING` (120s): Monitors RAM staging, accepting either device `/mnt/stage2_heartbeat` or host heartbeats until Stage 2 touches `/mnt/stage2_done`.
    * `HEALTH_MONITOR` (Configurable 600s default for first boot): Monitors Android second-stage init; polls Android property `sys.boot_completed=1` via chroot `/mnt/sysroot /system/bin/getprop` and root property bind-mounts. Exits cleanly (code 0) on success; triggers emergency reboot on timeout.
    * `DISARMED`: Atomic cancellation via regular file `/mnt/watchdog_cancel`.
  * State transitions are written atomically via temporary file and `mv -f` to prevent partial state reads.

### 14. Hardened Protobuf APEX Manifest Extraction & Strict Device-Side Validation
* **Problem**: Silent fallbacks to `version="1"` masked corrupted or missing APEX packages. Protobuf parsing without varint length bounds or strict UTF-8 checking risked parsing errors on compressed packages.
* **Solution**:
  * Hardened `tools/extract_apex_info.py` with protobuf varint/tag decoder:
    * Rejects tag 0, varints $> 10$ bytes, and invalid wire types.
    * Rejects length-delimited payloads that exceed buffer bounds.
    * Enforces strict UTF-8 decoding and package identifier syntax validation.
    * Safely unpacks compressed APEX packages (`original_apex`) with `BadZipFile` handling.
  * In `scripts/stage2_init.sh`:
    * Eliminated all silent fallback versions.
    * Validates that `.version` exists and matches `^[1-9][0-9]*$`.
    * Validates that `.fstype` exists and matches `erofs` or `ext4`.
    * Staged in authentic versioned directories `/mnt/sysroot/apex/${mod_name}@${version}` and active symlinks.

### 15. Volatile RAM Peak-Memory Budgeting (Fail-Closed)
* **Problem**: Staging 3.3 GB of disk images in RAM tmpfs without reliable `df` parsing risked out-of-memory kernel panics or false passes on empty output.
* **Solution**:
  * In `tools/safe/run_stage2.sh`:
    * Sized staged images with exact upward integer rounding: `TOTAL_STAGED_MB=$(((TOTAL_STAGED_BYTES + 1048575) / 1048576))`.
    * Verified `/mnt` is tmpfs using `/proc/mounts`.
    * Reliably parsed and validated numeric free space from `df -m /mnt`, failing closed on empty or invalid output.
    * Verified `MemTotal >= 6500MB` (8 GB target verification) and `MemAvailable >= REQUIRED_RAM_MB` (~6,372 MB peak budget).
    * Extended monitoring loop (`OOS16_WAIT_FOR_BOOT=1`) continues petting the safety watchdog heartbeat while awaiting `sys.boot_completed=1` or `watchdog_state=BOOT_COMPLETED`.

### 16. Device-Side Fail-Closed RAM Validation (`scripts/stage2_init.sh`)
* **Problem**: Previous `/mnt` check warned if free space was below 6000 MB and did not calculate actual image sizes or abort on empty/failed `df` output.
* **Solution**:
  * Replaced warning with strict fail-closed validation: verifies `/mnt` and `/tmp` are mounted as `tmpfs`.
  * Computes `_STAGED_BYTES` by summing exact byte sizes of all staged `.img` files and adding 512 MB OverlayFS upper/work reserve.
  * Rejects empty or malformed `df -m /mnt` output and aborts immediately before mounting or copying if available capacity cannot be verified.
  * Reads `/proc/meminfo` to verify `MemAvailable` exceeds the calculated required budget (`_STAGED_MB + _EXP_APEX_MB + 1024 + 512 + 1536 + 256 MB`).
  * Enforces pre-copy free memory validation on `/mnt/sysroot/apex` before copying each APEX payload.

### 17. Explicit Product and My_Product Mount Selection (`scripts/stage2_init.sh`)
* **Problem**: `REQUIRED_MOUNTPOINTS` pre-created directory `/mnt/sysroot/my_product`. Later, `if [ -d /mnt/sysroot/my_product ]` was used as a condition to mount, which always evaluated true and resulted in double-mounting `product.img` at `my_product` when no separate image existed.
* **Solution**:
  * Eliminated directory presence check as evidence for image presence.
  * Explicitly checks for distinct file presence (`[ -n "$MY_PROD_IMG" ] && [ "$MY_PROD_IMG" != "$PRODUCT_IMG" ]`).
  * Mounts `my_product.img` only when independently present; leaves `/mnt/sysroot/my_product` as empty overlay directory otherwise.
  * Never silently double-mounts single product images into both partitions.

### 18. Hardened BinderFS Device-Number Validation & Syscall Safety (`src/binderfs_init.go`)
* **Problem**: Minor numbers were not bounded separately from major; nil dereference on `st.Rdev` occurred when `syscall.Stat_t` assertion failed; existing char devices and symlinks were not verified by device number.
* **Solution**:
  * Enforced strict minor validation `min <= 0xfffff` (Linux 20-bit limit) in both `mkdev` and `parseSysfsDev`.
  * Fixed nil dereference by verifying `ok && st != nil` before checking `st.Rdev`.
  * Compares actual `rdev` against expected major:minor for existing char devices, refusing to overwrite conflicting nodes.
  * Verifies resolved symlink target is a char device with matching `rdev`.
  * Tracks newly allocated binderfs nodes and symlinks, rolling them back completely on partial initialization failure.
  * Added 8 comprehensive Go unit tests covering boundary values, overflow, conflicting char devices, and idempotency.

### 19. Simultaneous Source & Expanded APEX RAM Budget Calculation (`tools/safe/run_stage2.sh` & `scripts/build_stage2_erofs.sh`)
* **Problem**: Staging counted only compressed image sizes, ignoring that both source APEX images in `/mnt` and expanded payloads in `/mnt/sysroot/apex` reside simultaneously in RAM.
* **Solution**:
  * `scripts/build_stage2_erofs.sh` extracts uncompressed payloads and records exact byte counts into `*.expanded_size` metadata files, validated in `SHA256SUMS`.
  * `tools/safe/run_stage2.sh` aggregates measured expanded APEX payload sizes (`TOTAL_EXPANDED_APEX_MB`) alongside staged partition images, `/data` (1024 MB), overlay (512 MB), kernel reserve (1536 MB), and safety headroom (256 MB).
  * Validates both `/mnt` tmpfs free space and device-wide `MemAvailable` independently.

### 20. Strengthened Watchdog Lifecycle & Hardened APEX Protobuf/ZIP Limits
* **Problem**: Watchdog lifecycle lacked dedicated tests for delayed Android property service startup, property service failure, and ADB disconnection. Protobuf parser lacked 64-bit varint limit checking and ZIP archive resource limits.
* **Solution**:
  * Added dedicated watchdog tests in `tests/test_watchdog.py`: delayed `sys.boot_completed=1` (clean exit 0), property service failure (triggers safe reboot), ADB disconnect simulation (triggers safe reboot), and symlink rejection for markers.
  * Hardened `tools/extract_apex_info.py`: rejects varints $> 2^{64}-1$, tag 0, invalid tags $> 536870911$, duplicate critical fields, and enforces ZIP limits (`MAX_APEX_FILE_SIZE = 500MB`, `MAX_ZIP_ENTRIES = 1000`, `MAX_MANIFEST_BYTES = 10MB`).
  * Hardened safety auditor `tools/safe/audit-no-writes.sh` with comment-stripped command scanning for `dd`, `wipefs`, `sgdisk`, `parted`, `fdisk`, and `mkfs`.

### 21. Critical RAM Accounting, Partition Mapping, BinderFS Rollback & Validation Repairs
* **Problem**:
  1. `scripts/stage2_init.sh` double-counted staged images against `MemAvailable` after those images were already resident in RAM tmpfs, and checked `/mnt` free space against already-staged image bytes. It also silently skipped checks if `/proc/meminfo` was empty.
  2. `tools/safe/run_stage2.sh` duplicated `my_product.erofs.img` as both `/mnt/product.img` and `/mnt/my_product.img`.
  3. APEX expanded size fell back to guessing 2.5x image size instead of requiring authentic uncompressed measurements.
  4. `src/binderfs_init.go` rollback deleted pre-existing valid symlinks or character devices on failure because it didn't track ownership.
  5. Protobuf tag parsing in `tools/extract_apex_info.py` only read 1 byte rather than a bounded varint, didn't enforce wire types for known fields, and allowed duplicate `versionName`.
  6. Watchdog parameters (`STAGE2_TIMEOUT`, `HEALTH_TIMEOUT`, `SLEEP_INTERVAL`, `MAX_TICKS`) were not validated against bounds.
* **Solution**:
  1. **Device-Side RAM Accounting Model**:
     - Staged images in `/mnt` are already in RAM and accounted for in kernel `MemAvailable`.
     - Future allocations from `MemAvailable`: `_FUTURE_RAM_REQ_MB = _EXP_APEX_MB (measured) + 1024 (/data) + 512 (overlay) + 1536 (kernel/gpu/runtime) + 256 (safety headroom)`.
     - `/mnt` requires only 576 MB free (OverlayFS upper/work directories: 512MB + 64MB buffer).
     - `/tmp` checked independently, requiring >= 64 MB free.
     - Fail-closed on `/proc/meminfo`: missing file, missing `MemTotal` (<6500MB), missing `MemAvailable`, non-numeric values, or overflow strictly halt bringup.
  2. **Product & My_Product Explicit Mapping**:
     - Donor OxygenOS 16 / ColorOS uses `/my_product` as its product layer (`my_product.erofs.img` -> `/mnt/my_product.img`), mounting to `/mnt/sysroot/my_product` and leaving `/mnt/sysroot/product` as an empty overlay directory.
     - Staging manifest `PARTITION_MAP` generated in `build_stage2_erofs.sh` and tracked in `SHA256SUMS`.
     - SHA-256 duplicate content detection rejects identical images mapped to both product and my_product paths in both runner and Stage 2.
  3. **Strict APEX Expanded-Size Measurement**:
     - Build pipeline extracts uncompressed payloads (`fsck.erofs --extract` / `7z x`), validates non-empty payload, and measures exact uncompressed byte counts into `*.expanded_size`. Fails build if measurement cannot be obtained.
     - Runner strictly requires positive numeric `.expanded_size` metadata for all 4 bootstrap APEX modules (<= 500MB).
     - Stage 2 enforces per-module pre-copy check: parses `df -k /mnt/sysroot/apex` strictly, requiring that next module fits with a 5 MB headroom margin.
  4. **BinderFS Rollback Ownership**:
     - Introduced `OpResult` enum (`ResultAlreadyValid`, `ResultCreated`) in `src/binderfs_init.go`.
     - Tracks `newlyAllocated`, `newlySymlinked`, and `newlyLegacy`. Rollback removes ONLY resources created by this invocation, strictly preserving pre-existing valid nodes, symlinks, and legacy devices.
  5. **Hardened Protobuf Tag Varint Parser**:
     - Decodes protobuf tag keys as multi-byte varints with bounds and overflow checks.
     - Validates wire types for known fields (tag 1: wire 2, tag 2: wire 0, tag 3: wire 2).
     - Rejects duplicate critical fields (tags 1, 2, 3). Strictly validates JSON manifest field types.
  6. **Watchdog Configuration Validation**:
     - Validates all 5 configuration variables with safe fallbacks and bounds: `WATCHDOG_TIMEOUT` (1..86400, default 60), `WATCHDOG_STAGE2_TIMEOUT` (1..86400, default 120), `WATCHDOG_HEALTH_TIMEOUT` (1..86400, default 600), `WATCHDOG_SLEEP_INTERVAL` (0.001..60, default 1), `WATCHDOG_MAX_TICKS` (0..1000000, default 0).
  7. **Authentic Kernel Configuration Audit (`IKCONFIG`)**:
     - Decompressed and audited kernel config stream at offset 35146816 of `stage1/kernel_src/kernel`.
     - Verified built-in `=y` monolithic support for `CONFIG_EROFS_FS` (with XATTR, POSIX_ACL, SECURITY, ZIP, PCPU_KTHREAD), `CONFIG_BLK_DEV_LOOP` (16 min count), `CONFIG_OVERLAY_FS`, `CONFIG_TMPFS`, `CONFIG_ANDROID_BINDERFS`, `CONFIG_ANDROID_BINDER_IPC`, `CONFIG_DRM_MSM`, and `CONFIG_QCOM_KGSL`.
     - Verified `# CONFIG_DEVTMPFS is not set`, validating the necessity of userspace tmpfs `/dev` node management in Stage 1 and Stage 2.
  8. **Android 16 Init Handover (`selinux_setup`)**:
     - Corrected Stage-2 init handover from raw `second_stage` to `exec /system/bin/chroot /mnt/sysroot /system/bin/init "${INIT_ENTRY_STAGE:-selinux_setup}"`.
     - Preserves PID 1 while executing `SetupSelinux()`, mounting selinuxfs, loading policy, transitioning PID 1 context into `u:r:init:s0`, and seamlessly execing `second_stage`.
  9. **APEX Direct Loop-Mounts & Strict AOSP Metadata**:
     - Replaced `cp -a` unpacking with direct loop-backed filesystem mounts (`/apex/${mod_name}@${version}`) and active bind mounts (`/apex/${mod_name}`), eliminating unpack overhead and saving ~80 MB RAM.
     - Full compliance with Android 16 `ApexInfoList.xsd`: generates all 9 required XML attributes (`moduleName`, `modulePath`, `preinstalledModulePath`, `versionCode`, `versionName`, `isFactory`, `isActive`, `provideSharedApexLibs`, `partition`), validated via `extract_apex_info.py --validate-xml`.
     - Verified kernel APEX prerequisites (`CONFIG_AIO=y`, `CONFIG_BLK_DEV_LOOP=y`, `CONFIG_CRYPTO_SHA1=y`, `CONFIG_CRYPTO_SHA256=y`, `CONFIG_DM_VERITY=y`, `loop.max_part=7`, unset `loop.max_loop`).
  10. **Fail-Closed SELinux Diagnostics**:
     - Removed permissive `|| true` suppressions on `selinuxfs` mount.
     - Verifies kernel interface `/sys/fs/selinux/load`, discovers compiled monolithic policies (`sepolicy`, `precompiled_sepolicy`), and validates CIL policy files (`plat`, `system_ext`, `vendor`, `odm`).
     - Detects precompiled policy hash mismatch against platform hashes and strictly verifies that `/system/bin/secilc` is present and executable for runtime compilation.
  11. **Hardened 4-Field PARTITION_MAP Contract**:
     - Enforces strict 4-field contract (`image_filename:target_mountpoint:nature:sha256`) across both host runner and device Stage-2 orchestrator.
     - Enforces 64-hex SHA-256 pattern (`^[0-9a-fA-F]{64}$`), rejects directory traversal / slashes in filenames, detects duplicate images/mountpoints, and mandates core partitions (`system`, `system_ext`, `vendor`, `odm`).
  12. **BinderFS Device Identity Hardening & Collision-Resistant Temp Creation**:
     - Enforces Linux `dev_t` encoding (`unix.Mkdev`) and major/minor extraction macros (`major()`, `minor()`).
     - Rejects fake Binder character devices (e.g. major 1 `/dev/null`, `/dev/zero`), performs `BINDER_VERSION` ioctl check (`0xc0046209`), uses collision-resistant cryptographic temp paths, and guarantees atomic symlink replacement with rollback limited exclusively to newly created resources.
  13. **Fail-Closed Physical Storage Inventory & 6-Checkpoint Revalidation**:
     - Replaced permissive device node discovery with strict sysfs enumeration of all physical block devices and child partitions.
     - Discovers major:minor pairs, validates syntax, creates device nodes fail-closed, enforces `blockdev --setro`, and verifies `blockdev --getro == 1` across all nodes.
     - Maintains explicit inventory files (`/mnt/physical_storage_inventory` and `/tmp/physical_storage_inventory`) verified byte-for-byte across 6 distinct bringup checkpoints in Stage-2 (startup, before sysroot/overlay, before child partitions, before APEX mounts, before `/data` tmpfs, before init handover).
     - Revalidation automatically detects newly appearing physical partitions and locks them `ro=1`, while aborting fail-closed if any previously verified device disappears or reports `ro=0`. Continuous monitoring integrated into `watchdog.sh`.
  14. **Authentic Kernel & Hardware Asset Provenance**:
     - Confirmed authentic kernel banner: `4.14.357-perf-gcd3073fb68f1` (Snapdragon 855+ / SM8150), resolving previous documentation discrepancies.
     - Enforces strict SHA-256 asset validation in `build_loader.sh`, `build_stage1.sh`, and CI for kernel (`c32e3a26...`), SM8150 DTB (`e4faf7c5...`), and Samsung AMOLED DTBO (`7cfdd198...`).
  15. **Unified 3392 MB RAM Bringup Allocation Model**:
     - Unified host runner (`run_stage2.sh`) and device orchestrator (`stage2_init.sh`) around authoritative memory budget: `TOTAL_STAGED_MB + 3392 MB` (64MB direct loop buffers, 1024MB `/data` tmpfs, 512MB OverlayFS, 1536MB kernel/GPU/runtime reserve, 256MB safety headroom). Eliminates previous double counting of expanded APEX sizes.
  16. **10-State Hardware Display & Graphics Diagnostics**:
     - Implemented structured 10-state hardware diagnostic tracking (DRM `card0`, panel detected, panel enabled, DRM connector `DSI-1`, Adreno 640 GPU, EGL ready, Composer HAL, SurfaceFlinger, frames presented post-handover, touchscreen input) with clear separation between pre-handover hardware probe and post-handover userspace rendering milestones.
  17. **CI, Boot Images & Documentation Integrity**:
     - Rebuilt local boot images: `build/loader.img` (Rebuilt SHA-256: `6ec495865fcad15429625ebb3b515864a56163d9bc848a80c4b1fe5abb5e0257` / Baseline: `25c5433e1e9f3d2f94d7dd1e5b05ad13764c0c237a83654495c77c0b393a9de1`) and `build/stage1.img` (Rebuilt SHA-256: `01ba479dbae2522e5e94c70dd839f919f267880b4b0670df43d5b5236d4992b2` / Baseline: `c04480b53cf243ef15135ed3e5b1ab43e5738376520cbe8eddb53690997bee8f`), both passing 36/36 pre-boot safety checks locally. Excluded from git checkout via `.gitignore`.
     - Static cross-compiled ARM64 binary `src/binderfs_init_arm64` installed byte-identically across ramdisks.
     - Total automated test suite: 224 total defined Python test methods across 9 test classes + 15 Go tests = 239 total test methods across codebase. Verified in CI (Run #20, ID `42530682479` established recorded baseline; Run #21, ID `42532420525` validated documentation commit; historical: Run #19, #18): 239 passed (224 Python + 15 Go; all 5 live loop-device tests ran and passed, including Stage-2 block-node identity integration). Local execution: 234 passed, 1 skipped test class (219 simulated Python tests passed, 0 failed, 1 unprivileged loop class skipped containing 5 tests; 15 Go tests passed).
  18. **Disposable Loop & Linux Block-Device Test Tier (`tests/test_storage_loop.py`)**:
     - Created comprehensive Linux block-device test suite verifying real kernel loop semantics (major/minor matching, block-special node construction, blockdev --setro/--getro, sysfs partition discovery, and write rejection) when privileged in CI/VM, coupled with simulated block-device semantics tests that execute unconditionally across all environments.
  19. **Independent Stage-2 Block-Node Identity Verification**:
     - Implemented `verify_block_node_identity` in `scripts/stage2_init.sh` across existing inventory entries, newly appearing physical disks, newly appearing partitions, and `atomic_update_inventory`.
     - Validated via 12 dedicated regression tests in `tests/test_storage_safety.py` covering hex conversion, matching identity, major/minor mismatches, malformed stat output, zero identity rejection (0:0), stat failure, stat unavailability, and production mode block-special enforcement.
  20. **Real Stage-2 Block-Node Identity Integration Test & Artifact Provenance**:
     - Added direct `--verify-block-node` CLI dispatch to `scripts/stage2_init.sh` allowing direct execution of the production shell verification function.
     - Implemented `test_live_loop_stage2_verify_block_node_identity` in `tests/test_storage_loop.py` executing against real kernel block devices with live `stat -L -c "%t:%T"`.
     - Reconciled hardware bringup test ledger artifact hashes in `docs/TEST-LEDGER.md` (T0, T1, T2) against actual build artifacts with proven timestamps and active commit contexts: T0 rebuilt `stage1.img` (`01ba479d...`, built 2026-11-09 01:49:58 from `f073d8d` tree state prior to `cd6afa5`), T1 `loader.img` (`6ec49586...`, built 2026-11-09 01:49:46), T2 `build/images/SHA256SUMS` (`4fb28aab...`, 37/37 OK, built 2026-11-08 16:26:14 from `e18fff3` tree state prior to `9bb95a1`).
     - Disambiguated local and CI verification reporting: Local combined: 234 passed, 1 skipped test class; CI combined: 239 passed (224 Python + 15 Go).

---

## 3. Verification Architecture & Matrix Summary

The authoritative 6-tier verification status is maintained in [`README.md`](README.md#7-verification-status--test-matrix) and the detailed test ledger in [`docs/TEST-LEDGER.md`](docs/TEST-LEDGER.md):

| Verification Tier | Scope | Status | Local vs. CI Execution Details |
| :--- | :--- | :--- | :--- |
| **Tier 1: Implemented** | Codebase, ramdisks, APEX staging, scripts, safety proxies | **COMPLETE** | Architectural implementation complete across all supervisors and wrappers. |
| **Tier 2: Static Checks Passed** | `tools/safe/audit-no-writes.sh` | **LOCAL 36/36 PASSED / CI 34/34 PASSED (Packaged & Kernel Audits Skipped in CI)** | **Local**: Rebuilt `loader.img` (`6ec49586...`) and `stage1.img` (`01ba479d...`) pass 36/36 checks; ramdisk directories pass 34/34 checks.<br>**CI**: Native and loader ramdisk directories pass 34/34 checks; kernel assets and packaged boot-image audits were skipped because the files were absent from the checkout per `.gitignore`. |
| **Tier 3: Host Tests Passed** | Python, Go & Shell unit/integration test suites | **PASSED (239 CI / 234 local)** | **CI (Run #20, ID `42530682479` established baseline; Run #21, ID `42532420525` validated documentation commit; historical: Run #19, #18)**: 239 passed (224 Python + 15 Go; all 5 live loop tests ran and passed, including Stage-2 block-node identity integration test).<br>**Local**: 234 passed, 1 skipped test class (219 simulated Python + 15 Go; loop class skipped due to unprivileged userspace). Grand total defined in codebase: 239 test methods. |
| **Tier 4: Build Passed** | Boot images & Stage-2 EROFS partition images | **PASSED (Partially Verified)** | Built locally: `stage1.img` (`01ba479d...`), `loader.img` (`6ec49586...`), `SHA256SUMS` (`4fb28aab...`, 37/37 OK), `PARTITION_MAP` (`e7142764...`). Excluded from Git checkout via `.gitignore`. Clean reproducible rebuild required before live hardware testing. |
| **Tier 5: Device Boot Tested** | Live USB fastboot boot onto physical OnePlus 7T | **NOT PERFORMED** | Zero physical boots executed; physical storage safety remains unproven on physical hardware. PRE-BOOT VERIFICATION IN PROGRESS — HARDWARE BOOT NOT APPROVED. |
| **Tier 6: Hardware Functionality Verified** | Display rendering, touchscreen, and hardware HALs | **PENDING LIVE TEST** | Requires live runtime inspection of `SurfaceFlinger` and DRM compositor post-boot. |

---

## 4. Authoritative Hardware Boot Readiness Assessment

To eliminate ambiguity across documentation, project readiness is partitioned strictly by verification domain:

1. **Local Workstation Verification**:
   - Rebuilt packaged boot images (`build/stage1.img`: `01ba479d...`, `build/loader.img`: `6ec49586...`) pass 36/36 static safety and handover audit checks.
   - Stage-2 partition images and bootstrap APEX payloads are verified against master checksums (`build/images/SHA256SUMS`: `4fb28aab...`, 37/37 entries OK) and 4-field contract (`build/images/PARTITION_MAP`: `e7142764...`).
   - Automated host tests execute cleanly: 234 passed, 1 test class skipped (`TestLiveLoopBlockDeviceSafety`, 5 tests, due to unprivileged environment without loop-device attachment capabilities).
2. **CI Pipeline Verification (Run #20, ID `42530682479` established baseline; Run #21, ID `42532420525` validated documentation commit; historical: Run #19, #18)**:
   - Full automated test suite passes 100% green: 239 passed out of 239 defined test methods (224 Python + 15 Go).
   - All 5 live loop-device integration tests execute and pass in the privileged CI container environment, including the Stage-2 live block-node identity integration test (`test_live_loop_stage2_verify_block_node_identity`).
   - Both ramdisk directories (`stage1/native_ramdisk`, `stage1/loader_ramdisk`) pass 34/34 pre-boot safety checks.
   - Shell scripts pass `bash -n` and POSIX `sh -n` syntax validation.
3. **Skipped Checks in CI Checkout**:
   - Hardware kernel assets (`stage1/kernel_src/`) and packaged boot images (`build/*.img`) are excluded from Git checkout via `.gitignore`.
   - The CI pipeline explicitly logs these audits as `SKIPPED`, verifying ramdisk directory sources rather than packaged binaries. These checks were skipped because the files were absent from the checkout; they are not described as passed.
4. **Physical Device Verification**:
   - **NOT PERFORMED**: Zero physical boots have been executed.
   - Physical UFS storage write protection (`blockdev --setro /dev/block/sd*`) has not yet been proven on physical hardware.
5. **Final Readiness Verdict**:
   - **PRE-BOOT VERIFICATION IN PROGRESS — HARDWARE BOOT NOT APPROVED.**
   - Do not execute `fastboot boot`, `fastboot flash`, erase, format, or any physical storage modifications.
   - Physical hardware boot is strictly blocked until boot artifacts undergo a clean reproducible rebuild and independent safety review.
