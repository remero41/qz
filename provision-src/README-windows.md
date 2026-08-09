# Arranque de QZ Tray en Windows — cómo funciona y dónde están las trampas

Acompaña a `win-autostart.ps1` (instalación), `win-cleanup.ps1` (desinstalación) y
`win-winusb.ps1`. Existe porque el mecanismo de arranque de Windows es **distinto
del de Linux** en el punto que más importa (la JVM), y esa diferencia ya provocó
una premisa equivocada: se dio por hecho que `qz-tray.exe` era **launch4j** y que
por tanto no leía `QZ_OPTS`. **Es falso.**

> `patches/README-linux.md` documenta el parche 0002 (código Java). Esto documenta
> el *provisioning* de Windows, que es otra cosa: no toca el fuente de QZ.

---

## 1. Cómo arranca la JVM en Windows (y por qué `QZ_OPTS` sí funciona)

`qz-tray.exe` es un lanzador generado por **NSIS**, no launch4j. La plantilla es
`ant/windows/windows-launcher.nsi.in` del árbol `qzind/tray`:

```nsis
StrCpy $opts "${launch.opts}"          ; ant/project.properties: -Xms512m -Djna.nosys=true
${If} $java_major >= 9
    StrCpy $opts "${launch.opts} ${launch.jigsaw}"
${EndIf}
ReadEnvStr $R0 ${launch.overrides}     ; launch.overrides = QZ_OPTS
IfErrors +2 0
StrCpy $opts "$opts $R0"               ; <-- se añade AL FINAL: nuestros flags GANAN
StrCpy $command '"$javaw" $opts -jar "${JAR}" $params'
```

Es **el mismo mecanismo que en Linux**: `ant/unix/unix-launcher.sh.in` hace
`LAUNCH_OPTS="$LAUNCH_OPTS $QZ_OPTS"`. Lo único que cambia es **dónde se define la
variable**:

| | Linux | Windows |
|---|---|---|
| Lanzador | shell script `/opt/qz-tray/qz-tray` | `qz-tray.exe` (NSIS) |
| Dónde se pone `QZ_OPTS` | `Environment="QZ_OPTS=..."` en la unidad systemd | variable de entorno de **máquina** (HKLM) |
| Comillas | **obligatorias** (systemd parte por espacios y descarta trozos en silencio) | no aplica |

De ahí que `-Xms512m` aparezca en la línea de comandos sin que nadie lo haya
puesto: viene de `launch.opts`. **`-Xmx` no está en ningún sitio por defecto**, y
sin él la JVM se autoasigna 1/4 de la RAM.

### Alternativas descartadas

- **`_JAVA_OPTIONS` / `JAVA_TOOL_OPTIONS`** — afectarían a **toda** JVM del equipo,
  no solo a QZ. Descartado.
- **`.l4j.ini` / `.vmoptions`** — no aplican: no hay launch4j.
- **Fichero dentro de la carpeta de instalación** — no sobrevive a una
  reinstalación de QZ, y reinstalar es el flujo normal de despliegue.
- **Variable de usuario** — el mostrador es multiusuario y la tarea corre para el
  grupo `Users`. Va a nivel de **máquina**.

> Las variables de máquina solo llegan a procesos **nuevos**. Por eso
> `win-autostart.ps1` también hace `$env:QZ_OPTS = ...` en su propio proceso: así
> el primer disparo del watchdog (paso 6) ya lanza QZ con el techo puesto, sin
> esperar a un reinicio.

---

## 2. Las cuatro capas de arranque, y qué garantiza cada una

| Capa | Mecanismo | Cuándo | Sobrevive a… |
|---|---|---|---|
| 0 | `.lnk` en Startup común | t=0 | — (nativo del instalador de QZ) |
| 1 | Tarea `QZ Tray Autostart`, ONLOGON | +45 s | que el usuario borre el `.lnk` |
| 2 | Tarea `QZ Tray Watchdog`, cada 2 min | continuo | que QZ crashee o se quede zombi |
| 3 | `HKLM\...\Run` | +75 s | que el **Task Scheduler** esté roto |

**El escalonamiento es real, no decorativo.** Los +45 s y +75 s existen para que
las capas no lancen a la vez: la JVM tarda segundos en enlazar el puerto y el
`SingleInstanceChecker` de QZ no cubre ese margen. La capa 3 implementa su retardo
anteponiendo `Start-Sleep -Seconds 75` al cuerpo codificado del watchdog.

> Trampa histórica: ese `+75s` estuvo **solo en el comentario** durante toda la v2.
> El valor de `Run` se registraba sin espera y disparaba en t=0, junto al `.lnk`.

Solo la capa 2 (el watchdog) lanza QZ de forma incondicional, y lleva dedupe
integrado (mutex global + poda de duplicados), así que las capas no se pisan.

---

## 3. Los anti-bucles (hay tres, y son distintos)

Un QZ que revive en bucle es tan inservible como uno que no arranca — y encima
molesta en pantalla. Hay tres frenos independientes:

1. **Gate `.autostart`** — heredado de un bucle real en Linux (`e04a799`). Si el
   usuario apagó "Iniciar automáticamente" desde el icono de QZ, el watchdog **no
   relanza nada**. Sin esto: QZ arrancado con `--honorautostart` se autocierra, el
   watchdog lo relanza, y vuelta a empezar.
2. **Gracia de 90 s en el caso B** — con más de un proceso, solo se poda si
   **todos** llevan vivos >90 s. Si alguno es joven, es un arranque en curso y no
   se toca nada.
3. **Backoff + rendición en el caso C** — proceso vivo pero sin websocket. Se
   espera 4 min de gracia, y luego los reintentos van con backoff exponencial
   (4, 8, 16, 32, 60 min) hasta **rendirse a los 5**. El contador vive en
   `%LOCALAPPDATA%\qz-watchdog-state.txt` porque **cada pasada del watchdog es un
   proceso PowerShell nuevo**: un contador en memoria no frena nada.

> Trampa histórica: el caso C no tenía freno. Si el websocket **nunca** abría
> (puerto ocupado por otra app, firewall, puertos cambiados en las prefs de QZ),
> el relanzado reseteaba el `StartTime`, así que a los 4 min se volvía a cumplir
> la condición: **mata-relanza cada ~4-6 minutos, indefinidamente**.

Rendirse es lo correcto: si 5 reinicios no han abierto el websocket, el sexto
tampoco. Cualquier pasada que vea a QZ sano borra el estado, así que el freno se
**rearma solo**. Espeja `StartLimitBurst=5` de la unidad systemd de Linux.

---

## 4. La sonda de salud: qué NO puede hacer

`Test-QzAlive` responde "¿está QZ escuchando?". Dos formas de equivocarse, y las
dos son silenciosas:

- **Falso positivo** — otro programa ocupa el 8181. Una sonda que solo comprueba
  "¿acepta conexión?" declara vivo un QZ **muerto**, nadie lo relanza y el TPV no
  imprime. Por eso se compara el **PID dueño** del puerto (`Get-NetTCPConnection
  -State Listen` → `OwningProcess`, con `netstat -ano` de reserva) contra los
  procesos `qz-tray` vigilados.
- **Falso negativo** — los puertos son **configurables**
  (`WebsocketPorts.java` lee `websocket.secure.ports` / `websocket.insecure.ports`
  de las prefs). Una lista fija de 8 declara zombi a un QZ perfectamente sano y lo
  mata cada pocos minutos. Por eso `Get-QzPorts` lee las prefs además de los
  defaults de `Constants.DEFAULT_WSS_PORTS`.

Como efecto lateral bueno: mirar la tabla de conexiones no abre sockets, así que
una pasada ya no puede tardar los 6,4 s del peor caso de la sonda antigua
(8 puertos × 800 ms).

---

## 5. Reglas de despliegue (esto muerde)

- **`provision-src/` es la RECETA, no el binario.** Editar estos ficheros **no
  cambia** el `qz.exe` instalado en ningún equipo. Hace falta que corra
  `.github/workflows/build-win.yaml` y publique a **LFS de `main`**, que es de
  donde descarga el TPV
  (`https://media.githubusercontent.com/media/remero41/qz/main/qz.exe`).
- **`"phase": "install"`** ⇒ el script corre **solo al instalar**, una vez. Su
  salida (tareas, registro, `.lnk`, variable de máquina) queda congelada hasta la
  siguiente instalación. Un equipo ya instalado **no recibe** estos cambios: hay
  que reinstalar QZ ahí.
- **Reinstalar pisa lo anterior** sin preguntar. Por eso todo lo que hace
  `win-autostart.ps1` es idempotente.
- **El desinstalador debe borrar exactamente lo que el instalador crea.** El
  instalador registra el valor `QZ Tray Watchdog`; `QZ Tray` es solo un residuo de
  la v1. *(Trampa histórica: `win-cleanup.ps1` borraba únicamente `QZ Tray`, así
  que tras desinstalar QZ la entrada del watchdog sobrevivía y seguía lanzando un
  PowerShell en cada arranque.)*
- **⛔ No regenerar los certificados de QZ**: romperían la confianza de todo el
  parque instalado. Compilar por CI sí; tocar los certs no.
- El `.exe` sale **self-signed** (no hay Secrets `WIN_SIGNING_*`): válido para
  probar, pero SmartScreen pedirá confirmación al instalar.

---

## 6. Tests

| Fichero | Dónde corre | Qué cubre |
|---|---|---|
| `test/test-win-autostart-static.sh` | Linux (desarrollo) | Invariantes sobre el texto generado: heap, freno, retardo real, cleanup simétrico, sonda por dueño. |
| `test/win-autostart.Tests.ps1` | **Windows** (Pester) | Lógica pura extraída del watchdog: estado del freno, parseo de puertos, `.autostart`. |
| `test/MEDICION-WINDOWS.md` | **Windows** (manual) | Lo que ningún test automatiza: arranque en frío, multiusuario, parpadeo visible, consumo, relanzamientos/hora. |

Los estáticos corren en la máquina de desarrollo porque ahí **no hay PowerShell**.
Verde ahí **no** significa validado en Windows: son cosas distintas y el
`MEDICION-WINDOWS.md` lleva hueco para anotar los valores reales.
