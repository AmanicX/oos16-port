# Build Dependencies & External Assets Specification

This document details all external tools, hardware assets, firmware packages, and dependencies required to build and stage the OxygenOS 16 port for the OnePlus 7T (`HD1901` / `hotdogb`).

---

## 1. Required Host Tools

The following build tools must be installed on your Linux workstation:

| Tool | Minimum Version | Package / Download Source | Verification Command |
| :--- | :--- | :--- | :--- |
| **`mkbootimg`** | AOSP / v2+ | `android-tools` or `external/coloros_port/otatools/bin/` | `mkbootimg --version` |
| **`mkbootfs`** | AOSP | `android-tools` or `external/coloros_port/otatools/bin/` | `mkbootfs -h` |
| **`unpack_bootimg`** | AOSP | `android-tools` or `external/coloros_port/otatools/bin/` | `unpack_bootimg --help` |
| **`lz4`** | 1.9.0+ | Distribution repository (`apt install lz4` / `pacman -S lz4`) | `lz4 --version` |
| **`cpio`** | GNU 2.13+ | Distribution repository (`apt install cpio` / `pacman -S cpio`) | `cpio --version` |
| **`mkfs.erofs`** | 1.6+ | `erofs-utils` or `external/coloros_port/bin/Linux/x86_64/` | `mkfs.erofs -V` |
| **`fsck.erofs`** | 1.6+ | `erofs-utils` or `external/coloros_port/bin/Linux/x86_64/` | `fsck.erofs -V` |
| **`python3`** | 3.8+ | Standard Python 3 installation | `python3 --version` |

---

## 2. Hardware Kernel Assets (`stage1/kernel_src/`)

Because hardware kernel binaries are excluded from Git to prevent repository bloat, they must be placed in `stage1/kernel_src/`:

| Expected File Location | Description | Source Package | Expected SHA-256 |
| :--- | :--- | :--- | :--- |
| `stage1/kernel_src/kernel` | Linux 4.14.357-perf kernel binary | Extracted from LineageOS 23.2 recovery for hotdogb | `c43a41b53874136611417a86828fe6f6ea312384a51165215ff5df9f872b2c45` |
| `stage1/kernel_src/dtb` | SM8150 Snapdragon 855+ Device Tree Blob | Extracted from LineageOS 23.2 recovery for hotdogb | `a39151c5dc9670f9df50f38b1f851086bf8a08f51ec7dbdc1cbe8e4e93fb25db` |
| `stage1/kernel_src/recovery_dtbo` | Device Tree Blob Overlay for recovery | Extracted from LineageOS 23.2 recovery for hotdogb | `839fc41ebae7bfae6fec745e6eb48625ef356ba67e81406859341c2c31cb160d` |

### How to Extract Hardware Assets:
1. Download the official LineageOS 23.2 recovery image for OnePlus 7T (`hotdogb`):
   ```bash
   # From official LineageOS downloads for hotdogb
   wget https://download.lineageos.org/devices/hotdogb
   ```
2. Unpack the recovery image into `stage1/kernel_src`:
   ```bash
   mkdir -p stage1/kernel_src
   unpack_bootimg --boot_img lineage-23.2-recovery-hotdogb.img --out stage1/kernel_src
   mv stage1/kernel_src/dtbo stage1/kernel_src/recovery_dtbo
   ```

---

## 3. Donor ROM & Base Partitions (`work/`)

To build the Stage-2 EROFS images, the following donor and base partitions must be extracted into `work/`:

| Directory | Source Package | Version / Build | Role |
| :--- | :--- | :--- | :--- |
| `work/system/` | `ota_full-LE2113_16.0.10.500.zip` | Android 16 (`BP4A.251205.006`) | OxygenOS 16 system framework |
| `work/system_ext/` | `ota_full-LE2113_16.0.10.500.zip` | Android 16 (`BP4A.251205.006`) | OxygenOS 16 extensions & OnePlus services |
| `work/my_product/` | `ota_full-LE2113_16.0.10.500.zip` | Android 16 (`BP4A.251205.006`) | OnePlus system UI overlays and product apps |
| `work/my_region/` | `ota_full-LE2113_16.0.10.500.zip` | Android 16 (`BP4A.251205.006`) | Regional customizations |
| `work/vendor/` | `lineage-23.2-*-hotdogb-signed.zip` | Android 16 / SDK 36 (hotdogb) | Snapdragon 855 graphics, DRM, display HALs |
| `work/odm/` | `lineage-23.2-*-hotdogb-signed.zip` | Android 16 / SDK 36 (hotdogb) | OnePlus 7T device-specific configurations |

---

## 4. Porting Utilities (`external/coloros_port`)

Upstream ColorOS / OxygenOS porting utilities can be acquired via:
```bash
git clone https://github.com/toraidl/coloros_port external/coloros_port -b COS16/OOS16
```
This repository provides precompiled binaries for `mkbootfs`, `mkbootimg`, `unpack_bootimg`, and `mkfs.erofs`.
