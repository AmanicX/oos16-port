# OxygenOS 16 Port to OnePlus 7T (HD1901) — Project Summary

> **Document Version**: 2.0.0 (Comprehensive Critical Architecture & Safety Update)  
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

---

## 3. Verification Matrix & Current Status

| Verification Tier | Scope | Status | Notes |
| :--- | :--- | :--- | :--- |
| **Tier 1: Implemented** | Full codebase, ramdisks, APEX extraction, scripts, and wrappers | **COMPLETE** | All modules implemented in accordance with architecture specifications. |
| **Tier 2: Static Checks Passed** | `tools/safe/audit-no-writes.sh` | **PASSED (21/21)** | Passed on `build/loader.img` and `build/stage1.img` with zero mandatory unverified checks. |
| **Tier 3: Host Tests Passed** | Automated Python & Shell unit/integration test suites | **PASSED (34/34)** | 100% pass across ADB proxy, Fastboot proxy, Watchdog protocol, and Stage-2 runner mocks. |
| **Tier 4: Build Passed** | Boot images & EROFS partition images | **PASSED** | `loader.img`, `stage1.img`, and all 10 Stage-2 images generated with valid SHA256SUMS. |
| **Tier 5: Device Boot Tested** | Live USB fastboot boot onto physical OnePlus 7T | **PENDING LIVE TEST** | Requires physical device tethering and testing in fastboot mode. |
| **Tier 6: Hardware Functionality Verified** | Display rendering, touchscreen, and hardware HALs | **PENDING LIVE TEST** | Requires live runtime inspection of `SurfaceFlinger` and DRM compositor. |

---

## 4. Hardware Boot Readiness Assessment

The repository is in a verified, build-clean, and audited state:
* All host-side safety wrappers (`tools/safe/adb`, `tools/safe/fastboot`, `tools/safe/audit-no-writes.sh`) are active and verified.
* All Stage-1 boot images (`build/loader.img`, `build/stage1.img`) are generated and pass static audit.
* All Stage-2 EROFS partition images and bootstrap APEX payloads are packaged and verified with `SHA256SUMS`.
* All 34 automated unit and integration tests pass without error.
* **Verdict**: Ready for controlled live device testing via USB 3.0 (`fastboot boot build/loader.img` or `fastboot boot build/stage1.img`).
