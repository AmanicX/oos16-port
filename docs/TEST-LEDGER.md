# Test Ledger: OxygenOS 16 RAM Bring-up on OnePlus 7T

## 1. Automated Host & Build Verification (Current Commit)

| Test ID | Scope | Target / Subject | Verification Details | Result | Pass/Fail |
|---|---|---|---|---|---|
| **H0** | Script Syntax | 14 shell & init scripts | `bash -n` and POSIX `sh -n` for all scripts (runner, watchdog, stage2_init, ramdisk inits, recovery) | 14/14 scripts valid under both bash and sh | **PASS** |
| **H1** | Invariant Scan | Repository codebase | Static scan for forbidden `fastboot flash/erase/format`, `mkfs.ext4 /dev/block` | Zero violations detected | **PASS** |
| **H2** | Go Helper Unit Tests | `src/binderfs_init.go` | 15 Go tests: Linux dev_t mkdev encoding, major 1 rejection (/dev/null, /dev/zero), BINDER_VERSION ioctl, collision-resistant temp paths, atomic replacement, rollback ownership, safeSymlink, idempotency | 15/15 Go tests pass | **PASS** |
| **H3** | ARM64 Compilation | `src/binderfs_init_arm64` | Cross-compiled static ELF 64-bit ARM aarch64 with stripped symbols | Verified static ELF aarch64 | **PASS** |
| **H4** | C Reference Test | `src/binderfs_init.c` | Strict gcc compilation (-Wall -Wextra -Werror -pedantic) | Clean compilation | **PASS** |
| **H5** | Embedded Consistency | Ramdisk binaries & scripts | `cmp -s` across `loader_ramdisk`, `native_ramdisk`, and source files | All embedded files byte-identical | **PASS** |
| **H6** | APEX Metadata Tests | `tests/test_apex_info.py` | 26 unit tests: varint tags, wire types, duplicate fields, ZIP limits, XML schema validation, tag 11 provideSharedApexLibs, active mounts | 26/26 tests pass | **PASS** |
| **H7** | Watchdog Unit Tests | `tests/test_watchdog.py` | 41 unit tests: numeric parsing, timeout bounds, fail-closed storage validation (missing, empty, malformed inventory), blockdev ro=1, duplicate detection, newly appearing disk/partition discovery, mknod argument construction, emergency reboot trigger | 41/41 tests pass | **PASS** |
| **H8** | Stage-2 Integration Tests | `tests/test_integration_stage2.py` | 72 integration tests: RAM accounting, 4-field PARTITION_MAP contract, runner storage parity enforcement, APEX staging, fail-closed SELinux checks | 72/72 tests pass | **PASS** |
| **H9** | Safe ADB & Fastboot Tests | `tests/test_safe_*.py` | 11 tests: command interception, metacharacter protection, flash bans (8 ADB + 3 Fastboot) | 11/11 tests pass | **PASS** |
| **H10** | Physical Storage Safety Tests | `tests/test_storage_safety.py` | 27 tests: multi-disk sysfs discovery, duplicate detection, byte-identity verification, mount_and_verify_tmpfs extraction, capacity exhaustion, 6 checkpoint tracking | 27/27 tests pass | **PASS** |
| **H10b** | Loop & Block Device Safety Tests | `tests/test_storage_loop.py` | 9 tests: live kernel loop-device semantics (when privileged in CI/VM), simulated block-special node construction, major/minor hex matching, blockdev --setro/--getro state machine, multi-partition revalidation, disappearing/corrupt device handling | 9/9 verified (8 pass + 1 unprivileged skip locally, 9 in CI) | **PASS** |
| **H11** | Ramdisk Safety Audit | `loader_ramdisk` & `native_ramdisk` | `audit-no-writes.sh` on directory targets (34 checks per directory, 0 failures, 1 optional unverified cmdline) | 34/34 Passed, 0 Failed | **PASS** |
| **H12** | Packaged Loader Audit | `build/loader.img` | SHA-256: `d09ad5a59c42c73fe62c17235e73f38d0d676e0191af32ea7e3fb056a41215ab` (36 static & handover checks) | 36/36 Passed, 0 Failed | **PASS** |
| **H13** | Packaged Stage1 Audit | `build/stage1.img` | SHA-256: `eefcce94b79578966e077a4d3c5c87d39ea2d4017f5e4bb0104943ad3824b8f2` (36 static & handover checks) | 36/36 Passed, 0 Failed | **PASS** |
| **H14** | Hardware Kernel Assets | `stage1/kernel_src/` | Kernel `c32e3a26...` (banner `4.14.357-perf-gcd3073fb68f1`), DTB `e4faf7c5...` (`qcom,sm8150`), recovery DTBO `7cfdd198...` (`samsung_oneplus`) | Strict SHA-256 and symbol match | **PASS** |

Total automated Python test suite: **186 tests**, 100% pass rate.  
Total Go test suite: **15 tests**, 100% pass rate.  
Total automated host tests: **201 tests**, 100% pass rate.  
Total pre-boot auditor checks on packaged boot images: **36 checks**, 0 failures.  
Total pre-boot auditor checks on ramdisks: **34 checks**, 0 failures.

## 2. Physical Device Bring-Up Stages (OnePlus 7T Hardware)

> [!IMPORTANT]
> The following hardware stages track physical execution on the device via `fastboot boot`.
> Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to live device-level verification.
> All physical device execution stages (T0 through T7) remain strictly pending live test.

| ID | Date | Build Hash | Change / Target | Hypothesis | Command | Timeout | Result | Pass/Fail | Next Step |
|---|---|---|---|---|---|---|---|---|---|
| **T0** | Planned | `d09ad5a5...` | Stage-1 Native RAM Boot | Native static init + adbd; all fstabs removed; disks setro; 60s watchdog; adb root | `tools/safe/fastboot boot build/stage1.img` | 60s | Pending live hardware test | **PENDING** | T1 |
| **T1** | Planned | `d09ad5a5...` | Block Layer Read-Only Proof | All physical UFS block devices (`/dev/block/sd*`) are read-only; write attempts fail | `blockdev --getro /dev/block/sd[a-f]` -> all return 1 | 30s | Pending live hardware test | **PENDING** | T2 |
| **T2** | Planned | `d09ad5a5...` | RAM Image Build & Packaging | Built 6 high-compression EROFS partitions; zero userdata/metadata/super references; crDroid PIF + Photos spoof injected | `tools/safe/run_stage2.sh` | 300s | Pending live hardware test | **PENDING** | T3 |
| **T3** | Planned | Pending | RAM Mounts | EROFS images loop-mount; /data is RAM-backed; zero physical partitions mounted rw | `tools/safe/adb shell mount` check | 30s | Pending live hardware test | **PENDING** | T4 |
| **T4** | Planned | Pending | Android Init | Android init starts; core services launch; no update/verifier or bootctl services active | `tools/safe/adb logcat -d` | 60s | Pending live hardware test | **PENDING** | T5 |
| **T5** | Planned | Pending | Framework | Zygote and system_server stay up for >= 5 minutes without crashing | `tools/safe/adb shell ps -ef` | 300s | Pending live hardware test | **PENDING** | T6 |
| **T6** | Planned | Pending | UI & Lockscreen | Boot animation finishes, SystemUI and launcher render lock screen | Visual inspection & SurfaceFlinger dump | 120s | Pending live hardware test | **PENDING** | T7 |
| **T7** | Planned | Pending | Return Path & Integrity | Reboot into Android works; device fingerprint and small partition hashes 100% identical | Fingerprint comparison script | 60s | Pending live hardware test | **PENDING** | Phase B |
