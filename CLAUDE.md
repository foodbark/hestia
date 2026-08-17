# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Automation scripts that run **on Hestia herself** — a Lenovo ThinkPad X1 Carbon 5th Gen (Windows 10 Enterprise N LTSC 2021) embedded in a door, driving a touchscreen calendar/kitchen display ("The Monidoor"). The repo lives at `C:\Hestia` on the machine it controls; there is no separate deploy step — editing a file here edits the live script. There is no build system, test suite, linter, or package manager. This is a small set of PowerShell scripts plus captured logs and diagnostic output.

The scripts implement a **smart sleep/wake cycle**: Hestia sleeps at night (10pm weeknights / 11:59pm weekends) once idle, and wakes each morning (7am weekdays / 9am weekends) via Windows Task Scheduler wake timers.

## Active vs. reference files

Only three scripts are part of the live configuration:

- `smart-sleep.ps1` — the production sleep script. Run nightly by scheduled tasks with `-Schedule weeknight|weekend`. **This is the file to edit for sleep behavior.**
- `hestia-reset.ps1` — diagnostic + reset. Run manually as admin when wake breaks; it recreates all scheduled tasks and power settings from scratch and is the source of truth for their correct configuration.
- `wake.ps1` — intentionally empty stub. The scheduled wake task firing is what wakes the machine; the script does nothing and must stay that way.

Everything else is kept for reference and must **not** be treated as current:
- `smart-sleep1.0.ps1` and `hestia-sleep-test-3-3-26*.ps1` are **old, broken** approaches (WaitableTimer / `rundll32 SetSuspendState`) retained only to document what failed. Do not copy patterns from them into the active scripts — they contain exactly the anti-patterns listed below.
- `hestia.log`, `hestia-reset.log`, `output.txt`, `sleepstudy-report.html` are captured output.

## Hard-won constraints (do not regress these)

The correct approach was found through extensive debugging. Changes that violate these will silently break the wake cycle — and a broken wake means the physical hearth display is dark until someone resets it in person.

- **Sleep must use `PowrProf.dll` `SetSuspendState($false, $false, $false)`** (hibernate=false → hybrid sleep). This machine only fires wake timers from Hybrid Sleep (S3). `rundll32.exe powrprof.dll,SetSuspendState` goes straight to S4 hibernate here and loses the timer — it exists only as a last-ditch fallback inside a `catch`.
- **Never reintroduce `CreateWaitableTimer`/`SetWaitableTimer`.** That API lives in kernel memory, does not touch the hardware RTC, and is lost when the process sleeps. The morning wake is driven entirely by scheduled tasks with **Wake To Run** (`New-ScheduledTaskSettingsSet -WakeToRun`), not by any timer the script sets.
- **Power settings that must hold:** wake timers enabled (AC+DC), hybrid sleep enabled (AC+DC), and the S4 doze timeout (`9d7815a6-...`) set to `0`. `powercfg /restoredefaultschemes` resets the latter two — `hestia-reset.ps1` re-applies them explicitly after any restore.
- **Sleep scheduled tasks must pass `-ExecutionPolicy Bypass`.** They run as SYSTEM, whose default policy is Restricted; without the flag they fail silently with `0x80070001`. Do **not** change the system-wide execution policy to work around this.
- **Bedtime comes from the `-Schedule` param, never derived from the clock.** The weekend task fires at 11:59pm; deriving day-of-week near midnight caused a rollover bug. `weeknight` → 10pm, `weekend` → 11:59pm.
- **PowerShell here-strings (`@"` … `"@`) cannot be indented.** The opening `@"` must end its line and the closing `"@` must be at column 0 with no leading whitespace. All `Add-Type` type definitions are declared at top level before any `if`/`try` for this reason — indenting them causes parse errors and silent script failure.

## Activity detection (why sleep waits)

`smart-sleep.ps1` loops every 15 minutes and only sleeps when all three signals are quiet:
- **CPU** `< 25%` (threshold is above the script's own polling cost).
- **Idle** via `GetLastInputInfo` P/Invoke. Note this measures user input, not load, and is unreliable under SYSTEM — it defaults to `99999` on error so it never blocks sleep.
- **Audio** via `IAudioMeterInformation::GetPeakValue()` COM interop (peak `> 0` = playing). Chosen because it needs no external module, works as SYSTEM, and works with any output device including Bluetooth. Defaults to `0` on error so a broken check never blocks sleep.

The defensive defaults are deliberate: every detector fails **toward** allowing sleep.

## Common operations

There is nothing to build or test. To act on this repo you edit a script and/or run diagnostics on the machine:

```powershell
# Re-apply the entire known-good config (recreates tasks + power settings, then test-sleeps)
powershell -ExecutionPolicy Bypass -File C:\Hestia\hestia-reset.ps1   # run as admin

# Inspect state
powercfg /waketimers      # is a wake timer registered before sleep?
powercfg /lastwake        # what woke her? (want "Timer", not "Power Button")
powercfg /a               # which sleep states are available
Get-Content C:\Hestia\hestia.log -Tail 30

# A script copied in from elsewhere (git, another machine, generated) is blocked by Windows
Unblock-File -Path C:\Hestia\smart-sleep.ps1
```

`smart-sleep.ps1` logs to `hestia.log` (auto-rotates at 1MB). `hestia-reset.ps1` sets a `HestiaWakeTest` task 10 minutes out and then sleeps, so a reset is validated by physically watching for the machine to wake.

## Editing notes

- The README's "Sleep/Wake Troubleshooting History" section is the long-form rationale for everything above — read it before changing sleep/power logic.
- After editing a script that will be committed and later pulled back onto Hestia, remember it will need `Unblock-File` on arrival.
- `.gitignore` excludes `.claude` and `*.msi`; `hestia.log` and rotated `hestia_*.log` archives are runtime output.
