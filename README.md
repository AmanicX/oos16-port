# OxygenOS 16 Port for OnePlus 7T (`HD1901` / `hotdogb`)
### Pure Volatile RAM-Resident Execution via `fastboot boot` — Zero Physical Storage Writes

[![Android](https://img.shields.io/badge/Android-16%20Baklava%20(SDK%2036)-green.svg)](https://developer.android.com/)
[![Device](https://img.shields.io/badge/Device-OnePlus%207T%20(hotdogb)-blue.svg)](https://wiki.lineageos.org/devices/hotdogb/)
[![SoC](https://img.shields.io/badge/SoC-Snapdragon%20855%2B%20(SM8150--AC)-orange.svg)](https://www.qualcomm.com/)
[![Storage](https://img.shields.io/badge/Storage-100%25%20Read--Only%20RAM-red.svg)](#non-negotiable-safety-contract)
[![Tests](https://img.shields.io/badge/Tests-64%20Passing-brightgreen.svg)](#7-verification-status--test-matrix)

---

## 1. Project Overview & Objectives

This project ports and runs **OxygenOS 16** (Android 16 / SDK 36 / `BP4A.251205.006`) on the **OnePlus 7T (`HD1901` / `hotdogb`)** purely in volatile RAM using `fastboot boot`.

### Core Features & Architecture
1. **Zero Storage Alteration**: Internal UFS storage devices (`/dev/block/sd*`, `/dev/block/mmcblk*`) and all child partitions are dynamically locked read-only (`ro=1`). The existing installation (crDroid/LineageOS) and user data remain completely untouched.
2. **Volatile RAM Staging**: Staging filesystems (`/mnt` and `/tmp`) and ephemeral `/data` reside strictly in RAM (`tmpfs`), vanishing entirely upon power cycle.
3. **Display & Graphics Bringup**: Target Qualcomm DRM compositor (`msm_drm`), Adreno 640 GPU (`kgsl-3d0`), and `SurfaceFlinger` for OnePlus 7T AMOLED display (including fixed 60Hz aftermarket panels: `dsi_samsung_s6e3fc2x01_cmd_display`).
4. **Android 16 Bootstrap APEX Architecture**: Complete authentic staging and activation for all 4 bootstrap APEX modules (`com.android.runtime`, `com.android.art`, `com.android.i18n`, `com.android.tzdata`) with Bionic linker64, ART runtime libraries, ICU data, and timezone metadata.
5. **Google Photos & PIF Injections**: Feature overlays (`pixel_2016_experience.xml` + `pif.json` template) applied reversibly during image build.

---

## 2. Non-Negotiable Safety Contract

To guarantee that the host or phone never writes to physical internal flash:
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
| **`ota_full-LE2113_16.0.10.500.zip`** | Android 16 (`BP4A.251205.006`) | Official OnePlus / OPPO OTA Update Servers for OnePlus 9 Pro (`martinit`) | **Donor OS**: Provides OxygenOS 16 system framework, `system`, `system_ext`, `my_product`, and bootstrap APEX packages. |
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
│   └── watchdog.sh                # Modular Stage-1 watchdog supervisor script
├── tools/safe/                    # Host-side safety wrappers and auditors
│   ├── fastboot                   # Python safety wrapper blocking destructive commands
│   ├── adb                        # Python safety wrapper logging and blocking flash writes
│   ├── run_stage2.sh              # Host-side orchestrator pushing and executing Stage 2
│   └── audit-no-writes.sh         # Static auditor verifying 0 write commands in images
├── tests/                         # Unit and integration test suite
│   ├── test_safe_adb.py           # ADB safety proxy unit tests
│   ├── test_safe_fastboot.py      # Fastboot safety proxy unit tests
│   ├── test_watchdog.py           # Watchdog supervisor protocol test suite
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
3. Loop-mounts all staged partition images into `/mnt/sysroot/{system,system_ext,vendor,odm,product,my_product,my_region}`.
4. Populates and verifies Android 16 APEX bootstrap modules in canonical versioned structure:
   * Payload directories: `/mnt/sysroot/apex/${mod_name}@${version}`
   * Active symlinks: `/mnt/sysroot/apex/${mod_name} -> ${mod_name}@${version}`
   * `com.android.runtime@1` (Bionic `linker64`, `libc.so`, `libm.so`, `libdl.so`)
   * `com.android.art@361501120` (`libart.so`, `dalvikvm64`)
   * `com.android.i18n@1` (ICU libraries)
   * `com.android.tzdata@361157000` (Timezone data)
5. Mounts ephemeral `/data` tmpfs (1024 MB in RAM) and binds `/dev`, `/dev/pts`, `/proc`, `/sys`.
6. Performs display diagnostics: confirms DRM card0, KGSL 3D0, SurfaceFlinger binary, Composer HAL, and powers on AMOLED backlight.
7. Disarms Stage-1 watchdog cleanly by creating regular file `/mnt/watchdog_cancel` only after all mounts succeed. (On any failure, `fatal()` halts without disarming, ensuring safety reboot to bootloader).
8. Replaces process image via `exec /system/bin/chroot /mnt/sysroot /system/bin/init second_stage` (PID 1).

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

To maintain rigorous engineering honesty, verification states are strictly partitioned:

| Verification Tier | Scope | Status | Notes |
| :--- | :--- | :--- | :--- |
| **Tier 1: Implemented** | Full codebase, ramdisks, APEX extraction, scripts, and wrappers | **COMPLETE** | All modules implemented in accordance with architecture specifications. |
| **Tier 2: Static Checks Passed** | `tools/safe/audit-no-writes.sh` | **PASSED (23/23)** | Passed on `build/loader.img` and `build/stage1.img` with zero mandatory unverified checks. |
| **Tier 3: Host Tests Passed** | Automated Python & Shell unit/integration test suites | **PASSED (64/64)** | 100% pass across ADB proxy (8), Fastboot proxy (3), Watchdog protocol (10), and Stage-2 runner integration mocks (43). |
| **Tier 4: Build Passed** | Boot images & EROFS partition images | **PASSED** | `loader.img`, `stage1.img`, and all 10 Stage-2 images generated with valid SHA256SUMS. |
| **Tier 5: Device Boot Tested** | Live USB fastboot boot onto physical OnePlus 7T | **PENDING LIVE TEST** | Requires physical device tethering and testing in fastboot mode. |
| **Tier 6: Hardware Functionality Verified** | Display rendering, touchscreen, and hardware HALs | **PENDING LIVE TEST** | Requires live runtime inspection of `SurfaceFlinger` and DRM compositor. |

---

## 8. License & Disclaimer

This project is for research and development purposes. It does not flash, modify, format, or overwrite any physical internal partition. All operating system files run strictly in volatile memory (RAM) and are discarded upon power-off or reboot.
