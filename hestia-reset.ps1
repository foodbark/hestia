# Hestia Reset & Diagnostic Script
# Run once as admin to restore original working configuration

$logFile = "C:\Hestia\hestia-reset.log"

function Write-Log($msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp  $msg"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

Write-Log "====================================================="
Write-Log "        }  {                                        "
Write-Log "       } { } {    HESTIA RESET & DIAGNOSTIC        "
Write-Log "      } { } { }    $(Get-Date)    "
Write-Log "  .--------,---------.                             "
Write-Log "  |  ___   |   ___   |   the hearth awakens       "
Write-Log "  | |   |  |  |   |  |                            "
Write-Log "  | |___|  |  |___|  |                            "
Write-Log "  '----------------------------'                   "
Write-Log "====================================================="

# -------------------------------
# SECTION 1: System Info
# -------------------------------
Write-Log ""
Write-Log "--- SYSTEM INFO ---"
Write-Log "Hostname: $env:COMPUTERNAME"
Write-Log "OS: $((Get-WmiObject Win32_OperatingSystem).Caption)"
Write-Log "BIOS: $((Get-WmiObject Win32_BIOS).SMBIOSBIOSVersion)"
Write-Log "Uptime: $((Get-Date) - (gcim Win32_OperatingSystem).LastBootUpTime)"

# Battery
try {
    $batt = Get-WmiObject -Class BatteryStatus -Namespace root\wmi
    $battFull = Get-WmiObject -Class BatteryFullChargedCapacity -Namespace root\wmi
    Write-Log "Battery: PowerOnline=$($batt.PowerOnline) Charging=$($batt.Charging) RemainingCapacity=$($batt.RemainingCapacity) mWh"
    Write-Log "Battery health: $([math]::Round($battFull.FullChargedCapacity / 57020 * 100, 1))% ($($battFull.FullChargedCapacity) mWh of 57020 design)"
} catch {
    Write-Log "Battery info unavailable: $_"
}

# -------------------------------
# SECTION 2: Power State Diagnostics
# -------------------------------
Write-Log ""
Write-Log "--- POWER STATES ---"
$sleepStates = powercfg /a
$sleepStates | ForEach-Object { Write-Log "  $_" }

Write-Log ""
Write-Log "--- POWER REQUESTS (blocking sleep?) ---"
$requests = powercfg /requests
$requests | ForEach-Object { Write-Log "  $_" }

Write-Log ""
Write-Log "--- LAST WAKE ---"
$lastWake = powercfg /lastwake
$lastWake | ForEach-Object { Write-Log "  $_" }

Write-Log ""
Write-Log "--- CURRENT WAKE TIMERS ---"
$timers = powercfg /waketimers
$timers | ForEach-Object { Write-Log "  $_" }

Write-Log ""
Write-Log "--- SLEEP SETTINGS ---"
$sleepSettings = powercfg /query SCHEME_CURRENT SUB_SLEEP
$sleepSettings | ForEach-Object { Write-Log "  $_" }

Write-Log ""
Write-Log "--- HIBERNATE FILE ---"
$hibFile = "C:\hiberfil.sys"
if (Test-Path $hibFile) {
    $size = (Get-Item $hibFile).Length / 1GB
    Write-Log "  hiberfil.sys exists: $([math]::Round($size, 2)) GB"
} else {
    Write-Log "  hiberfil.sys NOT found - hibernate may not be fully enabled"
}

# -------------------------------
# SECTION 3: Recent Windows Updates
# -------------------------------
Write-Log ""
Write-Log "--- RECENT WINDOWS UPDATES ---"
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Log "  $($_.HotFixID)  $($_.InstalledOn)  $($_.Description)"
}

# -------------------------------
# SECTION 4: Services of interest
# -------------------------------
Write-Log ""
Write-Log "--- SERVICES (wazuh/elastic/relevant) ---"
Get-Service | Where-Object {
    $_.DisplayName -match "wazuh|elastic|opensearch|indexer|sleep|power|schedule"
} | ForEach-Object {
    Write-Log "  $($_.DisplayName) | Status=$($_.Status) | StartType=$($_.StartType)"
}

# -------------------------------
# SECTION 5: Scheduled Tasks
# -------------------------------
Write-Log ""
Write-Log "--- SCHEDULED TASKS ---"
Get-ScheduledTask | Where-Object { $_.TaskName -like "Hestia*" } | ForEach-Object {
    $info = $_ | Get-ScheduledTaskInfo
    Write-Log "  $($_.TaskName) | State=$($_.State) | LastResult=$($info.LastTaskResult) | LastRun=$($info.LastRunTime) | NextRun=$($info.NextRunTime)"
}

# -------------------------------
# SECTION 6: Recent wake events from event log
# -------------------------------
Write-Log ""
Write-Log "--- WAKE EVENTS (last 14 days) ---"
try {
    Get-WinEvent -LogName System -ErrorAction Stop | Where-Object {
        $_.Id -eq 1 -and $_.TimeCreated -gt (Get-Date).AddDays(-14)
    } | ForEach-Object {
        Write-Log "  $($_.TimeCreated)  $($_.Message -replace '\s+', ' ')"
    }
} catch {
    Write-Log "  Could not read wake events: $_"
}

# -------------------------------
# SECTION 7: RESET - Power config
# -------------------------------
Write-Log ""
Write-Log "      ( (  ( (                     "
Write-Log "     ) ) ) ) )    APPLYING RESET   "
Write-Log "    ( ( ( ( (     rolling up sleeves..."
Write-Log "   .--------------.               "
Write-Log "   |  []  []  []  |  <-- stovetop "
Write-Log "   |  HESTIA POT  |               "
Write-Log "   |   is on...   |               "
Write-Log "   '--------------'               "

Write-Log ""
Write-Log "--- Restoring default power schemes ---"
powercfg /restoredefaultschemes
Write-Log "  Done"

Write-Log "--- Enabling hibernate ---"
powercfg /hibernate on
Write-Log "  Done"

Write-Log "--- Enabling wake timers (AC) ---"
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 1
Write-Log "  Done"

Write-Log "--- Enabling wake timers (DC/battery) ---"
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 1
Write-Log "  Done"

# restoredefaultschemes resets hybrid sleep to Off and S4 doze to 3 hours.
# Must explicitly restore both or wake timers will not fire.
Write-Log "--- Enabling hybrid sleep (AC) ---"
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 1
Write-Log "  Done"

Write-Log "--- Enabling hybrid sleep (DC/battery) ---"
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 1
Write-Log "  Done"

Write-Log "--- Disabling S4 doze timeout (AC) ---"
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364 0
Write-Log "  Done"

Write-Log "--- Disabling S4 doze timeout (DC/battery) ---"
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP 9d7815a6-7ee4-497e-8888-515a05f02364 0
Write-Log "  Done"

Write-Log "--- Applying power scheme ---"
powercfg /setactive SCHEME_CURRENT
Write-Log "  Done"

# -------------------------------
# SECTION 8: Create wake stub
# -------------------------------
Write-Log ""
Write-Log "--- Creating wake stub ---"
"# hestia wake stub - this script does nothing" | Out-File "C:\Hestia\wake.ps1" -Encoding UTF8
Write-Log "  C:\Hestia\wake.ps1 created"

# -------------------------------
# SECTION 9: Recreate wake tasks
# -------------------------------
Write-Log ""
Write-Log "--- Removing old wake tasks if present ---"
foreach ($t in @("HestiaWakeWeekdays","HestiaWakeWeekend","HestiaSetRTCWake","HestiaWakeTest")) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        Write-Log "  Removed: $t"
    }
}

Write-Log ""
Write-Log "--- Creating HestiaWakeWeekdays (7am Mon-Fri) ---"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -File C:\Hestia\wake.ps1"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "7:00AM"
$settings = New-ScheduledTaskSettingsSet -WakeToRun
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "HestiaWakeWeekdays" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Log "  Created"

Write-Log "--- Creating HestiaWakeWeekend (9am Sat-Sun) ---"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday,Sunday -At "9:00AM"
Register-ScheduledTask -TaskName "HestiaWakeWeekend" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Log "  Created"

# -------------------------------
# SECTION 10: Deploy smart-sleep.ps1
# -------------------------------
Write-Log ""
Write-Log "--- Deploying smart-sleep.ps1 ---"

# Unblock in case the file was downloaded and blocked by Windows
Unblock-File -Path "C:\Hestia\smart-sleep.ps1" -ErrorAction SilentlyContinue
Write-Log "  Unblocked"

# Verify the deployed script does not contain dead WaitableTimer/rundll32 code
$sleepScript = Get-Content "C:\Hestia\smart-sleep.ps1" -Raw
if ($sleepScript -match "WaitableTimer") {
    Write-Log "  WARNING: smart-sleep.ps1 contains WaitableTimer code - replace with clean version from repo"
}
if ($sleepScript -match "rundll32") {
    Write-Log "  WARNING: smart-sleep.ps1 contains rundll32 sleep call - replace with clean version from repo"
}
if ($sleepScript -notmatch "PowrProf") {
    Write-Log "  WARNING: smart-sleep.ps1 does not use PowrProf.dll - replace with clean version from repo"
}

Write-Log "  smart-sleep.ps1 check complete"

# -------------------------------
# SECTION 11: Set up test wake task
# -------------------------------
Write-Log ""
Write-Log "--- Creating test wake task (10 minutes from now) ---"
$testTime = (Get-Date).AddMinutes(10)
$trigger = New-ScheduledTaskTrigger -Once -At $testTime
$settings = New-ScheduledTaskSettingsSet -WakeToRun
Register-ScheduledTask -TaskName "HestiaWakeTest" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Log "  HestiaWakeTest set for $testTime"

Write-Log ""
Write-Log "--- Final wake timers check ---"
$timers = powercfg /waketimers
$timers | ForEach-Object { Write-Log "  $_" }

# -------------------------------
# SECTION 12: Final state
# -------------------------------
Write-Log ""
Write-Log "         } { } {                  "
Write-Log "        { } { } }   RESET COMPLETE"
Write-Log "       } { } { {                  "
Write-Log "  .---------------------------.   "
Write-Log "  |  the hearth is tended.   |   "
Write-Log "  |  hestia is ready.  (,,,) |   "
Write-Log "  '---------------------------'   "
Write-Log ""
Write-Log "Current tasks:"
Get-ScheduledTask | Where-Object { $_.TaskName -like "Hestia*" } | ForEach-Object {
    Write-Log "  $($_.TaskName) | State=$($_.State)"
}

Write-Log ""
Write-Log "NEXT STEP: Stay in the room and watch for Hestia to wake at $testTime"
Write-Log "If she wakes: run 'powercfg /lastwake' and check for Timer (not Power Button)"
Write-Log "If she does not wake: run 'powercfg /sleepstudy' and paste results"
Write-Log ""
Write-Log "Log saved to: $logFile"

# Use PowrProf.dll SetSuspendState($false,$false,$false) to enter hybrid sleep.
# rundll32 SetSuspendState 0,1,0 goes directly to S4 hibernate on this machine,
# which loses the wake timer. PowrProf.dll respects the power plan and enters
# hybrid sleep, from which scheduled task wake timers fire correctly.
Write-Log ""
Write-Log "      . . . . . .                 "
Write-Log "    .  embers low  .  zzz         "
Write-Log "  .   the fire is   .   zzz       "
Write-Log "    .  banked for    .     zzz     "
Write-Log "      .  the night. .              "
Write-Log "  .---------------------------.    "
Write-Log "  |   goodnight, hestia.      |   "
Write-Log "  |   sleep warm. wake well.  |   "
Write-Log "  '---------------------------'    "
Write-Log "Entering hybrid sleep now..."
Start-Sleep -Seconds 3
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SleepButton {
    [DllImport("PowrProf.dll", SetLastError=true)]
    public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
}
"@ -ErrorAction SilentlyContinue
[SleepButton]::SetSuspendState($false, $false, $false)
