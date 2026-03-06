# Hestia

Automation scripts for Hestia, a Lenovo ThinkPad X1 Carbon 5th Gen that serves as the brain of **the Monidoor** — a touchscreen calendar, kitchen entertainment system, scrolling picture frame, and digital hearth of the home. Hestia is embedded in a door connected to an ASUS touchscreen monitor and runs as an always-on machine with a smart sleep/wake cycle.

## Hardware

| | |
|---|---|
| **Machine** | Lenovo ThinkPad X1 Carbon 5th Gen (20HRCTO1WW) |
| **OS** | Windows 10 Enterprise N LTSC 2021 |
| **BIOS** | N1MET78W (1.63) |
| **CPU** | Intel i7-7500U |
| **RAM** | 16GB |
| **Network** | WiFi only — Intel 8265 (no RJ45) |
| **Sleep states** | S3 (Standby) and Hibernate available |
| **Display** | ASUS BE24ECSBT 23.8" multi-touchscreen monitor, laptop lid always closed |

## What This Does

Hestia runs a smart sleep/wake cycle:

- **Sleeps** automatically at 10pm on weeknights and midnight on weekends, based on activity detection (CPU, idle time, audio)
- **Wakes** automatically at 7am on weekdays and 9am on weekends via Windows Task Scheduler wake timers

## Files

| File | Description |
|---|---|
| `smart-sleep.ps1` | Main sleep script. Checks activity, logs state, and puts Hestia to sleep. Run nightly by scheduled tasks. |
| `wake.ps1` | Wake stub. Does nothing — exists only so the scheduled wake tasks have something to run. The act of the task firing is what wakes the machine. |
| `hestia-reset.ps1` | Diagnostic and reset script. Gathers full system power state, restores tasks and power settings to known-good configuration. Run manually if wake behavior breaks. |
| `settings.local.json` | Claude Code permissions config. |
| `.gitignore` | Excludes `*.log` and `*.msi` from the repo. |

## Scheduled Tasks

Four tasks must exist for the sleep/wake cycle to work. The watchdog in `smart-sleep.ps1` will log a warning if any are missing.

| Task | Schedule | Action |
|---|---|---|
| `HestiaSleepWeeknights` | 10pm Sun–Thu | Runs `smart-sleep.ps1` |
| `HestiaSleepWeekend` | Midnight Fri–Sat | Runs `smart-sleep.ps1` |
| `HestiaWakeWeekdays` | 7am Mon–Fri | Runs `wake.ps1` with **Wake to run** enabled |
| `HestiaWakeWeekend` | 9am Sat–Sun | Runs `wake.ps1` with **Wake to run** enabled |

## Power Settings

Required power configuration:

```powershell
# Enable wake timers (AC and battery)
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 1

# Disable automatic hibernate-after-sleep timeout (so hybrid sleep persists until timer fires)
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364 0

# Enable hybrid sleep (S3 + hibernate file for safety)
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 1

powercfg /setactive SCHEME_CURRENT
```

## If Wake Stops Working

Run `hestia-reset.ps1` as admin. It will:

1. Log full system diagnostics (power states, wake history, scheduled tasks, recent updates)
2. Restore default power schemes
3. Re-enable hibernate and wake timers
4. Recreate all four scheduled tasks
5. Clean up `smart-sleep.ps1`
6. Set a test wake task 10 minutes out and hibernate

Then check `C:\Hestia\hestia-reset.log` for the diagnostic output.

Key commands for manual diagnosis:

```powershell
# Is a wake timer registered?
powercfg /waketimers

# What woke her last?
powercfg /lastwake

# Full sleep/wake history
powercfg /sleepstudy
start C:\Windows\system32\sleepstudy-report.html

# Recent log
Get-Content C:\Hestia\hestia.log -Tail 30
```

## Sleep/Wake Troubleshooting History

This has been extensively debugged (generated under the ever watchful eye of Claude, and to be taken with a heavy dose of salt).

### Background

The sleep/wake cycle ran perfectly on this same hardware under Linux using systemd and a bash script (`smart-suspend.sh`) that wrote directly to the hardware RTC before suspending. Linux has direct, clean access to `/sys/class/rtc/rtc0/wakealarm` which lets you set a hardware wake alarm that survives sleep and hibernate. The full story of the Linux setup — and the odyssey through Fedora, Ubuntu, and Tiny11 that eventually landed back on Windows 10 LTSC — is documented at [foodbark.io](https://foodbark.io/posts/the-big-sleep-and-wake-cycle/).

Windows does not expose direct RTC access the same way, which is the root cause of all the complexity below.

### Key findings:

- **Wake timers only work from Hybrid Sleep (S3)**, not from hibernate. If Hestia enters full hibernate before the timer fires, the wake will not happen.
- **`rundll32 SetSuspendState 0,1,0`** bypasses hybrid sleep and goes directly to hibernate on this machine — do not use this approach.
- **`PowrProf.dll SetSuspendState(false, false, false)`** respects the power plan sleep action and correctly enters Hybrid Sleep. This is what `smart-sleep.ps1` uses.
- **Hybrid sleep** writes a hibernate file as a safety net but keeps the machine in S3, allowing wake timers to fire.
- **The S4 doze timeout** (automatic conversion from S3 to hibernate after N minutes) must be set to 0 (disabled) or the timer will be unreachable by morning.
- **WaitableTimer API** (`CreateWaitableTimer`/`SetWaitableTimer`) does NOT write to hardware RTC registers — the timer lives in kernel memory and is lost when the process sleeps. Do not use this approach.
- **Wake-on-WiFi (WoWLAN)** was investigated and abandoned. The Intel 8265 adapter's "Allow this device to wake the computer" option is greyed out in Device Manager on this hardware/driver combination.
- The scheduled wake tasks need **"Wake the computer to run this task"** checked under Conditions. `powercfg /waketimers` should show the timer registered before sleep.
- Confirmed working dates: **Feb 12, 2026** (`HestiaWakeWeekdays`), **Feb 21, 2026** (`HestiaWakeWeekend`), **Mar 6, 2026** (`HestiaWakeWeekdays`).

## Logging

`smart-sleep.ps1` logs to `C:\Hestia\hestia.log` (excluded from git). The log auto-rotates at 1MB. Each nightly run logs:

- ASCII banner with date
- Watchdog status (missing tasks, disabled wake timers, current timer registration, last wake source)
- CPU usage, idle time, audio state
- Sleep decision and reason
