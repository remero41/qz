# win-autostart.ps1 v2 - arranque BLINDADO de QZ Tray en Windows (W8/W10/W11).
#
# Arquitectura: el .lnk nativo de QZ es la via rapida (t=0, respeta la preferencia
# del usuario). TODAS las capas anadidas pasan por el watchdog, que es el UNICO
# punto que lanza QZ incondicionalmente y lleva dedupe integrado (mutex global
# anti-solape + mata instancias duplicadas). Asi no hay carrera de doble
# instancia entre capas (la JVM tarda segundos en enlazar el puerto y el chequeo
# de instancia unica de QZ no protege ese margen).
#
# El watchdog se invoca por -EncodedCommand (base64 UTF-16LE), inmune a la
# ExecutionPolicy de PowerShell: no hay bypass ni fichero .ps1 en disco que
# dependa de la policy de la maquina. Es el mismo mecanismo de la v1 (validada
# en vivo). El UNICO .ps1 por -File es este propio script, que lo ejecuta el
# instalador de QZ (elevado) una sola vez.
#
# Capas (redundantes; basta con que una viva):
#   0) .lnk en Startup comun         - nativo del instalador QZ (t=0).
#   1) Tarea "QZ Tray Autostart"     - ONLOGON +45s -> watchdog. Principal de
#      GRUPO Users (S-1-5-32-545): dispara en la sesion de CUALQUIER usuario
#      interactivo (el schtasks clasico la crearia para la cuenta que elevo UAC).
#   2) Tarea "QZ Tray Watchdog"      - cada 2 min -> watchdog: sonda de salud
#      real (websocket), relanza si murio, mata+relanza si esta zombi, reactiva
#      entradas de arranque deshabilitadas, dedupe de instancias.
#   3) HKLM\...\Run "QZ Tray Watchdog" - +75s -> watchdog. Sobrevive incluso si
#      el servicio de tareas programadas esta roto.
#
# ANTI-BUCLE (aprendido del bucle de reinicio en Linux, commit e04a799):
#   - El watchdog RESPETA la preferencia .autostart de QZ: si el usuario apago
#     "Iniciar automaticamente" desde el icono, el watchdog NO relanza (si lo
#     hiciera, QZ arrancado por el .lnk nativo con --honorautostart se autocierra
#     y el watchdog lo relanzaria en bucle infinito).
#   - El watchdog lanza QZ CON --honorautostart, igual que el .lnk nativo: misma
#     semantica, sin pelearse con la preferencia.
#   - Ventana de arranque de la JVM cubierta por gracia de tiempo (no matar ni
#     relanzar procesos jovenes) para no crear dobles instancias.
#
# Corre ELEVADO en la fase "install" del provisioning. Nunca rompe la
# instalacion (exit 0 siempre).

$ErrorActionPreference = 'SilentlyContinue'

# --- 1) Localizar qz-tray.exe de forma robusta (no adivinar una sola ruta) ---
$candidates = @(
  (Join-Path $env:ProgramFiles 'QZ Tray\qz-tray.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'QZ Tray\qz-tray.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\QZ Tray\qz-tray.exe')
)
$exe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $exe) {
  $regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\QZ Tray',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\QZ Tray'
  )
  foreach ($rp in $regPaths) {
    $loc = (Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue).InstallLocation
    if ($loc -and (Test-Path (Join-Path $loc 'qz-tray.exe'))) { $exe = Join-Path $loc 'qz-tray.exe'; break }
  }
}

if (-not $exe) {
  Write-Host 'qz-tray.exe no encontrado; se omite el arranque blindado (QZ trae su propio autostart).'
  exit 0
}
$dir = Split-Path -Parent $exe
Write-Host "QZ localizado en: $exe"

# --- 2) Cuerpo del watchdog (se ejecutara por -EncodedCommand, sin tocar disco) ---
# Punto unico de arranque. Para PARAR QZ de verdad: apagar "Iniciar
# automaticamente" desde el icono de QZ (o deshabilitar la tarea "QZ Tray Watchdog").
$watchdog = @'
$ErrorActionPreference = 'SilentlyContinue'

# Mutex global: si otro watchdog esta en marcha, salir (anti-solape entre capas)
$mutex = New-Object System.Threading.Mutex($false, 'Global\QZTrayWatchdog')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {

$log = Join-Path $env:LOCALAPPDATA 'qz-watchdog.log'
function Log($msg) {
  if ((Test-Path $log) -and ((Get-Item $log).Length -gt 262144)) { Remove-Item $log -Force }
  Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
}

$candidates = @(
  (Join-Path $env:ProgramFiles 'QZ Tray\qz-tray.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'QZ Tray\qz-tray.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\QZ Tray\qz-tray.exe')
)
$exe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $exe) { Log 'qz-tray.exe no encontrado; nada que vigilar'; return }

# --- Preferencia .autostart de QZ (misma logica que FileUtilities.readAutoStartFile):
#     el fichero de usuario manda; si no, el compartido; si ninguno existe, "1".
#     "0" = el usuario apago el arranque -> NO relanzar (o entrariamos en bucle:
#     QZ lanzado con --honorautostart se autocierra y lo relanzariamos sin fin).
function Test-QzAutostartWanted {
  $userFile   = Join-Path $env:APPDATA     'qz\.autostart'
  $sharedFile = Join-Path $env:PROGRAMDATA 'qz\.autostart'
  $file = $null
  if (Test-Path $userFile)        { $file = $userFile }
  elseif (Test-Path $sharedFile)  { $file = $sharedFile }
  if (-not $file) { return $true }                    # sin fichero => QZ arranca
  $val = (Get-Content -Path $file -TotalCount 1 -ErrorAction SilentlyContinue)
  if ($null -eq $val) { return $true }
  return ($val.Trim() -ne '0')
}

# Autocuracion: reactivar entradas de arranque deshabilitadas desde Task Manager,
# PERO solo si el usuario NO ha apagado el autostart de QZ (respeta su intencion).
if (Test-QzAutostartWanted) {
  $sa = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
  foreach ($pair in @(@("$sa\StartupFolder",'QZ Tray.lnk'), @("$sa\Run",'QZ Tray Watchdog'))) {
    $key = $pair[0]; $name = $pair[1]
    $val = (Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue).$name
    if ($val -and $val.Length -ge 1 -and $val[0] -ne 2) {
      Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue
      Log "reactivada entrada de arranque deshabilitada: $name"
    }
  }
}

# Sonda de salud: escucha el websocket de QZ en algun puerto conocido?
function Test-QzAlive {
  foreach ($port in 8181,8282,8383,8484,8182,8283,8384,8485) {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
      $async = $tcp.BeginConnect('127.0.0.1', $port, $null, $null)
      if ($async.AsyncWaitHandle.WaitOne(800) -and $tcp.Connected) { return $true }
    } catch {} finally { $tcp.Close() }
  }
  return $false
}

# Lanza QZ con --honorautostart (misma semantica que el .lnk nativo): si el
# usuario apago el autostart, el propio QZ se autocierra sin abrir puerto y ya
# no lo tocamos (Test-QzAutostartWanted nos habra frenado antes de llegar aqui).
function Start-Qz {
  Start-Process -FilePath $exe -ArgumentList '--honorautostart' -WorkingDirectory (Split-Path -Parent $exe)
}

$procs = @(Get-Process qz-tray -ErrorAction SilentlyContinue)

# GATE ANTI-BUCLE: si el usuario apago el autostart, NO arrancamos NADA.
# Dejamos vivir lo que ya haya (por si lo abrio a mano) pero nunca relanzamos.
if (-not (Test-QzAutostartWanted)) {
  Log 'autostart de QZ desactivado por el usuario; el watchdog no relanza'
  return
}

# Caso A: no corre -> arrancar (una sola vez; el mutex evita solape de watchdogs)
if ($procs.Count -eq 0) {
  Start-Qz
  Log 'QZ no corria; relanzado (--honorautostart)'
  return
}

# Caso B: duplicados REALES y ESTABLES. Solo podamos si hay >1 proceso y TODOS
# llevan vivos > 90s (pasada la ventana de arranque de la JVM); si alguno es
# joven, es el arranque normal en curso y NO tocamos nada (evita matar la buena).
if ($procs.Count -gt 1) {
  $now = Get-Date
  $young = @($procs | Where-Object { $_.StartTime -and ($now - $_.StartTime).TotalSeconds -lt 90 })
  if ($young.Count -eq 0) {
    $extra = $procs | Sort-Object StartTime | Select-Object -Skip 1
    $extra | Stop-Process -Force
    Log ("instancias duplicadas estables eliminadas: {0}" -f $extra.Count)
    $procs = @($procs | Sort-Object StartTime | Select-Object -First 1)
  } else {
    # Arranque en curso: el SingleInstanceChecker de QZ se autoresuelve. No tocar.
    return
  }
}

if (Test-QzAlive) { return }   # sano: silencio total

# Caso C: proceso vivo pero sin websocket. Puede ser JVM fria (arranque) o zombi.
# Damos 4 min de gracia desde el arranque del MAS RECIENTE antes de actuar.
$newest = ($procs | Sort-Object StartTime -Descending | Select-Object -First 1).StartTime
if ($newest -and ((Get-Date) - $newest).TotalMinutes -lt 4) { return }

# Zombi confirmado: matar TODO qz-tray, esperar a que muera de verdad, y relanzar
# UNA vez. Esperar evita el solape (proceso agonizando + nuevo = doble instancia).
$procs | Stop-Process -Force
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Process qz-tray -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
}
Start-Qz
Log 'QZ zombi (proceso vivo, websocket muerto); reiniciado'
return

} finally { $mutex.ReleaseMutex() }
'@

# Codificar el watchdog para -EncodedCommand (UTF-16LE -> base64), inmune a ExecutionPolicy
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchdog))
$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wdArgs = "-NoProfile -WindowStyle Hidden -EncodedCommand $b64"

# --- 3) Capa 3: HKLM Run -> watchdog con retardo (sobrevive a un Task Scheduler roto) ---
$runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runCmd = "`"$ps`" -NoProfile -WindowStyle Hidden -EncodedCommand $b64"
New-ItemProperty -Path $runKey -Name 'QZ Tray Watchdog' -Value $runCmd -PropertyType String -Force | Out-Null
# Retirar entrada HKLM Run directa de versiones previas (evita doble lanzamiento)
Remove-ItemProperty -Path $runKey -Name 'QZ Tray' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name 'QZ Tray Watchdog' -ErrorAction SilentlyContinue
Write-Host 'Capa HKLM Run (watchdog EncodedCommand) instalada.'

# --- 4) Capas 1 y 2: tareas programadas via XML con principal de GRUPO Users ---
# XML (no schtasks clasico) porque permite GroupId S-1-5-32-545: la tarea corre en
# la sesion de CUALQUIER usuario interactivo, no solo del usuario que instalo.
# XML-escapar los & que aparecen en el argumento base64/comandos.
$xmlArgs = $wdArgs -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
$xmlExe  = $ps     -replace '&','&amp;'
$xmlDir  = $dir    -replace '&','&amp;'
$ns = 'http://schemas.microsoft.com/windows/2004/02/mit/task'

$xmlAutostart = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="$ns">
  <RegistrationInfo>
    <Description>Arranca QZ Tray al iniciar sesion cualquier usuario, via watchdog con dedupe</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>PT45S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$xmlExe</Command>
      <Arguments>$xmlArgs</Arguments>
      <WorkingDirectory>$xmlDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$xmlWatchdog = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="$ns">
  <RegistrationInfo>
    <Description>Vigila QZ Tray cada 2 min: relanza si murio, reinicia si esta zombi</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT2M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2020-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$xmlExe</Command>
      <Arguments>$xmlArgs</Arguments>
      <WorkingDirectory>$xmlDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$tmpDir = Join-Path $env:TEMP 'qz-provision'
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$xmlOk = $true
foreach ($task in @(@('QZ Tray Autostart', $xmlAutostart), @('QZ Tray Watchdog', $xmlWatchdog))) {
  $name = $task[0]; $xml = $task[1]
  $xmlFile = Join-Path $tmpDir (($name -replace ' ', '-') + '.xml')
  Set-Content -Path $xmlFile -Value $xml -Encoding Unicode
  schtasks /Create /TN "$name" /XML "$xmlFile" /F 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    $xmlOk = $false
    Write-Host "Registro XML de '$name' fallo (codigo $LASTEXITCODE); se usara el metodo clasico."
  } else {
    Write-Host "Tarea '$name' registrada (principal grupo Users)."
  }
}

# --- 5) Fallback clasico si el registro XML fallo (Windows muy viejos/capados) ---
if (-not $xmlOk) {
  schtasks /Create /TN "QZ Tray Autostart" /SC ONLOGON /F /TR "`"$ps`" $wdArgs" 2>$null | Out-Null
  schtasks /Create /TN "QZ Tray Watchdog" /SC MINUTE /MO 2 /F /TR "`"$ps`" $wdArgs" 2>$null | Out-Null
  Write-Host 'Tareas registradas por el metodo clasico (usuario instalador).'
}

# --- 6) Primer disparo inmediato: que QZ quede vivo ya, sin esperar re-login ---
schtasks /Run /TN "QZ Tray Watchdog" 2>$null | Out-Null

Write-Host 'Arranque blindado v2 de QZ configurado (lnk nativo + tarea logon + watchdog salud + HKLM Run diferido).'
exit 0
