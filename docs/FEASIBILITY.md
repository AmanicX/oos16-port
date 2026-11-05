# Feasibility Analysis & Porting Architecture: OxygenOS 16 on OnePlus 7T

**Device Target**: OnePlus 7T (`HD1901` / `hotdogb`)  
**SoC**: Qualcomm SM8150-AC (Snapdragon 855+)  
**Framework Target**: OxygenOS 16 (Android 16 / API 36)  
**Base Vendor/Kernel Target**: crDroid v12.x Android 16 hotdogb vendor stack & 4.14 kernel  
**Date**: November 5, 2026

---

## 1. Executive Summary & Recommended Route

### Recommended Route: Route A (OxygenOS 16 Userspace on Proven A16 hotdogb Vendor & Kernel)
- **Concept**: Treat the OxygenOS 16 system stack (`system`, `system_ext`, `product`, and generic `odm` assets) as a semi-GSI overlay that runs on top of the proven Android 16-compatible `hotdogb` vendor image, kernel, and device firmware.
- **Why Route A is the only viable path**:
  - The OnePlus 7T's stock OxygenOS firmware ended at Android 11 / 12 (FCM Level 5). Google's Android 16 VINTF compatibility matrix requires FCM Level 6 (Android 12) through 202504 (Android 16). The stock Android 11 vendor cannot boot an Android 16 framework without massive HAL breakage.
  - The active crDroid 12.x ROM on your phone **already proves** that a fully functional Android 16 vendor + kernel exists for this exact SM8150 hardware (driving the 90Hz AMOLED display, Adreno 640 GPU, Synaptics touch, and cellular baseband).
  - Route A decouples the complex OEM system framework from physical hardware drivers.

---

## 2. Donor Selection & Recommendation

### Recommended Donor: **Candidate 1 — OxygenOS 16 (v16.0.10.501) for OnePlus 8T (`KB2003`)**
- **SoC Generation**: SM8250 (Snapdragon 865) — the immediate successor to the 7T's SM8150.
- **Display**: 1080 x 2400 AMOLED (virtually identical to the 7T's 1080 x 2340 panel).
- **Tooling Support**: Directly supported by the `coloros_port` project (`external/coloros_port`) with pre-engineered Android 16 smali patches and feature shims.
- **Why not OnePlus 9 / 12 donors?**:
  - Higher generation devices (SM8350, SM8550) use 64-bit-only userspaces, different display pipelines, different thermal HALs, and camera provider interfaces that will cause immediate framework crash loops.

### Fallback Donor: **OxygenOS 16 GSI (Galaxy S21 / Treble)**
- Generic System Image format; useful as a reference if OnePlus-specific system services prove too tightly coupled to proprietary HALs.

---

## 3. Storage Strategy & RAM Feasibility (Strategy S1)

Because writing to physical UFS storage (`userdata` and `super`) is strictly forbidden by the Safety Contract:
- **Two-Stage RAM-Resident Boot**:
  1. `fastboot boot stage1.img` loads a minimal kernel + initramfs (~28 MB) into RAM.
  2. The stage-1 initramfs sets all physical disks to read-only (`blockdev --setro /dev/block/sd*`), brings up FunctionFS USB adbd, and creates a large tmpfs in RAM.
  3. The laptop pushes trimmed EROFS images (`system.img`, `system_ext.img`, `product.img` totaling ~2.8 GB) over USB into RAM.
  4. Stage-1 mounts `/data` as an ephemeral RAM tmpfs/zram (~1.0 GB), loop-mounts the EROFS system images, and passes execution to `/system/bin/init`.
- **RAM Headroom**:
  - Total physical RAM: **7.47 GiB**
  - System images in tmpfs: **~2.8 GiB**
  - Ephemeral `/data`: **~1.0 GiB**
  - Free runtime RAM: **~3.6 GiB** (plenty for SurfaceFlinger, SystemUI, and launcher).

---

## 4. Technical Risks & Mitigation Plan

| Risk | Severity | Root Cause | Mitigation Strategy |
|---|---|---|---|
| **SystemUI / Oplus App Crash Loop** | High | Apps querying non-existent Oplus HALs (fingerprint, display feature, inspiration AOD). | Inject dummy feature XMLs (`com.oplus.*-features-ext-bruce.xml`) to disable unsupported hardware features; apply smali gates. |
| **SELinux Denials** | Medium | Donor SELinux policy expecting Oplus domain types not present in A16 base vendor. | Run `androidboot.selinux=permissive` during initial Phase A boot tests; compile unified type policy before declaring Phase A complete. |
| **Storage Write Trap** | Critical | Stock Android init or vold attempting to mount/wipe `userdata` or misc. | Strip `/data` from fstab; use RAM-only tmpfs `/data`; audit with `tools/safe/audit-no-writes.sh`. |
| **GPU / SurfaceFlinger Hang** | Medium | Donor HWUI expecting higher Vulkan/GLES features than Adreno 640 supports. | Fall back to CPU software rendering (`libGLES_android.so` / SwiftShader) for initial lockscreen boot (Test T6), then wire Adreno 640 drivers in Phase B. |

---

## 5. Realistic Feature Expectations

- **Will Work (Phase A & B)**:
  - System boot to lockscreen and launcher
  - Display resolution, brightness, and refresh rate
  - Touchscreen and hardware buttons (power, volume, alert slider)
  - Adreno 640 hardware acceleration (GLES 3.2, Vulkan 1.1)
  - Wi-Fi, Bluetooth, Audio playback
- **Unlikely / Infeasible under Zero-Write Contract**:
  - OnePlus Stock Camera (relies on proprietary Oplus camera daemon tightly coupled to raw physical firmware partitions). Generic Camera2 API will be targeted instead.
  - Optical In-Display Fingerprint (relies on Goodix / Oplus HAL and kernel driver calibration stored in physical persist blocks).
