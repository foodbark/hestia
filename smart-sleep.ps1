# Smart Sleep Script for Hestia (Windows 10)
# - Reason codes
# - Log rotation
# - Watchdog for scheduled tasks and power settings
# - Auto-sleep after 15 minutes past bedtime

# -------------------------------
# Logging + Rotation
# -------------------------------
$logFile = "C:\Hestia\hestia.log"
function Write-Log($msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logFile -Value "$timestamp  $msg" -Encoding UTF8
}

try {
    if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
        $archive = "C:\Hestia\hestia_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss")
        Move-Item -Path $logFile -Destination $archive
        Write-Log "Log rotated: $archive"
    }
} catch {
    # If rotation fails, continue anyway - don't let a big log file prevent sleep
    Write-Log "WARNING: Log rotation failed: $_"
}

# -------------------------------
# Watchdog
# -------------------------------

# Daily ASCII banner
$dateStr = (Get-Date).ToString("yyyy-MM-dd")
Write-Log ""
Write-Log "================================================"
Write-Log "  (=^.^=)  HESTIA DAILY CHECK  $dateStr"
Write-Log "  > wake up sleepyhead <"
Write-Log "================================================"
Write-Log ""

$requiredTasks = @(
    "HestiaSleepWeeknights",
    "HestiaSleepWeekend",
    "HestiaWakeWeekdays",
    "HestiaWakeWeekend"
)
foreach ($task in $requiredTasks) {
    if (-not (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)) {
        Write-Log "Watchdog: Task '$task' missing!"
    }
}

# Check hibernate is enabled
try {
    $hibEnabled = (powercfg /a) -match "Hibernate"
    if (-not $hibEnabled) { Write-Log "Watchdog: Hibernate is disabled!" }
} catch {
    Write-Log "Watchdog: Could not check hibernate state: $_"
}

# Check wake timers are enabled
try {
    $wakeTimers = (powercfg /query SCHEME_CURRENT SUB_SLEEP bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d) -match "0x00000001"
    if (-not $wakeTimers) { Write-Log "Watchdog: Wake timers are disabled!" }
} catch {
    Write-Log "Watchdog: Could not check wake timer setting: $_"
}

# Check hybrid sleep is enabled (required for wake timers to fire)
try {
    $hybridSleep = (powercfg /query SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP) -match "0x00000001"
    if (-not $hybridSleep) { Write-Log "Watchdog: Hybrid sleep is disabled!" }
} catch {
    Write-Log "Watchdog: Could not check hybrid sleep setting: $_"
}

# Check S4 doze timeout is 0 (if non-zero, machine falls to full hibernate before wake timer fires)
try {
    $s4Query = powercfg /query SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364
    $s4AC = ($s4Query | Select-String "Current AC Power Setting Index: 0x00000000")
    $s4DC = ($s4Query | Select-String "Current DC Power Setting Index: 0x00000000")
    if (-not $s4AC) { Write-Log "Watchdog: S4 doze timeout (AC) is non-zero - wake timers may not fire!" }
    if (-not $s4DC) { Write-Log "Watchdog: S4 doze timeout (DC) is non-zero - wake timers may not fire!" }
} catch {
    Write-Log "Watchdog: Could not check S4 doze timeout: $_"
}

# Log current wake timers
try {
    $timers = powercfg /waketimers
    Write-Log "Watchdog: Wake timers: $($timers -join ' ')"
} catch {
    Write-Log "Watchdog: Could not read wake timers: $_"
}

# Log last wake source
try {
    $lastWake = powercfg /lastwake
    Write-Log "Watchdog: Last wake: $($lastWake -join ' ')"
} catch {
    Write-Log "Watchdog: Could not read last wake: $_"
}

# -------------------------------
# Determine bedtime and wake time
# -------------------------------
$now = Get-Date
$day = $now.DayOfWeek
switch ($day) {
    "Friday" {
        $bedtime = (Get-Date).Date.AddDays(1)
        $wakeTime = (Get-Date).Date.AddDays(1).AddHours(9)  # Saturday 9am
    }
    "Saturday" {
        $bedtime = (Get-Date).Date.AddDays(1)
        $wakeTime = (Get-Date).Date.AddDays(1).AddHours(9)  # Sunday 9am
    }
    "Sunday" {
        $bedtime = (Get-Date).Date.AddHours(22)
        $wakeTime = (Get-Date).Date.AddDays(1).AddHours(7)  # Monday 7am
    }
    default {
        $bedtime = (Get-Date).Date.AddHours(22)
        $wakeTime = (Get-Date).Date.AddDays(1).AddHours(7)  # Weekday 7am
    }
}
$pastBedtime = $now -gt $bedtime
Write-Log "Day=$day Bedtime=$bedtime PastBedtime=$pastBedtime"

# -------------------------------
# Activity detection
# -------------------------------
$cpu = 0
try {
    $cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
} catch {
    Write-Log "WARNING: Could not read CPU counter: $_"
}

# NOTE: GetLastInputInfo only sees input from the interactive desktop session.
# When running as SYSTEM via scheduled task, idle time reflects the last real
# user input and may be days old. $idleActive is retained for logging but is
# not a reliable signal in this context.
$idle = 99999
try {
    $idleTypeDef = @"
using System;
using System.Runtime.InteropServices;
public static class IdleTime {
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    public static uint GetIdleTime() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        GetLastInputInfo(ref lii);
        return ((uint)Environment.TickCount - lii.dwTime) / 1000;
    }
}
"@
    Add-Type -TypeDefinition $idleTypeDef -ErrorAction SilentlyContinue
    $idle = [IdleTime]::GetIdleTime()
} catch {
    Write-Log "WARNING: Could not read idle time: $_"
}

$audio = 0
try {
    $audio = (Get-AudioDevice -Playback).Volume
} catch {
    # AudioDevice module not present or no playback device - treat as silent
    $audio = 0
}

$cpuActive = $cpu -gt 10
$idleActive = $idle -lt 300
$audioActive = $audio -gt 0

$reasons = @()
if ($cpuActive)   { $reasons += "CPU busy" }
if ($idleActive)  { $reasons += "User active" }
if ($audioActive) { $reasons += "Audio playing" }

Write-Log "CPU=$cpu Idle=$idle Audio=$audio PastBedtime=$pastBedtime Reasons=[$($reasons -join ', ')]"

# -------------------------------
# Should we sleep?
# -------------------------------
$shouldSleep = $false

if ($pastBedtime -and $idle -ge 900) {
    Write-Log "Past bedtime + idle 15 min — sleeping now."
    $shouldSleep = $true
} elseif ($reasons.Count -gt 0) {
    Write-Log "System active — skipping sleep."
    exit 0
} else {
    Write-Log "System inactive — going to sleep now."
    $shouldSleep = $true
}

# -------------------------------
# Sleep
# -------------------------------
if ($shouldSleep) {
    # Use PowrProf.dll SetSuspendState($false,$false,$false) to enter hybrid sleep (S3 + hiberfil).
    # rundll32 SetSuspendState 0,1,0 goes directly to S4 hibernate on this machine,
    # which loses wake timers. PowrProf.dll respects the power plan and enters hybrid
    # sleep, from which scheduled task wake timers fire correctly.
    try {
        $sleepTypeDef = @"
using System;
using System.Runtime.InteropServices;
public class SleepButton {
    [DllImport("PowrProf.dll", SetLastError=true)]
    public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
}
"@
        Add-Type -TypeDefinition $sleepTypeDef -ErrorAction SilentlyContinue
        Write-Log "Entering hybrid sleep."
        [SleepButton]::SetSuspendState($false, $false, $false)
    } catch {
        Write-Log "ERROR: Failed to enter hybrid sleep: $_"
        Write-Log "Attempting fallback sleep via rundll32..."
        rundll32.exe powrprof.dll,SetSuspendState 0,1,0
    }
}
