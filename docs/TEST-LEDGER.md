# Test Ledger: OxygenOS 16 RAM Bring-up on OnePlus 7T

| ID | Date | Build Hash | Change / Target | Hypothesis | Command | Timeout | Result | Pass/Fail | Next Step |
|---|---|---|---|---|---|---|---|---|---|
| **T0** | 2026-11-05 | `0c45df5a...` | Stage-1 Native RAM Boot | Native static init + adbd; all fstabs removed; disks setro; 90s watchdog; adb root | `tools/safe/fastboot boot build/stage1.img` | 60s | Booted in 3.6s, adb root (u:r:su:s0), zero storage touched | **PASS** | T1 |
| **T1** | 2026-11-05 | `0c45df5a...` | Block Layer Read-Only Proof | All physical UFS block devices (`/dev/block/sd*`) are read-only; write attempts fail | `blockdev --getro /dev/block/sd[a-f]` -> all return 1 | 30s | All LUNs sda-sdf ro=1, mount table 100% tmpfs/rootfs, 7.37GB free RAM | **PASS** | T2 |
| **T2** | Planned | Pending | RAM Transfer | Compressed trimmed system images pushed into stage-1 tmpfs with matching SHA-256 | `tools/safe/adb push <erofs_images> /tmp/` | 180s | Pending | - | T3 |
| **T3** | Planned | Pending | RAM Mounts | EROFS images loop-mount; /data is RAM-backed; zero physical partitions mounted rw | `tools/safe/adb shell mount` check | 30s | Pending | - | T4 |
| **T4** | Planned | Pending | Android Init | Android init starts; core services launch; no update/verifier or bootctl services active | `tools/safe/adb logcat -d` | 60s | Pending | - | T5 |
| **T5** | Planned | Pending | Framework | Zygote and system_server stay up for >= 5 minutes without crashing | `tools/safe/adb shell ps -ef` | 300s | Pending | - | T6 |
| **T6** | Planned | Pending | UI & Lockscreen | Boot animation finishes, SystemUI and launcher render lock screen | Visual inspection & SurfaceFlinger dump | 120s | Pending | - | T7 |
| **T7** | Planned | Pending | Return Path & Integrity | Reboot into Android works; device fingerprint and small partition hashes 100% identical | Fingerprint comparison script | 60s | Pending | - | Phase B |
