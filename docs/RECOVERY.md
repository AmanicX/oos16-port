# Recovery Plan & Hardware Control (OnePlus 7T / hotdogb)

This recovery plan is established in Phase A0 before any hardware interactions.

---

## 1. Physical Hardware Key Combinations

If an experimental RAM image hangs, freezes, or encounters a kernel panic:

| Action | Hardware Key Combination | Timing & What to Expect |
|---|---|---|
| **Hard Force Reboot** | **Power + Volume Up** | Hold for **10 to 15 seconds**. The phone will abruptly cut power and restart. |
| **Enter Fastboot / Bootloader** | **Power + Volume Up + Volume Down** | Hold from power-off state until the black **FASTBOOT MODE** screen appears. |
| **Enter OrangeFox Recovery** | **Power + Volume Down** | Hold from power-off state until the OnePlus boot logo appears, then release. |

---

## 2. Automated Return Paths Built into Test Images

To prevent unattended hangs or needing physical button presses:
1. **Stage-1 Watchdog Timer**: Every stage-1 test image runs a background countdown timer (default: **60 to 90 seconds**). If the laptop does not send an explicit heartbeat or if userspace does not boot within the timeout window, the watchdog triggers `reboot bootloader`.
2. **Kernel Panic Handler**: All test kernels are built/command-lined with `panic=5`, causing the kernel to automatically reboot to the bootloader 5 seconds after any fatal exception or panic.
3. **USB RAM-Only Channel**: The stage-1 image exports a minimal `adbd` over FunctionFS in RAM. The laptop can issue `adb reboot bootloader` at any time.

---

## 3. Emergency Firmware / SIM Restoration

Because the phone's physical storage (`super` and `userdata`) is never written to, simply rebooting returns the phone to its installed crDroid / Android 16 system.

If the user ever intentionally flashes or restores baseline firmware:
- Windows: Run `restore-sim.bat` in `phone-backup-kit\`
- Linux: Run `./restore-sim.sh` in `phone-backup-kit\`
- Complete backup kit location: `/run/media/apex/New Volume/ios-project/phone-backup-kit/` and remote repository `https://github.com/AmanicX/phone-backup.git`.
