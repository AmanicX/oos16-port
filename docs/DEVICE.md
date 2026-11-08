# OnePlus 7T (HD1901 / hotdogb) Device Hardware Profile

> All data in this document is derived directly from the attached physical device via read-only inspection commands or verified source trees. Guesses are prohibited.

---

## 1. Identity & Build

- **Device Model**: OnePlus 7T (`HD1901`)
- **Product Device**: `OnePlus7T`
- **Device Codename**: `hotdogb` (`ro.crdroid.device=hotdogb`, `ro.lineage.device=hotdogb`, flavor: `hotdogb-user`)
- **Project Codename**: `hotdogt` (`ro.boot.project_codename=hotdogt`)
- **OS Running**: crDroid Android 16 (display version `v12.11-20260725`, display ID: `BP4A.251205.006 release-keys`)
- **Build Fingerprint**: `OnePlus/OnePlus7T/OnePlus7T:12/SKQ1.211113.001/Q.202303230244:user/release-keys`
- **Active Slot**: `_b` (`ro.boot.slot_suffix=_b`)
- **Platform**: Qualcomm `msmnile` / `SM8150` (SM8150-AC Snapdragon 855+)
- **Kernel Version**: `Linux localhost 4.14.357-perf-gcd3073fb68f1 #1 SMP PREEMPT aarch64`
- **Bootloader**: Unlocked (running custom ROM crDroid)

---

## 2. CPU & Cluster Topology

- **SoC**: Qualcomm SM8150-AC (Snapdragon 855+)
- **Architecture**: ARMv8.2-A (64-bit)
- **Total Cores**: 8 cores (1 Prime + 3 Gold + 4 Silver)
  - **Cluster 0 (Silver / Efficiency)**:
    - Cores: `cpu0` - `cpu3`
    - Implementer: `0x51` (Qualcomm / ARM Cortex-A55 derived)
    - Part: `0x805` (Kryo Silver)
    - Max Frequency: `1,785,600 kHz` (1.785 GHz)
  - **Cluster 1 (Gold / Performance)**:
    - Cores: `cpu4` - `cpu6`
    - Implementer: `0x51` (Qualcomm / ARM Cortex-A76 derived)
    - Part: `0x804` (Kryo Gold)
    - Max Frequency: `2,419,200 kHz` (2.419 GHz)
  - **Cluster 2 (Prime / Gold+)**:
    - Core: `cpu7`
    - Implementer: `0x51` (Qualcomm / ARM Cortex-A76 derived)
    - Part: `0x804` (Kryo Gold Prime)
    - Max Frequency: `2,956,800 kHz` (2.956 GHz - confirms SM8150-AC Snapdragon 855+)
- **Features**: `fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp`

---

## 3. Memory & Power

- **Total RAM**: `7,647,564 kB` (~8 GB LPDDR4X)
- **Battery**:
  - Capacity: `100%`
  - Temperature: `24.0°C`
  - Health: Good
  - Technology: Li-ion

---

## 4. Display & Framebuffer

- **Panel Type**: Samsung S6E3FC2X01 AMOLED (DSI Command Mode)
  - Verified cmdline: `msm_drm.dsi_display0=dsi_samsung_s6e3fc2x01_cmd_display:`
  - `panel_type=x_talk`
- **Native Resolution**: `1080 x 2340`
- **Density**: `420 dpi` (xDpi: 403.411, yDpi: 409.903)
- **Refresh Rates**: 
  - *OEM Stock Specification*: 60 Hz / 90 Hz peak
  - *Current Physical Panel (Aftermarket Replacement)*: Strictly fixed **60.00 Hz** (`activeMode={id=0, resolution=1080x2340, vsyncRate=60.00 Hz}`).
  - *Configuration*: Display properties explicitly lock SurfaceFlinger to 60Hz (`ro.surface_flinger.game_default_frame_rate_override=60`, `ro.surface_flinger.enable_frame_rate_override=false`) to prevent connector detachment.
- **MDSS MDP Base Address**: `0x0ae00000` (`soc/ae00000.qcom,mdss_mdp`)
- **DSI Interface**: `card0-DSI-1` (Command mode panel)
- **Cutout Inset**: Top notch `Rect(455, 0 - 625, 68)`

---

## 4.1 Platform Controllers & Addresses

- **USB DWC3 Controller**: `0x0a600000` (`soc/a600000.dwc3`)
- **UFS Host Controller**: `0x01d84000` (`soc/1d84000.ufshc`) - **Disabled per safety contract**
- **SPMI Controller**: `0x0c440000` (`soc/c440000.qcom,spmi`)
- **Platform ID**: `339` (SM8150)
- **Project Name / ID**: `19863` (`androidboot.prjname=19863`, `androidboot.hw_version=14`)
- **Verified Boot State**: `orange` (Unlocked)
- **DTB Index**: `16` (`androidboot.dtb_idx=16`)
- **DTBO Index**: `8` (`androidboot.dtbo_idx=8`)

---

## 5. Input & Buttons

- **Touchscreen Controller**:
  - Model: **Synaptics S3706** (`[TP]synaptics-s3706`)
  - Bus: `I2C` (`synaptics_i2c`)
  - Event Node: `/dev/input/event1` (`touchpanel`)
  - Coordinate Range: X: 0–1080, Y: 0–2340
  - Multi-touch: ABS_MT supported
- **Power Button**:
  - Driver: `qpnp_pon`
  - Interface: SPMI bus (`0x0c440000.qcom,spmi`), PM8150 PMIC (`qcom,pm8150@0`), offset `0x800` (`qcom,power-on@800`)
- **Volume Buttons**:
  - Driver: `gpio-keys` (`/sys/devices/platform/soc/soc:gpio_keys`)
- **Tri-State Alert Slider**:
  - Driver: `oplus,hall_tri_state_key` (`/dev/input/event8`)

---

## 6. Audio & PMIC

- **Audio Subsystem**:
  - Sound Card: `sm8150-tavil-snd-card`
  - Codec: Qualcomm WCD9340 (Tavil codec)
- **PMIC Topology**:
  - SPMI controller at `0x0c440000`
  - Primary PMIC: PM8150 (`qcom,pm8150@0`)

---

## 7. Storage & Partition Layout (UFS 3.0)

UFS LUNs: `sda`, `sdb`, `sdc`, `sdd`, `sde`, `sdf`

| Partition Name | Target Block Device | Notes |
|---|---|---|
| `boot_a` / `boot_b` | `/dev/block/sde11` / `/dev/block/sde38` | Kernel & ramdisk |
| `dtbo_a` / `dtbo_b` | `/dev/block/sde17` / `/dev/block/sde44` | Device tree overlays |
| `vbmeta_a` / `vbmeta_b` | `/dev/block/sde16` / `/dev/block/sde43` | Verified boot metadata |
| `userdata` | `/dev/block/sda23` | **FORBIDDEN TO WRITE/ERASE** |
| `persist` | `/dev/block/sda2` | Sensor calibration & persist data |
| `modemst1` / `modemst2` | `/dev/block/sdf2` / `/dev/block/sdf3` | NVRAM / baseband calibration |
| `fsg` / `fsc` | `/dev/block/sdf4` / `/dev/block/sdf5` | Golden baseband calibration |
| `logdump` | `/dev/block/sde67` | **DANGER**: HakiOS default logdump target. MUST BE COMPILED OUT. |
| `splash` | `/dev/block/sde62` | Continuous splash image |

---

## 8. Linux Block-Device Protection Model & Safety Architecture

Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to device-level verification. Internal UFS 3.0 flash must never receive write requests.

### 8.1 Linux Block-Layer Read-Only Scope (`BLKROSET`)
- Setting `blockdev --setro` invokes the kernel ioctl `BLKROSET`, which sets the `bdev_read_only()` flag on the target block device descriptor.
- **Critical Linux Limitation**: In the Linux block subsystem, setting `BLKROSET` on a parent whole-disk `gendisk` (e.g. `/dev/block/sda`) sets read-only on the whole-disk device node, but does **not** automatically propagate to existing child partition descriptors (`sda1`..`sda32`).
- **Enforcement Rule**: Stage-1 supervisor and Stage-2 bringup enumerate all child partitions under each discovered physical disk and explicitly invoke `blockdev --setro` on every individual child partition node.
- **Return Code Contract**: Fallback constructs such as `blockdev --getro ... || echo "1"` are strictly forbidden. `blockdev --getro` must return exit code 0 and stdout `1`. Any failure or `0` triggers immediate fail-closed halt and reboot.

### 8.2 Defense-in-Depth Protection Layers
1. **Layer 1: Kernel Command Line Invariants**:
   - `panic=5`, `androidboot.selinux=permissive`, zero physical root (`root=/dev/block` absent), zero wipe/format directives, zero userdata targets.
2. **Layer 2: Dynamic sysfs Discovery & Recursive Write-Locking**:
   - Discovers all physical storage devices via `/sys/block/*` with `/device` backing or `sd*`/`mmcblk*` naming.
   - Creates verified block device nodes (`mknod b <maj> <min>`) and sets `blockdev --setro`.
3. **Layer 3: Atomic Storage Inventory Publishing**:
   - Inventories are written to staging (`/tmp/inventory.staging.$$`), checked for syntax and duplicate records, verified against sysfs, atomically published via `mv` to `/mnt/physical_storage_inventory` and `/tmp/physical_storage_inventory`, and verified byte-identical (`cmp -s`).
4. **Layer 4: Host Runner Storage Pre-Conditioning**:
   - `tools/safe/run_stage2.sh` queries target inventory and sysfs, enforces 1-to-1 parity, rejects phantom/duplicate/unlocked devices before transferring images.
5. **Layer 5: Multi-Checkpoint Stage-2 Revalidation**:
   - Stage-2 revalidates the inventory across 6 critical bringup checkpoints (`stage2_startup`, `before_base_system_and_overlay_mount`, `before_child_partition_mounts`, `before_apex_loop_mounts`, `before_data_tmpfs_mount`, `before_init_handover`).
   - Confirms byte-identity of `/mnt` and `/tmp` inventory copies, detects disappearing devices, locks newly appearing partitions read-only, and verifies 0 writable physical mounts in `/proc/mounts`.
6. **Layer 6: Active Safety Watchdog**:
   - Device-side `scripts/watchdog.sh` monitors storage inventory every 5 seconds. Missing, empty, or corrupted inventory triggers `STORAGE_VIOLATION` and emergency reboot.
7. **Layer 7: 100% Volatile RAM Filesystems**:
   - All mount targets (`/mnt`, `/tmp`, `/data`, `/sysroot`) are strictly RAM-backed `tmpfs` instances. Physical flash is never mounted.

### 8.3 Protection Boundary Clarifications
- **Block-Layer Read-Only (`blockdev --setro`)**: Rejects standard block I/O requests (`BIO_OP_WRITE`) at the kernel request queue.
- **Filesystem Read-Only (`mount -o ro`)**: VFS-level enforcement preventing write syscalls.
- **Absence of Write Commands**: Static verification that binaries and scripts contain no destructive invocations (`fastboot flash`, `mkfs.ext4`, etc.).
- **Silicon-Level Write-Protect**: Hardware registers (e.g. UFS write-protect or eMMC hardware WP pins). While software blockdev locks do not configure silicon OTP registers, the combined 7-layer defense prevents any write execution paths.

---

## 9. Hardware Display Diagnostic Pipeline (10-State Visual Engine)

To provide tactile and visual feedback on the physical device without relying on adb logs, Stage 1 and Stage 2 implement a 10-state visual/hardware diagnostic sequence:

1. **State 1 (Hardware Tactile)**: Haptic vibrator pulse (300 ms) triggered via `/sys/class/leds/vibrator`.
2. **State 2 (AMOLED Backlight)**: Samsung AMOLED backlight powered on (level 200) via `/sys/class/backlight/panel0-backlight/brightness` or `lcd-backlight`.
3. **State 3 (Kernel DRM Node)**: Verified `/dev/dri/card0` and `/dev/dri/renderD128` from Qualcomm MDSS MDP driver (`0x0ae00000`).
4. **State 4 (Adreno KGSL Node)**: Verified `/dev/kgsl-3d0` character device from Qualcomm Adreno 640 GPU driver.
5. **State 5 (SurfaceFlinger 60Hz Mode)**: Display locked to 60.00 Hz to prevent panel connector detachment on aftermarket display panels.
6. **State 6 (Memory Allocation Feedback)**: Staging capacity verified (>= 6500 MB total, >= 3392 MB available).
7. **State 7 (Storage Protection Acknowledgment)**: Storage inventory locked and published to `/mnt/stage1_ack`.
8. **State 8 (APEX Mounting Phase)**: Visual/log confirmation of canonical AOSP APEX payloads mounted on loop devices.
9. **State 9 (SELinux Policy Handover)**: Compilation/hash verification of `plat_sepolicy.cil`, `vendor_sepolicy.cil`, `odm_sepolicy.cil`.
10. **State 10 (Android Init Exec)**: PID 1 handover to `/system/bin/init selinux_setup`.
