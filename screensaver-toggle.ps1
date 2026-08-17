# Screensaver Toggle for Hestia (Windows 10)
# Turns the photo screensaver on or off on the interactive (hestia) desktop.
#
# Hestia doubles as a Google Calendar display. During the day the screensaver
# is turned OFF so the calendar stays on screen; in the evening it is turned
# back ON so personal photos cycle when the machine is idle.
#
# Driven by two scheduled tasks (see hestia-reset.ps1 / README):
#   HestiaScreensaverOff  7:00am daily  -> screensaver-toggle.ps1 -Mode off
#   HestiaScreensaverOn   6:00pm daily  -> screensaver-toggle.ps1 -Mode on
#
# Must run in the interactive hestia session (LogonType Interactive) so the
# SystemParametersInfo broadcast reaches the live desktop. Running as SYSTEM
# would write the registry but not apply to the running session.
#
# Usage:
#   screensaver-toggle.ps1 -Mode off   (calendar mode - no screensaver)
#   screensaver-toggle.ps1 -Mode on    (photos after $timeoutSeconds idle)

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("on", "off")]
    [string]$Mode
)

$timeoutSeconds = 60   # idle seconds before photos start; matches existing config

# -------------------------------
# Logging (shared with smart-sleep.ps1)
# -------------------------------
$logFile = "C:\Hestia\hestia.log"
function Write-Log($msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logFile -Value "$timestamp  [screensaver] $msg" -Encoding UTF8
}

# -------------------------------
# SystemParametersInfo - applies the setting to the live session immediately
# instead of only at next logon. SPIF_UPDATEINIFILE persists it; SPIF_SENDCHANGE
# broadcasts WM_SETTINGCHANGE so the running desktop picks it up.
# -------------------------------
$spiTypeDef = @"
using System;
using System.Runtime.InteropServices;
public static class Spi {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
    public const uint SPI_SETSCREENSAVEACTIVE  = 0x0011;
    public const uint SPI_SETSCREENSAVETIMEOUT = 0x000F;
    public const uint SPIF_UPDATEINIFILE = 0x01;
    public const uint SPIF_SENDCHANGE    = 0x02;
}
"@
try {
    Add-Type -TypeDefinition $spiTypeDef -ErrorAction SilentlyContinue
} catch {
    Write-Log "WARNING: Could not load Spi type: $_"
}

$deskKey = "HKCU:\Control Panel\Desktop"
$flags = [Spi]::SPIF_UPDATEINIFILE -bor [Spi]::SPIF_SENDCHANGE

if ($Mode -eq "off") {
    try {
        Set-ItemProperty -Path $deskKey -Name ScreenSaveActive -Value "0"
        [Spi]::SystemParametersInfo([Spi]::SPI_SETSCREENSAVEACTIVE, 0, [IntPtr]::Zero, $flags) | Out-Null

        # If the photo screensaver is already running, kill it so the calendar
        # shows immediately rather than waiting for the next user input.
        Get-Process -Name PhotoScreensaver -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

        Write-Log "Screensaver DISABLED (calendar mode)."
    } catch {
        Write-Log "ERROR disabling screensaver: $_"
    }
} else {
    try {
        Set-ItemProperty -Path $deskKey -Name ScreenSaveTimeOut -Value "$timeoutSeconds"
        Set-ItemProperty -Path $deskKey -Name ScreenSaveActive -Value "1"
        [Spi]::SystemParametersInfo([Spi]::SPI_SETSCREENSAVETIMEOUT, $timeoutSeconds, [IntPtr]::Zero, $flags) | Out-Null
        [Spi]::SystemParametersInfo([Spi]::SPI_SETSCREENSAVEACTIVE, 1, [IntPtr]::Zero, $flags) | Out-Null
        Write-Log "Screensaver ENABLED ($timeoutSeconds s idle timeout)."
    } catch {
        Write-Log "ERROR enabling screensaver: $_"
    }
}
