# PLAN TDD — QZ Linux: techo de heap + icono de bandeja

**Rama:** `fix/qz-heap-y-bandeja`
**Worktree:** `~/dev/.worktrees/qz/fix-qz-heap-y-bandeja`
**Fecha:** 2026-08-05
**Alcance:** SOLO Linux. Windows se mide aparte con su propia spec.

---

## 0. Contexto imprescindible sobre este repo

Esto condiciona todo el plan y hay que tenerlo claro antes de empezar:

- **Este repo NO contiene el fuente de QZ.** Solo binarios (LFS), `patches/` y
  `provision-src/`. El fuente vive en `qzind/tray`, pineado a `46e404e`.
- **El `.run` NO se compila en local.** Lo genera
  `.github/workflows/build-linux.yaml` en un runner `ubuntu-latest`, con dos JDK 11
  distintos (full con JavaFX para compilar, pelado para jlink) y `ant makeself`.
  Reproducirlo a mano no es viable ni deseable.
- **El único archivo a modificar es `provision-src/linux-autostart.sh`**, que el CI
  copia a `tray/provision/` (paso 4 del workflow) y que el instalador ejecuta en
  fase `install` según `provision.json`.
- **El fix NO va en `/opt/qz-tray/`.** Eso es el instalado; se regenera en cada
  reinstalación del `.run`. Editar ahí solo sirve para validar en caliente.

### Consecuencia para el TDD

El "sistema bajo prueba" es **el script de provisioning**, no código Java. Los tests
son de shell: ejecutan `linux-autostart.sh` contra un `HOME` de mentira y verifican
la unidad systemd generada. Esto es rápido, determinista y no necesita CI ni reiniciar QZ.

La verificación de que el fix *funciona de verdad* (RSS, swap, icono) es una segunda
capa, manual y sobre el proceso vivo, porque depende del kernel y del escritorio.

---

## 1. Defectos a corregir

| # | Defecto | Origen |
|---|---------|--------|
| D1 | Heap sin techo: `MaxHeapSize`=3,9 GB, RSS 813 MB, swap 849 MB | QZ upstream (lanzador sin `-Xmx`) |
| D2 | Icono de bandeja ausente: sin `DISPLAY`/`WAYLAND_DISPLAY` | El fork (systemd sustituye al `.desktop`) |
| D3 | Primera impresión lenta: 159.840 page faults mayores | Consecuencia de D1 |
| D5 | **BUG PREEXISTENTE**: `linux-autostart.sh:47` usa `$QZ_PREFS`, variable **inexistente** | El fork |

> **D5 hallado al leer el script para este plan.** La línea 47 imprime
> `security.print.tofile=true escrito en ` (ruta vacía). Es un `echo` duplicado y
> erróneo del de la línea 37. Inocuo funcionalmente (solo ensucia el log de
> instalación), pero se corrige porque tocamos el archivo. Con `set -e` y una
> variable no definida no rompe, pero es ruido que confunde al diagnosticar.

D4 (log DEBUG/TRACE) queda **fuera de este plan**: vive en `qz-tray.properties`, es
un cambio independiente y no quiero mezclarlo con el fix de arranque.

---

## 2. Ciclo TDD

Un test por defecto. **RED antes que GREEN, siempre.** El arnés se escribe primero y
debe fallar contra el script actual — si pasa a la primera, el test está mal.

### Arnés: `test/test-linux-autostart.sh`

Ejecuta `linux-autostart.sh` en un entorno de mentira y afirma sobre el `.service`
generado. Requisitos del arnés:

- `HOME` falso en `mktemp -d`; nunca toca el `~` real ni el systemd real.
- Stubbea `QZ_BIN` (crea un ejecutable falso) para superar el guard de la línea 17.
- Neutraliza `loginctl`, `runuser`, `systemctl` y `chown` vía `PATH` con stubs, para
  que el script no toque el sistema.
- No requiere root.

> **Gotcha**: el script hace `exit 0` temprano si `/opt/qz-tray/qz-tray` no es
> ejecutable (línea 17-20). El arnés debe parametrizar `QZ_BIN` o crear el stub en
> la ruta esperada. Como la ruta está hardcodeada, **el fix debe hacer `QZ_BIN`
> sobreescribible por entorno** (`QZ_BIN="${QZ_BIN:-/opt/qz-tray/qz-tray}"`) — cambio
> mínimo y necesario para poder testear. Se documenta como parte del fix, no como
> extra.

### T1 — RED: la unidad no exporta el entorno gráfico (D2)

```
Afirma: el .service generado contiene Environment=DISPLAY
Estado esperado inicial: FALLA (el script actual no lo emite)
```

**GREEN:** añadir a la plantilla de la unidad:
```ini
Environment=DISPLAY=:1
Environment=WAYLAND_DISPLAY=wayland-0
```

> **Decisión pendiente del usuario (ver §5):** `:1` hardcodeado vs. detección
> dinámica. El test debe afirmar sobre *la presencia de la variable*, no sobre el
> valor `:1`, para no atarse a la decisión.

### T2 — RED: la unidad no fija techo de heap (D1, D3)

```
Afirma: el .service contiene QZ_OPTS con -Xmx
Estado esperado inicial: FALLA
```

**GREEN:**
```ini
Environment=QZ_OPTS=-Xmx512m -XX:+UseSerialGC -XX:MaxMetaspaceSize=128m
```

El lanzador `/opt/qz-tray/qz-tray` ya soporta `QZ_OPTS` (línea 40:
`LAUNCH_OPTS="$LAUNCH_OPTS $QZ_OPTS"`), así que **no hay que parchear el lanzador ni
recompilar el jar**. Es puramente configuración de arranque.

### T3 — RED: enganche a la sesión gráfica (D2, robustez)

```
Afirma: WantedBy=graphical-session.target y PartOf=graphical-session.target
Estado esperado inicial: FALLA (hoy es WantedBy=default.target)
```

**GREEN:** cambiar el `[Install]` y añadir `PartOf`.

> **Riesgo a evaluar**: hoy hay `loginctl enable-linger` (línea 89) para arrancar al
> encender el PC sin sesión gráfica. `WantedBy=graphical-session.target` **es
> incompatible con esa intención**: si QZ debe correr sin sesión gráfica, no puede
> depender de ella. Pero si no hay sesión gráfica **tampoco puede haber icono de
> bandeja**. Son objetivos que se excluyen.
> **Esto necesita decisión del usuario (§5).** T3 queda BLOQUEADO hasta resolverlo.

### T4 — RED: `$QZ_PREFS` inexistente (D5)

```
Afirma: la salida del script NO contiene la línea con ruta vacía
Estado esperado inicial: FALLA
```

**GREEN:** eliminar la línea 47 (duplicado erróneo de la 37).

### T5 — Idempotencia (regresión)

```
Afirma: ejecutar el script dos veces produce el MISMO .service, sin duplicar líneas
```

El script se declara idempotente en su cabecera. Como ahora emite más `Environment=`,
hay que probarlo: usa `cat >` (sobrescribe), así que debería serlo — pero se verifica,
no se asume.

---

## 3. Verificación en el proceso vivo (2ª capa, manual)

Tras aplicar y **reinstalar**, dejar correr **≥ 24 h** para que se manifieste el
patrón de inactividad. Comparar contra los valores pre-fix medidos:

| AC | Comando | Pre-fix | Criterio |
|----|---------|---------|----------|
| AC1 | `jcmd $PID VM.flags \| grep MaxHeapSize` | 3,9 GB | ≈ 512 MB |
| AC2 | `grep -E "VmRSS\|VmSwap" /proc/$PID/status` | 813 / 849 MB | RSS 200-350 MB, Swap ≈ 0 |
| AC3 | `ps -o maj_flt= -p $PID` | 159.840 | órdenes de magnitud menor |
| AC4 | `jcmd $PID Thread.print \| grep -cE '^"AWT-'` | 0 | ≥ 1 |
| AC5 | **Visual: icono en la bandeja de KDE** | ausente | **lo confirma el usuario** |
| AC6 | `ss -tanp \| grep 8181` | ESTAB | ESTAB al reconectar el TPV |

> AC2/AC3 son **estimación**. La causa raíz está confirmada con medición directa;
> la magnitud del ahorro no lo estará hasta medir post-fix.

---

## 4. Compilación y despliegue del `.run`

**No se compila en local.** El flujo real:

1. Commit en `fix/qz-heap-y-bandeja` (firmado con YubiKey, `-S`).
2. El workflow `build-linux.yaml` dispara con `push` **solo en `main` y
   `feat/usb-devicepath-linux`** (líneas 36-43). Para esta rama hay dos opciones:
   - `workflow_dispatch` manual apuntando a la rama, o
   - añadir la rama al filtro, o
   - mergear a `main` (dispara solo, ya que `provision-src/**` está en `paths`).
   **Decisión del usuario (§5).**
3. El CI genera `qz.run`, lo sube como artefacto y —si es `main`— lo **commitea al
   LFS de main**, que es de donde lo descarga el TPV
   (`zq/printer-modal.js → QZ_DL.linux`).
4. Instalar el `.run` nuevo en `kaz` y medir la 2ª capa (§3).

### Gotchas del build documentados en el workflow

- **No encadenar targets de instalador** (`nsis` y `makeself` escriben en el mismo
  `out/`).
- Los **dos JDK son obligatorios** y no intercambiables (JavaFX / split packages).
- El commit de publicación **debe quedar como puntero LFS**; el workflow aborta si
  no (evita meter 122 MB en el árbol).

### Validación rápida SIN esperar al CI

Para no gastar un ciclo de CI en un fallo tonto, antes de commitear:
- Correr el arnés de tests (§2) en local — cubre todo lo que cambiamos.
- `bash -n provision-src/linux-autostart.sh` (sintaxis).
- Opcional: `systemd-analyze verify` sobre la unidad generada por el arnés.

### Validación en caliente ANTES de reinstalar

Se puede aplicar el mismo cambio a mano sobre
`~/.config/systemd/user/qz-tray.service` + `daemon-reload` + `restart`, y medir la
2ª capa **sin esperar al CI**. Esto valida el fix real; el `.run` solo lo hace
permanente.
⚠️ **Reiniciar QZ corta la conexión del TPV.** Coordinar con el usuario.

---

## 5. Decisiones — RESUELTAS (2026-08-05)

1. **`-Xmx512m`** ✅ elegido. Medición post-fix confirma que sobra: heap usado
   166 MB de 512.

2. **`DISPLAY=:1` fijo** ✅ elegido, por simplicidad. Si algún día cambia el
   display habrá que revisarlo (queda como deuda conocida, no como bug).

3. **`linger` gana sobre `graphical-session.target`** ✅ — prevalece "QZ nunca
   falta". La unidad sigue en `WantedBy=default.target` y se mantiene
   `enable-linger`. T3/T3b congelan esta decisión.

4. **Build**: PENDIENTE. Sin decidir al cerrar el TDD.

### Hallazgo que cambió el fix: las comillas de `Environment=`

`Environment=QZ_OPTS=-Xmx512m -XX:+UseSerialGC -XX:MaxMetaspaceSize=128m` **sin
comillas** NO funciona: systemd parte el valor por espacios y descarta lo que no
sea `K=V`, así que `QZ_OPTS` habría llegado a la JVM valiendo **solo `-Xmx512m`**
y SerialGC se habría perdido EN SILENCIO.

Lo cazó `systemd-analyze verify` en un dry-run, no los tests: T2/T2b hacen `grep`
sobre el *fichero* y no ven lo que systemd *entiende*. Por eso se añadió **T2c**,
que corre `systemd-analyze verify` y falla si hay `Invalid environment assignment`.

---

## 5-bis. Resultado medido en `kaz` (2026-08-05)

Validación en caliente sobre el proceso vivo. **AC1-AC5 verdes.**

| AC | Pre-fix | Post-fix | |
|----|---------|----------|---|
| AC1 heap | 3,84 GB · UseG1GC | **512 MB fijo · SerialGC · Metaspace 128 MB** | ✅ |
| AC2 RSS/Swap | 392 MB / **1,28 GB** | 712 MB / **0 kB** | ✅ |
| AC3 maj_flt | 188.492 | **464** | ✅ |
| AC4 hilos AWT | **0** | **3** (XAWT, EventQueue-0, Shutdown) | ✅ |
| AC5 icono bandeja | ausente | **presente** (confirmado por el usuario) | ✅ |
| AC6 puerto 8181 | ESTAB | ESTAB (heartbeat `getVersion` cada 25 s) | ✅ |

> **El RSS SUBE (392 → 712 MB) y es correcto**, no una regresión: el 1,28 GB que
> estaba paginado a disco ahora vive en RAM. Lo que importa es Swap = 0 y
> maj_flt = 464. `-Xms512m` (del lanzador upstream, no de este fix) compromete los
> 512 MB de golpe y SerialGC no los devuelve al SO.
>
> Metaspace real: 60 MB usados de los 128 MB de techo — el límite no ahoga a JavaFX.

### Efecto secundario esperable de arreglar D2

Al dar `DISPLAY` a la unidad, se hace VISIBLE un comportamiento de QZ 2.2.6 que
antes estaba latente:

```
IDLE: Starting up JFX for HTML printing
Setting starting size 0.0:0.0
```

QZ precalienta JavaFX tras ~1 min inactivo y crea una ventana 0×0, que parpadea
como si se lanzara otra app. **No es un relanzamiento** (`NRestarts=0`, proceso
único). Antes no se veía porque sin `DISPLAY` JFX no podía crear ventana alguna.
No se considera defecto de este fix; si molesta, es trabajo aparte.

---

## 6. Fuera de alcance

- **Windows**: se mide en el Claude Code de Windows con spec propia.
- **D4 log DEBUG/TRACE**: cambio independiente en `qz-tray.properties`.
- **Websocket zombi**: QZ vivo con conexión muerta; `Restart=on-failure` no lo cubre
  porque el proceso no falla. Requiere healthcheck activo. No investigado.

---

## 7. Orden de ejecución

```
[x] Resolver decisiones §5 (BLOQUEA T1, T2, T3)
[x] Escribir arnés test/test-linux-autostart.sh
[x] T4 RED → GREEN  (QZ_PREFS; el más simple, valida el arnés)
[x] T2 RED → GREEN  (QZ_OPTS / heap)  + T2c (systemd entiende el valor entero)
[x] T1 RED → GREEN  (DISPLAY)
[x] T3 RED → GREEN  (default.target + linger; §5.3 resuelto)
[x] T5 idempotencia
[x] bash -n + arnés completo en verde (13/13)
[x] Mutation testing: cada mutante mata SOLO su test
[x] Validación en caliente sobre el QZ vivo + medir AC1-AC4, AC6
[x] AC5 visual → CONFIRMADO POR EL USUARIO
[x] Commit (sin firma, a petición del usuario)
[ ] Disparar build según §5.4 → instalar .run → re-medir
```

### Bugs del propio arnés hallados al verificar que los tests MUERDEN

Los tres se corrigieron; sin ellos el TDD habría dado falsa seguridad:

1. **T1 daba falso VERDE**: `grep '^Environment=.*DISPLAY'` casaba con la línea de
   `WAYLAND_DISPLAY` (contiene la subcadena). Se borraba `DISPLAY=:1` y el test
   seguía pasando. Anclado a `^Environment=DISPLAY=`.
2. **T5 daba falso ROJO**: comparaba dos ejecuciones en sandboxes `mktemp -d`
   distintos, y la ruta se colaba en el `ExecStart` vía `QZ_BIN`. El script SÍ era
   idempotente. Separado `new_sandbox` de `invoke_script` para reejecutar sobre la
   misma instalación (que además es el caso real: reinstalar encima).
3. **T5b reventaba**: `grep -c ... || echo 0` producía `"0\n0"` y el `[ -le ]`
   fallaba con "se esperaba una expresión entera".

---

## 8. Pendiente / deuda conocida

- **Disparar el build** (§5.4) e instalar el `.run` — SIN decidir.
- **`StartLimitIntervalSec` / `StartLimitBurst` están en `[Service]`**, pero
  systemd los espera en `[Unit]`. Ahí se IGNORAN: el cortafuegos anti-bucle que
  describe el comentario NO está actuando. Defecto **preexistente**, detectado con
  `systemd-analyze verify` durante este trabajo. Fuera del alcance de este plan.
- **AC2/AC3 a 24 h**: las cifras de arriba son de un proceso recién arrancado. El
  patrón de swap/page-faults en inactividad prolongada no estará confirmado hasta
  dejarlo correr un día.

**No se hace push ni merge sin que el usuario lo pida explícitamente.**
