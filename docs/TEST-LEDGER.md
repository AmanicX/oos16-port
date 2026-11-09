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
| **H12** | Packaged Loader Audit | `build/loader.img` | Rebuilt SHA-256: `6ec495865fcad15429625ebb3b515864a56163d9bc848a80c4b1fe5abb5e0257` (built 2026-11-09 01:49:46 +0500 from tree at commit `f073d8d` with working tree changes subsequently committed in `cd6afa5` at 01:53:30) / Baseline: `25c5433e1e9f3d2f94d7dd1e5b05ad13764c0c237a83654495c77c0b393a9de1` (commit `f073d8d`). 36/36 static & handover checks passed locally; explicitly logged as skipped in CI checkout via `.gitignore` | 36/36 Passed locally, Skipped in CI checkout | **LOCAL PASS / CI SKIPPED** |
| **H13** | Packaged Stage1 Audit | `build/stage1.img` | Rebuilt SHA-256: `01ba479dbae2522e5e94c70dd839f919f267880b4b0670df43d5b5236d4992b2` (built 2026-11-09 01:49:58 +0500 from tree at commit `f073d8d` with working tree changes subsequently committed in `cd6afa5` at 01:53:30) / Baseline: `c04480b53cf243ef15135ed3e5b1ab43e5738376520cbe8eddb53690997bee8f` (commit `f073d8d`). 36/36 static & handover checks passed locally; explicitly logged as skipped in CI checkout via `.gitignore` | 36/36 Passed locally, Skipped in CI checkout | **LOCAL PASS / CI SKIPPED** |
| **H14** | Hardware Kernel Assets | `stage1/kernel_src/` | Kernel `c32e3a26...` (banner `4.14.357-perf-gcd3073fb68f1`), DTB `e4faf7c5...` (`qcom,sm8150`), recovery DTBO `7cfdd198...` (`samsung_oneplus`). Verified strictly locally; explicitly logged as skipped in CI checkout via `.gitignore` | Strict SHA-256 and symbol match locally, Skipped in CI checkout | **LOCAL PASS / CI SKIPPED** |
| **H15** | Build Pipeline Unit & Integration Tests | `tests/test_build_pipeline.py` | 32 tests: CLI flags, authoritative APEX directory resolution (`system/system/apex` and `system/apex`), mandatory module rejection, corrupted/mismatched APEX rejection, Stage-2 disposable workspace immutability, OTATOOLS environment precedence (bin and flat directory), authentic hardware asset checksum/size verification, independent boot image verifier, 4-field PARTITION_MAP schema, static safety auditor enforcement | 32/32 tests pass | **PASS** |

### Summary of Automated Test Suite

- **Total Defined Test Methods in Codebase**: **271** (256 Python test methods across 16 classes in 8 files + 15 Go test functions).
- **CI Environment Verification (Historical Reference: Run #26, ID `42541597726`, Result: SUCCESS; Historical Baselines: Run #20 ID `42530682479`, Run #21 ID `42532420525`)**:
  - Python tests executed: **256 tests defined, all live loop-device integration tests execute in privileged CI container environment**.
  - Go tests executed: **15 passed, 0 failed**.
  - **Actual combined CI capacity**: **271 passing tests (100% of defined tests executed and passed)**.
  - Static safety audits: Native and loader ramdisk directories pass 34/34 checks each.
  - Skipped CI checks: Kernel assets (`stage1/kernel_src/`) and packaged boot-image audits (`build/loader.img`, `build/stage1.img`) were skipped because these files were absent from the checkout per `.gitignore`. Do not describe skipped checks as passed.
- **Actual Local Environment Execution (Developer Workstation)**:
  - Python tests executed: **251 tests ran, 250 passed, 0 failed, 0 errors, 1 skipped** (unprivileged loop capability).
  - Live loop-device tests: **1 test suite class skipped** (`TestLiveLoopBlockDeviceSafety`, containing 5 live loop test methods) because local loop-device capabilities were unavailable (`CAN_LOOP: False`).
  - Go tests executed: **15 passed, 0 failed**.
  - **Actual local combined result**: **265 passed, 1 skipped test class** (out of 252 discovered units).
  - Note on test counting: In Python's `unittest`, class-level `setUpClass` skips do not increment `testsRun`; all 250 executed tests passed.
  - Local passing percentage: Do not claim 100% passing locally due to the unprivileged loop-device skip.
- **Conditional Test Behavior**:
  - When loop capabilities are present (CI / root / privileged VM): **256 Python + 15 Go = 271 passed** (5 live loop tests run).
  - When loop capabilities are absent (unprivileged host): **250 Python passed (1 suite skipped) + 15 Go = 265 passed** (5 live loop tests skipped).
- **Pre-Boot Static Safety Auditor**:
  - Local packaged boot images (`build/loader.img`, `build/stage1.img`): **36/36 checks passed**, 0 failed.
  - Ramdisks (`stage1/native_ramdisk`, `stage1/loader_ramdisk`): **34/34 checks passed**, 0 failed, 1 optional unverified cmdline (both locally and in CI).
  - CI checkout status: Ramdisk audits pass (34/34), while kernel assets and packaged boot-image audits were skipped because the files were absent from the checkout per `.gitignore`.
- **Physical Device Verification Status**:
  - Status: **PRE-BOOT VERIFICATION IN PROGRESS — HARDWARE BOOT NOT APPROVED.** (All T0–T7 physical stages strictly pending live fastboot execution; physical storage safety remains subject to live device-level verification).

## 2. Boot Artifact Provenance & Physical Device Bring-Up Stages

### Boot Artifact Provenance Ledger

| Field | `build/stage1.img` (T0 Target) | `build/loader.img` (T1 Target) | `build/images/SHA256SUMS` (Manifest) | `build/images/PARTITION_MAP` (Contract) |
| :--- | :--- | :--- | :--- | :--- |
| **Full SHA-256 Checksum** | `01ba479dbae2522e5e94c70dd839f919f267880b4b0670df43d5b5236d4992b2` | `6ec495865fcad15429625ebb3b515864a56163d9bc848a80c4b1fe5abb5e0257` | `4fb28aabe75bfa39089d783f35fb4700445ee58dadebdeb99533243bcf6c3743` | `e7142764a3f46cb20b4fbc5aa87cb15e9c7b37a6bf3b36c7713af32e26dd8226` |
| **File Size** | 80,166,912 bytes | 80,166,912 bytes | 3,766 bytes | 798 bytes |
| **Proven Build Timestamp** | `2026-11-09 01:49:58.164786100 +0500` | `2026-11-09 01:49:46.920550200 +0500` | `2026-11-08 16:26:14.494358500 +0500` | `2026-11-08 16:25:57.415544000 +0500` |
| **Active Git HEAD at Build** | `f073d8dde6380a2fbe04eb5aa8e8cdc78952fa5a` | `f073d8dde6380a2fbe04eb5aa8e8cdc78952fa5a` | `e18fff3141d9ab8d34b91e71b6e877c8d4962411` | `e18fff3141d9ab8d34b91e71b6e877c8d4962411` |
| **Active Git Tree SHA at Build** | `516d5e9de285687189e100748fd2345021e132e7` | `516d5e9de285687189e100748fd2345021e132e7` | `7fe1f7868516fb83df1e52003cffc82fb66a12df` | `7fe1f7868516fb83df1e52003cffc82fb66a12df` |
| **Uncommitted Working Edits** | Built from dirty working tree with `--verify-block-node` additions; subsequently committed at 01:53:30 as `cd6afa5` (tree `ced6d485...`) | Built from dirty working tree with `--verify-block-node` additions; subsequently committed at 01:53:30 as `cd6afa5` (tree `ced6d485...`) | Built during transition between `e18fff3` and `9bb95a1`; subsequently committed at 16:32:36 as `9bb95a1` (tree `eb9d8ae8...`) | Built alongside `SHA256SUMS` during transition between `e18fff3` and `9bb95a1` |
| **Reproducible Patch SHA-256** | `c8781e55f35d1390ceb910eeae5122aedfe960da663811f4a1e3d17c3c09e355` (`f073d8d..cd6afa5`) | `c8781e55f35d1390ceb910eeae5122aedfe960da663811f4a1e3d17c3c09e355` (`f073d8d..cd6afa5`) | `91b6767ad37ad0cbb6eec1f05fb52399c9249b7c3f6b6dcfd8f7debf67efca20` (`e18fff3..9bb95a1`) | `91b6767ad37ad0cbb6eec1f05fb52399c9249b7c3f6b6dcfd8f7debf67efca20` (`e18fff3..9bb95a1`) |
| **Embedded Subsystem Tree SHA** | `26e11caaf151a41a3d8cf940ba49f0fe3b1f8be5` (`stage1/native_ramdisk`) | `9c6cc4a9dbfcc972908affad2ea76995fc8f20f5` (`stage1/loader_ramdisk`) | N/A (Stage-2 EROFS master manifest) | N/A (Stage-2 4-field contract) |
| **Build Command & Tools** | `scripts/build_stage1.sh` (`mkbootimg` AOSP v2, `lz4` v1.10.0, `python` 3.14.8) | `scripts/build_loader.sh` (`mkbootimg` AOSP v2, `lz4` v1.10.0, `python` 3.14.8) | `scripts/build_stage2_erofs.sh` (`mkfs.erofs`, `fsck.erofs`, coreutils `sha256sum`) | `scripts/build_stage2_erofs.sh` |
| **Kernel / DTB / DTBO Inputs** | Kernel `c32e3a26...` (48,713,752 B), DTB `e4faf7c5...` (9,055,368 B), DTBO `7cfdd198...` (3,219,456 B) | Kernel `c32e3a26...` (48,713,752 B), DTB `e4faf7c5...` (9,055,368 B), DTBO `7cfdd198...` (3,219,456 B) | N/A | N/A |
| **Audit Result & Log Reference** | **PASSED (36/36 checks)**; `logs/audit-report-20261109_014958.log` & `021932.log` | **PASSED (36/36 checks)**; `logs/audit-report-20261109_014946.log` & `021929.log` | **PASSED (37/37 OK via `sha256sum -c`)**; verified across all 6 partitions + 4 APEX modules | **PASSED (Contract validated)**; 4-field schema verified across all 6 partitions |
| **Availability in Workspace** | Available locally (`build/stage1.img`); excluded via `.gitignore` (not in clone) | Available locally (`build/loader.img`); excluded via `.gitignore` (not in clone) | Available locally (`build/images/SHA256SUMS`); excluded via `.gitignore` | Available locally (`build/images/PARTITION_MAP`); excluded via `.gitignore` |
| **Provenance Status** | **PARTIALLY VERIFIED** (Clean reproducible rebuild required before live hardware testing) | **PARTIALLY VERIFIED** (Clean reproducible rebuild required before live hardware testing) | **PARTIALLY VERIFIED** (Clean reproducible rebuild required before live hardware staging) | **PARTIALLY VERIFIED** (Clean reproducible rebuild required before live hardware staging) |

### Reproducible Independent Artifact Verification Procedure

For independent reviewers auditing this repository without access to local `build/` files or physical hardware:

1. **Verify Source Code & Safety Invariants**:
   ```bash
   # Audit ramdisk directory targets (verifies fail-closed read-only logic, watchdog, absence of writes)
   tools/safe/audit-no-writes.sh stage1/loader_ramdisk
   tools/safe/audit-no-writes.sh stage1/native_ramdisk
   ```
2. **Compile & Test BinderFS Binary**:
   ```bash
   (cd src && go test -v ./...)
   (cd src && make arm64)
   ```
3. **Execute Full Automated Host Test Suite**:
   ```bash
   python3 -m unittest discover -s tests -v
   ```
4. **Local Boot Image Packaging & Audit** *(Requires OnePlus 7T kernel/dtb/dtbo in `stage1/kernel_src/`)*:
   ```bash
   scripts/build_loader.sh
   scripts/build_stage1.sh
   tools/safe/audit-no-writes.sh build/loader.img
   tools/safe/audit-no-writes.sh build/stage1.img
   ```

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
