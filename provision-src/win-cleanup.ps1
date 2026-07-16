# win-cleanup.ps1 — deshace el arranque blindado al desinstalar QZ Tray.
# Corre ELEVADO en la fase "uninstall" del provisioning. Nunca aborta (exit 0).

$ErrorActionPreference = 'SilentlyContinue'

schtasks /Delete /TN "QZ Tray Autostart" /F 2>$null | Out-Null
schtasks /Delete /TN "QZ Tray Watchdog" /F 2>$null | Out-Null

Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'QZ Tray' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name 'QZ Tray' -ErrorAction SilentlyContinue

Write-Host 'Arranque blindado de QZ retirado (tareas + HKLM Run).'
exit 0
