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
