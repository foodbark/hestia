# Smart Sleep Script for Hestia (Windows 10)
# - Reason codes
# - Log rotation
# - Watchdog for scheduled tasks and power settings
# - Loops every 15 minutes until system is idle, then sleeps
#
# Usage:
#   smart-sleep.ps1 -Schedule weeknight   (called by HestiaSleepWeeknights, bedtime 10pm)
#   smart-sleep.ps1 -Schedule weekend     (called by HestiaSleepWeekend, bedtime 11:59pm)

param(
    [string]$Schedule = "weeknight"  # "weeknight" or "weekend"
)

# -------------------------------
# Type definitions - must be at top level, here-strings cannot be indented
# -------------------------------
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

$audioTypeDef = @"
using System;
using System.Runtime.InteropServices;
[Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioMeterInformation {
    int GetPeakValue(out float pfPeak);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MMDeviceEnumeratorClass { }
public static class AudioChecker {
    public static float GetPeakValue() {
        var enumeratorGuid = typeof(MMDeviceEnumeratorClass).GUID;
        var enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(typeof(MMDeviceEnumeratorClass));
        IMMDevice device;
        enumerator.GetDefaultAudioEndpoint(0, 1, out device); // eRender, eMultimedia
        var iidMeter = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
        object meterObj;
        device.Activate(ref iidMeter, 23, IntPtr.Zero, out meterObj); // CLSCTX_ALL = 23
        var meter = (IAudioMeterInformation)meterObj;
        float peak;
        meter.GetPeakValue(out peak);
        return peak;
    }
}
"@

$sleepTypeDef = @"
using System;
using System.Runtime.InteropServices;
public class SleepButton {
    [DllImport("PowrProf.dll", SetLastError=true)]
    public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
}
"@

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
    Write-Log "WARNING: Log rotation failed: $_"
}

# -------------------------------
# Watchdog - runs once at startup
# -------------------------------
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

try {
    $hibEnabled = (powercfg /a) -match "Hibernate"
    if (-not $hibEnabled) { Write-Log "Watchdog: Hibernate is disabled!" }
} catch {
    Write-Log "Watchdog: Could not check hibernate state: $_"
}

try {
    $wakeTimers = (powercfg /query SCHEME_CURRENT SUB_SLEEP bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d) -match "0x00000001"
    if (-not $wakeTimers) { Write-Log "Watchdog: Wake timers are disabled!" }
} catch {
    Write-Log "Watchdog: Could not check wake timer setting: $_"
}

try {
    $hybridSleep = (powercfg /query SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP) -match "0x00000001"
    if (-not $hybridSleep) { Write-Log "Watchdog: Hybrid sleep is disabled!" }
} catch {
    Write-Log "Watchdog: Could not check hybrid sleep setting: $_"
}

try {
    $s4Query = powercfg /query SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364
    $s4AC = ($s4Query | Select-String "Current AC Power Setting Index: 0x00000000")
    $s4DC = ($s4Query | Select-String "Current DC Power Setting Index: 0x00000000")
    if (-not $s4AC) { Write-Log "Watchdog: S4 doze timeout (AC) is non-zero - wake timers may not fire!" }
    if (-not $s4DC) { Write-Log "Watchdog: S4 doze timeout (DC) is non-zero - wake timers may not fire!" }
} catch {
    Write-Log "Watchdog: Could not check S4 doze timeout: $_"
}

try {
    $timers = powercfg /waketimers
    Write-Log "Watchdog: Wake timers: $($timers -join ' ')"
} catch {
    Write-Log "Watchdog: Could not read wake timers: $_"
}

try {
    $lastWake = powercfg /lastwake
    Write-Log "Watchdog: Last wake: $($lastWake -join ' ')"
} catch {
    Write-Log "Watchdog: Could not read last wake: $_"
}

# -------------------------------
# Determine bedtime
# -------------------------------
# Bedtime is determined by which scheduled task invoked this script, not by
# deriving it from the current time. This avoids edge cases where the task
# fires near midnight and the day-of-week has already rolled over.
#
#   weeknight: HestiaSleepWeeknights fires at 10pm - bedtime is 10pm
#   weekend:   HestiaSleepWeekend fires at 11:59pm - bedtime is 11:59pm

$now = Get-Date
if ($Schedule -eq "weekend") {
    $bedtime = (Get-Date).Date.AddHours(23).AddMinutes(59)
} else {
    $bedtime = (Get-Date).Date.AddHours(22)
}
$pastBedtime = $now -gt $bedtime
Write-Log "Schedule=$Schedule Bedtime=$bedtime PastBedtime=$pastBedtime"

# Load types once before the loop
try {
    Add-Type -TypeDefinition $idleTypeDef -ErrorAction SilentlyContinue
} catch {
    Write-Log "WARNING: Could not load IdleTime type: $_"
}

try {
    Add-Type -TypeDefinition $audioTypeDef -ErrorAction SilentlyContinue
} catch {
    Write-Log "WARNING: Could not load AudioChecker type: $_"
}

try {
    Add-Type -TypeDefinition $sleepTypeDef -ErrorAction SilentlyContinue
} catch {
    Write-Log "WARNING: Could not load SleepButton type: $_"
}

# -------------------------------
# Sleep loop - checks every 15 minutes until idle, then sleeps
# CPU threshold raised to 25% so script polling does not trip it
# Audio checked via IAudioMeterInformation peak value - works with
# bluetooth and any audio device, no external module required
# -------------------------------
while ($true) {
    $cpu = 0
    try {
        $cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
    } catch {
        Write-Log "WARNING: Could not read CPU counter: $_"
    }

    # NOTE: GetLastInputInfo measures user input (keyboard/mouse/touch), not CPU load.
    # When running as SYSTEM via scheduled task, this reflects last real user
    # input and may be unreliable. Idle defaults to 99999 on error so it never
    # blocks sleep.
    $idle = 99999
    try {
        $idle = [IdleTime]::GetIdleTime()
    } catch {
        Write-Log "WARNING: Could not read idle time: $_"
    }

    # Peak value > 0.0 means audio is actively rendering on the default playback device.
    # This works regardless of output device (bluetooth, HDMI, built-in speakers).
    # Defaults to 0 on error so a broken audio check never blocks sleep.
    $audioPeak = 0
    try {
        $audioPeak = [AudioChecker]::GetPeakValue()
    } catch {
        Write-Log "WARNING: Could not read audio peak: $_"
    }

    $cpuActive   = $cpu -gt 25
    $idleActive  = $idle -lt 900
    $audioActive = $audioPeak -gt 0

    $reasons = @()
    if ($cpuActive)   { $reasons += "CPU busy" }
    if ($idleActive)  { $reasons += "User active" }
    if ($audioActive) { $reasons += "Audio playing" }

    Write-Log "CPU=$cpu Idle=$idle AudioPeak=$audioPeak PastBedtime=$pastBedtime Reasons=[$($reasons -join ', ')]"

    if ($reasons.Count -eq 0) {
        Write-Log "System inactive - going to sleep."

        # Use PowrProf.dll SetSuspendState($false,$false,$false) to enter hybrid sleep.
        # rundll32 goes directly to S4 hibernate on this machine, losing wake timers.
        # PowrProf.dll respects the power plan and enters hybrid sleep, from which
        # scheduled task wake timers fire correctly.
        try {
            Write-Log "Entering hybrid sleep."
            [SleepButton]::SetSuspendState($false, $false, $false)
        } catch {
            Write-Log "ERROR: Failed to enter hybrid sleep: $_"
            Write-Log "Attempting fallback sleep via rundll32..."
            rundll32.exe powrprof.dll,SetSuspendState 0,1,0
        }
        break
    }

    Write-Log "System active - waiting 15 minutes before retry."
    Start-Sleep -Seconds 900
}
