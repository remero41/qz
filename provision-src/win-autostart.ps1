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
#      el servicio de tareas programadas esta roto. El +75s es un Start-Sleep
#      antepuesto al cuerpo codificado: antes solo estaba en ESTE comentario y
#      la capa disparaba en t=0, a la vez que el .lnk nativo.
#
# TECHO DE HEAP (paridad con la unidad systemd de Linux): se fija QZ_OPTS como
# variable de MAQUINA. El lanzador de Windows NO es launch4j: es NSIS y lee esa
# variable (launch.overrides), concatenandola DESPUES de launch.opts. Ver el
# bloque 1b.
#
# FRENO ANTI-BUCLE DEL CASO C: el relanzado por zombi lleva backoff exponencial
# y se rinde a los 5 intentos, con el contador PERSISTIDO en disco (cada pasada
# del watchdog es un proceso nuevo). Sin el, un websocket que nunca abre producia
# mata-relanza cada ~4 min indefinidamente.
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

# --- 1b) Techo de heap de la JVM (paridad con la unidad systemd de Linux) ----
# Sin -Xmx la JVM se autoasigna 1/4 de la RAM (4 GB en un equipo de 16 GB): el
# RSS engorda, Windows lo pagina estando la app parada, y la PRIMERA impresion
# tras un rato inactivo va lenta porque hay que traer paginas de disco. Medido
# en Linux (kaz): swap 1,28 GB -> 0, maj_flt 188.492 -> 464.
#
# MECANISMO EN WINDOWS: qz-tray.exe NO es launch4j (creencia previa erronea).
# Es un lanzador NSIS generado por ant/windows/windows-launcher.nsi.in, que hace:
#     StrCpy $opts "${launch.opts}"                 ; = "-Xms512m -Djna.nosys=true"
#     ReadEnvStr $R0 ${launch.overrides}            ; launch.overrides = QZ_OPTS
#     StrCpy $opts "$opts $R0"                      ; se anade AL FINAL
# Es decir: lee QZ_OPTS del entorno y lo concatena DESPUES de launch.opts, asi
# que nuestros flags GANAN. Mecanismo identico al de Linux (unix-launcher.sh.in),
# solo cambia donde se define la variable.
#
# Se escribe como variable de entorno de MAQUINA (HKLM Environment) y no de
# usuario: el TPV es multiusuario en mostrador y la tarea corre para el grupo
# Users. Sobrevive a reinstalaciones de QZ (no vive dentro de su carpeta).
#
# NO se usa _JAVA_OPTIONS / JAVA_TOOL_OPTIONS: afectarian a TODA JVM del equipo.
$qzOpts = '-Xmx512m -XX:+UseSerialGC -XX:MaxMetaspaceSize=128m'
[Environment]::SetEnvironmentVariable('QZ_OPTS', $qzOpts, 'Machine')
# Y en el proceso actual, para que el primer disparo del watchdog (paso 6) ya
# arranque QZ con el techo puesto sin esperar a un reinicio: las variables de
# maquina solo llegan a procesos NUEVOS lanzados tras la difusion del cambio.
$env:QZ_OPTS = $qzOpts
Write-Host "Techo de heap fijado: QZ_OPTS=$qzOpts (variable de maquina)"

# --- 2) Cuerpo del watchdog (se ejecutara por -EncodedCommand, sin tocar disco) ---
# Punto unico de arranque. Para PARAR QZ de verdad: apagar "Iniciar
# automaticamente" desde el icono de QZ (o deshabilitar la tarea "QZ Tray Watchdog").
$watchdog = @'
$ErrorActionPreference = 'SilentlyContinue'

# Mutex global: si otro watchdog esta en marcha, salir (anti-solape entre capas).
#
# El WaitOne va en try/catch por AbandonedMutexException: si una pasada anterior
# murio sin liberar el mutex (proceso matado, ExecutionTimeLimit del Task
# Scheduler, apagon), .NET lo entrega ABANDONADO lanzando esa excepcion. Sin
# tratarla, la excepcion tumba la pasada ANTES de entrar al try/finally y el
# watchdog queda mudo pasada tras pasada: QZ podria estar caido y nadie lo
# relanzaria (el fallo mas grave posible, porque es SILENCIOSO).
# Mutex abandonado = el anterior ya no existe => nos lo quedamos y seguimos.
$mutex = New-Object System.Threading.Mutex($false, 'Global\QZTrayWatchdog')
$owned = $false
try   { $owned = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }
catch { $owned = $false }
if (-not $owned) { exit 0 }
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

# --- Puertos a sondear -------------------------------------------------------
# Los 8 por defecto (Constants.DEFAULT_WSS_PORTS = 8181,8282,8383,8484 seguros +
# los inseguros +1) son SOLO el default: WebsocketPorts.java lee las prefs
# websocket.secure.ports / websocket.insecure.ports, asi que un equipo con otra
# configuracion tendria a QZ escuchando fuera de la lista fija. Con la lista fija
# la sonda daria FALSO NEGATIVO: se declara zombi un QZ perfectamente sano y se
# lo mata cada pocos minutos. Se leen las prefs y se anaden a los defaults.
function Get-QzPorts {
  $ports = [System.Collections.Generic.List[int]]::new()
  foreach ($p in 8181,8282,8383,8484,8182,8283,8384,8485) { [void]$ports.Add($p) }
  $prefFiles = @(
    (Join-Path $env:APPDATA     'qz\prefs.properties'),
    (Join-Path $env:PROGRAMDATA 'qz\prefs.properties'),
    (Join-Path (Split-Path -Parent $exe) 'qz-tray.properties')
  )
  foreach ($f in $prefFiles) {
    if (-not (Test-Path $f)) { continue }
    foreach ($line in (Get-Content -Path $f -ErrorAction SilentlyContinue)) {
      if ($line -match '^\s*websocket\.(secure|insecure)\.ports\s*=\s*(.+)$') {
        foreach ($tok in ($matches[2] -split '[,;\s]+')) {
          $n = 0
          if ([int]::TryParse($tok.Trim(), [ref]$n) -and $n -gt 0 -and $n -lt 65536) {
            if (-not $ports.Contains($n)) { [void]$ports.Add($n) }
          }
        }
      }
    }
  }
  return $ports
}

# Sonda de salud: escucha el websocket de QZ en algun puerto conocido?
#
# NO basta con que el puerto acepte conexion: cualquier OTRO programa que ocupe
# el 8181 haria que un QZ MUERTO se declarase vivo (falso POSITIVO), nadie lo
# relanzaria y el TPV no imprimiria — y ademas en silencio. Se exige que el
# proceso DUENO del puerto sea uno de los qz-tray que estamos vigilando.
# Get-NetTCPConnection no abre sockets: no hay espera de 800 ms por puerto, asi
# que la pasada tampoco puede tardar 6,4 s como la sonda anterior.
function Test-QzAlive {
  param([int[]]$QzPids)

  $ports = Get-QzPorts

  # Camino bueno: mirar quien tiene el puerto en LISTEN (Windows 8+/2012+).
  $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                 Where-Object { $ports -contains $_.LocalPort })
  if ($listeners.Count -gt 0) {
    foreach ($l in $listeners) {
      if ($QzPids -contains [int]$l.OwningProcess) { return $true }
    }
    # Los puertos estan tomados pero por OTRO proceso: QZ no esta escuchando.
    return $false
  }

  # Fallback (Get-NetTCPConnection ausente o sin permisos): netstat -ano, que da
  # igualmente el PID dueno. Solo si el camino bueno no devolvio NADA.
  $netstat = @(netstat -ano 2>$null | Select-String 'LISTENING')
  if ($netstat.Count -gt 0) {
    foreach ($row in $netstat) {
      $f = ($row.ToString() -split '\s+') | Where-Object { $_ }
      if ($f.Count -lt 5) { continue }
      $localPort = 0
      $portTok = ($f[1] -split ':')[-1]
      if (-not [int]::TryParse($portTok, [ref]$localPort)) { continue }
      if (-not ($ports -contains $localPort)) { continue }
      $owner = 0
      if ([int]::TryParse($f[-1], [ref]$owner) -and ($QzPids -contains $owner)) { return $true }
    }
    return $false
  }

  # Ultimo recurso: sin forma de saber el dueno, sonda TCP a secas (el
  # comportamiento antiguo). Peor, pero mejor que declarar zombi sin motivo.
  foreach ($port in $ports) {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
      $async = $tcp.BeginConnect('127.0.0.1', $port, $null, $null)
      if ($async.AsyncWaitHandle.WaitOne(300) -and $tcp.Connected) { return $true }
    } catch {} finally { $tcp.Close() }
  }
  return $false
}

# Lanza QZ con --honorautostart (misma semantica que el .lnk nativo): si el
# usuario apago el autostart, el propio QZ se autocierra sin abrir puerto y ya
# no lo tocamos (Test-QzAutostartWanted nos habra frenado antes de llegar aqui).
# -WindowStyle Hidden explicito: en un mostrador, una ventana que aparece y
# desaparece cada pocos minutos es lo que mas molesta al usuario. qz-tray.exe es
# GUI, pero el lanzador NSIS puede materializar consola segun variante y no
# cuesta nada dejarlo dicho.
function Start-Qz {
  Start-Process -FilePath $exe -ArgumentList '--honorautostart' `
                -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden
}

# --- Freno del relanzado (estado PERSISTENTE en disco) -----------------------
# Cada pasada del watchdog es un proceso PowerShell NUEVO: un contador en
# variable no frena nada. El estado vive en un fichero junto al log.
#
# BUG QUE ARREGLA: el caso C (proceso vivo, websocket muerto) mataba y relanzaba
# sin contador ni tope. Si el websocket NUNCA llega a abrir —puerto ocupado por
# otra aplicacion, firewall, QZ escuchando fuera de los puertos sondeados, JVM
# que revienta al arrancar— el relanzado RESETEA el StartTime, asi que 4 minutos
# despues se vuelve a cumplir la condicion: mata-relanza CADA ~4-6 MINUTOS,
# INDEFINIDAMENTE. Ese es justo el ciclo abrir-cerrar que el script decia evitar.
#
# Politica: backoff exponencial (4, 8, 16, 32... min, tope 60) y RENDICION tras
# 5 intentos fallidos seguidos. Rendirse es lo correcto: si 5 reinicios no han
# abierto el websocket, el problema no lo arregla un sexto, y un QZ vivo aunque
# sin websocket molesta menos que un mata-relanza perpetuo. Cualquier pasada que
# vea a QZ sano borra el estado, asi que el freno se rearma solo (autocuracion).
# Espeja StartLimitBurst=5 de la unidad systemd de Linux.
$stateFile = Join-Path $env:LOCALAPPDATA 'qz-watchdog-state.txt'

function Get-RestartState {
  # Devuelve @{ Count = n; Last = [datetime] }; ceros si no hay estado.
  $st = @{ Count = 0; Last = [datetime]::MinValue }
  if (Test-Path $stateFile) {
    $raw = (Get-Content -Path $stateFile -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($raw -and ($raw -match '^\s*(\d+)\s*\|\s*(.+?)\s*$')) {
      $st.Count = [int]$matches[1]
      $parsed = [datetime]::MinValue
      if ([datetime]::TryParse($matches[2], [ref]$parsed)) { $st.Last = $parsed }
    }
  }
  return $st
}

function Set-RestartState($count) {
  Set-Content -Path $stateFile -Value ("{0}|{1}" -f $count, (Get-Date).ToString('o')) -ErrorAction SilentlyContinue
}

function Clear-RestartState {
  if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
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

# Sano: silencio total. Y ademas se REARMA el freno: cualquier pasada que vea a
# QZ funcionando borra el contador de reintentos (autocuracion).
if (Test-QzAlive -QzPids @($procs | ForEach-Object { $_.Id })) {
  Clear-RestartState
  return
}

# Caso C: proceso vivo pero sin websocket. Puede ser JVM fria (arranque) o zombi.
# Damos 4 min de gracia desde el arranque del MAS RECIENTE antes de actuar.
$newest = ($procs | Sort-Object StartTime -Descending | Select-Object -First 1).StartTime
if ($newest -and ((Get-Date) - $newest).TotalMinutes -lt 4) { return }

# FRENO ANTI-BUCLE: backoff exponencial + rendicion a los 5 intentos.
$state = Get-RestartState
if ($state.Count -ge 5) {
  # Rendido. Se registra UNA sola vez cada hora para no engordar el log con 720
  # lineas al dia repitiendo lo mismo.
  if (((Get-Date) - $state.Last).TotalMinutes -ge 60) {
    Log 'RENDIDO: 5 reintentos sin que el websocket abra. No se relanza mas (revisar puerto ocupado/firewall/prefs). Se rearmara solo en cuanto QZ vuelva a responder.'
    Set-RestartState 5
  }
  return
}
# Backoff: 4, 8, 16, 32, 60 min desde el ultimo intento.
$waitMin = [Math]::Min(60, 4 * [Math]::Pow(2, $state.Count))
if ($state.Count -gt 0 -and ((Get-Date) - $state.Last).TotalMinutes -lt $waitMin) { return }

# Zombi confirmado: matar TODO qz-tray, esperar a que muera de verdad, y relanzar
# UNA vez. Esperar evita el solape (proceso agonizando + nuevo = doble instancia).
$procs | Stop-Process -Force
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Process qz-tray -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
}
Start-Qz
Set-RestartState ($state.Count + 1)
Log ("QZ zombi (proceso vivo, websocket muerto); reiniciado (intento {0}/5)" -f ($state.Count + 1))
return

} finally { $mutex.ReleaseMutex() }
'@

# Codificar el watchdog para -EncodedCommand (UTF-16LE -> base64), inmune a ExecutionPolicy
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchdog))
$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wdArgs = "-NoProfile -WindowStyle Hidden -EncodedCommand $b64"

# --- 3) Capa 3: HKLM Run -> watchdog con retardo (sobrevive a un Task Scheduler roto) ---
#
# EL RETARDO ES REAL, NO SOLO DOCUMENTAL. La cabecera de este script describia
# esta capa como "+75s" y la capa 1 como "+45s" para escalonar el arranque, pero
# el valor de Run se registraba SIN espera alguna: se disparaba en t=0, a la vez
# que el .lnk nativo de QZ. Dos lanzamientos simultaneos son justo la carrera de
# doble instancia que el escalonamiento pretendia evitar (la JVM tarda segundos
# en enlazar el puerto, y el SingleInstanceChecker de QZ no cubre ese margen).
# Se antepone un Start-Sleep de 75 s al cuerpo del watchdog para ESTA capa; asi
# el orden real queda .lnk (t=0) -> tarea ONLOGON (+45 s) -> HKLM Run (+75 s), y
# cuando llega esta ultima el caso B ya tiene con que decidir.
$runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$b64Run = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Start-Sleep -Seconds 75`r`n$watchdog"))
$runCmd = "`"$ps`" -NoProfile -WindowStyle Hidden -EncodedCommand $b64Run"
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
