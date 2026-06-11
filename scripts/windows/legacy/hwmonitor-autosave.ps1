# HWMonitor Auto-Save Script
# Saves sensor data to C:\HWMonitor.txt using F5 key
# Register with Task Scheduler to run every 5 minutes
#
# Setup:
#   1. Update $HWMonitorExe path if needed
#   2. Test: powershell.exe -ExecutionPolicy Bypass -File C:\hwmonitor-save.ps1
#   3. Register: See README.md for Task Scheduler setup

param(
    [string]$HWMonitorExe = "C:\Software\hwmonitor\HWMonitor_x64.exe",
    [string]$LogPath      = "C:\HWMonitor.txt"
)

# Start HWMonitor if not running
$proc = Get-Process "HWMonitor_x64" -ErrorAction SilentlyContinue
if (-not $proc) {
    if (-not (Test-Path $HWMonitorExe)) {
        Write-Error "HWMonitor not found: $HWMonitorExe"
        exit 1
    }
    Start-Process $HWMonitorExe
    Start-Sleep -Seconds 8
    $proc = Get-Process "HWMonitor_x64" -ErrorAction SilentlyContinue
}

if (-not $proc) {
    Write-Error "Failed to start HWMonitor"
    exit 1
}

# Send F5 to start logging, wait, send F5 to stop
$shell = New-Object -ComObject WScript.Shell
$shell.AppActivate($proc.Id) | Out-Null
Start-Sleep -Milliseconds 500
$shell.SendKeys("{F5}")     # Start logging
Start-Sleep -Seconds 3
$shell.SendKeys("{F5}")     # Stop logging
Start-Sleep -Seconds 2

# Close Notepad that HWMonitor opens automatically
Get-Process "notepad" -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowTitle -match "HWMonitor" } |
  Stop-Process -Force

Write-Host "Saved: $LogPath ($(Get-Date -Format 'HH:mm:ss'))"
