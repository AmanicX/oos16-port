# OnePlus 7T (HD1901 / hotdogb) Target Partitions Inventory

**Device Profile:**
- **Model:** OnePlus 7T HD1901 (`hotdogb`)
- **Platform / SoC:** Qualcomm Snapdragon 855+ (`SM8150-AC` / `msmnile`)
- **RAM:** 8 GB LPDDR4X
- **Target OS:** OxygenOS 16 / Android 16 (SDK 36 / Baklava)
- **Execution Mode:** Strictly RAM-only (`fastboot boot`)

## 1. Summary of Discovered Assets

- **Total Partition Images Discovered:** 84
- **Cryptographically Verified:** 84
- **Checksum Mismatches:** 0
- **Missing Manifest Entries:** 0
- **Duplicate Manifest Entries:** 0
- **Unexpected Manifest Entries:** 0
- **Integrity Status:** **100% VERIFIED** (all 84 images matched cryptographic SHA-256 hashes against `SHA256SUMS`)

## 2. Explicit Provenance Architecture

This project strictly separates four distinct partition provenance tiers:

1. **Tier 1 — Authentic OnePlus 7T Physical Partition Images (`partitions/*.img`):**
   - 84 authentic dumped partition images from the physical device (boot, dtbo, modem, dsp, bluetooth, bootloader, trustzone, NVRAM).
   - **Note on Dynamic Partitions:** The omitted dynamic `super` partition is NOT present in this raw dump. Dynamic logical partitions (`system`, `system_ext`, `product`, `vendor`, `odm`) are provided by Tiers 2 and 3.
   - **Note on Userdata:** The `data` partition is deliberately omitted from physical storage and replaced with an ephemeral 1024 MB RAM tmpfs (`/data`) during Stage 2.
   - **Safety Policy:** These images are inspected for hardware extraction and verification ONLY. NEVER flash, write, or restore them to the phone.

2. **Tier 2 — OxygenOS 16 OnePlus 9 Donor Logical Partitions (`extracted_donor/`):**
   - Extracted from OnePlus 9 (lemonade / LE2113) build `LE2113_16.0.10.500`.
   - Provides the authentic OxygenOS 16 Android 16 (SDK 36) userspace: `system`, `system_ext`, `my_product`, `my_region`, `product`, and bootstrap APEXes.

3. **Tier 3 — Separately Sourced OnePlus 7T Vendor/ODM Trees (`work/vendor`, `work/odm`):**
   - Sourced from LineageOS 23.2 for `hotdogb` (`extracted/base_lineage/`), providing the Android 16 (SDK 36, target-level 7) HAL implementation for SM8150 display (Adreno 640), audio, camera, sensors, and RIL.
   - **Clarification:** These are NOT stock OnePlus OxygenOS vendor/ODM images (stock OnePlus 7T was never updated beyond Android 11 / SDK 30; Android 16 requires target-level 7 HALs).

4. **Tier 4 — Generated RAM-Only Boot Images (`build/loader.img`, `build/stage1.img`, `build/images/`):**
   - Ephemeral boot packages packaged in EROFS and booted via `fastboot boot` without modifying device UFS.

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

## 3. Comprehensive Partition Image Table

| Image Filename | Size (Bytes) | Format / FS | Category | Verification | Computed SHA-256 Checksum |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `ALIGN_TO_128K_1.img` | 106,496 | Binary Data Partition | Hardware / Config | [OK] Verified | `caa961e702d561d3...` |
| `ALIGN_TO_128K_2.img` | 106,496 | Binary Data Partition | Hardware / Config | [OK] Verified | `caa961e702d561d3...` |
| `LOGO_a.img` | 16,777,216 | Splash / Boot Logo Bitmap | Display Splash | [OK] Verified | `0c2c62faca3a4e65...` |
| `LOGO_b.img` | 16,777,216 | Splash / Boot Logo Bitmap | Display Splash | [OK] Verified | `0c2c62faca3a4e65...` |
| `abl_a.img` | 8,388,608 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `9bcac221251b98a0...` |
| `abl_b.img` | 8,388,608 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `9bcac221251b98a0...` |
| `aop_a.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `8e72f9cc9aae6d1b...` |
| `aop_b.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `8e72f9cc9aae6d1b...` |
| `apdp.img` | 262,144 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `82fec0357a1fe26b...` |
| `bluetooth_a.img` | 1,048,576 | FAT Filesystem (vfat) | Bluetooth Subsystem | [OK] Verified | `72a806d83274e8a5...` |
| `bluetooth_b.img` | 1,048,576 | FAT Filesystem (vfat) | Bluetooth Subsystem | [OK] Verified | `72a806d83274e8a5...` |
| `boot_a.img` | 100,663,296 | Android Boot Image v2 | Boot & Kernel | [OK] Verified | `6324a772e9b1de84...` |
| `boot_b.img` | 100,663,296 | Android Boot Image v2 | Boot & Kernel | [OK] Verified | `841dc715d2bf8197...` |
| `carrier.img` | 67,108,864 | ext4 Filesystem | Carrier Configuration | [OK] Verified | `5ae2ec05f378dea2...` |
| `catecontentfv.img` | 1,048,576 | Binary Data Partition | Hardware / Config | [OK] Verified | `30e14955ebf13522...` |
| `catefv.img` | 524,288 | Binary Data Partition | Hardware / Config | [OK] Verified | `07854d2fef297a06...` |
| `cateloader.img` | 2,097,152 | Binary Data Partition | Hardware / Config | [OK] Verified | `5647f05ec1895894...` |
| `cdt.img` | 131,072 | Hardware Parameter Table | Hardware / Config | [OK] Verified | `fa43239bcee7b97c...` |
| `cmnlib64_a.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `b7c775d91ef2a5a1...` |
| `cmnlib64_b.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `b7c775d91ef2a5a1...` |
| `cmnlib_a.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `b9f353b84038338b...` |
| `cmnlib_b.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `b9f353b84038338b...` |
| `config.img` | 524,288 | Binary Data Partition | Hardware / Config | [OK] Verified | `2db84805ea2ae2ef...` |
| `ddr.img` | 1,048,576 | Hardware Parameter Table | Hardware / Config | [OK] Verified | `60e4b969146973b2...` |
| `devcfg_a.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `f81dacc21cf91d09...` |
| `devcfg_b.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `f81dacc21cf91d09...` |
| `devinfo.img` | 4,096 | Hardware Parameter Table | Hardware / Config | [OK] Verified | `12691a5b12f4abea...` |
| `dip.img` | 1,048,576 | Binary Data Partition | Hardware / Config | [OK] Verified | `30e14955ebf13522...` |
| `dsp_a.img` | 67,108,864 | ext4 Filesystem | DSP & Audio Subsystem | [OK] Verified | `1ec56bbb1e84527c...` |
| `dsp_b.img` | 67,108,864 | ext4 Filesystem | DSP & Audio Subsystem | [OK] Verified | `1ec56bbb1e84527c...` |
| `dtbo_a.img` | 25,165,824 | Android DTBO Table v1 | Boot & Device Tree | [OK] Verified | `668e54337925f1fc...` |
| `dtbo_b.img` | 25,165,824 | Android DTBO Table v1 | Boot & Device Tree | [OK] Verified | `668e54337925f1fc...` |
| `fsc.img` | 131,072 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `fa43239bcee7b97c...` |
| `fsg.img` | 2,097,152 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `5647f05ec1895894...` |
| `hyp_a.img` | 8,388,608 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `a5646e0fe1e0814e...` |
| `hyp_b.img` | 8,388,608 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `a5646e0fe1e0814e...` |
| `imagefv_a.img` | 2,097,152 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `a71dfdc84a03093b...` |
| `imagefv_b.img` | 2,097,152 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `a71dfdc84a03093b...` |
| `keymaster_a.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `ffe97683e2f09ca8...` |
| `keymaster_b.img` | 524,288 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `ffe97683e2f09ca8...` |
| `limits.img` | 4,096 | Hardware Parameter Table | Hardware / Config | [OK] Verified | `f05cf6deb8f78bb8...` |
| `mdm1m9kefs1.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `30e14955ebf13522...` |
| `mdm1m9kefs2.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `30e14955ebf13522...` |
| `mdm1m9kefs3.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `30e14955ebf13522...` |
| `mdm1m9kefsc.img` | 4,096 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `ad7facb2586fc6e9...` |
| `mdm1oemnvbktmp.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `30e14955ebf13522...` |
| `mdm_oem_dycnvbk.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `30e14955ebf13522...` |
| `mdm_oem_stanvbk.img` | 1,048,576 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `30e14955ebf13522...` |
| `mdmddr.img` | 1,048,576 | Binary Data Partition | Hardware / Config | [OK] Verified | `30e14955ebf13522...` |
| `modem_a.img` | 314,572,800 | FAT Filesystem (vfat) | Cellular Baseband | [OK] Verified | `d3b237d27b399ce7...` |
| `modem_b.img` | 314,572,800 | FAT Filesystem (vfat) | Cellular Baseband | [OK] Verified | `d3b237d27b399ce7...` |
| `modemst1.img` | 2,097,152 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `85f1e6fa549388c7...` |
| `modemst2.img` | 2,097,152 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `61d688caec110067...` |
| `msadp.img` | 262,144 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `3b7a4522631ea9c9...` |
| `oem_dycnvbk.img` | 10,485,760 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `dd0fa093cf08030c...` |
| `oem_stanvbk.img` | 10,485,760 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `9619d75a70b257d2...` |
| `op1.img` | 314,572,800 | ext4 Filesystem | OEM Customization | [OK] Verified | `c724057efec911e6...` |
| `op2.img` | 268,435,456 | ext4 Filesystem | OEM Customization | [OK] Verified | `b64e865d8c443838...` |
| `opproduct_a.img` | 1,717,989,376 | ext4 Filesystem | OEM Customization | [OK] Verified | `796cc464b8d905b1...` |
| `opproduct_b.img` | 1,717,989,376 | ext4 Filesystem | OEM Customization | [OK] Verified | `7e416c00320c7ac4...` |
| `param.img` | 1,048,576 | Hardware Parameter Table | Hardware / Config | [OK] Verified | `024c73a514e8bf68...` |
| `persist.img` | 33,554,432 | ext4 Filesystem | Calibration & Security | [OK] Verified | `be1554d91f0c362c...` |
| `qupfw_a.img` | 81,920 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `a57cce639459a2c6...` |
| `qupfw_b.img` | 81,920 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `a57cce639459a2c6...` |
| `recovery_a.img` | 100,663,296 | Android Boot Image v2 | Boot & Kernel | [OK] Verified | `0557bc27e4361cb4...` |
| `recovery_b.img` | 100,663,296 | Android Boot Image v2 | Boot & Kernel | [OK] Verified | `41965b2155f59a2f...` |
| `secdata.img` | 28,672 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `c1f6356d1a4591f0...` |
| `splash.img` | 34,226,176 | Splash / Boot Logo Bitmap | Display Splash | [OK] Verified | `7283ab986bc6374f...` |
| `spunvm.img` | 8,388,608 | Qualcomm Non-Volatile / EFS Data | Radio Calibration & NV | [OK] Verified | `2daeb1f36095b44b...` |
| `storsec_a.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `4b913bc198abd925...` |
| `storsec_b.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `4b913bc198abd925...` |
| `tz_a.img` | 4,194,304 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `1cc890914292550f...` |
| `tz_b.img` | 4,194,304 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `1cc890914292550f...` |
| `uefisecapp_a.img` | 2,097,152 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `cef95b58a3382cd8...` |
| `uefisecapp_b.img` | 2,097,152 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `cef95b58a3382cd8...` |
| `uefivarstore.img` | 524,288 | Binary Data Partition | Hardware / Config | [OK] Verified | `07854d2fef297a06...` |
| `vbmeta_a.img` | 65,536 | Android Verified Boot (AVB 2.0) | Verified Boot / Integrity | [OK] Verified | `ea376996e61d6927...` |
| `vbmeta_b.img` | 65,536 | Android Verified Boot (AVB 2.0) | Verified Boot / Integrity | [OK] Verified | `312a2485b1abe217...` |
| `vbmeta_system_a.img` | 65,536 | Android Verified Boot (AVB 2.0) | Verified Boot / Integrity | [OK] Verified | `e9fb2e584d5dcb93...` |
| `vbmeta_system_b.img` | 65,536 | Android Verified Boot (AVB 2.0) | Verified Boot / Integrity | [OK] Verified | `d1776b3138f579ab...` |
| `xbl_a.img` | 3,670,016 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `16079f32e6557641...` |
| `xbl_b.img` | 3,670,016 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `16079f32e6557641...` |
| `xbl_config_a.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `63c73af81ef5b854...` |
| `xbl_config_b.img` | 131,072 | ELF Binary / Qualcomm MBN | Bootloader & Secure Firmware | [OK] Verified | `63c73af81ef5b854...` |

