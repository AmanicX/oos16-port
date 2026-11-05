# Storage Strategy & RAM Budget: OnePlus 7T (HD1901)

Per Section 1 of the Safety Contract, writing to the physical UFS storage of the phone is strictly prohibited. The system must run entirely from RAM.

---

## 1. Selected Strategy: Strategy S1 (Two-Stage RAM-Resident Boot Over USB)

### Architecture Workflow:
```
 Laptop (Host)                          OnePlus 7T (Phone in RAM)
   |                                              |
   | --- fastboot boot stage1.img -------------> | [Stage-1 Minimal Kernel + Initramfs]
   |                                              |   - Read-only block layer enforced
   |                                              |   - FunctionFS USB adbd started
   |                                              |   - Watchdog timer running
   |                                              |
   | --- safe adb push system.erofs /tmp/ ------> | [tmpfs /tmp/ in Phone RAM]
   | --- safe adb push system_ext.erofs /tmp/ --> | [tmpfs /tmp/ in Phone RAM]
   | --- safe adb push product.erofs /tmp/ -----> | [tmpfs /tmp/ in Phone RAM]
   |                                              |
   | --- safe adb shell /init_stage2 -----------> | [Stage-2 Android Switch]
   |                                              |   - Loop-mounts EROFS images
   |                                              |   - Mounts RAM-backed tmpfs /data
   |                                              |   - Starts Android init
   |                                              |   - SurfaceFlinger -> SystemUI -> Lock Screen
```

---

## 2. Hardware Budget & Measurement

| Metric | Measured Value | Implications |
|---|---|---|
| **Total Physical RAM** | `7,647,564 kB` (~7.47 GiB) | Measured from live device `/proc/meminfo`. |
| **Fastboot max-download-size** | `805,306,368 bytes` (768 MiB) | Maximum accepted single payload via `fastboot boot`. |
| **Stage-1 Boot Image** | `~28 MiB` | Kernel (~18 MiB) + initramfs (~10 MiB with busybox, adbd, tools). Easily fits within 768 MiB. |
| **Trimmed EROFS System Images** | `~2.8 GiB` | High-compression EROFS with unneeded apps/locales/bloat stripped. |
| **RAM-backed `/data` (zram/tmpfs)** | `~1.0 GiB` | Ephemeral scratch space for Android runtime and caches. |
| **Available Runtime RAM** | `~3.6 GiB` | Ample headroom for Android 16 Zygote, System Server, and UI rendering. |

---

## 3. Storage Invariants & Zero Persistence Guarantee

- **No Persistence**: All system state, cache, and modified settings live strictly in RAM. Rebooting the phone instantly and cleanly purges all memory.
- **Physical Block Devices Locked**: In Stage-1, all physical storage devices (`/dev/block/sda` through `/dev/block/sdf`) are set to read-only via `blockdev --setro`.
- **Userdata & Super Untouched**: No fstab entry, init script, or kernel command line ever references or probes `/dev/block/sda23` (userdata) or `/dev/block/sda24` (super).
