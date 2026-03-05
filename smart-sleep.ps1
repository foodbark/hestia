# Smart Sleep Script for Hestia (Windows 10)
# - Log rotation
# - Watchdog for scheduled tasks and power settings
# - Activity detection (CPU, idle time, audio)
# - Auto-sleep after 15 minutes past bedtime
#
# Scheduled tasks:
#   HestiaSleepWeeknights  - runs this script at 10pm Sun-Thu
#   HestiaSleepWeekend     - runs this script at midnight Fri-Sat
#   HestiaWakeWeekdays     - wake timer 7am Mon-Fri (WakeToRun, stub script)
#   HestiaWakeWeekend      - wake timer 9am Sat-Sun (WakeToRun, stub script)

# -------------------------------
# Logging + Rotation
# -------------------------------
$logFile = "C:\Hestia\hestia.log"

function Write-Log($msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logFile -Value "$timestamp  $msg"
}

if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    $archive = "C:\Hestia\hestia_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss")
    Move-Item -Path $logFile -Destination $archive
    Write-Log "Log rotated: $archive"
}

# -------------------------------
# Watchdog
# -------------------------------
$dateStr = (Get-Date).ToString("yyyy-MM-dd")
Write-Log ""
Write-Log "================================================"
Write-Log "  (=^.^=)  HESTIA DAILY CHECK  $dateStr"
Write-Log "  > wake up sleepyhead <"
Write-Log "================================================"
Write-Log ""

# Check required tasks exist
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

# Check wake timers are enabled (GUID: bd3b718a = Allow wake timers)
$wakeTimerSetting = powercfg /query SCHEME_CURRENT SUB_SLEEP bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d
if (-not ($wakeTimerSetting -match "0x00000001")) {
    Write-Log "Watchdog: Wake timers are disabled!"
}

# Log current wake timers and last wake source
$timers = powercfg /waketimers
Write-Log "Watchdog: Wake timers: $($timers -join ' ')"

$lastWake = powercfg /lastwake
Write-Log "Watchdog: Last wake: $($lastWake -join ' ')"

# -------------------------------
# Determine bedtime
# -------------------------------
$now = Get-Date
$day = $now.DayOfWeek

switch ($day) {
    "Friday" {
        # Stay up until midnight, wake Saturday 9am
        $bedtime = (Get-Date).Date.AddDays(1)
    }
    "Saturday" {
        # Stay up until midnight, wake Sunday 9am
        $bedtime = (Get-Date).Date.AddDays(1)
    }
    default {
        # Weeknight bedtime: 10pm
        $bedtime = (Get-Date).Date.AddHours(22)
    }
}

$pastBedtime = $now -gt $bedtime

# -------------------------------
# Activity detection
# -------------------------------
$cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue

Add-Type @"
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
$idle = [IdleTime]::GetIdleTime()

try {
    $audio = (Get-AudioDevice -Playback).Volume
} catch {
    $audio = 0
}

$cpuActive   = $cpu -gt 10
$idleActive  = $idle -lt 300   # less than 5 minutes idle
$audioActive = $audio -gt 0

$reasons = @()
if ($cpuActive)   { $reasons += "CPU busy" }
if ($idleActive)  { $reasons += "User active" }
if ($audioActive) { $reasons += "Audio playing" }

Write-Log "CPU=$cpu Idle=$idle Audio=$audio PastBedtime=$pastBedtime Reasons=[$($reasons -join ', ')]"

# -------------------------------
# Sleep decision
# -------------------------------
if ($pastBedtime -and $idle -ge 900) {
    Write-Log "Past bedtime + idle 15 min — sleeping now."
} elseif ($reasons.Count -gt 0) {
    Write-Log "System active — skipping sleep."
    exit 0
} else {
    Write-Log "System inactive — going to sleep now."
}

# Sleep - let Windows choose S3 or hibernate based on power settings
rundll32.exe powrprof.dll,SetSuspendState 0,1,0
