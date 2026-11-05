# Inputs & Provenance Manifest

This document records the exact provenance, sources, and checksums of all input packages for the OxygenOS 16 port to the OnePlus 7T (`hotdogb`).

---

## 1. Proven Base Assets (Android 16 hotdogb)

| Asset | Source / Project | Version / Build | Critical Components |
|---|---|---|---|
| **crDroid 12.x (Android 16)** | Official crDroid for OnePlus 7T (`hotdogb`) | `v12.11` (Android 16 / BP4A) | - Proven 4.14 non-GKI kernel with SM8150 A16 adaptations<br>- Vendor image with Adreno 640 GPU stack, display DSI, Synaptics touch HAL<br>- Audio (WCD9340 Tavil), Bluetooth, Wi-Fi HALs |
| **OnePlus 7T Hardware Dumps** | Live device pull from `/dev/block/bootdevice/by-name/*` | 84 Partitions Verified | `boot_b`, `dtbo_b`, `vbmeta_b`, `persist`, `param`, `carrier`, `dsp_b`, `modem_b` |

---

## 2. Donor Candidates (OxygenOS 16 / ColorOS 16)

| Candidate | Source | Target Base / Architecture | Screen & Density | Pros / Cons |
|---|---|---|---|---|
| **Candidate 1: OxygenOS 16 (16.0.10.501)** | SourceForge `coloros-port` / OnePlus 8T (`KB2003`) base | SM8250 (Snapdragon 865) / OnePlus 8T port | `1080 x 2400` @ 420 dpi | **RECOMMENDED**: Closest generation (SM8250 vs SM8150), identical 1080p Samsung AMOLED panel layout, OnePlus-specific service adaptations already tested on older hardware. |
| **Candidate 2: OnePlus 9 / 9 Pro OxygenOS 16** | XDA 4800073 / OnePlus 9 series | SM8350 (Snapdragon 888) | `1080 x 2400` (9) / `1440 x 3216` (9 Pro) | Alternative donor; higher generation SoC and different camera pipeline. |
| **Candidate 3: OxygenOS 16 GSI (Galaxy S21)** | XDA 4796632 | Generic System Image (Exynos / SM8350) | Generic Dynamic | Pure GSI; useful reference for generic VNDK / Treble shims. |

---

## 3. Tooling Repositories (`external/`)

- **`external/coloros_port`**: Branch `COS16/OOS16` (GitHub `toraidl/coloros_port`). Contains AOSP Android 16 smali patches, `lpunpack.py`, `contextpatch.py`, `fspatch.py`, and inspiration AOD gate patches.
