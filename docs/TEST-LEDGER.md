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
| **H7** | Watchdog Unit & Synchronization Tests | `tests/test_watchdog.py` | 62 unit tests: numeric parsing, timeout bounds, fail-closed storage validation (missing, empty, unreadable, malformed inventory), blockdev ro=1, duplicate detection, newly appearing disk/partition discovery, mknod argument construction, emergency reboot trigger, two-copy inventory synchronization (/mnt & /tmp), atomic staging & publication, byte-identity verification, block-node identity verification via stat -L -c %t:%T, POSIX hex-to-decimal conversion, 0:0 rejection, fail-closed missing stat | 62/62 tests pass | **PASS** |
| **H8** | Stage-2 Integration Tests | `tests/test_integration_stage2.py` | 72 integration tests: RAM accounting, 4-field PARTITION_MAP contract, runner storage parity enforcement, APEX staging, fail-closed SELinux checks | 72/72 tests pass | **PASS** |
| **H9** | Safe ADB & Fastboot Tests | `tests/test_safe_*.py` | 11 tests: command interception, metacharacter protection, flash bans (8 ADB + 3 Fastboot) | 11/11 tests pass | **PASS** |
| **H10** | Physical Storage Safety Tests | `tests/test_storage_safety.py` | 39 tests: multi-disk sysfs discovery, duplicate detection, byte-identity verification, strict block-node identity verification (`stat -L -c "%t:%T"` with hex-to-decimal conversion), mount_and_verify_tmpfs extraction, capacity exhaustion, 6 checkpoint tracking | 39/39 tests pass | **PASS** |
| **H10b** | Loop & Block Device Safety Tests | `tests/test_storage_loop.py` | Disposable loop-device integration tests (exercising production `scripts/stage2_init.sh` `verify_block_node_identity` with real `stat -L -c "%t:%T"` on live loop device when privileged in CI/VM) and simulated block-device semantics tests (unconditional across all environments) | 9 verified locally (8 passed, 0 failed, 1 unprivileged skip); all passed in CI/VM | **PASS** |
| **H11** | Ramdisk Safety Audit | `loader_ramdisk` & `native_ramdisk` | `audit-no-writes.sh` on directory targets (34 checks per directory, 0 failures, 1 optional unverified cmdline). Unconditionally validated both locally and in CI | 34/34 Passed, 0 Failed | **PASS** |
| **H12** | Packaged Loader Audit | `build/loader.img` | SHA-256: `6ec495865fcad15429625ebb3b515864a56163d9bc848a80c4b1fe5abb5e0257` (rebuilt) / `25c5433e1e9f3d2f94d7dd1e5b05ad13764c0c237a83654495c77c0b393a9de1` (baseline) (36 static & handover checks). Audited locally; explicitly logged as skipped in CI checkout when binary omitted | 36/36 Passed locally, Skipped in CI checkout | **PASS** |
| **H13** | Packaged Stage1 Audit | `build/stage1.img` | SHA-256: `01ba479dbae2522e5e94c70dd839f919f267880b4b0670df43d5b5236d4992b2` (rebuilt) / `c04480b53cf243ef15135ed3e5b1ab43e5738376520cbe8eddb53690997bee8f` (baseline) (36 static & handover checks). Audited locally; explicitly logged as skipped in CI checkout when binary omitted | 36/36 Passed locally, Skipped in CI checkout | **PASS** |
| **H14** | Hardware Kernel Assets | `stage1/kernel_src/` | Kernel `c32e3a26...` (banner `4.14.357-perf-gcd3073fb68f1`), DTB `e4faf7c5...` (`qcom,sm8150`), recovery DTBO `7cfdd198...` (`samsung_oneplus`). Verified strictly locally; explicitly logged as skipped in CI checkout via `.gitignore` | Strict SHA-256 and symbol match locally, Skipped in CI checkout | **PASS** |

### Summary of Automated Test Suite

- **Automated Python Tests**:
  - Local environment: **219 tests** (218 passed, 0 failed, 1 skipped)
  - CI environment: **219 passed**
  - Skipped test: `TestLiveLoopBlockDeviceSafety`, skipped in unprivileged local user space; passes in CI/VM with loop capabilities
- **Automated Go Tests**:
  - **15 tests passed**, 0 failed
- **Combined Host Verification**:
  - Local combined: **233 passed, 1 skipped** (out of 234 total; do not claim 100% passing locally due to unprivileged loop skip)
  - CI combined: **234 passed** (with passwordless sudo loop capabilities in CI/VM)
- **Pre-Boot Static Safety Auditor**:
  - Local packaged boot images (`build/loader.img`, `build/stage1.img`): **36/36 checks passed**, 0 failed.
  - Ramdisks (`stage1/native_ramdisk`, `stage1/loader_ramdisk`): **34/34 checks passed**, 0 failed, 1 optional unverified cmdline.
  - CI execution without local device kernel checkout: Ramdisk audits pass (34/34), while kernel assets and packaged boot-image audits are explicitly logged as skipped (`SKIPPED`).
- **Physical Device Verification Status**:
  - Status: **PENDING LIVE HARDWARE TEST** (All T0–T7 stages pending live fastboot execution; physical storage safety remains subject to device-level verification).

## 2. Physical Device Bring-Up Stages (OnePlus 7T Hardware)

> [!IMPORTANT]
> The following hardware stages track physical execution on the device via `fastboot boot`.
> Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to live device-level verification.
> All physical device execution stages (T0 through T7) remain strictly pending live test.

| ID | Date | Build Hash | Change / Target | Hypothesis | Command | Timeout | Result | Pass/Fail | Next Step |
|---|---|---|---|---|---|---|---|---|---|
| **T0** | Planned | `c04480b5...` | Stage-1 Native RAM Boot | Native static init + adbd; all fstabs removed; disks setro; 60s watchdog; adb root | `tools/safe/fastboot boot build/stage1.img` | 60s | Pending live hardware test | **PENDING** | T1 |
| **T1** | Planned | `c04480b5...` / `25c5433e...` | Block Layer Read-Only Proof | All physical UFS block devices (`/dev/block/sd*`) are read-only; write attempts fail | Resulting from booted `build/stage1.img` (`c04480b5...`) or `build/loader.img` (`25c5433e...`); `blockdev --getro /dev/block/sd[a-f]` -> all return 1 | 30s | Pending live hardware test | **PENDING** | T2 |
| **T2** | Planned | `Pending (Manifest: 4fb28aab...)` | RAM Image Build & Packaging | Built 6 high-compression EROFS partitions; zero userdata/metadata/super references; manifest verified (`build/images/SHA256SUMS`: `4fb28aab...`) | `tools/safe/run_stage2.sh` | 300s | Pending live hardware test | **PENDING** | T3 |
| **T3** | Planned | Pending | RAM Mounts | EROFS images loop-mount; /data is RAM-backed; zero physical partitions mounted rw | `tools/safe/adb shell mount` check | 30s | Pending live hardware test | **PENDING** | T4 |
| **T4** | Planned | Pending | Android Init | Android init starts; core services launch; no update/verifier or bootctl services active | `tools/safe/adb logcat -d` | 60s | Pending live hardware test | **PENDING** | T5 |
| **T5** | Planned | Pending | Framework | Zygote and system_server stay up for >= 5 minutes without crashing | `tools/safe/adb shell ps -ef` | 300s | Pending live hardware test | **PENDING** | T6 |
| **T6** | Planned | Pending | UI & Lockscreen | Boot animation finishes, SystemUI and launcher render lock screen | Visual inspection & SurfaceFlinger dump | 120s | Pending live hardware test | **PENDING** | T7 |
| **T7** | Planned | Pending | Return Path & Integrity | Reboot into Android works; device fingerprint and small partition hashes 100% identical | Fingerprint comparison script | 60s | Pending live hardware test | **PENDING** | Phase B |
