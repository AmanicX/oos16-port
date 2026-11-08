# Inputs & Provenance Manifest
### OxygenOS 16 Port for OnePlus 7T (`HD1901` / `hotdogb`)

This document records the exact provenance, sources, versions, and checksums of all input packages and assets used in the port.

---

## 1. Active Donor ROM (OxygenOS 16 / Android 16)

The active donor operating system package used in this port is the official OxygenOS 16 release for the **OnePlus 9 (`LE2113` / `lemonade`)**:

| Field | Detail |
| :--- | :--- |
| **Package Filename** | `ota_full-LE2113_16.0.10.500.zip` |
| **Package SHA-256** | `5ea5f120a2bce5eb98bd2a5d1aca872f5888903825861142bd0900772b8d0844` (7,402,464,442 bytes) |
| **Donor Device / Architecture** | OnePlus 9 (`lemonade` / `OnePlus9_EEA`, Model `LE2113`, Snapdragon 888 / SM8350, ARM64-v8a) |
| **Android Version** | Android 16 (`Baklava` / SDK 36) |
| **Build ID / Fingerprint** | `BP2A.250605.015` / `LE2113_16.0.10.500(EX01)` (`OnePlus/OnePlus9_EEA/OnePlus9:16/BP2A.250605.015/1785498910198:user/release-keys`) |
| **Official Download Source** | Official OnePlus / OPPO OTA Update Delivery Servers |
| **Extracted Partitions** | `system`, `system_ext`, `my_product`, `my_region`, `com.android.runtime.apex`, bootstrap APEXes |
| **Rationale** | Provides modern OxygenOS 16 system framework, ColorOS/OOS SystemUI, notification panel, and core user-facing features on Android 16 Baklava. |

*Note on Prior Evaluations*: Earlier feasibility notes evaluated OnePlus 8T (`KB2003`) as a candidate donor; however, OnePlus 9 (`LE2113_16.0.10.500`, European variant `OnePlus9_EEA`) was selected and finalized as the active working donor because it provided complete Android 16 Baklava images with matching SDK 36 interfaces. Note: `LE2113` is OnePlus 9 standard (Snapdragon 888, codename `lemonade`), whereas OnePlus 9 Pro models are `LE2123`/`LE2121`/`LE2125` (`lemonadep`). The recipient target device is the OnePlus 7T HD1901 (`hotdogb`, Snapdragon 855+ / SM8150-AC).

---

## 2. Hardware Base & Vendor Stack (LineageOS 23.2 / crDroid 12.x)

To drive the OnePlus 7T's hardware (Snapdragon 855+ / SM8150-AC), the HALs and vendor libraries are sourced from LineageOS 23.2:

| Component | Source Package | Version / Detail |
| :--- | :--- | :--- |
| **Vendor HAL Stack (`vendor/`)** | LineageOS 23.2 for `hotdogb` | SDK 36 (Android 16 / BP4A match), SM8150 Adreno 640 graphics, audio, display, sensors |
| **OnePlus ODM Stack (`odm/`)** | LineageOS 23.2 for `hotdogb` | OnePlus 7T device-specific configurations and audio calibration |
| **Recovery Kernel (`stage1/kernel_src/kernel`)** | LineageOS 23.2 Recovery for `hotdogb` | Linux version `4.14.357-perf-gcd3073fb68f1` (Clang 21.0.0, non-GKI) |
| **Device Tree (`stage1/kernel_src/dtb`)** | LineageOS 23.2 Recovery for `hotdogb` | SM8150-AC Snapdragon 855+ Device Tree Blob |
| **DTBO (`stage1/kernel_src/recovery_dtbo`)** | LineageOS 23.2 Recovery for `hotdogb` | Recovery Device Tree Overlay for OnePlus 7T |

---

## 3. Physical Device Hardware Specifications

| Hardware Component | OEM Specification | Physical Device Live Verification |
| :--- | :--- | :--- |
| **Device Model** | OnePlus 7T (`HD1901`) | Confirmed (`getprop ro.product.model: HD1901`) |
| **SoC** | Qualcomm Snapdragon 855+ (SM8150-AC) | Confirmed (`getprop ro.board.platform: msmnile`) |
| **System RAM** | 8 GB LPDDR4x | Confirmed (`MemTotal: 7432 MB` in `/proc/meminfo`) |
| **Internal Flash** | 128 GB UFS 3.0 (`sda` through `sdf`) | Confirmed write-locked (`blockdev --getro = 1`) |
| **Display Panel** | OEM 90Hz Samsung Fluid AMOLED | **Replaced with aftermarket panel**: `dsi_samsung_s6e3fc2x01_cmd_display`, operating strictly at fixed 60.00 Hz (`1080x2340 @ 60 Hz`). |

---

## 4. Injected Feature Manifest

| Injected Feature | Target File | Purpose | Limitation Note |
| :--- | :--- | :--- | :--- |
| **Google Photos Spoof** | `configs/pixel_2016_experience.xml` | Declares `PIXEL_2016_EXPERIENCE` and `NEXUS_PRELOAD` permissions. | Enables original quality backup spoof for Google Photos. |
| **Play Integrity Template** | `configs/pif.json` | OnePlus 7T HD1901 Android 12 certified release-keys profile. | Template configuration. Modifying JSON does NOT guarantee CTS/Integrity pass without runtime hooking. |
| **SELinux Property Contexts** | `patches/system_ext_property_contexts.patch` | Comments out 18 duplicate property prefixes. | Resolves Android 16 init property context serialization abort. |
| **Display Refresh Lock** | `patches/vendor_build_prop_display.patch` | Sets frame rate override to 60Hz. | Prevents SurfaceFlinger connector drops on aftermarket 60Hz screen. |
