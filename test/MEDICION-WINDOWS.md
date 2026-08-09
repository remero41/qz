# Guion de medición en Windows real — QZ Tray: arranque, estabilidad y heap

Para recorrer **del tirón en una sesión corta** con un Windows delante. Cada bloque
trae el comando copiable, el **valor esperado** y hueco para anotar el **real**.

> Nada de este documento está medido todavía. Todo lo de aquí está marcado como
> **solo verificable en Windows**. Verde en `test/test-win-autostart-static.sh` NO
> significa validado en máquina.

**Requisito previo:** el equipo debe tener instalado un `qz.exe` que incluya este
provisioning (ver "Plan de despliegue" en el informe: hay que disparar el workflow
`build-win` y reinstalar QZ; editar `provision-src/` NO cambia el binario instalado).

---

## Presupuesto de estabilidad — qué números definen "sano"

| Métrica | Sano | Sospechoso | Roto |
|---|---|---|---|
| Relanzamientos de QZ / hora en régimen normal | **0** | 1 | ≥2 |
| Ventanas visibles del watchdog | **0** | — | ≥1 |
| Icono de bandeja de QZ | **presente** | — | ausente |
| RSS de `qz-tray` en reposo | **< 400 MB** | 400–600 MB | > 700 MB |
| CPU media del watchdog por pasada | **< 1 s de CPU** | 1–3 s | > 3 s |
| Duración de una pasada del watchdog | **< 2 s** | 2–5 s | > 5 s |
| Procesos `powershell.exe` acumulados | **0–1** | 2 | ≥3 |
| Tamaño de `qz-watchdog.log` | **< 256 KB** (rota solo) | — | crece sin tope |

---

## 0) Preparación (una vez)

```powershell
$log   = "$env:LOCALAPPDATA\qz-watchdog.log"
$state = "$env:LOCALAPPDATA\qz-watchdog-state.txt"
Get-Item $log, $state -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime
```

Anotar estado inicial: ______________________

---

## 1) Techo de heap — ¿llegó `QZ_OPTS` a la JVM?

**Esperado:** la variable existe a nivel de máquina y la línea de comandos de la
JVM lleva los tres flags.

```powershell
# 1a) La variable de máquina
[Environment]::GetEnvironmentVariable('QZ_OPTS','Machine')
```
Esperado: `-Xmx512m -XX:+UseSerialGC -XX:MaxMetaspaceSize=128m`
Real: ______________________

```powershell
# 1b) ¿La JVM realmente arrancó con esos flags? (la prueba que de verdad cuenta)
Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" |
  Where-Object { $_.CommandLine -match 'qz-tray' } |
  Select-Object ProcessId, CommandLine | Format-List
```
Esperado: la `CommandLine` contiene `-Xmx512m`, `-XX:+UseSerialGC` y
`-XX:MaxMetaspaceSize=128m` **después** de `-Xms512m`.
Real: ______________________

> Si 1a sale bien pero 1b no lleva los flags: QZ se lanzó **antes** de que la
> variable de máquina se difundiera. Cerrar QZ y relanzarlo, o reiniciar.

```powershell
# 1c) Consumo real de memoria
Get-Process qz-tray, javaw -ErrorAction SilentlyContinue |
  Select-Object Name, Id, @{n='RSS_MB';e={[math]::Round($_.WorkingSet64/1MB,1)}},
                @{n='Commit_MB';e={[math]::Round($_.PagefileUsage/1MB,1)}}
```
Esperado: RSS < 400 MB (antes del fix la JVM se autoasignaba ~1/4 de la RAM).
Real: ______________________

---

## 2) Arranque garantizado — las cuatro capas

```powershell
# 2a) Las dos tareas existen, habilitadas, con principal de grupo Users
Get-ScheduledTask -TaskName 'QZ Tray *' | Select-Object TaskName, State
Get-ScheduledTask -TaskName 'QZ Tray *' | ForEach-Object { $_.Principal }
```
Esperado: `QZ Tray Autostart` y `QZ Tray Watchdog` en `Ready`; `GroupId = S-1-5-32-545`.
Real: ______________________

```powershell
# 2b) La entrada HKLM Run existe y lleva el retardo de 75 s
$v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run').'QZ Tray Watchdog'
$v.Substring(0,80)
# Decodificar el base64 y comprobar que empieza por el Start-Sleep
$b64 = ($v -split '-EncodedCommand ')[1]
[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64)).Split("`n")[0]
```
Esperado: primera línea `Start-Sleep -Seconds 75`
Real: ______________________

```powershell
# 2c) Historial: ¿la tarea del watchdog corre de verdad cada 2 min?
Get-ScheduledTaskInfo -TaskName 'QZ Tray Watchdog' |
  Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns
```
Esperado: `LastTaskResult = 0`, `NumberOfMissedRuns = 0`, `NextRunTime` ≈ ahora+2 min.
Real: ______________________

### 2d) Reinicio en frío (**apagar del todo, no "reiniciar"**)

Fast Startup hace que "Apagar" sea en realidad una hibernación: para probar el
arranque en frío de verdad, `shutdown /s /full /t 0` o desactivar Fast Startup.

```powershell
shutdown /s /full /t 0
```
Al volver, **sin abrir nada a mano**, esperar 2 minutos y:
```powershell
Get-Process qz-tray | Select-Object Id, StartTime
```
Esperado: 1 proceso, `StartTime` ≈ momento del arranque.
Real: ______________________
¿Icono de bandeja visible? SÍ / NO: ______________________

### 2e) Multiusuario (**solo si el equipo tiene 2 cuentas**)

Iniciar sesión con un **segundo** usuario (cambio rápido de usuario) y repetir 2d.
Esperado: QZ arranca también para ese usuario, y sigue habiendo **1 solo** proceso.
Real: ______________________

> Este punto es el que más dudas tiene en frío: la tarea usa `GroupId Users`, que
> *debería* disparar para cualquier usuario interactivo, pero **no está verificado**.
> Si aquí salen 2 procesos, el caso B del watchdog debería podar el sobrante a los
> 90 s — comprobarlo antes de tocar nada.

### 2f) Usuario que desactiva el arranque desde el Administrador de tareas

Administrador de tareas → Inicio → deshabilitar "QZ Tray". Esperar 2 min.
```powershell
$sa='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
Get-ItemProperty "$sa\StartupFolder" -ErrorAction SilentlyContinue
Get-Content "$env:LOCALAPPDATA\qz-watchdog.log" -Tail 5
```
Esperado: el watchdog registra `reactivada entrada de arranque deshabilitada` y la
entrada desaparece del registro.
Real: ______________________

---

## 3) Estabilidad — el ciclo abrir-cerrar

### 3a) Régimen normal: relanzamientos por hora (**la métrica clave**)

Dejar el equipo con QZ funcionando **1 hora sin tocarlo**, luego:

```powershell
Get-Content "$env:LOCALAPPDATA\qz-watchdog.log" -Tail 100 |
  Select-String 'relanzado|reiniciado|eliminadas|RENDIDO'
```
Esperado: **ninguna línea** en una hora de régimen normal.
Real: ______________________

```powershell
# El PID no debe haber cambiado en toda la hora
Get-Process qz-tray | Select-Object Id, StartTime
```
Esperado: mismo `Id` que al empezar; `StartTime` de hace ≥ 1 h.
Real: ______________________

### 3b) Provocar el caso peor: websocket que NUNCA abre

Es el escenario del bug: antes producía mata-relanza cada ~4 min **para siempre**.

```powershell
# Ocupar los puertos de QZ con otro proceso y matar QZ
Stop-Process -Name qz-tray -Force
$listeners = foreach ($p in 8181,8282,8383,8484,8182,8283,8384,8485) {
  $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $p); $l.Start(); $l
}
"puertos ocupados; dejar 40 min y NO cerrar esta ventana de PowerShell"
```

Tras **40 minutos**:
```powershell
Get-Content "$env:LOCALAPPDATA\qz-watchdog.log" -Tail 40
Get-Content "$env:LOCALAPPDATA\qz-watchdog-state.txt"
```
Esperado: **como mucho 5** líneas `reiniciado (intento N/5)`, con separación
creciente (4, 8, 16, 32, 60 min), y después `RENDIDO`. **Nunca** un relanzado cada
2-4 min indefinidamente.
Real (nº de relanzados en 40 min): ______________________

Liberar y comprobar la autocuración:
```powershell
$listeners | ForEach-Object { $_.Stop() }
# esperar ~4 min
Get-Process qz-tray -ErrorAction SilentlyContinue
Test-Path "$env:LOCALAPPDATA\qz-watchdog-state.txt"
```
Esperado: QZ vuelve a estar vivo y el fichero de estado **ha desaparecido** (freno
rearmado solo).
Real: ______________________

### 3c) Falso positivo de la sonda: otro programa en el puerto de QZ

```powershell
Stop-Process -Name qz-tray -Force
$l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 8181); $l.Start()
# esperar 3 min
Get-Process qz-tray -ErrorAction SilentlyContinue
$l.Stop()
```
Esperado: QZ **se relanza** pese a que el 8181 está ocupado por otro proceso (la
sonda comprueba el PID dueño). Antes del fix se declaraba "vivo" y no se relanzaba.
Real: ______________________

### 3d) Parpadeo visible (**mirar la pantalla, no la consola**)

Dejar el equipo en el escritorio, **sin tocarlo, mirando**, durante 6 minutos
(3 pasadas del watchdog).
Esperado: **cero** ventanas, cero parpadeos de consola, cero iconos que aparecen y
desaparecen en la barra de tareas.
Real: ______________________

### 3e) Coste del watchdog

```powershell
# Duración de una pasada
Measure-Command {
  Start-ScheduledTask -TaskName 'QZ Tray Watchdog'
  do { Start-Sleep -Milliseconds 200 }
  while ((Get-ScheduledTask -TaskName 'QZ Tray Watchdog').State -eq 'Running')
}
```
Esperado: < 2 s (antes, la sonda TCP podía tardar 6,4 s ella sola).
Real: ______________________

```powershell
# ¿Se acumulan powershell.exe?
Get-Process powershell -ErrorAction SilentlyContinue |
  Select-Object Id, StartTime, @{n='CPU_s';e={[math]::Round($_.CPU,2)}}
```
Esperado: 0–1 (solo la sesión desde la que se mide).
Real: ______________________

```powershell
# Rotación del log
(Get-Item "$env:LOCALAPPDATA\qz-watchdog.log").Length / 1KB
```
Esperado: < 256 KB.
Real: ______________________

---

## 4) Desinstalación limpia (**bug corregido en esta tanda**)

Desinstalar QZ Tray desde Panel de control y después:

```powershell
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run').'QZ Tray Watchdog'
Get-ScheduledTask -TaskName 'QZ Tray *' -ErrorAction SilentlyContinue
[Environment]::GetEnvironmentVariable('QZ_OPTS','Machine')
```
Esperado: los tres **vacíos/ausentes**. Antes, la entrada `QZ Tray Watchdog`
sobrevivía a la desinstalación y seguía lanzando PowerShell en cada arranque.
Real: ______________________

---

## 5) Tests Pester (lógica del watchdog)

```powershell
Install-Module Pester -Force -Scope CurrentUser   # si hace falta
Invoke-Pester .\test\win-autostart.Tests.ps1 -Output Detailed
```
Esperado: todo verde. **Nunca se han ejecutado**: anotar el resultado real, y si
algo falla, es un fallo del test o del fix — no darlo por bueno.
Real: ______________________

---

## Resumen de la sesión de medición

| Bloque | Resultado |
|---|---|
| 1. Heap aplicado a la JVM | |
| 2. Arranque en frío | |
| 2e. Multiusuario | |
| 3a. Relanzamientos/hora = 0 | |
| 3b. Caso peor acotado (≤5 y RENDIDO) | |
| 3d. Cero ventanas visibles | |
| 4. Desinstalación limpia | |
| 5. Pester | |
