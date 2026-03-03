# Hestia Reset & Diagnostic Script
# Run once as admin to restore original working configuration

$logFile = "C:\Hestia\hestia-reset.log"

function Write-Log($msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp  $msg"
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

Write-Log "====================================================="
Write-Log "  HESTIA RESET & DIAGNOSTIC"
Write-Log "  $(Get-Date)"
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
    $battStatic = Get-WmiObject -Class Win32_Battery
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
Write-Log "====================================================="
Write-Log "  APPLYING RESET"
Write-Log "====================================================="

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
# SECTION 10: Update smart-sleep.ps1
# -------------------------------
Write-Log ""
Write-Log "--- Updating smart-sleep.ps1 ---"
$sleepScript = Get-Content "C:\Hestia\smart-sleep.ps1" -Raw

# Revert any SetSuspendState variant back to 0,1,0
$sleepScript = $sleepScript -replace 'SetSuspendState \d,\d,\d', 'SetSuspendState 0,1,0'

# Remove WaitableTimer RTC block if present
$sleepScript = $sleepScript -replace '(?s)# Define RtcWake.*?rundll32\.exe powrprof\.dll,SetSuspendState 0,1,0\s*\}', 'rundll32.exe powrprof.dll,SetSuspendState 0,1,0'

# Update watchdog task list to match current tasks
$sleepScript = $sleepScript -replace '(?s)\$requiredTasks = @\(.*?\)', '$requiredTasks = @(
    "HestiaSleepWeeknights",
    "HestiaSleepWeekend",
    "HestiaWakeWeekdays",
    "HestiaWakeWeekend"
)'

# Remove any test overrides
$sleepScript = $sleepScript -replace '.*\$pastBedtime = \$true.*\n', ''
$sleepScript = $sleepScript -replace '.*\$idleActive = \$false.*\n', ''
$sleepScript = $sleepScript -replace '(?s)# TEMPORARY TEST.*?# -{30,}\n', ''

Set-Content "C:\Hestia\smart-sleep.ps1" $sleepScript -Encoding UTF8
Write-Log "  smart-sleep.ps1 updated"

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
Write-Log "====================================================="
Write-Log "  RESET COMPLETE"
Write-Log "====================================================="
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

# Now hibernate
Write-Log ""
Write-Log "Hibernating now..."
Start-Sleep -Seconds 3
rundll32.exe powrprof.dll,SetSuspendState 0,1,0