# Authoritative OnePlus 7T Hardware Asset Integration Manifest

Target Device: **OnePlus 7T HD1901 (`hotdogb`)**  
Platform: **Qualcomm Snapdragon 855+ (SM8150-AC / `msmnile`)**  
Verification Mode: **AUTHENTIC HARDWARE VERIFICATION**  
Total Physical Partition Assets: **84 Images**  
Safety Policy: **STRICTLY RAM-ONLY (`fastboot boot`). Zero physical partition flashing, zero storage writes.**

## 1. Discrete Verification Stages Summary

| Verification Stage | Status | Detail |
| :--- | :---: | :--- |
| **1. INVENTORY_VERIFIED** | `PASSED` | 84 images checked against SHA-256 manifest |
| **2. ASSET_CLASSIFIED** | `PASSED` | All physical partitions assigned hardware roles & safety rules |
| **3. ASSET_EXTRACTED** | `PASSED` | Authentic DTB and Recovery DTBO extracted from boot/recovery |
| **4. ASSET_STAGED** | `PASSED` | Stage-1 kernel, DTB, and recovery DTBO staged and validated |
| **5. RUNTIME_CONFIG_VERIFIED** | `PASSED` | Firmware mount points & read-only options verified in fstab.qcom |
| **6. INTEGRATION_VERIFIED** | `PASSED` | End-to-end integration across all hardware subsystems |

## 2. Integrated Stage-1 Hardware Payloads

| Asset | Role / Source | Size (Bytes) | SHA-256 Checksum | Compatibility Verification |
| :--- | :--- | :--- | :--- | :--- |
| `stage1/kernel_src/dtb` | SM8150 Device Tree Blob / `boot_a.img` | 9,055,368 | `e4faf7c553f88246...` | `qcom,sm8150` verified |
| `stage1/kernel_src/recovery_dtbo` | Samsung AMOLED Panel DTBO / `recovery_a.img` | 3,219,456 | `7cfdd1984a7be7ed...` | Samsung `sofef03f_m` verified |
| `stage1/kernel_src/kernel` | SM8150 Linux 4.14 Kernel / Android 16 | 48,713,752 | `c32e3a267b1e44e9...` | `4.14.357-perf-gcd3073fb68f1` verified |

## 3. Stage-2 Runtime Firmware Mounts (`fstab.qcom`)

| Mount Point | Source Partition | Filesystem | Mount Flags | Safety Invariant |
| :--- | :--- | :--- | :--- | :--- |
| `/vendor/firmware_mnt` | `/dev/block/bootdevice/by-name/modem` | `vfat` | `ro,shortname=lower,uid=1000,gid=1000,dmask=227,fmask=337,context=u:object_r:firmware_file:s0` | **READ-ONLY ENFORCED** |
| `/vendor/dsp` | `/dev/block/bootdevice/by-name/dsp` | `ext4` | `ro,nosuid,nodev,barrier=1,noload` | **READ-ONLY ENFORCED** |
| `/vendor/bt_firmware` | `/dev/block/bootdevice/by-name/bluetooth` | `vfat` | `ro,shortname=lower,uid=1002,gid=3002,dmask=227,fmask=337,context=u:object_r:bt_firmware_file:s0` | **READ-ONLY ENFORCED** |
| `/mnt/vendor/persist` | `/dev/block/bootdevice/by-name/persist` | `ext4` | `ro,nosuid,nodev,barrier=1,noload` | **READ-ONLY ENFORCED** |

## 4. Persist Partition Physical Storage Contract

- **Physical UFS Preservation**: The phone's authentic `persist` partition is NEVER flashed, formatted, or modified.
- **Secrets Protection**: The dumped `persist.img` is NOT baked into public or distributable build images.
- **Mount Configuration**: Mounted strictly read-only (`ro,nosuid,nodev,barrier=1,noload`) at `/mnt/vendor/persist`.

## 5. Complete Physical Partition Inventory

| Partition Image | Size (Bytes) | Format | Architectural Category | Verification Status |
| :--- | :--- | :--- | :--- | :--- |
| `ALIGN_TO_128K_1.img` | 106,496 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `ALIGN_TO_128K_2.img` | 106,496 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `LOGO_a.img` | 16,777,216 | Binary Data Partition | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `LOGO_b.img` | 16,777,216 | Binary Data Partition | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `abl_a.img` | 8,388,608 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `abl_b.img` | 8,388,608 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `aop_a.img` | 524,288 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `aop_b.img` | 524,288 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `apdp.img` | 262,144 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `bluetooth_a.img` | 1,048,576 | FAT / vfat Filesystem | `REQUIRED_HARDWARE_FIRMWARE` | `[OK] VERIFIED` |
| `bluetooth_b.img` | 1,048,576 | FAT / vfat Filesystem | `REQUIRED_HARDWARE_FIRMWARE` | `[OK] VERIFIED` |
| `boot_a.img` | 100,663,296 | Android Boot Image v2 | `REQUIRED_RAM_BOOT` | `[OK] VERIFIED` |
| `boot_b.img` | 100,663,296 | Android Boot Image v2 | `REQUIRED_RAM_BOOT` | `[OK] VERIFIED` |
| `carrier.img` | 67,108,864 | ext4 Filesystem | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `catecontentfv.img` | 1,048,576 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `catefv.img` | 524,288 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `cateloader.img` | 2,097,152 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `cdt.img` | 131,072 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `cmnlib64_a.img` | 524,288 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `cmnlib64_b.img` | 524,288 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `cmnlib_a.img` | 524,288 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `cmnlib_b.img` | 524,288 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `config.img` | 524,288 | Binary Data Partition | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `ddr.img` | 1,048,576 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `devcfg_a.img` | 131,072 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `devcfg_b.img` | 131,072 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `devinfo.img` | 4,096 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `dip.img` | 1,048,576 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `dsp_a.img` | 67,108,864 | ext4 Filesystem | `REQUIRED_HARDWARE_FIRMWARE` | `[OK] VERIFIED` |
| `dsp_b.img` | 67,108,864 | ext4 Filesystem | `REQUIRED_HARDWARE_FIRMWARE` | `[OK] VERIFIED` |
| `dtbo_a.img` | 25,165,824 | DTBO Image (dtbo/dtb) | `REQUIRED_RAM_BOOT` | `[OK] VERIFIED` |
| `dtbo_b.img` | 25,165,824 | DTBO Image (dtbo/dtb) | `REQUIRED_RAM_BOOT` | `[OK] VERIFIED` |
| `fsc.img` | 131,072 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `fsg.img` | 2,097,152 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `hyp_a.img` | 8,388,608 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `hyp_b.img` | 8,388,608 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `imagefv_a.img` | 2,097,152 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `imagefv_b.img` | 2,097,152 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `keymaster_a.img` | 524,288 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `keymaster_b.img` | 524,288 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `limits.img` | 4,096 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `mdm1m9kefs1.img` | 1,048,576 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `mdm1m9kefs2.img` | 1,048,576 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `mdm1m9kefs3.img` | 1,048,576 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `mdm1m9kefsc.img` | 4,096 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `mdm1oemnvbktmp.img` | 1,048,576 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `mdm_oem_dycnvbk.img` | 1,048,576 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `mdm_oem_stanvbk.img` | 1,048,576 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `mdmddr.img` | 1,048,576 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `modem_a.img` | 314,572,800 | FAT / vfat Filesystem | `REQUIRED_HARDWARE_FIRMWARE` | `[OK] VERIFIED` |
| `modem_b.img` | 314,572,800 | FAT / vfat Filesystem | `REQUIRED_HARDWARE_FIRMWARE` | `[OK] VERIFIED` |
| `modemst1.img` | 2,097,152 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `modemst2.img` | 2,097,152 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `msadp.img` | 262,144 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `oem_dycnvbk.img` | 10,485,760 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `oem_stanvbk.img` | 10,485,760 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `op1.img` | 314,572,800 | ext4 Filesystem | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `op2.img` | 268,435,456 | ext4 Filesystem | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `opproduct_a.img` | 1,717,989,376 | ext4 Filesystem | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `opproduct_b.img` | 1,717,989,376 | ext4 Filesystem | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `param.img` | 1,048,576 | Binary Data Partition | `DEVICE_CALIBRATION_NVRAM` | `[OK] VERIFIED` |
| `persist.img` | 33,554,432 | ext4 Filesystem | `REQUIRED_HARDWARE_FIRMWARE` | `[OK] VERIFIED` |
| `qupfw_a.img` | 81,920 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `qupfw_b.img` | 81,920 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `recovery_a.img` | 100,663,296 | Android Boot Image v2 | `REQUIRED_RAM_BOOT` | `[OK] VERIFIED` |
| `recovery_b.img` | 100,663,296 | Android Boot Image v2 | `REQUIRED_RAM_BOOT` | `[OK] VERIFIED` |
| `secdata.img` | 28,672 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `splash.img` | 34,226,176 | Binary Data Partition | `REFERENCE_ONLY` | `[OK] VERIFIED` |
| `spunvm.img` | 8,388,608 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `storsec_a.img` | 131,072 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `storsec_b.img` | 131,072 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `tz_a.img` | 4,194,304 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `tz_b.img` | 4,194,304 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `uefisecapp_a.img` | 2,097,152 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `uefisecapp_b.img` | 2,097,152 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `uefivarstore.img` | 524,288 | Binary Data Partition | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `vbmeta_a.img` | 65,536 | AVB vbmeta Structure | `VERIFIED_BOOT_AVB` | `[OK] VERIFIED` |
| `vbmeta_b.img` | 65,536 | AVB vbmeta Structure | `VERIFIED_BOOT_AVB` | `[OK] VERIFIED` |
| `vbmeta_system_a.img` | 65,536 | AVB vbmeta Structure | `VERIFIED_BOOT_AVB` | `[OK] VERIFIED` |
| `vbmeta_system_b.img` | 65,536 | AVB vbmeta Structure | `VERIFIED_BOOT_AVB` | `[OK] VERIFIED` |
| `xbl_a.img` | 3,670,016 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `xbl_b.img` | 3,670,016 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `xbl_config_a.img` | 131,072 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
| `xbl_config_b.img` | 131,072 | ELF Binary / Qualcomm MBN | `FORBIDDEN_USERSPACE` | `[OK] VERIFIED` |
