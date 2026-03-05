# Hestia

Automation scripts for Hestia, a Lenovo ThinkPad X1 Carbon 5th Gen running Windows 10 LTSC 2021 as a home server / always-on machine.

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

# Disable automatic hibernate-after-sleep timeout (so S3 sleep persists until timer fires)
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

This has been extensively debugged. Key findings:

- **Wake timers only work from S3 sleep**, not from hibernate. If Hestia converts from S3 to hibernate before the timer fires, the wake will not happen.
- **`SetSuspendState 0,1,0`** is the correct call. The machine goes to S3 or hybrid sleep depending on power settings.
- **Hybrid sleep** writes a hibernate file as a safety net but keeps the machine in S3, allowing wake timers to fire.
- **The S4 doze timeout** (automatic conversion from S3 to hibernate after N minutes) must be set to 0 (disabled) or the timer will be unreachable by morning.
- **WaitableTimer API** (`CreateWaitableTimer`/`SetWaitableTimer`) does NOT write to hardware RTC registers — the timer lives in kernel memory and is lost when the process sleeps. Do not use this approach.
- **Wake-on-WiFi (WoWLAN)** was investigated and abandoned. The Intel 8265 adapter's "Allow this device to wake the computer" option is greyed out in Device Manager on this hardware/driver combination.
- The scheduled wake tasks need **"Wake the computer to run this task"** checked under Conditions. `powercfg /waketimers` should show the timer registered before sleep.
- Confirmed working dates: **Feb 12, 2026** (`HestiaWakeWeekdays`) and **Feb 21, 2026** (`HestiaWakeWeekend`).

## Logging

`smart-sleep.ps1` logs to `C:\Hestia\hestia.log` (excluded from git). The log auto-rotates at 1MB. Each nightly run logs:

- ASCII banner with date
- Watchdog status (missing tasks, disabled wake timers, current timer registration, last wake source)
- CPU usage, idle time, audio state
- Sleep decision and reason
