# PROMPT — QZ Tray en Windows: heap + arranque garantizado + estabilidad

## Contexto

Repo **`~/dev/qz`** (`githubssh:remero41/qz`), `main` = `origin/main` = **`e472e67`**, limpio.

Acabamos de cerrar **el equivalente en Linux** (merge `e472e67`, firmado y pusheado): la
unidad systemd arrancaba QZ **sin `-Xmx`** (la JVM se autoasignaba 1/4 de la RAM: 3,84 GB
de 15,7 GB) y **sin `DISPLAY`** (0 hilos AWT ⇒ sin icono de bandeja). Medido en vivo en
`kaz`: swap 1,28 GB → 0 kB, `maj_flt` 188.492 → 464. Era **la causa de la primera
impresión lenta tras un rato parado**.

**Tres objetivos, en orden de importancia:**

1. **🔴 VITAL — QZ arranca SÍ O SÍ al iniciar Windows.** Si un equipo enciende y QZ no
   está, el TPV no imprime.
2. **🔴 VITAL — y se queda quieto y barato.** Nada de abrirse y cerrarse, parpadeo de
   ventanas, instancias duplicadas, ni consumo desbocado (CPU, RAM, handles, disco por
   logs). Un QZ que revive en bucle es tan inservible como uno que no arranca, y además
   **molesta al usuario en pantalla**.
3. **Paridad con Linux ante el TPV**: techo de heap, sin swap, icono de bandeja presente.

Los objetivos 1 y 2 **están en tensión**: las capas redundantes que garantizan el arranque
son justo el mecanismo que puede provocar el ciclo abrir-cerrar. Resolver esa tensión es el
corazón del encargo.

## Disponibilidad de hardware — TRABAJO EN DOS TIEMPOS

Hay un Windows accesible, **pero no en esta sesión**.

**Tiempo 1 (ahora, sin máquina):** todo lo determinable leyendo código. Cierra el frente 3
(el mecanismo de inyección del heap se puede resolver leyendo launch4j y el `build.xml` de
qzind/tray). Audita el watchdog en busca de caminos de bucle, falsos negativos de
`Test-QzAlive` y parpadeo visible. Monta el arnés de tests hasta donde llegue sin PowerShell.

**Tiempo 2 (después, con máquina):** deja escrito un **guion de medición ejecutable** —
comandos concretos, copiables, con el valor esperado al lado y sitio para anotar el real.
Debe cubrir: relanzamientos/hora en régimen normal (esperado 0), CPU y RAM del watchdog por
pasada, RSS de QZ, ventanas visibles (esperado 0), icono de bandeja presente, y el
comportamiento tras reinicio en frío. Ordénalo para recorrerlo del tirón en una sesión corta.

**No cierres en falso nada del tiempo 2.** Marca cada hallazgo como *verificado en frío*,
*sospecha pendiente de máquina* o *solo verificable en Windows*.

## Cómo se compila (ya verificado — no lo redescubras)

El `.exe` **no se compila a mano**: lo hace **GitHub Actions**,
`.github/workflows/build-win.yaml`, en `windows-latest`. El último (`bbf9d78`, 24/07) es un
commit de `github-actions[bot]`.

Flujo: checkout de este repo (solo `provision-src/` + `patches/`) → clona `qzind/tray`
**pineado a `46e404e`** (este repo NO tiene el fuente) → aplica los **5 parches en orden**
(`0001`…`0005`, aditivos, activados en runtime por SO) → copia `provision-src/*` a
`tray/provision/` → `ant nsis` (NSIS vía choco, `-Dnsisbin` explícito porque la
autodetección de ant falla en el runner) → renombra a `qz.exe` → **commitea a LFS de `main`**.

**Eso último es la clave**: el TPV descarga de
`https://media.githubusercontent.com/media/remero41/qz/main/qz.exe` (LFS de main, **no** de
Releases). Ya hubo un incidente el 22/07 por esto: el binario de main quedó congelado en un
build manual del 16/07, anterior al parche USB, y el TPV **degradaba a cola en silencio**.

Disparo: push a `main` que toque `patches/**`, `provision-src/**` o el workflow; o
`workflow_dispatch` con `publicar: true`.

⚠️ **ANTI-BUCLE documentado**: el paso de publicación pushea a `main`, la rama que dispara
el workflow. No reentra porque el commit solo toca `qz.exe`, que **no está** en el filtro
`paths`, y porque `GITHUB_TOKEN` no dispara workflows. **Si alguien añade `qz.exe` o `**` a
`paths`, es un bucle infinito de builds. NO lo hagas.**

**Corrección de una sesión anterior:** se dijo que "el fix no llega a ninguna máquina porque
recompilar está vetado". **Es falso.** El veto es sobre **regenerar certificados**, no sobre
disparar el CI. **Recompilar = lanzar el workflow**, y es la vía normal de despliegue. Igual
para Linux (`build-linux.yaml`) con el fix ya mergeado.

## Certificados (ya resueltos — no los toques)

- Los tres del parque están en `/home/zak/Escritorio/cert/`: `cert.pem`, `key.pem`,
  `override.crt` — `Catinfog LLC`, `CN=*.catinfog.com`, autofirmados, válidos hasta **2122**.
  `override.crt` es copia idéntica de `cert.pem`.
- **Ya están cargados como Secrets del repo** (`QZ_CERT_PEM`, `QZ_KEY_PEM`,
  `QZ_OVERRIDE_CRT`, desde el 16/07), así que **el CI ya compila con la confianza del
  parque**. No hay que subir nada.
- ⛔ **NO los regeneres** (`reference_qz_certificados_compilacion.md`): romperían la
  confianza de todo el parque instalado. Compilar por CI sí; tocar los certs no.
- ⚠️ **Firma Authenticode ≠ certificado de confianza QZ.** Los Secrets
  `WIN_SIGNING_KEYSTORE_B64` / `WIN_SIGNING_ALIAS` / `WIN_SIGNING_STOREPASS` **NO existen**
  en el repo, así que ant autogenera un keystore self-signed y el `.exe` sale
  **self-signed**: válido para probar, pero Windows/SmartScreen pedirá confirmación al
  instalar. Si eso es un problema para el despliegue en el parque, **dilo en el informe** —
  es decisión del usuario, no la resuelvas por tu cuenta.

## Terreno

**`provision-src/win-autostart.ps1` — 328 líneas, CERO tests.** Cuatro capas redundantes:

- 0) `.lnk` en Startup común — nativo del instalador (t=0)
- 1) Tarea `QZ Tray Autostart` — ONLOGON +45s, principal de **grupo** `Users` (S-1-5-32-545),
  vía XML (no `schtasks` clásico) para que dispare en la sesión de cualquier usuario interactivo
- 2) Tarea `QZ Tray Watchdog` — **cada 2 min**
- 3) `HKLM\...\Run` +75s — sobrevive si el Task Scheduler está roto

El watchdog se invoca por `-EncodedCommand` (base64 UTF-16LE), inmune a ExecutionPolicy, con
**mutex global** anti-solape. Su lógica, ya leída:

- `Test-QzAutostartWanted` lee `.autostart` de `%APPDATA%\qz` o `%PROGRAMDATA%\qz`; si vale
  `0`, **gate anti-bucle**: no relanza nada
- Autocuración: borra entradas de `HKCU\...\StartupApproved` deshabilitadas desde el
  Administrador de tareas
- `Test-QzAlive`: sonda TCP a 8 puertos (8181…8485), 800 ms cada uno
- Caso A: 0 procesos → `Start-Qz`
- Caso B: >1 proceso **y todos con >90s** → mata todos menos el más viejo; si alguno es
  joven, **no toca nada**
- Caso C: proceso vivo sin websocket → **4 min de gracia**; pasados, `Stop-Process -Force` a
  todos, espera hasta 15s a que mueran, relanza una vez

Anti-bucle explícito heredado de un bucle real en Linux (`e04a799`): respeta `.autostart` y
lanza con `--honorautostart`.

Otros ficheros: `win-winusb.ps1` (86 líneas, driver WinUSB), `win-cleanup.ps1` (13,
`phase: uninstall`), `patches/0001` (devicePath USB), `0003` (workOffline por cola), `0005`
(identidad USB en cola) + su test. **`HANDOFF-CLAUDE-WINDOWS.md`** — diagnóstico de
`WindowsUsbInfo.readRegistry()` devolviendo `{}` (hipótesis: permisos HKLM vs estructura del
registro); **léelo y comprueba si sigue vivo**. **No existe `patches/README-windows.md`**
(sí `README-linux.md`).

Comparativa que motiva todo esto: **Linux 16 tests, Windows 0**, siendo el de Windows 15×
más largo y con mucha más superficie (registro, tareas programadas, UAC, multiusuario,
base64, session 0).

## Frente 1 — Arranque garantizado 🔴

Revisión **adversarial** de las 4 capas. No las rehagas: busca por dónde se caen.

- **Varios usuarios**: la tarea es de grupo `Users` — ¿dispara para el segundo usuario?
  ¿Cambio rápido de usuario?
- **Session 0 isolation**: ¿alguna capa lanza QZ **sin sesión interactiva**? Proceso vivo
  **sin icono de bandeja** — el gemelo exacto del bug del `DISPLAY` en Linux.
- **Arranque en frío vs reinicio**: Fast Startup, inicio de sesión automático, equipos que
  nunca apagan.
- Usuario que **desactiva la entrada de arranque**: el watchdog dice reactivarla — ¿lo hace
  de verdad?
- **Dominio/GPO, cuentas sin privilegios, antivirus** que bloquee `-EncodedCommand`.

## Frente 2 — Estabilidad y consumo 🔴

Aquí hay que ser más desconfiado, porque **el watchdog mata procesos cada 2 minutos**.

- **Ciclo abrir-cerrar**: enumera todos los caminos por los que QZ pueda ser matado y
  relanzado en bucle. ¿Qué pasa si el websocket **nunca** abre (puerto ocupado por otra app,
  firewall, QZ en otro puerto fuera de los 8 sondeados)? Caso C mataría y relanzaría **cada
  2 min indefinidamente**. ¿Está acotado? ¿Hay backoff, o tope de reintentos?
- **`Test-QzAlive` puede dar falso negativo**: 8 puertos × 800 ms = hasta **6,4 s** por
  pasada. Si QZ escucha en otro puerto o la sonda tarda, se declara zombi un proceso **sano**
  y se lo mata. Y si el puerto está ocupado por un proceso ajeno, da falso **positivo** (QZ
  muerto declarado vivo).
- **Parpadeo visible**: `Start-Process` sin `-WindowStyle Hidden` en `Start-Qz`, PowerShell
  arrancando cada 2 min. ¿Ve el usuario ventanas o iconos apareciendo y desapareciendo? Esto
  es lo que más molesta en un mostrador.
- **Contexto de `HKCU`**: la autocuración lee `HKCU\...\StartupApproved` y `.autostart` de
  `%APPDATA%`. Si la tarea corre en un contexto de usuario distinto del que tiene la sesión,
  esas rutas apuntan a **otro perfil** ⇒ decisiones tomadas sobre datos equivocados.
- **Coste del propio watchdog**: 720 ejecuciones de PowerShell al día. Mide CPU, RAM y
  handles por pasada. ¿Crece el log sin rotación? ¿Se acumulan procesos `powershell.exe` si
  una pasada se cuelga (el mutex no tiene timeout visible)?
- **Interacción entre capas**: `.lnk` (t=0) + tarea ONLOGON (+45s) + `HKLM\Run` (+75s) pueden
  intentar lanzar en ventanas solapadas. La gracia de 90s del caso B lo cubre en teoría —
  **verifícalo**, no lo asumas.
- **Consumo de QZ en sí**: sin `-Xmx` (frente 3), en un equipo de 16 GB la JVM se autoasigna 4 GB.

## Frente 3 — Heap/JVM

Dato ya verificado: `grep -nE "Xmx|Xms|QZ_OPTS|java" provision-src/win-autostart.ps1` →
**cero coincidencias**. El techo de heap **no está puesto en Windows**.

**No asumas que el fix de Linux se traslada.** Allí QZ arranca por `/opt/qz-tray/qz-tray`, un
shell script que concatena `$QZ_OPTS` (por eso funcionó, y por eso las comillas eran
obligatorias: sin ellas systemd partía el valor y **SerialGC se perdía en silencio**). En
Windows arranca por `qz-tray.exe` (**launch4j**), que **no lee `QZ_OPTS`**.

Averigua el mecanismo real y **cuál sobrevive a una reinstalación**: `.l4j.ini` junto al exe,
`_JAVA_OPTIONS`, `JAVA_TOOL_OPTIONS`, `.vmoptions`, variable de entorno de máquina, o parche
al fuente. Ojo: en Linux el proceso arranca con `-Xms512m` pero sin `-Xmx` — mira de dónde
sale ese `-Xms`, porque probablemente ya haya un punto de inyección reutilizable.

Objetivo: `-Xmx512m -XX:+UseSerialGC -XX:MaxMetaspaceSize=128m` (SerialGC porque **G1 no
devuelve memoria al SO** en una app parada todo el día; el RSS sube y **es correcto**: lo
paginado a disco pasa a RAM).

## Entregable

1. Hallazgos clasificados: **verificado en frío / sospecha pendiente de máquina / solo
   verificable en Windows**.
2. Fix **de raíz** en `provision-src/` (y `patches/` si toca fuente).
3. **Arnés de tests** para `win-autostart.ps1` al estilo del de Linux (Pester u otro). Si no
   puedes ejecutar PowerShell aquí, **dilo claro** y separa lo verificable estáticamente de
   lo que exige Windows real. **No finjas verde.**
4. **Guion de medición para el tiempo 2** (ver arriba): comandos copiables, valor esperado al
   lado, hueco para el real.
5. **Presupuesto de estabilidad medible**: qué números definen "sano" (relanzamientos/hora en
   régimen normal = 0, CPU media del watchdog, RSS de QZ, ventanas visibles = 0).
6. Plan de despliegue: qué disparar, en qué orden, cómo verificar que el `.exe` publicado
   lleva el cambio.
7. Valora si toca escribir `patches/README-windows.md`.

## Reglas duras

- ⛔ **NO regeneres los certificados de QZ** (ver sección Certificados).
- ⚠️ **`provision-src/` es la RECETA, no el binario.** Editarlo no cambia `qz.exe`: hace
  falta que corra el workflow y publique a LFS de main. Sé exacto al declarar qué queda
  "aplicado".
- `"phase": "install"` ⇒ el script corre **solo al instalar**, una vez; su salida (tareas,
  registro, `.lnk`) queda congelada. Y **reinstalar pisa lo anterior** sin preguntar.
- **No dispares el workflow ni hagas push por tu cuenta.** Prepáralo y pídeselo al usuario.
  Si te lo pide, firma con `-S` (YubiKey `ED25519-SK`); ante `agent refused`, mira **`lsusb`
  ANTES** — la llave suele no estar enchufada y `ssh-add -l` la lista igual.
- **No verifiques con Playwright**; lo visual lo comprueba el usuario. Termina pidiéndole la
  comprobación concreta.
- No lances subagentes.

## Método

**Ley anti-vanidad**: un bug solo cuenta si un test lo reproduce y **muerde al mutar** el fix.

En la sesión de Linux esto cazó un error: la primera derivación del `DISPLAY` elegía "el
socket de menor número", que en `kaz` da `:0`… el Xorg del **greeter SDDM**, muerto para el
usuario. Habría roto el icono **justo en la máquina donde se midió el fix**. Lo cazó el test.
El discriminante bueno era *de quién* es el servidor X, no su número.

**Busca el equivalente en Windows** — sospecha de toda heurística que elija "el primero", "el
de menor número", "la ruta por defecto" o "el puerto habitual". `Test-QzAlive` sondeando 8
puertos fijos huele exactamente a eso.

Y aplica el mismo escepticismo al anti-bucle existente: el script **afirma** ser anti-bucle y
hereda la lección de un bucle real. Trata esa afirmación como hipótesis a refutar, no como
hecho.
