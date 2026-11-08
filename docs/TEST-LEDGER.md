# Test Ledger: OxygenOS 16 RAM Bring-up on OnePlus 7T

## 1. Automated Host & Build Verification (Current Commit)

| Test ID | Scope | Target / Subject | Verification Details | Result | Pass/Fail |
|---|---|---|---|---|---|
| **H0** | Script Syntax | 14 shell & init scripts | `bash -n` per script (runner, watchdog, stage2_init, ramdisk inits) | 14/14 scripts valid | **PASS** |
| **H1** | Invariant Scan | Repository codebase | Static scan for forbidden `fastboot flash/erase/format`, `mkfs.ext4 /dev/block` | Zero violations detected | **PASS** |
| **H2** | Go Helper Unit Tests | `src/binderfs_init.go` | 15 Go tests: Linux dev_t mkdev encoding, major 1 rejection (/dev/null, /dev/zero), BINDER_VERSION ioctl, collision-resistant temp paths, atomic replacement, rollback ownership, safeSymlink, idempotency | 15/15 Go tests pass | **PASS** |
| **H3** | ARM64 Compilation | `src/binderfs_init_arm64` | Cross-compiled static ELF 64-bit ARM aarch64 with stripped symbols (SHA-256: `a2bec3dac63b6fd26fa0d59bb00ae9f660812fd89ed98ed8ad9af3345d068f76`) | Verified static ELF aarch64 | **PASS** |
| **H4** | C Reference Test | `src/binderfs_init.c` | Strict gcc compilation (-Wall -Wextra -Werror -pedantic) | Clean compilation | **PASS** |
| **H5** | Embedded Consistency | Ramdisk binaries & scripts | `cmp -s` across `loader_ramdisk`, `native_ramdisk`, and source files | All embedded files byte-identical | **PASS** |
| **H6** | APEX Metadata Tests | `tests/test_apex_info.py` | 26 unit tests: varint tags, wire types, duplicate fields, ZIP limits, XML schema validation, tag 11 provideSharedApexLibs, active mounts | 26/26 tests pass | **PASS** |
| **H7** | Watchdog Unit Tests | `tests/test_watchdog.py` | 22 unit tests: numeric parsing, timeout arithmetic bounds, ADB disconnect, prop fail, config bounds | 22/22 tests pass | **PASS** |
| **H8** | Stage-2 Integration Tests | `tests/test_integration_stage2.py` | 67 integration tests: RAM accounting, 4-field PARTITION_MAP contract, product mapping, APEX staging, fail-closed SELinux checks | 67/67 tests pass | **PASS** |
| **H9** | Safe ADB & Fastboot Tests | `tests/test_safe_*.py` | 11 tests: command interception, metacharacter protection, flash bans (8 ADB + 3 Fastboot) | 11/11 tests pass | **PASS** |
| **H10** | Ramdisk Safety Audit | `loader_ramdisk` & `native_ramdisk` | `audit-no-writes.sh` on directory targets | 29/29 Passed, 0 Failed | **PASS** |
| **H11** | Packaged Loader Audit | `build/loader.img` | SHA-256: `428706b09e11e56f2e4a791113bb5722e5ff2398ba402bd930a14299b5225b38` | 31/31 Passed, 0 Failed | **PASS** |
| **H12** | Packaged Stage1 Audit | `build/stage1.img` | SHA-256: `eef8950ca85f37e6204d58997a51b1a87145088037255f252eaa506049b391af` | 31/31 Passed, 0 Failed | **PASS** |

## 2. Physical Device Bring-Up Stages (OnePlus 7T Hardware)

> [!IMPORTANT]
> The following hardware stages track physical execution on the device via `fastboot boot`.
> Stages T3 through T7 have not yet been executed on physical hardware and remain strictly pending live test.

| ID | Date | Build Hash | Change / Target | Hypothesis | Command | Timeout | Result | Pass/Fail | Next Step |
|---|---|---|---|---|---|---|---|---|---|
| **T0** | 2026-11-05 | `0c45df5a...` | Stage-1 Native RAM Boot | Native static init + adbd; all fstabs removed; disks setro; 90s watchdog; adb root | `tools/safe/fastboot boot build/stage1.img` | 60s | Booted in 3.6s, adb root (u:r:su:s0), zero storage touched | **PASS** | T1 |
| **T1** | 2026-11-05 | `0c45df5a...` | Block Layer Read-Only Proof | All physical UFS block devices (`/dev/block/sd*`) are read-only; write attempts fail | `blockdev --getro /dev/block/sd[a-f]` -> all return 1 | 30s | All LUNs sda-sdf ro=1, mount table 100% tmpfs/rootfs, 7.37GB free RAM | **PASS** | T2 |
| **T2** | 2026-11-06 | `adfce4c4...` | RAM Image Build & Packaging | Built 6 high-compression EROFS partitions; zero userdata/metadata/super references; crDroid PIF + Photos spoof injected | `tools/safe/run_stage2.sh` | 300s | All 6 EROFS images built (4.58 GB total), fsck.erofs clean, audit 100% passed | **PASS** | T3 |
| **T3** | Planned | Pending | RAM Mounts | EROFS images loop-mount; /data is RAM-backed; zero physical partitions mounted rw | `tools/safe/adb shell mount` check | 30s | Pending | - | T4 |
| **T4** | Planned | Pending | Android Init | Android init starts; core services launch; no update/verifier or bootctl services active | `tools/safe/adb logcat -d` | 60s | Pending | - | T5 |
| **T5** | Planned | Pending | Framework | Zygote and system_server stay up for >= 5 minutes without crashing | `tools/safe/adb shell ps -ef` | 300s | Pending | - | T6 |
| **T6** | Planned | Pending | UI & Lockscreen | Boot animation finishes, SystemUI and launcher render lock screen | Visual inspection & SurfaceFlinger dump | 120s | Pending | - | T7 |
| **T7** | Planned | Pending | Return Path & Integrity | Reboot into Android works; device fingerprint and small partition hashes 100% identical | Fingerprint comparison script | 60s | Pending | - | Phase B |
