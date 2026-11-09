# OnePlus 7T (HD1901 / hotdogb) Target Partitions Inventory

**Device Profile:**
- **Model:** OnePlus 7T HD1901 (`hotdogb`)
- **Platform / SoC:** Qualcomm Snapdragon 855+ (`SM8150-AC` / `msmnile`)
- **RAM:** 8 GB LPDDR4X
- **Target OS:** OxygenOS 16 / Android 16 (SDK 36 / Baklava)
- **Execution Mode:** Strictly RAM-only (`fastboot boot`)

## 1. Summary of Discovered Assets

- **Total Partition Images:** 84
- **Integrity Status:** 100% verified against authentic `SHA256SUMS` manifest
- **Omitted Dynamic / Ephemeral Partitions:** `super` (dynamic logical containers) and `data` (ephemeral RAM tmpfs)

### Category Breakdown

| Category | Count | Primary Role |
| :--- | :--- | :--- |
| Bluetooth Subsystem | 2 | Hardware operation |
| Boot & Device Tree | 2 | Stage-1 kernel and device tree overlays |
| Boot & Kernel | 4 | Stage-1 kernel and device tree overlays |
| Bootloader & Secure Firmware | 31 | Stage-1 kernel and device tree overlays |
| Calibration & Security | 1 | Per-device hardware calibration (/mnt/vendor/persist) |
| Carrier Configuration | 1 | Hardware operation |
| Cellular Baseband | 2 | Cellular radio and RIL firmware (/vendor/firmware_mnt) |
| DSP & Audio Subsystem | 2 | Hexagon ADSP/CDSP audio and sensor DSP firmware (/vendor/dsp) |
| Display Splash | 3 | Hardware operation |
| Hardware / Config | 14 | Hardware operation |
| OEM Customization | 4 | OnePlus customization and carrier settings |
| Radio Calibration & NV | 14 | Per-device hardware calibration (/mnt/vendor/persist) |
| Verified Boot / Integrity | 4 | Stage-1 kernel and device tree overlays |

## 2. Comprehensive Partition Image Table

| Image Filename | Size (Bytes) | Format / FS | Category | Suitability | SHA-256 Checksum |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `ALIGN_TO_128K_1.img` | 106,496 | Binary Data Partition | Hardware / Config | **Reference Only** | `caa961e702d561d3...` |
| `ALIGN_TO_128K_2.img` | 106,496 | Binary Data Partition | Hardware / Config | **Reference Only** | `caa961e702d561d3...` |
| `LOGO_a.img` | 16,777,216 | Splash / Boot Logo Bitmap | Display Splash | **Reference Only** | `0c2c62faca3a4e65...` |
| `LOGO_b.img` | 16,777,216 | Splash / Boot Logo Bitmap | Display Splash | **Reference Only** | `0c2c62faca3a4e65...` |
| `abl_a.img` | 8,388,608 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `9bcac221251b98a0...` |
| `abl_b.img` | 8,388,608 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `9bcac221251b98a0...` |
| `aop_a.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `8e72f9cc9aae6d1b...` |
| `aop_b.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `8e72f9cc9aae6d1b...` |
| `apdp.img` | 262,144 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `82fec0357a1fe26b...` |
| `bluetooth_a.img` | 1,048,576 | FAT Filesystem (vfat) | Bluetooth Subsystem | **Direct Reuse** | `72a806d83274e8a5...` |
| `bluetooth_b.img` | 1,048,576 | FAT Filesystem (vfat) | Bluetooth Subsystem | **Direct Reuse** | `72a806d83274e8a5...` |
| `boot_a.img` | 100,663,296 | Android Boot Image v2 | Boot & Kernel | **Extraction / Direct Reuse** | `6324a772e9b1de84...` |
| `boot_b.img` | 100,663,296 | Android Boot Image v2 | Boot & Kernel | **Extraction / Direct Reuse** | `841dc715d2bf8197...` |
| `carrier.img` | 67,108,864 | ext4 Filesystem | Carrier Configuration | **Reference Only** | `5ae2ec05f378dea2...` |
| `catecontentfv.img` | 1,048,576 | Binary Data Partition | Hardware / Config | **Reference Only** | `30e14955ebf13522...` |
| `catefv.img` | 524,288 | Binary Data Partition | Hardware / Config | **Reference Only** | `07854d2fef297a06...` |
| `cateloader.img` | 2,097,152 | Binary Data Partition | Hardware / Config | **Reference Only** | `5647f05ec1895894...` |
| `cdt.img` | 131,072 | Hardware Parameter Table | Hardware / Config | **Reference Only** | `fa43239bcee7b97c...` |
| `cmnlib64_a.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `b7c775d91ef2a5a1...` |
| `cmnlib64_b.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `b7c775d91ef2a5a1...` |
| `cmnlib_a.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `b9f353b84038338b...` |
| `cmnlib_b.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `b9f353b84038338b...` |
| `config.img` | 524,288 | Binary Data Partition | Hardware / Config | **Reference Only** | `2db84805ea2ae2ef...` |
| `ddr.img` | 1,048,576 | Hardware Parameter Table | Hardware / Config | **Reference Only** | `60e4b969146973b2...` |
| `devcfg_a.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `f81dacc21cf91d09...` |
| `devcfg_b.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `f81dacc21cf91d09...` |
| `devinfo.img` | 4,096 | Hardware Parameter Table | Hardware / Config | **Reference Only** | `12691a5b12f4abea...` |
| `dip.img` | 1,048,576 | Binary Data Partition | Hardware / Config | **Reference Only** | `30e14955ebf13522...` |
| `dsp_a.img` | 67,108,864 | ext4 Filesystem | DSP & Audio Subsystem | **Direct Reuse** | `1ec56bbb1e84527c...` |
| `dsp_b.img` | 67,108,864 | ext4 Filesystem | DSP & Audio Subsystem | **Direct Reuse** | `1ec56bbb1e84527c...` |
| `dtbo_a.img` | 25,165,824 | Android DTBO Table v1 | Boot & Device Tree | **Direct Reuse / Extraction** | `668e54337925f1fc...` |
| `dtbo_b.img` | 25,165,824 | Android DTBO Table v1 | Boot & Device Tree | **Direct Reuse / Extraction** | `668e54337925f1fc...` |
| `fsc.img` | 131,072 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `fa43239bcee7b97c...` |
| `fsg.img` | 2,097,152 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `5647f05ec1895894...` |
| `hyp_a.img` | 8,388,608 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `a5646e0fe1e0814e...` |
| `hyp_b.img` | 8,388,608 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `a5646e0fe1e0814e...` |
| `imagefv_a.img` | 2,097,152 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `a71dfdc84a03093b...` |
| `imagefv_b.img` | 2,097,152 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `a71dfdc84a03093b...` |
| `keymaster_a.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `ffe97683e2f09ca8...` |
| `keymaster_b.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `ffe97683e2f09ca8...` |
| `limits.img` | 4,096 | Hardware Parameter Table | Hardware / Config | **Reference Only** | `f05cf6deb8f78bb8...` |
| `mdm1m9kefs1.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `30e14955ebf13522...` |
| `mdm1m9kefs2.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `30e14955ebf13522...` |
| `mdm1m9kefs3.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `30e14955ebf13522...` |
| `mdm1m9kefsc.img` | 4,096 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `ad7facb2586fc6e9...` |
| `mdm1oemnvbktmp.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `30e14955ebf13522...` |
| `mdm_oem_dycnvbk.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `30e14955ebf13522...` |
| `mdm_oem_stanvbk.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `30e14955ebf13522...` |
| `mdmddr.img` | 1,048,576 | Binary Data Partition | Hardware / Config | **Reference Only** | `30e14955ebf13522...` |
| `modem_a.img` | 314,572,800 | FAT Filesystem (vfat) | Cellular Baseband | **Direct Reuse** | `d3b237d27b399ce7...` |
| `modem_b.img` | 314,572,800 | FAT Filesystem (vfat) | Cellular Baseband | **Direct Reuse** | `d3b237d27b399ce7...` |
| `modemst1.img` | 2,097,152 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `85f1e6fa549388c7...` |
| `modemst2.img` | 2,097,152 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `61d688caec110067...` |
| `msadp.img` | 262,144 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `3b7a4522631ea9c9...` |
| `oem_dycnvbk.img` | 10,485,760 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `dd0fa093cf08030c...` |
| `oem_stanvbk.img` | 10,485,760 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `9619d75a70b257d2...` |
| `op1.img` | 314,572,800 | ext4 Filesystem | OEM Customization | **Reference Only** | `c724057efec911e6...` |
| `op2.img` | 268,435,456 | ext4 Filesystem | OEM Customization | **Reference Only** | `b64e865d8c443838...` |
| `opproduct_a.img` | 1,717,989,376 | ext4 Filesystem | OEM Customization | **Reference / Selective Merging** | `796cc464b8d905b1...` |
| `opproduct_b.img` | 1,717,989,376 | ext4 Filesystem | OEM Customization | **Reference / Selective Merging** | `7e416c00320c7ac4...` |
| `param.img` | 1,048,576 | Hardware Parameter Table | Hardware / Config | **Reference Only** | `024c73a514e8bf68...` |
| `persist.img` | 33,554,432 | ext4 Filesystem | Calibration & Security | **Reference Only (Hardware Device Persist)** | `be1554d91f0c362c...` |
| `qupfw_a.img` | 81,920 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `a57cce639459a2c6...` |
| `qupfw_b.img` | 81,920 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `a57cce639459a2c6...` |
| `recovery_a.img` | 100,663,296 | Android Boot Image v2 | Boot & Kernel | **Extraction / Direct Reuse** | `0557bc27e4361cb4...` |
| `recovery_b.img` | 100,663,296 | Android Boot Image v2 | Boot & Kernel | **Extraction / Direct Reuse** | `41965b2155f59a2f...` |
| `secdata.img` | 28,672 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `c1f6356d1a4591f0...` |
| `splash.img` | 34,226,176 | Splash / Boot Logo Bitmap | Display Splash | **Reference Only** | `7283ab986bc6374f...` |
| `spunvm.img` | 8,388,608 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | **Reference Only (Device Specific Hardware)** | `2daeb1f36095b44b...` |
| `storsec_a.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `4b913bc198abd925...` |
| `storsec_b.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `4b913bc198abd925...` |
| `tz_a.img` | 4,194,304 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `1cc890914292550f...` |
| `tz_b.img` | 4,194,304 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `1cc890914292550f...` |
| `uefisecapp_a.img` | 2,097,152 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `cef95b58a3382cd8...` |
| `uefisecapp_b.img` | 2,097,152 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `cef95b58a3382cd8...` |
| `uefivarstore.img` | 524,288 | Binary Data Partition | Hardware / Config | **Reference Only** | `07854d2fef297a06...` |
| `vbmeta_a.img` | 65,536 | Android Verified Boot (AVB 2.0) | Verified Boot / Integrity | **Reference Only** | `ea376996e61d6927...` |
| `vbmeta_b.img` | 65,536 | Android Verified Boot (AVB 2.0) | Verified Boot / Integrity | **Reference Only** | `312a2485b1abe217...` |
| `vbmeta_system_a.img` | 65,536 | Android Verified Boot (AVB 2.0) | Verified Boot / Integrity | **Reference Only** | `e9fb2e584d5dcb93...` |
| `vbmeta_system_b.img` | 65,536 | Android Verified Boot (AVB 2.0) | Verified Boot / Integrity | **Reference Only** | `d1776b3138f579ab...` |
| `xbl_a.img` | 3,670,016 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `16079f32e6557641...` |
| `xbl_b.img` | 3,670,016 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `16079f32e6557641...` |
| `xbl_config_a.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `63c73af81ef5b854...` |
| `xbl_config_b.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | **Direct Reuse (Target UFS)** | `63c73af81ef5b854...` |

## 3. Actionable Utilization Plan

### A. Direct Reuse / Device Integration
These authentic OnePlus 7T partitions provide the hardware firmware stack required by the SM8150 SoC:
- `modem_a.img` / `modem_b.img`: Mounted to `/vendor/firmware_mnt` (FAT) for Qualcomm cellular baseband.
- `dsp_a.img` / `dsp_b.img`: Mounted to `/vendor/dsp` (ext4) for Hexagon audio/sensor DSP.
- `bluetooth_a.img` / `bluetooth_b.img`: Mounted to `/vendor/bt_firmware` (FAT) for Bluetooth controller NVM.
- `dtbo_a.img` / `dtbo_b.img`: Device tree overlays (10 DT entries) for OnePlus 7T hardware.
- Firmware partitions (`abl`, `xbl`, `tz`, `hyp`, `aop`, `keymaster`, `cmnlib`, `qupfw`, `storsec`): Resident on device UFS; required for hardware cryptographic bootloader environment.

### B. Extracted Hardware Kernel Base
- `boot_a.img`: Contains authentic Linux 4.14.357 SM8150 kernel built with Android 16 Clang 21 toolchain (`14054515`). Extracted for Stage-1 `loader.img` and `stage1.img`.
- Ramdisk fstab (`system/etc/fstab.qcom`): Authoritative reference for partition mountpoints and flags.

### C. Vendor / ODM Dynamic Partitions
- Sourced from LineageOS 23.2 for `hotdogb` (`extracted/base_lineage/vendor.img` and `odm.img`), providing the Android 16 (SDK 36, target-level 7) HAL implementation for SM8150 display (Adreno 640), audio, camera, sensors, and RIL.

### D. Donor Partitions (OnePlus 9 OxygenOS 16)
- Sourced from `extracted_donor/` (`system`, `system_ext`, `my_product`, `my_region`, bootstrap APEX modules) providing the authentic OxygenOS 16 userspace and framework.
