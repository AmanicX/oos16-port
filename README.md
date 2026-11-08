# OxygenOS 16 Port for OnePlus 7T (`HD1901` / `hotdogb`)
### RAM-Resident Execution with Fail-Closed Block-Layer Read-Only Protection

[![Android](https://img.shields.io/badge/Android-16%20Baklava%20(SDK%2036)-green.svg)](https://developer.android.com/)
[![Device](https://img.shields.io/badge/Device-OnePlus%207T%20(hotdogb)-blue.svg)](https://wiki.lineageos.org/devices/hotdogb/)
[![SoC](https://img.shields.io/badge/SoC-Snapdragon%20855%2B%20(SM8150--AC)-orange.svg)](https://www.qualcomm.com/)
[![Storage](https://img.shields.io/badge/Storage-Fail--Closed%20RAM-red.svg)](#non-negotiable-safety-contract)
[![Tests](https://img.shields.io/badge/Tests-233%2F234%20Passing-brightgreen.svg)](#7-verification-status--test-matrix)
[![Audit](https://img.shields.io/badge/Audit-36%2F36%20Passed-brightgreen.svg)](#7-verification-status--test-matrix)

---

## 1. Project Overview & Objectives

This project ports and runs **OxygenOS 16** (Android 16 / SDK 36 / `BP4A.251205.006`) on the **OnePlus 7T (`HD1901` / `hotdogb`)** purely in volatile RAM using `fastboot boot`.

### Core Features & Architecture
1. **Designed for Zero Storage Alteration**: Internal UFS storage devices (`/dev/block/sd*`, `/dev/block/mmcblk*`) and all child partitions are dynamically locked read-only (`ro=1`). The existing installation (crDroid/LineageOS) and user data remain completely untouched.
2. **Volatile RAM Staging**: Staging filesystems (`/mnt` and `/tmp`) and ephemeral `/data` reside strictly in RAM (`tmpfs`), vanishing entirely upon power cycle.
3. **Display & Graphics Bringup**: Target Qualcomm DRM compositor (`msm_drm`), Adreno 640 GPU (`kgsl-3d0`), and `SurfaceFlinger` for OnePlus 7T AMOLED display (including fixed 60Hz aftermarket panels: `dsi_samsung_s6e3fc2x01_cmd_display`).
4. **Android 16 Bootstrap APEX Architecture**: Complete authentic staging and activation for all 4 bootstrap APEX modules (`com.android.runtime`, `com.android.art`, `com.android.i18n`, `com.android.tzdata`) with Bionic linker64, ART runtime libraries, ICU data, and timezone metadata.
5. **Google Photos & PIF Injections**: Feature overlays (`pixel_2016_experience.xml` + `pif.json` template) applied reversibly during image build.

---

## 2. Non-Negotiable Safety Contract

Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to device-level verification.

To prevent write execution paths to physical internal flash:
* **Strict Command Banning**: Destructive fastboot subcommands (`flash`, `erase`, `format`, `wipe`, `set_active`) are intercepted and blocked by `tools/safe/fastboot`.
* **Dynamic Block-Layer Write Locks**: The Stage-1 RAM supervisor discovers all physical block devices (`/sys/block/*`) and child partitions, applies `blockdev --setro`, and confirms `ro=1` on every partition before any operation begins.
* **Continuous Guard Loop**: A background monitoring loop periodically verifies that all physical disks and partitions remain read-only; any violation immediately triggers an emergency reboot to bootloader.
* **Ephemeral Volatile State**: `/data` is strictly a 1024 MB `tmpfs` in RAM that vanishes upon reboot.
* **Race-Safe Watchdog Supervisor**: Modular supervisor (`scripts/watchdog.sh`) monitors `/mnt/watchdog_heartbeat` with automatic fallback reboot to bootloader if the host disconnects.

---

## 3. Provenance of All Files & Packages Used

Every file, partition image, and tool used in this project is documented with its exact upstream source:

| File / Component | Version / Build | Source / Site | Purpose in Port |
| :--- | :--- | :--- | :--- |
| **`ota_full-LE2113_16.0.10.500.zip`** | Android 16 (`BP2A.250605.015`, Display: `LE2113_16.0.10.500(EX01)`, SDK 36) | Official OnePlus / OPPO OTA Update Servers for OnePlus 9 (`lemonade` / `OnePlus9_EEA`, Model `LE2113`) | **Donor OS**: Provides OxygenOS 16 system framework, `system`, `system_ext`, `my_product`, and bootstrap APEX packages. |
| **`lineage-23.2-20261009-nightly-hotdogb-signed.zip`** | Android 16 / SDK 36 | Official LineageOS for OnePlus 7T (`hotdogb`) | **Base Hardware HALs**: Provides Snapdragon 855 (SM8150) graphics, display, sensor, audio, and camera HALs matching Android 16. |
| **`crDroid 12.x / LineageOS Recovery`** | Kernel 4.14.357-perf+ (`4.14.357-perf-gcd3073fb68f1`) | crDroid Android / LineageOS hotdogb releases | **Stage-1 Kernel & Ramdisk**: Provides the recovery kernel, DTB, DTBO, and initial USB ADB endpoint. |
| **`external/coloros_port`** | Branch `COS16/OOS16` | [GitHub: toraidl/coloros_port](https://github.com/toraidl/coloros_port) | **Porting Utilities**: Provides `mkfs.erofs`, `fsck.erofs`, and Android boot image tools. |
| **`pixel_2016_experience.xml`** | 2026 Revision | Google Pixel sysconfig / crDroid feature overlay | **Photos Spoof**: Grants unlimited original quality Google Photos cloud backup. |
| **`pif.json`** | OnePlus 7T HD1901 Target | Play Integrity Fix profile | **Play Integrity**: Spoofs CTS / MEETS_DEVICE_INTEGRITY profile template for Google Play Services. |

---

## 4. Repository Structure & File Catalog

```text
oos16-port/
├── README.md                      # Master technical documentation (this file)
├── PROJECT-SUMMARY.md             # Detailed engineering log, phase history, and bug fixes
├── .gitignore                     # Protects large binary dumps and proprietary partitions
├── configs/                       # Feature injections & spoof configurations
│   ├── pixel_2016_experience.xml  # Google Photos unlimited original backup XML
│   └── pif.json                   # Play Integrity Fix profile for HD1901
├── scripts/                       # Build and runtime orchestration scripts
│   ├── build_loader.sh            # Builds First-Stage RAM Loader (build/loader.img)
│   ├── build_stage1.sh            # Builds Native Recovery RAM boot image (build/stage1.img)
│   ├── build_stage2_erofs.sh      # Repacks EROFS partitions and extracts bootstrap APEXes
│   ├── stage2_init.sh             # Phone-side Stage-2 orchestrator running in RAM
│   └── watchdog.sh                # Modular 4-state Stage-1 watchdog supervisor script
├── src/                           # Native helper source code
│   ├── binderfs_init.go           # Dynamic BinderFS allocation tool (Go, zero libc dependencies)
│   ├── binderfs_init.c            # Dynamic BinderFS allocation tool (C fallback)
│   └── Makefile                   # Builds static aarch64 & host test binaries
├── tools/                         # Tooling and utilities
│   ├── extract_apex_info.py       # APEX protobuf & JSON manifest metadata extractor
│   └── safe/                      # Host-side safety wrappers and auditors
│       ├── fastboot               # Python safety wrapper blocking destructive commands
│       ├── adb                    # Python safety wrapper logging and blocking flash writes
│       ├── run_stage2.sh          # Host-side orchestrator with RAM budget enforcement
│       └── audit-no-writes.sh     # Static auditor verifying 0 write commands in images
├── tests/                         # Unit and integration test suite
│   ├── test_safe_adb.py           # ADB safety proxy unit tests
│   ├── test_safe_fastboot.py      # Fastboot safety proxy unit tests
│   ├── test_watchdog.py           # Watchdog supervisor protocol test suite
│   ├── test_storage_safety.py     # Physical storage discovery, fail-closed mknod & inventory tests
│   └── test_integration_stage2.py # End-to-end integration tests (Mock ADB, auditor, build validation)
├── stage1/                        # Stage-1 RAM harness sources
│   ├── loader_ramdisk/            # Minimal shell init ramdisk (init, stage2_init.sh, watchdog.sh)
│   ├── native_ramdisk/            # Native A16 recovery ramdisk (recovery, stage2_init.sh, watchdog.sh)
│   └── kernel_src/                # Kernel 4.14.357, DTB, and recovery_dtbo
└── docs/                          # Technical deep-dive documentation
```

---

## 5. Stage 1 vs. Stage 2 Execution Flow & PID 1 Preservation

### Legitimate PID 1 Architecture:
Both `loader.img` and `stage1.img` enforce a strict single-process replacement chain (`exec`), ensuring **no competing inits** run simultaneously and that Android's second stage init executes with legitimate `PID == 1`:
```text
Kernel Boot (/init as PID 1)
   │
   ▼
Stage-1 RAM Supervisor (PID 1)
   ├── Dynamic storage discovery & hardware write-locks (blockdev --setro)
   ├── Kernel filesystem mounts (proc, sys, devtmpfs/tmpfs)
   ├── Binderfs mount & symlinks (/dev/binder, /dev/hwbinder, /dev/vndbinder)
   ├── ueventd startup & sysfs coldboot uevent trigger
   ├── AMOLED backlight initialization (panel0-backlight = 200)
   ├── Volatile RAM staging (/mnt 6500MB tmpfs, /tmp 512MB tmpfs)
   ├── Root USB gadget adbd daemon
   ├── Safety watchdog supervisor (/system/bin/watchdog.sh)
   └── Await /mnt/boot_now trigger
   │
   ▼ (exec /system/bin/sh /system/bin/stage2_init.sh — PID 1 PRESERVED)
Stage-2 Orchestrator (PID 1)
   ├── Safety verification (blockdev --getro, 0 writable mounts)
   ├── Base system EROFS + OverlayFS root (/mnt/sysroot)
   ├── Child partition mounts (system_ext, product, vendor, odm)
   ├── Canonical AOSP APEX versioned directories & active symlinks:
   │     /apex/<mod>@<version> (directory) & /apex/<mod> (symlink)
   ├── Ephemeral RAM /data (1024MB tmpfs) & Binder / Dev / Proc / Sys bind mounts
   ├── Display diagnostics (DRM card0, KGSL Adreno 640, SurfaceFlinger, Composer HAL)
   ├── Watchdog cancellation via /mnt/watchdog_cancel regular file
   └── Unbind USB gadget & stop Stage-1 adbd
   │
   ▼ (exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage — PID 1 PRESERVED)
OxygenOS 16 Android Init Second Stage (PID 1)
```

### Two Consistent Stage-1 Ramdisk Implementations:
1. **Loader Ramdisk (`build/loader.img`)**:
   * Standalone POSIX supervisor script as `/init` (PID 1).
   * Configures `devtmpfs` with `tmpfs` fallback, mounts `binderfs`, and launches `ueventd`.
   * Triggers coldboot uevents across `/sys` and scans sysfs for DRM `/dev/dri/card0` and Adreno `/dev/kgsl-3d0`.
   * Enforces blockdev read-only locks, stages RAM tmpfs, and performs `exec` handover to Stage-2.
2. **Native Ramdisk (`build/stage1.img`)**:
   * Uses the identical Stage-1 supervisor as `/init` (PID 1), eliminating intermediate recovery child services.
   * Ensures `/mnt` has `size=6500M tmpfs` mounted in `init.rc`.
   * Ensures identical write-lock, `ueventd`, watchdog, and `exec` handover semantics.

### Host Runner Orchestration (`tools/safe/run_stage2.sh`):
1. Verifies phone connection via `tools/safe/adb get-state`.
2. Dynamically queries target physical storage (`/sys/block/*`) and child partitions; confirms `blockdev --getro == 1` across all.
3. Confirms `/mnt` is mounted as RAM `tmpfs` and verifies $\ge 6000\text{ MB}$ free capacity.
4. Starts active host safety heartbeat loop (`touch /mnt/watchdog_heartbeat` every 5s).
5. Validates host images, calculates host SHA-256 hashes, transfers images to RAM (`/mnt/`), and verifies device-side SHA-256 checksums match host calculation:
   * **Mandatory partition images**: `system.erofs.img`, `system_ext.erofs.img`, `vendor.erofs.img`, `odm.erofs.img`, `my_product.erofs.img` (or `product.erofs.img`).
   * **Mandatory bootstrap APEX modules**: `runtime_apex.img`, `art_apex.img`, `i18n_apex.img`, `tzdata_apex.img` (+ `.fstype` and `.version` metadata).
   * **Optional partition images**: `my_region.erofs.img`.
6. Activates Stage-1 boot supervisor trigger via `touch /mnt/boot_now` and maintains heartbeats until acknowledged.

### Phone-Side Stage-2 Handover (`scripts/stage2_init.sh`):
1. Re-verifies all physical block devices are read-only (`ro=1`) and live mounts have zero writable physical partitions.
2. Sets up OverlayFS mount on `/mnt/sysroot` backed by volatile tmpfs upper layer.
3. Loop-mounts all staged partition images into `/mnt/sysroot/{system,system_ext,vendor,odm,product,my_product,my_region}` using non-fatal `try_mount()` candidate evaluation.
4. Populates and verifies Android 16 APEX bootstrap modules in canonical versioned structure:
   * Payload directories: `/mnt/sysroot/apex/${mod_name}@${version}`
   * Active symlinks: `/mnt/sysroot/apex/${mod_name} -> ${mod_name}@${version}`
   * `com.android.runtime@1` (Bionic `linker64`, `libc.so`, `libm.so`, `libdl.so`)
   * `com.android.art@361501120` (`libart.so`, `dalvikvm64`)
   * `com.android.i18n@1` (ICU libraries)
   * `com.android.tzdata@361157000` (Timezone data)
5. Mounts ephemeral `/data` tmpfs (1024 MB in RAM) and binds `/dev`, `/dev/pts`, `/proc`, `/sys`.
6. Performs display diagnostics: confirms DRM card0, KGSL 3D0, SurfaceFlinger binary, Composer HAL, and powers on AMOLED backlight.
7. Maintains active device-side heartbeat (`/mnt/stage2_heartbeat`) during bringup, and signals `/mnt/stage2_done` to transition watchdog into Android `HEALTH_MONITOR` state.
8. Replaces process image via `exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage` (PID 1).

### Dynamic BinderFS Device Allocation (`binderfs_init`):
In fresh Linux BinderFS instances, mounting `none /dev/binderfs binder` creates only the control device `/dev/binderfs/binder-control`. IPC nodes (`binder`, `hwbinder`, `vndbinder`) do **not** appear automatically and must be allocated dynamically:
* The native helper `src/binderfs_init` opens `/dev/binderfs/binder-control` and invokes `ioctl(ctl_fd, BINDER_CTL_ADD, &dev)` with `struct binderfs_device` for `binder`, `hwbinder`, and `vndbinder`.
* On older kernels lacking dynamic BinderFS ioctls, it provides automatic fallback to legacy sysfs major:minor nodes (`/sys/class/misc/<name>/dev`).
* Standard Linux 64-bit `dev_t` device-number encoding is implemented according to glibc/sysmacros ABI:
  ```go
  devNum := (maj & 0xfff) << 8 | (min & 0xff) | (uint64(maj &^ 0xfff) << 32) | (uint64(min &^ 0xff) << 12)
  ```
* Sysfs device numbers are strictly validated against numeric boundaries (`major <= 0xfffff`), rejecting empty, negative, or malformed strings.
* Safe syscall handling validates that all `Mknod`, `Chmod`, `Symlink`, and `Remove` calls succeed, and strictly refuses to overwrite unrelated character devices, regular files, or directories.
* Built reproducibly into static ARM64 ELF via `src/Makefile` with Go unit tests (`go test -v ./...`) and strict C compiler verification (`gcc -Wall -Wextra -Werror -pedantic -std=gnu11`).

### Watchdog 4-State Lifecycle Protocol:
The watchdog supervisor (`scripts/watchdog.sh`) implements an atomic 4-state state machine guarding every phase of volatile execution:
1. **`STAGE1_WAIT`** (Timeout: 60s): Monitors host heartbeats (`/mnt/watchdog_heartbeat`) while waiting for the Stage-1 supervisor to consume `/mnt/boot_now` and issue `/mnt/stage1_ack`.
2. **`STAGE2_RUNNING`** (Timeout: 120s): Monitors Stage-2 bringup in RAM, accepting either device-side (`/mnt/stage2_heartbeat`) or host-side heartbeats until Stage-2 finishes and touches `/mnt/stage2_done`.
3. **`HEALTH_MONITOR`** (Configurable Timeout: 600s default for first boot): Monitors Android init bringup after `exec init second_stage`. Continuously queries Android property service (`sys.boot_completed=1`) across chroot `/mnt/sysroot /system/bin/getprop` and root namespace property bind-mounts. Upon successful boot completion, logs `BOOT_COMPLETED` and exits cleanly (exit code 0). If boot fails to complete within timeout, triggers emergency reboot to bootloader.
4. **`DISARMED`**: If manual cancellation is requested via regular file `/mnt/watchdog_cancel`, logs `DISARMED` and exits cleanly (exit code 0).
* State transitions are written atomically (`set_state`) to `/mnt/watchdog_state` to prevent partial reads by host runners.

### Device-Side APEX Metadata Enforcement & Protobuf Parser:
* **No Silent Fallbacks**: Hardcoded fallbacks to `version="1"` or synthetic versions are completely eliminated.
* **Strict Validation**: `.version` metadata files must exist and match regex `^[1-9][0-9]*$`; `.fstype` must exist and match `erofs` or `ext4`. If missing or invalid for mandatory APEX modules, Stage 2 halts closed immediately.
* **Hardened Protobuf Parser (`tools/extract_apex_info.py`)**:
  * Validates protobuf tags (tag 0 rejected) and wire types (only 0, 1, 2, 5 permitted).
  * Validates varint bounds (rejects truncated varints and lengths $> 10$ bytes).
  * Validates length-delimited payload boundaries, rejecting out-of-bounds field lengths.
  * Enforces strict UTF-8 decoding without replacement characters.
  * Validates package identifier syntax (`validate_package_name`).
  * Safely handles compressed APEX payloads (`original_apex`) with `BadZipFile` recovery.

### Volatile RAM Capacity & Peak-Memory Budgeting:
Running an entire mobile operating system purely from RAM requires strict memory budgeting:
* Target device: OnePlus 7T (`hotdogb`), 8 GB LPDDR4X physical RAM.
* Staged partition images (`system`, `system_ext`, `vendor`, `odm`, `my_product`, APEXes): ~3,300 MB.
* Exact upward integer rounding: `TOTAL_STAGED_MB=$(((TOTAL_STAGED_BYTES + 1048575) / 1048576))`.
* Authoritative Bringup Allocation: **3,392 MB**:
  * Direct APEX loop backing buffer: 64 MB (direct loop mounted from staged images)
  * Ephemeral `/data` tmpfs quota: 1,024 MB
  * Volatile staging `/tmp` & OverlayFS upper layers: 512 MB
  * Kernel, base drivers, display buffers & Android runtime headroom: 1,536 MB
  * Filesystem metadata & safety headroom: 256 MB
* **Total Peak Memory Required**: `TOTAL_STAGED_MB + 3392` (~6,692 MB, $\approx 6.7\text{ GB}$).
* In `tools/safe/run_stage2.sh` and `scripts/stage2_init.sh`, the budget model is strictly unified. `/mnt` tmpfs mount is verified via `/proc/mounts`, and `df -m /mnt` is parsed strictly with numeric validation. The runner verifies `MemTotal >= 6500MB` and `MemAvailable >= REQUIRED_RAM_MB` before initiating image transfer and fails closed immediately if capacity is insufficient or unreadable.
* Extended monitoring loop (`OOS16_WAIT_FOR_BOOT=1`) continues petting the safety watchdog heartbeat while awaiting `sys.boot_completed=1` or `watchdog_state=BOOT_COMPLETED`.

### OnePlus 7T Display & Graphics Bringup Technical Analysis:
* **Display Hardware**: OnePlus 7T (`hotdogb`) features a 6.55" 2400x1080 Fluid AMOLED display driven by Qualcomm Snapdragon 855 (SM8150) Mobile Display Subsystem (MDSS) and Display Processing Unit (DPU).
* **Command Mode & Aftermarket Panels**: Common replacement AMOLED panels use Samsung display driver IC `dsi_samsung_s6e3fc2x01_cmd_display`. Injected vendor properties enforce fixed 60Hz mode (`default_fps=60`, `game_default_frame_rate_override=60`) to avoid display flicker or blank screens caused by 90Hz timing mismatches on replacement glass.
* **Kernel & DRM Stack**:
  * Adreno 640 GPU kernel driver: `/dev/kgsl-3d0`
  * Qualcomm Snapdragon Display Engine (SDE) DRM compositor: `/dev/dri/card0`
  * Backlight control: `/sys/class/backlight/panel0-backlight/brightness`
* **Honest Scope Distinction**: The diagnostic checks in Stage 1 and Stage 2 confirm that the kernel has enumerated `/dev/dri/card0`, `/dev/kgsl-3d0`, and powered the backlight (`brightness = 200`). However, actual display rendering (SurfaceFlinger HWComposer vs GPU composition, frame delivery) requires live execution on physical silicon and is classified strictly under **Tier 6: PENDING LIVE TEST**.

---

## 6. How to Build & Verify

### Step 1: Build the Stage-1 Boot Images
```bash
# Build alternate loader ramdisk boot image:
bash scripts/build_loader.sh

# Or build native recovery ramdisk boot image:
bash scripts/build_stage1.sh
```

### Step 2: Build and Package Stage-2 EROFS Images & APEX Payloads
```bash
bash scripts/build_stage2_erofs.sh
```
Build features:
* Validates all mandatory source trees and APEX packages before building.
* Performs reversible source modifications with automated `.orig` rollback on failure.
* Extracts and packages all 4 bootstrap APEX modules (`runtime`, `art`, `i18n`, `tzdata`).
* Employs atomic publishing with SHA256 checksum validation and rollback protection.

### Step 3: Run the Comprehensive Safety & Unit Test Suite
```bash
# Run ADB safety proxy tests:
python3 tests/test_safe_adb.py

# Run Fastboot safety proxy tests:
python3 tests/test_safe_fastboot.py

# Run Real Watchdog implementation tests:
python3 -m unittest tests/test_watchdog.py

# Run Full Integration & Auditor test suite:
python3 -m unittest discover tests
```

### Step 4: Audit Pre-Boot Safety
```bash
bash tools/safe/audit-no-writes.sh build/loader.img
bash tools/safe/audit-no-writes.sh build/stage1.img
```

### Step 5: Controlled Hardware Device Boot
Connect OnePlus 7T in fastboot mode via USB 3.0:
```bash
# Boot RAM loader:
tools/safe/fastboot boot build/loader.img
# (or tools/safe/fastboot boot build/stage1.img)

# Once device appears in ADB recovery mode, orchestrate Stage-2 RAM boot:
bash tools/safe/run_stage2.sh
```

---

## 7. Verification Status & Test Matrix

To maintain rigorous engineering honesty, verification states are strictly partitioned across 6 distinct tiers:

| Verification Tier | Scope | Status | Notes |
| :--- | :--- | :--- | :--- |
| **Tier 1: Implemented** | Full codebase, ramdisks, APEX extraction, scripts, and wrappers | **COMPLETE** | All modules implemented in accordance with architecture specifications. Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to device-level verification. |
| **Tier 2: Static Checks Passed** | `tools/safe/audit-no-writes.sh` | **PASSED (36/36 local, 34/34 CI)** | Local-only static audit passed on local packaged boot images: `loader.img` (Rebuilt SHA-256: `6ec49586...` / Baseline: `25c5433e...`, 36/36 checks passed) and `stage1.img` (Rebuilt SHA-256: `01ba479d...` / Baseline: `c04480b5...`, 36/36 checks passed); ramdisk directories pass 34/34 checks (0 failures, 1 optional unverified cmdline). In CI without device kernel inputs, ramdisks pass (34/34) and packaged boot-image audits are logged as skipped via `.gitignore`. |
| **Tier 3: Host Tests Passed** | Automated Python, Go & Shell unit/integration test suites | **PASSED (239 CI / 234 local)** | Total defined test methods in codebase: 239 (224 Python across 9 classes + 15 Go). Latest CI execution (Run #19 / #18): 239 passed (224 Python + 15 Go; all 5 live loop-device integration tests executed and passed). Local workstation execution: 234 passed, 1 skipped test class (219 simulated Python tests passed, 0 failed, 1 unprivileged loop class skipped containing 5 tests; 15 Go tests passed). Verified across ADB proxy (8), Fastboot proxy (3), APEX protobuf, ZIP limits & XML schema (26), Watchdog protocol, two-copy inventory synchronization & fail-closed lifecycle (62), Stage-2 runner integration mocks (72), Storage safety, strict block-node identity & 6-checkpoint inventory revalidation (39), Disposable loop & block device safety (9 simulated passed + 5 live loop tests), and Go BinderFS unit tests (15). |
| **Tier 4: Build Passed** | Boot images & EROFS partition images | **PASSED (Partially Verified)** | Locally built and verified: `stage1.img` (`01ba479d...`), `loader.img` (`6ec49586...`), and all Stage-2 images with master checksums (`build/images/SHA256SUMS`: `4fb28aab...`, 37/37 OK) and `PARTITION_MAP` (`e7142764...`). Excluded from git checkout via `.gitignore` (not available via direct clone). Clean reproducible rebuild required before live hardware testing. |
| **Tier 5: Device Boot Tested** | Live USB fastboot boot onto physical OnePlus 7T | **NOT PERFORMED** | Physical device boot not performed. Zero physical boots executed; hardware storage safety has not yet been proven on physical UFS hardware. PRE-BOOT VERIFICATION IN PROGRESS — HARDWARE BOOT NOT APPROVED. |
| **Tier 6: Hardware Functionality Verified** | Display rendering, touchscreen, and hardware HALs | **PENDING LIVE TEST** | Requires live runtime inspection of `SurfaceFlinger` and DRM compositor on physical hardware. |

---

## 8. License & Disclaimer

This project is for research and development purposes. Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to device-level verification. All operating system files run strictly in volatile memory (RAM) and are discarded upon power-off or reboot.
