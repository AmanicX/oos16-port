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
| **H10b** | Loop & Block Device Safety Tests | `tests/test_storage_loop.py` | 14 total test methods: 9 simulated block-device semantics tests (unconditional) + 5 live kernel loop-device integration tests (exercising production `scripts/stage2_init.sh` `verify_block_node_identity` with real `stat -L -c "%t:%T"` against disposable Linux loop devices when privileged in CI/VM) | 9 tests executed locally (9 passed, 0 failed, 1 class-level unprivileged skip); all executed in CI/VM | **PASS** |
| **H11** | Ramdisk Safety Audit | `loader_ramdisk` & `native_ramdisk` | `audit-no-writes.sh` on directory targets (34 checks per directory, 0 failures, 1 optional unverified cmdline). Unconditionally validated both locally and in CI | 34/34 Passed, 0 Failed | **PASS** |
| **H12** | Packaged Loader Audit | `build/loader.img` | Rebuilt SHA-256: `6ec495865fcad15429625ebb3b515864a56163d9bc848a80c4b1fe5abb5e0257` (commit `cd6afa5`, 2026-11-09) / Baseline: `25c5433e1e9f3d2f94d7dd1e5b05ad13764c0c237a83654495c77c0b393a9de1` (commit `f073d8d`). 36/36 static & handover checks passed locally; explicitly logged as skipped in CI checkout via `.gitignore` | 36/36 Passed locally, Skipped in CI checkout | **PASS** |
| **H13** | Packaged Stage1 Audit | `build/stage1.img` | Rebuilt SHA-256: `01ba479dbae2522e5e94c70dd839f919f267880b4b0670df43d5b5236d4992b2` (commit `cd6afa5`, 2026-11-09) / Baseline: `c04480b53cf243ef15135ed3e5b1ab43e5738376520cbe8eddb53690997bee8f` (commit `f073d8d`). 36/36 static & handover checks passed locally; explicitly logged as skipped in CI checkout via `.gitignore` | 36/36 Passed locally, Skipped in CI checkout | **PASS** |
| **H14** | Hardware Kernel Assets | `stage1/kernel_src/` | Kernel `c32e3a26...` (banner `4.14.357-perf-gcd3073fb68f1`), DTB `e4faf7c5...` (`qcom,sm8150`), recovery DTBO `7cfdd198...` (`samsung_oneplus`). Verified strictly locally; explicitly logged as skipped in CI checkout via `.gitignore` | Strict SHA-256 and symbol match locally, Skipped in CI checkout | **PASS** |

### Summary of Automated Test Suite

- **Automated Python Tests**:
  - Total defined test methods: **224 test methods** across 9 test classes.
  - Simulated / host tests: **219 tests** (unconditional across all environments).
  - Live loop-device tests: **5 tests** in `TestLiveLoopBlockDeviceSafety` (conditional on loop capabilities / root privileges).
  - Local environment execution:
    - Tests run: **219 tests**
    - Passed: **219 tests**
    - Failed: **0 tests**
    - Errors: **0**
    - Skipped: **1 test suite** (`TestLiveLoopBlockDeviceSafety`, skipped at class level via `setUpClass` due to unprivileged user space without loop-device capabilities; `CAN_LOOP: False`).
    - Note on test counting: In Python's `unittest`, class-level `setUpClass` skips do not increment `testsRun`; all 219 tests reported in `testsRun` actually executed and passed.
  - CI environment execution:
    - Without loop capabilities: **219 passed, 1 skipped**.
    - With loop capabilities: up to **224 passed**.
- **Automated Go Tests**:
  - Total: **15 tests**
  - Passed: **15 tests**
  - Failed: **0 tests**
  - Skipped: **0 tests**
- **Combined Host Verification**:
  - Local combined: **234 passed, 1 skipped** (out of 235 test units: 219 simulated Python tests + 1 skipped live loop class + 15 Go tests; 239 total defined test methods across Python and Go).
  - Local passing percentage: Do not claim 100% passing locally due to the unprivileged loop-device skip.
  - CI combined: **234 passed** (when loop skipped) / up to **239 passed** (when all 5 live loop tests execute).
- **Pre-Boot Static Safety Auditor**:
  - Local packaged boot images (`build/loader.img`, `build/stage1.img`): **36/36 checks passed**, 0 failed.
  - Ramdisks (`stage1/native_ramdisk`, `stage1/loader_ramdisk`): **34/34 checks passed**, 0 failed, 1 optional unverified cmdline.
  - CI checkout status: Ramdisk audits pass (34/34), while kernel assets and packaged boot-image audits are explicitly logged as skipped (`SKIPPED`) because binary artifacts are excluded from git checkout per `.gitignore`.
- **Physical Device Verification Status**:
  - Status: **PENDING INDEPENDENT SAFETY REVIEW & PHYSICAL HARDWARE TEST** (All T0–T7 physical stages strictly pending live fastboot execution; physical storage safety remains subject to live device-level verification).

## 2. Boot Artifact Provenance & Physical Device Bring-Up Stages

### Boot Artifact Provenance Ledger

| Artifact Filename | Full SHA-256 Checksum | Build Source Commit | Build Date | Kernel / Hardware Provenance | Static Audit Result | Independent Availability | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `build/stage1.img` (Intended T0 Target) | `01ba479dbae2522e5e94c70dd839f919f267880b4b0670df43d5b5236d4992b2` | `cd6afa5` | 2026-11-09 01:49:58 +0500 | Authentic OnePlus 7T SM8150 `4.14.357-perf-gcd3073fb68f1` (`c32e3a26...`), SM8150 DTB (`e4faf7c5...`), Samsung AMOLED DTBO (`7cfdd198...`) | PASSED (36/36 checks) | Available in local build tree (`build/stage1.img`); excluded from git checkout via `.gitignore` | **LOCAL BUILD VERIFIED; PHYSICAL BOOT PENDING** |
| `build/loader.img` (Intended T1 Alternative) | `6ec495865fcad15429625ebb3b515864a56163d9bc848a80c4b1fe5abb5e0257` | `cd6afa5` | 2026-11-09 01:49:46 +0500 | Authentic OnePlus 7T SM8150 `4.14.357-perf-gcd3073fb68f1` (`c32e3a26...`), SM8150 DTB (`e4faf7c5...`), Samsung AMOLED DTBO (`7cfdd198...`) | PASSED (36/36 checks) | Available in local build tree (`build/loader.img`); excluded from git checkout via `.gitignore` | **LOCAL BUILD VERIFIED; PHYSICAL BOOT PENDING** |
| `build/stage1.img` (Historical Baseline) | `c04480b53cf243ef15135ed3e5b1ab43e5738376520cbe8eddb53690997bee8f` | `f073d8d` | 2026-11-08 20:00:51 +0500 | Authentic OnePlus 7T SM8150 `4.14.357-perf-gcd3073fb68f1` (`c32e3a26...`), SM8150 DTB (`e4faf7c5...`), Samsung AMOLED DTBO (`7cfdd198...`) | PASSED (36/36 checks) | Replaced by rebuilt image `01ba479d...` | **SUPERSEDED BY REBUILD** |
| `build/loader.img` (Historical Baseline) | `25c5433e1e9f3d2f94d7dd1e5b05ad13764c0c237a83654495c77c0b393a9de1` | `f073d8d` | 2026-11-08 20:00:51 +0500 | Authentic OnePlus 7T SM8150 `4.14.357-perf-gcd3073fb68f1` (`c32e3a26...`), SM8150 DTB (`e4faf7c5...`), Samsung AMOLED DTBO (`7cfdd198...`) | PASSED (36/36 checks) | Replaced by rebuilt image `6ec49586...` | **SUPERSEDED BY REBUILD** |
| `build/images/SHA256SUMS` (Stage-2 Manifest) | `4fb28aabe75bfa39089d783f35fb4700445ee58dadebdeb99533243bcf6c3743` | `cd6afa5` | 2026-11-08 16:26:00 +0500 | Packaging manifest covering all 6 EROFS partitions and 4 APEX modules | Verified via `sha256sum -c` (37/37 OK) | Available in local build tree (`build/images/`); excluded from git checkout via `.gitignore` | **LOCAL BUILD VERIFIED; RAM STAGING PENDING** |

### Stage-2 Partition Image Entries Verified in `PARTITION_MAP` & `SHA256SUMS`

1. `system.erofs.img`: `3616f6596bd84b7d044b45b2f5743e2cbf8332605a18d26a8e25950609316fb7` -> target mountpoint `/mnt/sysroot` (`mandatory`)
2. `system_ext.erofs.img`: `039081856103b3aa83929f3c97cc2986156e6d950c1fb9108c5a9726ddc57825` -> target mountpoint `/mnt/sysroot/system_ext` (`mandatory`)
3. `vendor.erofs.img`: `8798b7c064c6293609ab0f8ccba72bbcc7f20f1dbdfd378e139b0519c874d8d9` -> target mountpoint `/mnt/sysroot/vendor` (`mandatory`)
4. `odm.erofs.img`: `56594b49080cd73becb0518e29b1217a349f096a8b7c401f7cfdc2e157b70566` -> target mountpoint `/mnt/sysroot/odm` (`mandatory`)
5. `my_product.erofs.img`: `dd44d6920df7622c6389ae8a17b14846dbc7f6a1e24b257f9a238f0a347400ea` -> target mountpoint `/mnt/sysroot/my_product` (`mandatory`)
6. `my_region.erofs.img`: `fbde55dbaa7859c80403cfba11d7042cb2b7f2250d6c2df360bd8fc87809835f` -> target mountpoint `/mnt/sysroot/my_region` (`optional`)

Bootstrap APEX modules verified in `SHA256SUMS`:
- `runtime_apex.img`: `0e5a9c5a8646f0cc809c0b998ce295ab3d0f1c84cdd3f0f64c42daa338db293b`
- `art_apex.img`: `532bfe5de73077f172caa28ebd18e8466406d7b8938724f748f1eb81f370bcf4`
- `i18n_apex.img`: `504e0ea405e7f70f529719574a00d3b67ded8674e618fa119440366f0a2e618e`
- `tzdata_apex.img`: `3d1b7ac96dfeef3b077529f4183dd754fccf0b18c1fc00bb7ff9737790b4da7d`

### Physical Device Bring-Up Stages (OnePlus 7T Hardware)

> [!IMPORTANT]
> The following hardware stages track physical execution on the device via `fastboot boot`.
> Designed for RAM-only execution with fail-closed block-layer read-only protection. Physical storage safety remains subject to live device-level verification.
> All physical device execution stages (T0 through T7) remain strictly pending live test. Zero physical boots have been performed.

| ID | Date | Exact Build Hash | Change / Target | Hypothesis | Command | Timeout | Result | Pass/Fail | Next Step |
|---|---|---|---|---|---|---|---|---|---|
| **T0** | Planned | `01ba479dbae2522e5e94c70dd839f919f267880b4b0670df43d5b5236d4992b2` | Stage-1 Native RAM Boot | Native static init + adbd; all fstabs removed; disks setro; 60s watchdog; adb root | `tools/safe/fastboot boot build/stage1.img` | 60s | Pending live hardware test (zero physical boot executed) | **PENDING** | T1 |
| **T1** | Planned | `01ba479dbae2522e5e94c70dd839f919f267880b4b0670df43d5b5236d4992b2` / `6ec495865fcad15429625ebb3b515864a56163d9bc848a80c4b1fe5abb5e0257` | Block Layer Read-Only Proof | All physical UFS block devices (`/dev/block/sd*`) are read-only; write attempts fail | Resulting from booted `build/stage1.img` (`01ba479d...`) or `build/loader.img` (`6ec49586...`); `blockdev --getro /dev/block/sd[a-f]` -> all return 1 | 30s | Pending live hardware test (safety not yet proven on physical hardware) | **PENDING** | T2 |
| **T2** | Planned | `4fb28aabe75bfa39089d783f35fb4700445ee58dadebdeb99533243bcf6c3743` | RAM Image Build & Packaging | Built 6 high-compression EROFS partitions + 4 APEX modules; zero userdata/metadata/super references; manifest verified (`build/images/SHA256SUMS`: `4fb28aab...`) | `tools/safe/run_stage2.sh` | 300s | Local build verified (37/37 OK); RAM staging pending live test | **PENDING** | T3 |
| **T3** | Planned | Pending | RAM Mounts | EROFS images loop-mount; /data is RAM-backed; zero physical partitions mounted rw | `tools/safe/adb shell mount` check | 30s | Pending live hardware test | **PENDING** | T4 |
| **T4** | Planned | Pending | Android Init | Android init starts; core services launch; no update/verifier or bootctl services active | `tools/safe/adb logcat -d` | 60s | Pending live hardware test | **PENDING** | T5 |
| **T5** | Planned | Pending | Framework | Zygote and system_server stay up for >= 5 minutes without crashing | `tools/safe/adb shell ps -ef` | 300s | Pending live hardware test | **PENDING** | T6 |
| **T6** | Planned | Pending | UI & Lockscreen | Boot animation finishes, SystemUI and launcher render lock screen | Visual inspection & SurfaceFlinger dump | 120s | Pending live hardware test | **PENDING** | T7 |
| **T7** | Planned | Pending | Return Path & Integrity | Reboot into Android works; device fingerprint and small partition hashes 100% identical | Fingerprint comparison script | 60s | Pending live hardware test | **PENDING** | Phase B |
