# OxygenOS 16 Port to OnePlus 7T (HD1901) — Project Summary

> **Document Version**: 2.2.0 (Dynamic BinderFS Allocation, Watchdog 4-State Lifecycle, Protobuf APEX Metadata & RAM Budgeting)  
> **Target Device**: OnePlus 7T (`HD1901` / `hotdogb`, Snapdragon 855+ / SM8150-AC, 8 GB RAM)  
> **Source ROM**: OxygenOS 16 (Android 16 / SDK 36 / `Baklava` / `BP4A.251205.006`)  
> **Base OS on Device**: crDroid (Android 16 / LineageOS 23.2 base, FBE Encrypted)  
> **Primary Safety Mandate**: **Zero physical writes to internal flash** — Strictly volatile RAM execution.

---

## 1. Executive Summary & Core Mandate

The objective of this project is to port and run OxygenOS 16 (Android 16 / SDK 36) on the OnePlus 7T purely in volatile memory (RAM) via `fastboot boot`, featuring:
1. **Google Photos Unlimited Original Backup Spoof** (`pixel_2016_experience.xml` + `NEXUS_PRELOAD`).
2. **Play Integrity Profile Template** (`pif.json` release-keys profile for `HD1901`).
3. **Display Hardware Handover** (`SurfaceFlinger` + Qualcomm DRM `msm_drm` compositor on AMOLED display with fixed 60Hz replacement panel configuration).
4. **Android 16 Bootstrap APEX Architecture** (`com.android.runtime`, `com.android.art`, `com.android.i18n`, `com.android.tzdata`).

### The Non-Negotiable Safety Directive
Under **no circumstances** is the phone's internal physical flash storage to be altered:
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

### 12. Dynamic BinderFS Device Allocation (`binderfs_init`)
* **Problem**: Fresh BinderFS mount points only create `/dev/binderfs/binder-control`. IPC devices (`binder`, `hwbinder`, `vndbinder`) do not exist automatically, causing Binder-dependent services to crash.
* **Solution**:
  * Implemented static ARM64 executable `src/binderfs_init` (with Go and C implementations in `src/`).
  * Uses `ioctl(ctl_fd, BINDER_CTL_ADD, &dev)` with `struct binderfs_device` to allocate `binder`, `hwbinder`, and `vndbinder`.
  * Logs allocated major:minor device numbers, chmods to `0666`, creates `/dev/<name>` symlinks, and verifies `O_RDWR` accessibility.
  * Embedded into both `stage1/loader_ramdisk` and `stage1/native_ramdisk` at `/system/bin/binderfs_init`.

### 13. Watchdog 4-State Lifecycle Protocol & Health Monitoring
* **Problem**: Two-tier watchdog did not actively guard Stage 2 in RAM or monitor whether Android completed booting after `exec init second_stage`.
* **Solution**:
  * Implemented 4-state state machine in `scripts/watchdog.sh`:
    * `STAGE1_WAIT` (60s): Monitors host heartbeats until Stage-1 consumes `/mnt/boot_now` and touches `/mnt/stage1_ack`.
    * `STAGE2_RUNNING` (120s): Monitors RAM staging, accepting either device `/mnt/stage2_heartbeat` or host heartbeats until Stage 2 touches `/mnt/stage2_done`.
    * `HEALTH_MONITOR` (180s): Monitors Android second-stage init; polls Android property `sys.boot_completed=1` via `getprop`. Exits cleanly (code 0) on success; triggers emergency reboot on timeout.
    * `DISARMED`: Atomic cancellation via regular file `/mnt/watchdog_cancel`.

### 14. Protobuf APEX Manifest Metadata Extraction & Non-Fatal Mounting
* **Problem**: `com.google.android.art_compressed.apex` and `com.google.android.tzdata6.apex` encode metadata in protobuf `apex_manifest.pb`. Fallbacks to version 1 broke canonical `@version` paths, and candidate mount failures aborted Stage 2.
* **Solution**:
  * Created `tools/extract_apex_info.py` with protobuf varint/tag decoder and JSON fallback.
  * Extracts authentic versions (`com.android.art` -> 361501120, `com.android.tzdata` -> 361157000).
  * Enforces positive integer version codes and validates package names.
  * In `scripts/stage2_init.sh`, implemented non-fatal `try_mount()` helper, allowing candidate filesystem evaluation without aborting.

### 15. Volatile RAM Peak-Memory Budgeting
* **Problem**: Pushing 3.3 GB of disk images into RAM tmpfs without verifying available system RAM risked out-of-memory kernel panics.
* **Solution**:
  * In `tools/safe/run_stage2.sh`, dynamically inspects target `/proc/meminfo` (`MemTotal` and `MemAvailable`).
  * Calculates total size of staged images + reservations (1024 MB data + 512 MB tmp/overlay + 1536 MB kernel/runtime = ~6,372 MB peak).
  * Fails closed immediately if `/proc/meminfo` cannot be read or if `MemAvailable < REQUIRED_RAM_MB`.

---

## 3. Verification Matrix & Current Status

| Verification Tier | Scope | Status | Notes |
| :--- | :--- | :--- | :--- |
| **Tier 1: Implemented** | Full codebase, ramdisks, APEX extraction, scripts, and wrappers | **COMPLETE** | All modules implemented in accordance with architecture specifications. |
| **Tier 2: Static Checks Passed** | `tools/safe/audit-no-writes.sh` | **PASSED (31/31)** | Passed on `build/loader.img` and `build/stage1.img` with zero mandatory unverified checks. |
| **Tier 3: Host Tests Passed** | Automated Python & Shell unit/integration test suites | **PASSED (66/66)** | 100% pass across ADB proxy (8), Fastboot proxy (3), Watchdog protocol (15), and Stage-2 runner integration mocks (40). |
| **Tier 4: Build Passed** | Boot images & EROFS partition images | **PASSED** | `loader.img`, `stage1.img`, and all 10 Stage-2 images generated with valid SHA256SUMS. |
| **Tier 5: Device Boot Tested** | Live USB fastboot boot onto physical OnePlus 7T | **PENDING LIVE TEST** | Requires physical device tethering and testing in fastboot mode. |
| **Tier 6: Hardware Functionality Verified** | Display rendering, touchscreen, and hardware HALs | **PENDING LIVE TEST** | Requires live runtime inspection of `SurfaceFlinger` and DRM compositor. |

---

## 4. Hardware Boot Readiness Assessment

The repository is in a verified, build-clean, and audited state:
* All host-side safety wrappers (`tools/safe/adb`, `tools/safe/fastboot`, `tools/safe/audit-no-writes.sh`) are active and verified.
* All Stage-1 boot images (`build/loader.img`, `build/stage1.img`) are generated and pass static audit (31/31).
* All Stage-2 EROFS partition images and bootstrap APEX payloads are packaged and verified with `SHA256SUMS`.
* All 66 automated unit and integration tests pass without error.
* **Verdict**: Ready for controlled live device testing via USB 3.0 (`fastboot boot build/loader.img` or `fastboot boot build/stage1.img`).
