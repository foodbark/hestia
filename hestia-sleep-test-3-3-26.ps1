$wakeTime = (Get-Date).AddMinutes(6)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -File C:\Hestia\wake.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At $wakeTime
$settings = New-ScheduledTaskSettingsSet -WakeToRun
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "HestiaWakeTest" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
powercfg /waketimers
Write-Host "Hibernating in 3 seconds... wake expected at $wakeTime"
Start-Sleep -Seconds 3
rundll32.exe powrprof.dll,SetSuspendState 0,1,0