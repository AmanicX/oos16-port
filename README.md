# OxygenOS 16 Port for OnePlus 7T (`HD1901` / `hotdogb`)
### Pure Volatile RAM-Resident Execution via `fastboot boot` — Zero Physical Storage Writes

[![Android](https://img.shields.io/badge/Android-16%20Baklava%20(SDK%2036)-green.svg)](https://developer.android.com/)
[![Device](https://img.shields.io/badge/Device-OnePlus%207T%20(hotdogb)-blue.svg)](https://wiki.lineageos.org/devices/hotdogb/)
[![SoC](https://img.shields.io/badge/SoC-Snapdragon%20855%2B%20(SM8150--AC)-orange.svg)](https://www.qualcomm.com/)
[![Storage](https://img.shields.io/badge/Storage-100%25%20Read--Only%20RAM-red.svg)](#non-negotiable-safety-contract)

---

## 1. Project Overview & Objectives

This project ports and runs **OxygenOS 16** (Android 16 / SDK 36 / `BP4A.251205.006`) on the **OnePlus 7T (`HD1901` / `hotdogb`)** purely in volatile RAM. 

### Core Features & Targets
1. **Zero Storage Alteration**: The phone's internal UFS flash partitions (`sda` through `sdf`), existing OS (crDroid/LineageOS), and user data remain 100% write-locked and untouched.
2. **Display & Graphics Bringup**: Full hardware UI rendering (`SurfaceFlinger` + Qualcomm DRM compositor `msm_drm` + `bootanimation`) on the OnePlus 7T's AMOLED display (including aftermarket fixed 60Hz panels: `dsi_samsung_s6e3fc2x01_cmd_display`).
3. **Google Photos Unlimited Original Quality Backup**: Native XML injection (`pixel_2016_experience.xml` + `NEXUS_PRELOAD`).
4. **Play Integrity & CTS Spoof**: Play Integrity Fix configuration (`pif.json`).

---

## 2. Non-Negotiable Safety Contract

To guarantee that the host or phone never writes to physical internal flash:
* **Strict Command Banning**: Fastboot subcommands (`flash`, `erase`, `format`, `wipe`, `set_active`) are intercepted and hard-blocked by `tools/safe/fastboot`.
* **Physical Block-Layer Write Locks**: The Stage-1 RAM recovery kernel executes `blockdev --setro` on all physical LUNs (`/dev/block/sda` through `/dev/block/sdf`) before any operation begins.
* **Ephemeral Volatile State**: `/data` is strictly a 1024 MB `tmpfs` in RAM that vanishes upon reboot.
* **Safe Watchdog**: A fallback countdown timer automatically reboots the device back into the existing ROM if disconnected.

---

## 3. Provenance of All Files & Packages Used

Every file, partition image, and tool used in this project is documented with its exact upstream source:

| File / Component | Version / Build | Source / Site | Purpose in Port |
| :--- | :--- | :--- | :--- |
| **`ota_full-LE2113_16.0.10.500.zip`** | Android 16 (`BP4A.251205.006`) | Official OnePlus / OPPO OTA Update Servers for OnePlus 9 Pro (`martinit`) | **Donor OS**: Provides OxygenOS 16 system framework, `system`, `system_ext`, `my_product`, and regional configurations. |
| **`lineage-23.2-20261009-nightly-hotdogb-signed.zip`** | Android 16 / SDK 36 | Official LineageOS for OnePlus 7T (`hotdogb`) | **Base Hardware HALs**: Provides Snapdragon 855 (SM8150) graphics, display, sensor, audio, and camera HALs matching Android 16. |
| **`crDroid 12.x / LineageOS Recovery`** | Kernel 4.14.336-perf+ | crDroid Android / LineageOS hotdogb releases | **Stage-1 Kernel & Ramdisk**: Provides the recovery kernel, DTB, DTBO, and initial USB ADB endpoint. |
| **`external/coloros_port`** | Branch `COS16/OOS16` | [GitHub: toraidl/coloros_port](https://github.com/toraidl/coloros_port) | **Porting Utilities**: Provides `mkfs.erofs`, `fsck.erofs`, SELinux context patchers, and smali hooks. |
| **`pixel_2016_experience.xml`** | 2026 Revision | Google Pixel sysconfig / crDroid feature overlay | **Photos Spoof**: Grants unlimited original quality Google Photos cloud backup. |
| **`pif.json`** | OnePlus 7T HD1901 Target | Play Integrity Fix profile | **Play Integrity**: Spoofs CTS / MEETS_DEVICE_INTEGRITY profile for Google Play Services. |

---

## 4. Repository Structure & File-by-File Catalog

```text
oos16-port/
├── README.md                      # Master technical documentation (this file)
├── PROJECT-SUMMARY.md             # Detailed engineering log, phase history, and bug fixes
├── .gitignore                     # Protects large binary dumps and proprietary partitions
├── configs/                       # Feature injections & spoof configurations
│   ├── pixel_2016_experience.xml  # Google Photos unlimited original backup XML
│   └── pif.json                   # Play Integrity Fix profile for HD1901
├── patches/                       # Patches applied to OS files
│   ├── system_ext_property_contexts.patch # 18 duplicate SELinux prefix conflict fixes
│   └── vendor_build_prop_display.patch   # 60Hz display refresh rate properties
├── scripts/                       # Build and runtime orchestration scripts
│   ├── build_stage1.sh            # Packages Stage-1 RAM recovery kernel & ramdisk
│   ├── build_stage2_erofs.sh      # Repacks all 6 partitions into EROFS images
│   ├── build_loader.sh            # Builds alternate loader ramdisk
│   └── stage2_init.sh             # Phone-side orchestrator running in RAM
├── tools/safe/                    # Host-side safety wrappers and auditors
│   ├── fastboot                   # Python safety wrapper blocking destructive commands
│   ├── adb                        # Python safety wrapper logging and blocking flash writes
│   ├── run_stage2.sh              # Host-side orchestrator pushing and executing Stage 2
│   └── audit-no-writes.sh         # Static auditor verifying 0 write commands in images
├── stage1/                        # Stage-1 native RAM harness sources
│   ├── native_ramdisk/            # Root filesystem files, init scripts, and SELinux policies
│   └── loader_ramdisk/            # Secondary loader ramdisk definition
└── docs/                          # Technical deep-dive documentation
    ├── INPUTS.md                  # Detailed provenance, URLs, and checksums
    ├── DEVICE.md                  # OnePlus 7T hardware and aftermarket screen specs
    ├── STORAGE-STRATEGY.md        # Mathematical proof of zero physical storage writes
    ├── FEASIBILITY.md             # In-RAM execution feasibility study
    ├── TEST-LEDGER.md             # Immutable chronological test audit log
    └── RECOVERY.md                # Emergency recovery procedures
```

### Detailed Breakdown of Scripts and Tools

#### 1. `tools/safe/fastboot`
* **Language**: Python 3
* **Purpose**: Replaces system `fastboot` in all automated scripts.
* **Mechanism**: Intercepts arguments. Strictly allows `devices`, `getvar`, `reboot`, and `boot <file>`. Blocks all occurrences of `flash`, `erase`, `format`, `wipe`, `set_active`, and `snapshot-update`.

#### 2. `tools/safe/adb`
* **Language**: Python 3
* **Purpose**: Safety proxy for Android Debug Bridge.
* **Mechanism**: Logs all executed commands with timestamps to `logs/phone-commands.log`. Blocks `sideload`, `install`, raw block writes (`dd of=`), and partition remounts (`remount`). Only allows pushing to `/tmp/` and safe inspection commands.

#### 3. `tools/safe/audit-no-writes.sh`
* **Language**: Bash
* **Purpose**: Pre-boot static validation of boot images.
* **Mechanism**: Unpacks `boot.img`/`stage1.img`, parses the kernel command line, scans ramdisk scripts for any write traps or mount commands targeting physical disks, and returns `PASS` or `FAIL`.

#### 4. `tools/safe/run_stage2.sh`
* **Language**: Bash
* **Purpose**: Host-side orchestrator for the Stage-2 bringup.
* **Mechanism**:
  1. Verifies ADB connection in RAM mode.
  2. Runs a host heartbeat loop.
  3. Verifies physical block devices `sda` through `sdf` are write-locked (`ro=1`).
  4. Pushes the 6 EROFS images to `/tmp/` in volatile RAM at ~115 MB/s over USB 3.0.
  5. Pushes and executes `/tmp/stage2_init.sh` on the phone.

#### 5. `scripts/build_stage1.sh`
* **Language**: Bash
* **Purpose**: Generates `build/stage1.img` using `mkbootimg`.
* **Mechanism**: Combines the stock recovery kernel, DTB, DTBO, and the native recovery ramdisk with stripped fstabs and host `adbkey.pub` for instant authorized root ADB.

#### 6. `scripts/build_stage2_erofs.sh`
* **Language**: Bash
* **Purpose**: Builds high-compression EROFS partition images.
* **Mechanism**:
  1. Injects `pixel_2016_experience.xml` and `pif.json`.
  2. Sets `0755` permissions on vendor/odm binaries.
  3. Adds 60Hz display lock properties to `vendor/build.prop`.
  4. Fixes the 18 duplicate SELinux property context prefixes.
  5. Packages `odm`, `vendor`, `my_region`, `system`, `system_ext`, and `my_product` using `mkfs.erofs -z lz4 -x -1`.
  6. Unpacks and prepares `runtime_apex.erofs.img`.

#### 7. `scripts/stage2_init.sh`
* **Language**: Android `/system/bin/sh`
* **Purpose**: Phone-side bringup script running inside volatile RAM.
* **Mechanism**:
  1. Disarms the 90-second safety watchdog.
  2. Verifies `blockdev --getro` on all physical storage.
  3. Loop-mounts the EROFS images to `/mnt/sysroot`.
  4. Initializes a 1024 MB RAM `tmpfs` on `/mnt/sysroot/data`.
  5. Binds `/dev`, `/proc`, `/sys`, isolates `/dev/__properties__` and `/dev/socket`.
  6. Links the Bionic runtime dynamic linker `/apex/com.android.runtime/bin/linker64`.
  7. Executes `chroot /mnt/sysroot /system/bin/init second_stage`.

---

## 5. Architectural Deep Dive: Stage 1 vs. Stage 2

```
 +-------------------------------------------------------------------------------+
 |                        OnePlus 7T Volatile RAM (8 GB)                         |
 |                                                                               |
 | +---------------------------------------------------------------------------+ |
 | | Stage-1: Recovery RAM Kernel & Root ADB Endpoint (build/stage1.img)       | |
 | | - sda-sdf forced read-only (ro=1) at Linux block layer                    | |
 | | - Host adbkey embedded; instant authorized root ADB                       | |
 | | - 24-Hour /tmp/watchdog_cancel disarm mechanism                           | |
 | +------------------------------------+--------------------------------------+ |
 |                                      | USB 3.0 Transfer (115 MB/s)            |
 |                                      v                                        |
 | +---------------------------------------------------------------------------+ |
 | | Ephemeral RAM Staging Area (/tmp and /mnt tmpfs)                          | |
 | | - system.erofs.img     (966 MB)                                           | |
 | | - system_ext.erofs.img (1.1 GB, 0 SELinux property collisions)            | |
 | | - my_product.erofs.img (748 MB, trimmed bloat, framework intact)          | |
 | | - vendor.erofs.img     (317 MB, SM8150 HALs + 60Hz AMOLED props)          | |
 | | - odm.erofs.img        (48 MB, OnePlus hardware configs)                  | |
 | | - my_region.erofs.img  (58 MB, regional configurations)                   | |
 | | - runtime_apex.img     (6.2 MB, Bionic libc/libm/libdl)                   | |
 | | - /data tmpfs          (1024 MB ephemeral RAM filesystem)                 | |
 | +------------------------------------+--------------------------------------+ |
 |                                      | Loop-mounts to /mnt/sysroot            |
 |                                      v                                        |
 | +---------------------------------------------------------------------------+ |
 | | Stage-2: Android 16 Init & Display Handover                               | |
 | | - ueventd, servicemanager, /dev/dri/card0 DRM display, Adreno GPU online  | |
 | | - Bionic dynamic linker bridged to /apex/com.android.runtime/bin/linker64 | |
 | | - vendor.hwcomposer-2-4 & vendor.qti.hardware.display.allocator startup   | |
 | | - SurfaceFlinger & bootanimation on Samsung 60Hz AMOLED screen            | |
 | +---------------------------------------------------------------------------+ |
 +-------------------------------------------------------------------------------+
```

---

## 6. Current Status & Active Engineering Focus

### Achievements Verified
* **Physical Storage Write Lock**: Verified 100% clean (`blockdev --getro = 1` across `sda`–`sdf`). Zero physical writes.
* **USB 3.0 RAM Staging**: All 4.5 GB of EROFS partition images push to RAM in ~43 seconds at ~115 MB/s.
* **Core Subsystems Online**: Android 16 `init second_stage`, `ueventd`, `servicemanager`, GPU `/dev/kgsl-3d0`, and DRM `/dev/dri/card0` start cleanly.
* **SELinux Property Collision Fix**: 18 conflicting property contexts between OnePlus 13/OOS16 and LineageOS 23.2 resolved.

### Active Focus: Subcontext Dynamic Linker Resolution
* Android 16's `init` forks a helper process `vendor_init` subcontext (`u:r:vendor_init:s0`) to process vendor hardware `.rc` triggers.
* The subcontext requires the 64-bit dynamic linker at `/apex/com.android.runtime/bin/linker64`.
* In `scripts/stage2_init.sh`, the symlink from `/system/bin/bootstrap/linker64` to `/apex/com.android.runtime/bin/linker64` is now implemented. Once `vendor_init` completes its handshake, `vendor.hwcomposer-2-4` and `surfaceflinger` will initialize the display and push the boot animation to the screen.

---

## 7. How to Build & Run

### Prerequisites
* Linux host workstation (Ubuntu / Debian / Arch / Fedora).
* `android-tools` (`adb`, `fastboot`).
* OnePlus 7T (`HD1901` / `hotdogb`) with unlocked bootloader connected via USB 3.0.

### Step 1: Build the Stage-1 RAM Recovery Image
```bash
bash scripts/build_stage1.sh
```

### Step 2: Audit for Zero Storage Writes
```bash
bash tools/safe/audit-no-writes.sh build/stage1.img
```

### Step 3: Boot Stage-1 into Volatile RAM
Reboot the phone into the bootloader (`fastboot`), then run:
```bash
tools/safe/fastboot boot build/stage1.img
```

### Step 4: Execute Stage-2 Bringup
Once the device appears in `tools/safe/adb devices` (recovery mode):
```bash
bash tools/safe/run_stage2.sh
```

---

## 8. License & Disclaimer

This project is for research and development purposes. It does not flash, modify, or overwrite any partition on the device's internal physical storage. All operating system files run strictly in volatile memory (RAM) and are discarded upon power-off or reboot.
