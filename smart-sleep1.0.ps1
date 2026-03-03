# Smart Sleep Script for Hestia (Windows 10)
# - Reason codes
# - Log rotation
# - Watchdog for scheduled tasks
# - Auto-sleep after 15 minutes past bedtime
# - RTC wake alarm set before sleep

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
    "HestiaSleepWeekend"
)
foreach ($task in $requiredTasks) {
    if (-not (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)) {
        Write-Log "Watchdog: Task '$task' missing!"
    }
}

# Check hibernate is enabled
$hibEnabled = (powercfg /a) -match "Hibernate"
if (-not $hibEnabled) { Write-Log "Watchdog: Hibernate is disabled!" }

# Check wake timers are enabled
$wakeTimers = (powercfg /query SCHEME_CURRENT SUB_SLEEP bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d) -match "0x00000001"
if (-not $wakeTimers) { Write-Log "Watchdog: Wake timers are disabled!" }

# Log current wake timers
$timers = powercfg /waketimers
Write-Log "Watchdog: Wake timers: $($timers -join ' ')"

# Log last wake source
$lastWake = powercfg /lastwake
Write-Log "Watchdog: Last wake: $($lastWake -join ' ')"

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

$cpuActive = $cpu -gt 10
$idleActive = $idle -lt 300
$audioActive = $audio -gt 0

$reasons = @()
if ($cpuActive)  { $reasons += "CPU busy" }
if ($idleActive) { $reasons += "User active" }
if ($audioActive){ $reasons += "Audio playing" }

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
# Set RTC wake alarm then sleep
# -------------------------------
if ($shouldSleep) {
    # Define RtcWake only if not already defined
    if (-not ([System.Management.Automation.PSTypeName]'RtcWake').Type) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class RtcWake {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr CreateWaitableTimer(IntPtr lpTimerAttributes, bool bManualReset, string lpTimerName);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetWaitableTimer(IntPtr hTimer, ref long pDueTime, int lPeriod, IntPtr pfnCompletionRoutine, IntPtr lpArgToCompletionRoutine, bool fResume);
    public static IntPtr SetAndHoldWakeTimer(DateTime wakeTime) {
        IntPtr handle = CreateWaitableTimer(IntPtr.Zero, false, "HestiaWakeTimer");
        long dueTime = wakeTime.ToFileTimeUtc();
        SetWaitableTimer(handle, ref dueTime, 0, IntPtr.Zero, IntPtr.Zero, true);
        return handle;
    }
}
"@
    }

    try {
        $handle = [RtcWake]::SetAndHoldWakeTimer($wakeTime)
        Write-Log "RTC wake alarm set for $wakeTime (handle: $handle)"
    } catch {
        Write-Log "ERROR setting RTC wake alarm: $_"
    }

    # Small pause to ensure timer is registered before sleep
    Start-Sleep -Seconds 2

    # Sleep while holding the timer handle
    rundll32.exe powrprof.dll,SetSuspendState 1,1,0
}