$wakeTime = (Get-Date).AddMinutes(10)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -File C:\Hestia\wake.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At $wakeTime
$settings = New-ScheduledTaskSettingsSet -WakeToRun
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "HestiaWakeTest" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
powercfg /waketimers
Write-Host "Wake timer set for $wakeTime - sleeping in 5 seconds"
Start-Sleep -Seconds 5
rundll32.exe powrprof.dll,SetSuspendState 0,1,0