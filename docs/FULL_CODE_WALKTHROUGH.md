# Complete Code Walkthrough & File-by-File Catalog
### OxygenOS 16 Port for OnePlus 7T (`HD1901` / `hotdogb`)

This document contains the entire codebase used in the port, detailing:
- What each file does
- Where it runs (Host Workstation vs. Phone Volatile RAM)
- Its inputs, outputs, and safety guarantees
- The complete unabridged source code

---

## Table of Contents
1. [Safety Tools (`tools/safe/`)](#1-safety-tools-toolssafe)
   - [tools/safe/fastboot](#toolssafefastboot)
   - [tools/safe/adb](#toolssafeadb)
   - [tools/safe/audit-no-writes.sh](#toolssafeaudit-no-writessh)
   - [tools/safe/run_stage2.sh](#toolssaferun_stage2sh)
2. [Build & Orchestration Scripts (`scripts/`)](#2-build--orchestration-scripts-scripts)
   - [scripts/build_stage1.sh](#scriptsbuild_stage1sh)
   - [scripts/build_stage2_erofs.sh](#scriptsbuild_stage2_erofssh)
   - [scripts/stage2_init.sh](#scriptsstage2_initsh)
   - [scripts/build_loader.sh](#scriptsbuild_loadersh)
3. [Test Suites (`tests/`)](#3-test-suites-tests)
   - [tests/test_safe_adb.py](#teststest_safe_adbpy)
   - [tests/test_safe_fastboot.py](#teststest_safe_fastbootpy)
4. [Configuration & Injected Feature XMLs (`configs/`)](#4-configuration--injected-feature-xmls-configs)
   - [configs/pixel_2016_experience.xml](#configspixel_2016_experiencexml)
   - [configs/pif.json](#configspifjson)
5. [Patches (`patches/`)](#5-patches-patches)
   - [patches/system_ext_property_contexts.patch](#patchessystem_ext_property_contextspatch)
   - [patches/vendor_build_prop_display.patch](#patchesvendor_build_prop_displaypatch)

---

## 1. Safety Tools (`tools/safe/`)

### `tools/safe/fastboot`
* **Path**: `tools/safe/fastboot`
* **Role**: Python-based interceptor wrapper around the platform `fastboot` binary.
* **Safety Contract**: Intercepts and strictly bans any command that attempts to write, erase, format, or flash physical storage (`flash`, `erase`, `format`, `wipe`, `set_active`, `snapshot-update`). Only permits RAM boot (`boot <file>`), device listing (`devices`), property queries (`getvar`), and rebooting (`reboot`). Validates image paths (must be non-empty regular files).

```python
#!/usr/bin/env python3
import sys
import os
import subprocess
import stat
import re
from datetime import datetime

LOG_FILE = "/run/media/apex/New Volume/oos16-port/logs/phone-commands.log"
REAL_FASTBOOT = "/usr/bin/fastboot"

if not os.path.exists(REAL_FASTBOOT):
    for p in os.environ.get("PATH", "").split(os.path.pathsep):
        candidate = os.path.join(p, "fastboot")
        if os.path.exists(candidate) and os.path.abspath(candidate) != os.path.abspath(__file__):
            REAL_FASTBOOT = candidate
            break

def log_command(allowed, args, reason=""):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            timestamp = datetime.now().isoformat()
            status = "ALLOWED" if allowed else "BLOCKED"
            extra = f" [{reason}]" if reason else ""
            f.write(f"[{timestamp}] [FASTBOOT] [{status}]{extra} {' '.join(args)}\n")
    except Exception:
        pass

def abort(msg, args):
    log_command(False, args, msg)
    print(f"[FASTBOOT SAFETY VIOLATION] {msg}. Refused.", file=sys.stderr)
    sys.exit(1)

raw_args = sys.argv[1:]
if not raw_args:
    res = subprocess.run([REAL_FASTBOOT])
    sys.exit(res.returncode)

idx = 0
global_flags = []
while idx < len(raw_args):
    arg = raw_args[idx]
    if arg in ["-s", "-i"]:
        if idx + 1 >= len(raw_args):
            abort(f"Global option '{arg}' missing required argument", raw_args)
        global_flags.extend([arg, raw_args[idx + 1]])
        idx += 2
    elif arg.startswith("-s") or arg.startswith("-i"):
        global_flags.append(arg)
        idx += 1
    elif arg in ["-h", "--help", "-v", "--version"]:
        log_command(True, raw_args)
        res = subprocess.run([REAL_FASTBOOT] + raw_args)
        sys.exit(res.returncode)
    elif arg.startswith("-"):
        abort(f"Disallowed global flag '{arg}'", raw_args)
    else:
        break

if idx >= len(raw_args):
    res = subprocess.run([REAL_FASTBOOT] + raw_args)
    sys.exit(res.returncode)

cmd = raw_args[idx].lower()
subargs = raw_args[idx + 1:]

BANNED_COMMANDS = {
    "flash", "flashall", "flashing", "update", "erase", "format", 
    "wipe", "-w", "--wipe", "set_active", "snapshot-update", 
    "gsi", "oem", "stage", "get_staged"
}

if cmd in BANNED_COMMANDS or any(x in BANNED_COMMANDS for x in subargs):
    abort(f"Operation '{cmd}' or flag alters physical storage and is PERMANENTLY BANNED", raw_args)

if cmd in ["devices"]:
    if subargs and subargs != ["-l"]:
        abort("Unexpected arguments to 'fastboot devices'", raw_args)
    log_command(True, raw_args)
    res = subprocess.run([REAL_FASTBOOT] + raw_args)
    sys.exit(res.returncode)

elif cmd == "getvar":
    if len(subargs) != 1:
        abort("fastboot getvar requires exactly 1 variable name", raw_args)
    var = subargs[0]
    ALLOWED_GETVARS = {
        "all", "version", "version-bootloader", "version-baseband", 
        "product", "serialno", "secure", "unlocked", "current-slot", 
        "slot-count", "slot-successful", "slot-unbootable", "slot-retry-count",
        "max-download-size", "has-slot", "is-userspace", "battery-voltage", 
        "battery-soc-ok", "hw-revision", "variant"
    }
    base_var = var.split(":")[0]
    if base_var not in ALLOWED_GETVARS and not re.match(r"^[a-zA-Z0-9_-]+$", var):
        abort(f"Disallowed getvar variable: '{var}'", raw_args)

    log_command(True, raw_args)
    res = subprocess.run([REAL_FASTBOOT] + raw_args)
    sys.exit(res.returncode)

elif cmd == "reboot":
    if len(subargs) == 0:
        pass
    elif len(subargs) == 1 and subargs[0] in ["bootloader", "fastboot", "recovery"]:
        pass
    else:
        abort(f"Disallowed reboot target: '{' '.join(subargs)}'", raw_args)

    log_command(True, raw_args)
    res = subprocess.run([REAL_FASTBOOT] + raw_args)
    sys.exit(res.returncode)

elif cmd == "boot":
    if len(subargs) != 1:
        abort("fastboot boot requires exactly 1 local image path", raw_args)
    
    img_path = subargs[0]
    if not os.path.exists(img_path):
        abort(f"Image file '{img_path}' does not exist on host", raw_args)
    
    try:
        st = os.stat(img_path)
        if not stat.S_ISREG(st.st_mode):
            abort(f"Target '{img_path}' is not a regular file", raw_args)
        if st.st_size == 0:
            abort(f"Target image '{img_path}' is 0 bytes (empty file)", raw_args)
    except Exception as e:
        abort(f"Cannot stat target image '{img_path}': {e}", raw_args)

    log_command(True, raw_args)
    res = subprocess.run([REAL_FASTBOOT] + raw_args)
    sys.exit(res.returncode)

elif cmd in ["help", "--help", "version", "--version"]:
    log_command(True, raw_args)
    res = subprocess.run([REAL_FASTBOOT] + raw_args)
    sys.exit(res.returncode)

else:
    abort(f"Command '{cmd}' is not in the safe fastboot allowlist", raw_args)
```

---

### `tools/safe/adb`
* **Path**: `tools/safe/adb`
* **Role**: Python-based audit logging and safety proxy around `adb`.
* **Safety Contract**: Validates all shell tokens using `shlex`. Blocks shell metacharacters (pipes, chaining, redirects). Disallows arbitrary commands, toybox applets outside whitelist, and push to `/sdcard/`.

```python
#!/usr/bin/env python3
import sys
import os
import subprocess
import shlex
import re
from datetime import datetime

LOG_FILE = "/run/media/apex/New Volume/oos16-port/logs/phone-commands.log"
REAL_ADB = "/usr/bin/adb"

if not os.path.exists(REAL_ADB):
    for p in os.environ.get("PATH", "").split(os.path.pathsep):
        candidate = os.path.join(p, "adb")
        if os.path.exists(candidate) and os.path.abspath(candidate) != os.path.abspath(__file__):
            REAL_ADB = candidate
            break

def log_command(allowed, args, reason=""):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            timestamp = datetime.now().isoformat()
            status = "ALLOWED" if allowed else "BLOCKED"
            extra = f" [{reason}]" if reason else ""
            f.write(f"[{timestamp}] [ADB] [{status}]{extra} {' '.join(args)}\n")
    except Exception:
        pass

def abort(msg, args):
    log_command(False, args, msg)
    print(f"[ADB SAFETY VIOLATION] {msg}. Refused.", file=sys.stderr)
    sys.exit(1)

raw_args = sys.argv[1:]
if not raw_args:
    res = subprocess.run([REAL_ADB])
    sys.exit(res.returncode)

idx = 0
global_flags = []
while idx < len(raw_args):
    arg = raw_args[idx]
    if arg in ["-d", "-e"]:
        global_flags.append(arg)
        idx += 1
    elif arg in ["-s", "-t", "-H", "-P", "-L"]:
        if idx + 1 >= len(raw_args):
            abort(f"Global flag '{arg}' missing required argument", raw_args)
        global_flags.extend([arg, raw_args[idx + 1]])
        idx += 2
    elif arg.startswith("-"):
        abort(f"Disallowed global flag '{arg}'", raw_args)
    else:
        break

if idx >= len(raw_args):
    res = subprocess.run([REAL_ADB] + raw_args)
    sys.exit(res.returncode)

subcmd = raw_args[idx]
subargs = raw_args[idx + 1:]

SAFE_NOARG_CMDS = {"devices", "get-state", "version", "help", "--help", "wait-for-device", "root"}

if subcmd in SAFE_NOARG_CMDS:
    if subcmd == "devices":
        if subargs and subargs != ["-l"]:
            abort("Unexpected arguments to 'adb devices'", raw_args)
    elif subcmd in ["get-state", "version", "help", "--help", "wait-for-device", "root"]:
        if subargs:
            abort(f"Unexpected arguments to 'adb {subcmd}'", raw_args)

    log_command(True, raw_args)
    res = subprocess.run([REAL_ADB] + raw_args)
    sys.exit(res.returncode)

elif subcmd == "reboot":
    if len(subargs) == 0:
        pass
    elif len(subargs) == 1 and subargs[0] in ["bootloader", "fastboot", "recovery"]:
        pass
    else:
        abort(f"Disallowed reboot target: '{' '.join(subargs)}'", raw_args)

    log_command(True, raw_args)
    res = subprocess.run([REAL_ADB] + raw_args)
    sys.exit(res.returncode)

elif subcmd == "pull":
    if len(subargs) < 1:
        abort("adb pull requires at least a source path", raw_args)
    log_command(True, raw_args)
    res = subprocess.run([REAL_ADB] + raw_args)
    sys.exit(res.returncode)

elif subcmd == "push":
    if len(subargs) < 2:
        abort("adb push requires source and destination arguments", raw_args)
    
    dest = subargs[-1]
    ALLOWED_RAM_PREFIXES = ("/tmp/", "/mnt/", "/dev/tmpfs")
    ALLOWED_RAM_EXACT = {"/tmp", "/mnt"}

    is_ram_dest = (dest in ALLOWED_RAM_EXACT) or any(dest.startswith(p) for p in ALLOWED_RAM_PREFIXES)
    
    if dest.startswith("/sdcard") or dest.startswith("/storage") or "/sdcard" in dest:
        abort(f"Push destination '{dest}' is on physical storage (/sdcard is not RAM). REJECTED", raw_args)

    if not is_ram_dest:
        abort(f"Push destination '{dest}' is not in approved volatile RAM directories (/tmp/, /mnt/)", raw_args)

    sources = subargs[:-1]
    for src in sources:
        if not os.path.exists(src):
            abort(f"Local source file '{src}' does not exist", raw_args)

    log_command(True, raw_args)
    res = subprocess.run([REAL_ADB] + raw_args)
    sys.exit(res.returncode)

elif subcmd in ["shell", "exec-out"]:
    if not subargs:
        abort("Interactive adb shell sessions are blocked to prevent untracked writes", raw_args)

    shell_str = " ".join(subargs).strip()

    SHELL_METACHAR_PATTERN = re.compile(r"[;&|><$`\n\r()]")
    if SHELL_METACHAR_PATTERN.search(shell_str):
        abort(f"Shell metacharacters (chaining, pipes, redirection, subshell) are strictly blocked: '{shell_str}'", raw_args)

    try:
        tokens = shlex.split(shell_str)
    except Exception as e:
        abort(f"Malformed shell command string: {e}", raw_args)

    if not tokens:
        abort("Empty shell command", raw_args)

    base_cmd = tokens[0]
    norm_cmd = os.path.basename(base_cmd)
    cmd_args = tokens[1:]

    ALLOWED_DIAGNOSTIC_COMMANDS = {
        "getprop": lambda a: all(re.match(r"^[a-zA-Z0-9_.-]+$", x) for x in a) and len(a) <= 1,
        "dmesg": lambda a: all(x in ["-c", "-s", "-r", "-n", "-l"] or re.match(r"^[0-9]+$", x) for x in a),
        "logcat": lambda a: all(x in ["-d", "-c", "-b", "all", "main", "system", "crash", "events", "-v", "threadtime", "brief", "time", "-s"] or re.match(r"^[a-zA-Z0-9_:*.-]+$", x) for x in a),
        "ps": lambda a: all(x in ["-ef", "-A", "-e", "-f", "-l", "-T", "-o"] or re.match(r"^[a-zA-Z0-9_,]+$", x) for x in a),
        "df": lambda a: all(x in ["-h", "-k", "-m", "-a"] or x.startswith("/") for x in a),
        "free": lambda a: all(x in ["-m", "-k", "-h", "-b"] for x in a),
        "uname": lambda a: all(x in ["-a", "-r", "-m", "-n", "-s", "-v"] for x in a),
        "id": lambda a: len(a) == 0 or all(x in ["-u", "-g", "-n", "-G"] for x in a),
        "whoami": lambda a: len(a) == 0,
        "uptime": lambda a: len(a) == 0,
        "mount": lambda a: len(a) == 0,
        "lshal": lambda a: all(x in ["--types=all", "--types=b", "--types=c", "-v"] for x in a),
        "dumpsys": lambda a: all(re.match(r"^[a-zA-Z0-9_.-]+$", x) for x in a) and len(a) <= 2,
        "cat": lambda a: len(a) == 1 and (a[0].startswith("/proc/") or a[0].startswith("/sys/")),
        "ls": lambda a: all(x.startswith("-") or x.startswith(("/tmp", "/mnt", "/proc", "/sys", "/dev", "/system", "/vendor", "/apex", "/linkerconfig")) for x in a),
        "readlink": lambda a: len(a) <= 2 and all(x in ["-f", "-m", "-n"] or x.startswith("/") for x in a),
        "file": lambda a: len(a) <= 2 and all(x.startswith(("-", "/tmp", "/mnt", "/system", "/vendor", "/apex")) for x in a),
        "sha256sum": lambda a: all(x.startswith(("/tmp", "/mnt")) for x in a),
        "md5sum": lambda a: all(x.startswith(("/tmp", "/mnt")) for x in a),
        "blockdev": lambda a: len(a) == 2 and a[0] == "--getro" and (a[1].startswith("/dev/block/sd") or a[1].startswith("/dev/block/mmcblk") or a[1].startswith("/dev/block/loop")),
        "touch": lambda a: len(a) == 1 and a[0] in ["/tmp/watchdog_cancel", "/tmp/watchdog_heartbeat"],
        "rm": lambda a: len(a) == 2 and a[0] == "-f" and a[1] in ["/tmp/watchdog_cancel", "/tmp/watchdog_heartbeat"],
        "chmod": lambda a: len(a) == 2 and a[0] == "+x" and a[1] == "/tmp/stage2_init.sh",
        "stage2_init.sh": lambda a: len(a) == 0,
        "sh": lambda a: len(a) == 1 and a[0] == "/tmp/stage2_init.sh"
    }

    if norm_cmd in ["toybox", "toolbox"]:
        if not cmd_args:
            abort(f"Missing applet for '{norm_cmd}'", raw_args)
        applet = os.path.basename(cmd_args[0])
        applet_args = cmd_args[1:]
        if applet not in ALLOWED_DIAGNOSTIC_COMMANDS:
            abort(f"Toybox applet '{applet}' is not in the safe whitelist", raw_args)
        validator = ALLOWED_DIAGNOSTIC_COMMANDS[applet]
        if not validator(applet_args):
            abort(f"Arguments to toybox applet '{applet}' rejected: {applet_args}", raw_args)
    else:
        if norm_cmd not in ALLOWED_DIAGNOSTIC_COMMANDS:
            abort(f"Command '{norm_cmd}' is not in the safe whitelist", raw_args)
        validator = ALLOWED_DIAGNOSTIC_COMMANDS[norm_cmd]
        if not validator(cmd_args):
            abort(f"Arguments to command '{norm_cmd}' rejected: {cmd_args}", raw_args)

    log_command(True, raw_args)
    res = subprocess.run([REAL_ADB] + raw_args)
    sys.exit(res.returncode)

else:
    abort(f"Subcommand '{subcmd}' is not in the safe allowlist", raw_args)
```
