# Authoritative OnePlus 7T Hardware Asset Integration Manifest

Target Device: **OnePlus 7T HD1901 (`hotdogb`)**  
Platform: **Qualcomm Snapdragon 855+ (SM8150-AC / `msmnile`)**  
Total Physical Partition Assets: **84 Images (100% Cryptographically Verified)**  
Safety Policy: **STRICTLY RAM-ONLY (`fastboot boot`). Zero physical partition flashing, zero storage writes.**

## 1. Executive Summary & Provenance Architecture

The 84 images in `partitions/` represent the authentic physical partition dump of the OnePlus 7T device. Dynamic partition contents (`system`, `system_ext`, `product`, `vendor`, `odm`) were omitted from physical storage because the stock device was retired on Android 11. They are provided at runtime by Tier 2 (OxygenOS 16 donor) and Tier 3 (LineageOS 23.2 SM8150 HAL base). The `data` partition is replaced by an ephemeral RAM tmpfs (`/data`).

### Category Breakdown

| Category | Count | Runtime Role | Safety Rule |
| :--- | :--- | :--- | :--- |
| Boot & Device Tree (RAM Boot & Overlays) | **6** | REQUIRED_RAM_BOOT | Extracted for Stage-1 |
| Subsystem Firmware & Runtime Mounts | **7** | REQUIRED_HARDWARE_FIRMWARE | Mounted read-only |
| Factory Calibration & Baseband NV (UFS Resident) | **17** | DEVICE_CALIBRATION_NVRAM | NEVER flash / UFS intact |
| Bootloader & Secure Firmware (FORBIDDEN from Userspace) | **41** | FORBIDDEN_USERSPACE | FORBIDDEN from userspace |
| Verified Boot Metadata (AVB) | **4** | VERIFIED_BOOT_AVB | Analysis only |
| Display Splash & Legacy Userspace (Reference Only) | **9** | REFERENCE_ONLY | Analysis only |

## 2. Integrated Hardware Assets Detail

### A. Stage-1 Boot & Hardware Overlays (`REQUIRED_RAM_BOOT`)

| Image | Size (B) | Format | Destination / Consumer | SHA-256 Checksum |
| :--- | :--- | :--- | :--- | :--- |
| `boot_a.img` | 100,663,296 | Android Boot Image v2 | Stage-1 boot image assembly (DTB extraction & kernel validation) | `6324a772e9b1de84...` |
| `boot_b.img` | 100,663,296 | Android Boot Image v2 | Alternate slot reference / fallback verification | `841dc715d2bf8197...` |
| `dtbo_a.img` | 25,165,824 | DTBO Image (dtbo/dtb) | Hardware overlay reference and panel parameter inspection | `668e54337925f1fc...` |
| `dtbo_b.img` | 25,165,824 | DTBO Image (dtbo/dtb) | Alternate slot reference | `668e54337925f1fc...` |
| `recovery_a.img` | 100,663,296 | Android Boot Image v2 | Stage-1 hardware extraction (DTB + Samsung AMOLED Recovery DTBO) | `0557bc27e4361cb4...` |
| `recovery_b.img` | 100,663,296 | Android Boot Image v2 | Alternate slot reference / fallback verification | `41965b2155f59a2f...` |

### B. Runtime Firmware Mounts (`REQUIRED_HARDWARE_FIRMWARE`)

| Image | Size (B) | Filesystem | Mount Point | Runtime Consumer |
| :--- | :--- | :--- | :--- | :--- |
| `bluetooth_a.img` | 1,048,576 | FAT / vfat Filesystem | /vendor/bt_firmware (mount read-only on physical device) | Qualcomm Bluetooth HAL (android.hardware.bluetooth@1.0-service-qti) |
| `bluetooth_b.img` | 1,048,576 | FAT / vfat Filesystem | /vendor/bt_firmware alternate slot | Qualcomm Bluetooth HAL |
| `dsp_a.img` | 67,108,864 | ext4 Filesystem | /vendor/dsp (mount read-only on physical device) | Qualcomm FastRPC userspace library (libadsprpc.so) and audio/sensor HALs |
| `dsp_b.img` | 67,108,864 | ext4 Filesystem | /vendor/dsp alternate slot | Qualcomm FastRPC driver |
| `modem_a.img` | 314,572,800 | FAT / vfat Filesystem | /vendor/firmware_mnt (mount read-only on physical device) | Qualcomm PIL (Peripheral Image Loader) kernel driver & RIL daemon |
| `modem_b.img` | 314,572,800 | FAT / vfat Filesystem | /vendor/firmware_mnt alternate slot | Qualcomm PIL kernel driver |
| `persist.img` | 33,554,432 | ext4 Filesystem | /mnt/vendor/persist (mounted read-only, physical UFS preserved) | Sensors HAL, Camera HAL, Wi-Fi driver, Goodix/Focaltech fingerprint HAL |

### C. Complete 84 Partition Asset Inventory

| Image Filename | Size (Bytes) | Detected Format | Category | Status |
| :--- | :--- | :--- | :--- | :--- |
| `ALIGN_TO_128K_1.img` | 106,496 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `ALIGN_TO_128K_2.img` | 106,496 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `LOGO_a.img` | 16,777,216 | Binary Data Partition | REFERENCE_ONLY | [OK] 100% Verified |
| `LOGO_b.img` | 16,777,216 | Binary Data Partition | REFERENCE_ONLY | [OK] 100% Verified |
| `abl_a.img` | 8,388,608 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `abl_b.img` | 8,388,608 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `aop_a.img` | 524,288 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `aop_b.img` | 524,288 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `apdp.img` | 262,144 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `bluetooth_a.img` | 1,048,576 | FAT / vfat Filesystem | REQUIRED_HARDWARE_FIRMWARE | [OK] 100% Verified |
| `bluetooth_b.img` | 1,048,576 | FAT / vfat Filesystem | REQUIRED_HARDWARE_FIRMWARE | [OK] 100% Verified |
| `boot_a.img` | 100,663,296 | Android Boot Image v2 | REQUIRED_RAM_BOOT | [OK] 100% Verified |
| `boot_b.img` | 100,663,296 | Android Boot Image v2 | REQUIRED_RAM_BOOT | [OK] 100% Verified |
| `carrier.img` | 67,108,864 | ext4 Filesystem | REFERENCE_ONLY | [OK] 100% Verified |
| `catecontentfv.img` | 1,048,576 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `catefv.img` | 524,288 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `cateloader.img` | 2,097,152 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `cdt.img` | 131,072 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `cmnlib64_a.img` | 524,288 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `cmnlib64_b.img` | 524,288 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `cmnlib_a.img` | 524,288 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `cmnlib_b.img` | 524,288 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `config.img` | 524,288 | Binary Data Partition | REFERENCE_ONLY | [OK] 100% Verified |
| `ddr.img` | 1,048,576 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `devcfg_a.img` | 131,072 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `devcfg_b.img` | 131,072 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `devinfo.img` | 4,096 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `dip.img` | 1,048,576 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `dsp_a.img` | 67,108,864 | ext4 Filesystem | REQUIRED_HARDWARE_FIRMWARE | [OK] 100% Verified |
| `dsp_b.img` | 67,108,864 | ext4 Filesystem | REQUIRED_HARDWARE_FIRMWARE | [OK] 100% Verified |
| `dtbo_a.img` | 25,165,824 | DTBO Image (dtbo/dtb) | REQUIRED_RAM_BOOT | [OK] 100% Verified |
| `dtbo_b.img` | 25,165,824 | DTBO Image (dtbo/dtb) | REQUIRED_RAM_BOOT | [OK] 100% Verified |
| `fsc.img` | 131,072 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `fsg.img` | 2,097,152 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `hyp_a.img` | 8,388,608 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `hyp_b.img` | 8,388,608 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `imagefv_a.img` | 2,097,152 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `imagefv_b.img` | 2,097,152 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `keymaster_a.img` | 524,288 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `keymaster_b.img` | 524,288 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `limits.img` | 4,096 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `mdm1m9kefs1.img` | 1,048,576 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `mdm1m9kefs2.img` | 1,048,576 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `mdm1m9kefs3.img` | 1,048,576 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `mdm1m9kefsc.img` | 4,096 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `mdm1oemnvbktmp.img` | 1,048,576 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `mdm_oem_dycnvbk.img` | 1,048,576 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `mdm_oem_stanvbk.img` | 1,048,576 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `mdmddr.img` | 1,048,576 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `modem_a.img` | 314,572,800 | FAT / vfat Filesystem | REQUIRED_HARDWARE_FIRMWARE | [OK] 100% Verified |
| `modem_b.img` | 314,572,800 | FAT / vfat Filesystem | REQUIRED_HARDWARE_FIRMWARE | [OK] 100% Verified |
| `modemst1.img` | 2,097,152 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `modemst2.img` | 2,097,152 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `msadp.img` | 262,144 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `oem_dycnvbk.img` | 10,485,760 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `oem_stanvbk.img` | 10,485,760 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `op1.img` | 314,572,800 | ext4 Filesystem | REFERENCE_ONLY | [OK] 100% Verified |
| `op2.img` | 268,435,456 | ext4 Filesystem | REFERENCE_ONLY | [OK] 100% Verified |
| `opproduct_a.img` | 1,717,989,376 | ext4 Filesystem | REFERENCE_ONLY | [OK] 100% Verified |
| `opproduct_b.img` | 1,717,989,376 | ext4 Filesystem | REFERENCE_ONLY | [OK] 100% Verified |
| `param.img` | 1,048,576 | Binary Data Partition | DEVICE_CALIBRATION_NVRAM | [OK] 100% Verified |
| `persist.img` | 33,554,432 | ext4 Filesystem | REQUIRED_HARDWARE_FIRMWARE | [OK] 100% Verified |
| `qupfw_a.img` | 81,920 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `qupfw_b.img` | 81,920 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `recovery_a.img` | 100,663,296 | Android Boot Image v2 | REQUIRED_RAM_BOOT | [OK] 100% Verified |
| `recovery_b.img` | 100,663,296 | Android Boot Image v2 | REQUIRED_RAM_BOOT | [OK] 100% Verified |
| `secdata.img` | 28,672 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `splash.img` | 34,226,176 | Binary Data Partition | REFERENCE_ONLY | [OK] 100% Verified |
| `spunvm.img` | 8,388,608 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `storsec_a.img` | 131,072 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `storsec_b.img` | 131,072 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `tz_a.img` | 4,194,304 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `tz_b.img` | 4,194,304 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `uefisecapp_a.img` | 2,097,152 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `uefisecapp_b.img` | 2,097,152 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `uefivarstore.img` | 524,288 | Binary Data Partition | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `vbmeta_a.img` | 65,536 | AVB vbmeta Structure | VERIFIED_BOOT_AVB | [OK] 100% Verified |
| `vbmeta_b.img` | 65,536 | AVB vbmeta Structure | VERIFIED_BOOT_AVB | [OK] 100% Verified |
| `vbmeta_system_a.img` | 65,536 | AVB vbmeta Structure | VERIFIED_BOOT_AVB | [OK] 100% Verified |
| `vbmeta_system_b.img` | 65,536 | AVB vbmeta Structure | VERIFIED_BOOT_AVB | [OK] 100% Verified |
| `xbl_a.img` | 3,670,016 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `xbl_b.img` | 3,670,016 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `xbl_config_a.img` | 131,072 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
| `xbl_config_b.img` | 131,072 | ELF Binary / Qualcomm MBN | FORBIDDEN_USERSPACE | [OK] 100% Verified |
