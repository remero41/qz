# win-winusb.ps1 — asigna el driver WinUSB (winusb.sys) a las impresoras USB para
# permitir la impresión USB directa (qz.usb.*). NO usa binarios externos: genera un
# INF WinUSB al vuelo por cada impresora detectada y lo instala con pnputil (nativo
# de Windows). Para parque heterogéneo: recorre los dispositivos presentes.
#
# Referencia: WinUSB Installation (Microsoft Learn) — INF universal con
# Include=winusb.inf / Needs=WINUSB.NT + DeviceInterfaceGUIDs.

$ErrorActionPreference = 'SilentlyContinue'
$work = Join-Path $env:TEMP 'qz-winusb'
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Enumera dispositivos USB presentes que parezcan impresora (clase 07 o "print" en el nombre).
$devs = Get-PnpDevice -PresentOnly | Where-Object {
  $_.InstanceId -match 'USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})'
}

$applied = 0
foreach ($d in $devs) {
  if ($d.InstanceId -notmatch 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { continue }
  $vid = $matches[1].ToUpper(); $pid = $matches[2].ToUpper()

  # Filtro impresora: clase USB 07 o nombre con "print"/"pos"/"ticket". Evita ratones/teclados.
  $class = ($d.Class + '')
  $name  = ($d.FriendlyName + '')
  $looksPrinter = ($class -eq 'Printer') -or ($class -eq 'USB') -or ($name -match '(?i)print|pos|ticket|receipt')
  if (-not $looksPrinter) { continue }

  # GUID de interfaz estable por VID/PID (determinista, no aleatorio → mismo parque = mismo GUID).
  $seed = "$vid$pid".PadRight(32,'0').Substring(0,32)
  $guid = '{' + $seed.Substring(0,8) + '-' + $seed.Substring(8,4) + '-' + $seed.Substring(12,4) + '-' + $seed.Substring(16,4) + '-' + $seed.Substring(20,12) + '}'

  $inf = @"
;
; INF WinUSB generado por QZ para impresora USB VID_$vid PID_$pid
;
[Version]
Signature   = "`$Windows NT`$"
Class       = USBDevice
ClassGUID   = {88BAE032-5A81-49f0-BC3D-A4FF138216D6}
Provider    = %ManufacturerName%
DriverVer   = 01/01/2024,1.0.0.0
PnpLockdown = 1

[Manufacturer]
%ManufacturerName% = Standard,NTamd64,NTarm64

[Standard.NTamd64]
%DeviceName% = USB_Install, USB\VID_$vid&PID_$pid

[Standard.NTarm64]
%DeviceName% = USB_Install, USB\VID_$vid&PID_$pid

[USB_Install]
Include = winusb.inf
Needs   = WINUSB.NT

[USB_Install.Services]
Include = winusb.inf
Needs   = WINUSB.NT.Services

[USB_Install.HW]
AddReg = Dev_AddReg

[Dev_AddReg]
HKR,,DeviceInterfaceGUIDs,0x10000,"$guid"

[Strings]
ManufacturerName = "POS Printer"
DeviceName       = "Impresora USB $vid:$pid (WinUSB)"
"@

  $infPath = Join-Path $work "winusb_${vid}_${pid}.inf"
  Set-Content -Path $infPath -Value $inf -Encoding ASCII
  Write-Host "Instalando WinUSB para VID_$vid PID_$pid ($name)"
  # /add-driver instala el paquete; /install lo aplica a los dispositivos que casen.
  & pnputil.exe /add-driver "$infPath" /install 2>&1 | Out-Null
  $applied++
}

if ($applied -eq 0) {
  Write-Host "No se detecto ninguna impresora USB presente; WinUSB se aplicara al conectar (repetir tras enchufar)."
} else {
  Write-Host "WinUSB aplicado a $applied dispositivo(s)."
}
exit 0
