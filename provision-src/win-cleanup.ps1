# win-cleanup.ps1 — deshace el arranque blindado al desinstalar QZ Tray.
# Corre ELEVADO en la fase "uninstall" del provisioning. Nunca aborta (exit 0).

$ErrorActionPreference = 'SilentlyContinue'

schtasks /Delete /TN "QZ Tray Autostart" /F 2>$null | Out-Null
schtasks /Delete /TN "QZ Tray Watchdog" /F 2>$null | Out-Null

# El instalador (win-autostart.ps1) crea el valor 'QZ Tray Watchdog'; 'QZ Tray'
# es solo un residuo de la v1 que aquel mismo script elimina. Borrar unicamente
# 'QZ Tray' dejaba VIVA la entrada del watchdog tras desinstalar QZ: en cada
# arranque de Windows se lanzaba un PowerShell a vigilar un programa que ya no
# existe. Se borran AMBOS nombres, en Run y en StartupApproved.
foreach ($name in @('QZ Tray Watchdog', 'QZ Tray')) {
  Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name $name -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name $name -ErrorAction SilentlyContinue
}

# El techo de heap se puso como variable de MAQUINA; sin QZ instalado no pinta
# nada (y podria confundir a otra herramienta que leyera QZ_OPTS).
[Environment]::SetEnvironmentVariable('QZ_OPTS', $null, 'Machine')

# Estado del freno anti-bucle del watchdog (por usuario; se limpia el del que
# ejecuta la desinstalacion, el resto caduca solo al no existir ya el watchdog).
Remove-Item (Join-Path $env:LOCALAPPDATA 'qz-watchdog-state.txt') -Force -ErrorAction SilentlyContinue

Write-Host 'Arranque blindado de QZ retirado (tareas + HKLM Run + QZ_OPTS).'
exit 0
