#!/usr/bin/env bash
# Tests ESTÁTICOS de provision-src/win-autostart.ps1 (+ win-cleanup.ps1).
#
# POR QUÉ ESTÁTICOS: este arnés corre en la máquina de desarrollo (Linux), donde
# NO hay PowerShell ni registro ni Task Scheduler. Aquí NO se puede ejecutar el
# script ni afirmar sobre su efecto real. Lo que sí se puede afirmar —y es donde
# vivían los bugs encontrados— son invariantes sobre el TEXTO generado: qué
# nombre de valor se borra al desinstalar, si hay techo de heap, si el bucle de
# relanzado tiene freno, si la ventana se abre oculta.
#
# La parte que EXIGE Windows real (¿dispara la tarea para el 2º usuario?, ¿ve el
# usuario un parpadeo?, ¿cuánto consume el watchdog?) está en:
#   - test/win-autostart.Tests.ps1   (Pester, lógica del watchdog en un Windows)
#   - test/MEDICION-WINDOWS.md       (guion de medición manual)
# NO se finge verde aquí sobre nada de eso.
#
# Uso:  bash test/test-win-autostart-static.sh
# Salida: 0 si todo pasa; 1 si algo falla.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_DIR/provision-src/win-autostart.ps1"
CLEANUP="$REPO_DIR/provision-src/win-cleanup.ps1"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  \033[1;32mPASS\033[0m %s\n' "$1"; }
ko() { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

echo "== Tests estáticos de win-autostart.ps1 =="
echo

[ -f "$TARGET" ] || { echo "no existe $TARGET"; exit 1; }

# ---------------------------------------------------------------------------
# W1 — Techo de heap (paridad con Linux)
#
# En Linux la unidad systemd exporta QZ_OPTS y eso arregló el swapping. En
# Windows qz-tray.exe NO es launch4j (creencia previa): es un lanzador NSIS
# (ant/windows/windows-launcher.nsi.in) que hace
#     ReadEnvStr $R0 ${launch.overrides}   ; launch.overrides=QZ_OPTS
#     StrCpy $opts "$opts $R0"
# es decir, SÍ lee QZ_OPTS y lo añade DESPUÉS de launch.opts (-Xms512m), así que
# gana el valor de la variable. Mismo mecanismo exacto que Linux.
# ---------------------------------------------------------------------------
# Sin comentarios: el fichero EXPLICA el -Xmx en la cabecera, así que un grep a
# secas pasaba aunque el flag desapareciera del valor real (test vanidoso).
if grep -vE '^\s*#' "$TARGET" | grep -qE 'Xmx[0-9]+[mMgG]'; then
  ok "W1 el provisioning fija techo de heap (-Xmx)"
else
  ko "W1 el provisioning fija techo de heap (-Xmx)" \
     "sin -Xmx la JVM se autoasigna 1/4 de la RAM (4 GB en un equipo de 16 GB) y acaba en swap: primera impresión lenta"
fi

if grep -vE '^\s*#' "$TARGET" | grep -qE 'UseSerialGC'; then
  ok "W1b selecciona SerialGC"
else
  ko "W1b selecciona SerialGC" "G1 no devuelve memoria al SO en una app parada todo el día"
fi

if grep -vE '^\s*#' "$TARGET" | grep -qE 'MaxMetaspaceSize=[0-9]+[mMgG]'; then
  ok "W1c acota el metaspace"
else
  ko "W1c acota el metaspace" "paridad con la unidad de Linux"
fi

# W1d — el heap debe fijarse por un mecanismo que SOBREVIVA a la reinstalación y
# que el lanzador lea de verdad: la variable de entorno de MÁQUINA QZ_OPTS.
# _JAVA_OPTIONS no vale: afectaría a TODA JVM del equipo, no solo a QZ.
if grep -vE '^\s*#' "$TARGET" | grep -qE "SetEnvironmentVariable\('QZ_OPTS'"; then
  ok "W1d el heap se inyecta por QZ_OPTS (lo que lee el lanzador NSIS)"
else
  ko "W1d el heap se inyecta por QZ_OPTS (lo que lee el lanzador NSIS)" \
     "el lanzador de Windows solo consulta la variable nombrada en launch.overrides (=QZ_OPTS)"
fi

# Ojo: se filtran las líneas de comentario. La primera versión de este test
# mordía el propio comentario que explica POR QUÉ no se usan esas variables.
if grep -vE '^\s*#' "$TARGET" | grep -qE '_JAVA_OPTIONS|JAVA_TOOL_OPTIONS'; then
  ko "W1e no usa _JAVA_OPTIONS/JAVA_TOOL_OPTIONS (global a toda JVM del equipo)" \
     "afectaría a cualquier programa Java del mostrador, no solo a QZ"
else
  ok "W1e no usa _JAVA_OPTIONS/JAVA_TOOL_OPTIONS"
fi

# ---------------------------------------------------------------------------
# W2 — El desinstalador debe borrar EXACTAMENTE lo que el instalador crea.
#
# BUG REAL: el instalador crea el valor HKLM\...\Run 'QZ Tray Watchdog'
# (New-ItemProperty ... -Name 'QZ Tray Watchdog') pero win-cleanup.ps1 borraba
# 'QZ Tray' — un nombre que este script ya solo ELIMINA como residuo de v1. Tras
# desinstalar QZ, la entrada del watchdog sobrevivía y seguía intentando
# relanzar un QZ que ya no existe.
# ---------------------------------------------------------------------------
# Se afirma sobre el HECHO (el nombre aparece como valor a borrar), no sobre la
# forma: el cleanup puede borrarlo con -Name literal o iterando una lista.
if grep -vE '^\s*#' "$CLEANUP" | grep -qE "'QZ Tray Watchdog'" && grep -q 'Remove-ItemProperty' "$CLEANUP"; then
  ok "W2 el desinstalador borra la entrada Run 'QZ Tray Watchdog' que crea el instalador"
else
  ko "W2 el desinstalador borra la entrada Run 'QZ Tray Watchdog'" \
     "el instalador crea 'QZ Tray Watchdog' pero el cleanup solo borra 'QZ Tray': queda huérfana tras desinstalar"
fi

# ---------------------------------------------------------------------------
# W3 — Freno del bucle mata-relanza (caso C)
#
# BUG REAL: si el websocket NUNCA abre (puerto ocupado por otra app, firewall,
# o el usuario cambió los puertos en las prefs de QZ), el caso C mata y relanza.
# El relanzado resetea StartTime, así que a los 4 min vuelve a cumplirse la
# condición: mata-relanza CADA ~4-6 MINUTOS PARA SIEMPRE. No había contador,
# ni backoff, ni tope. Es exactamente el ciclo abrir-cerrar que se quería evitar.
# ---------------------------------------------------------------------------
if grep -vE '^\s*#' "$TARGET" | grep -qE 'Set-RestartState|Get-RestartState'; then
  ok "W3 el relanzado por zombi lleva freno (backoff/tope de reintentos)"
else
  ko "W3 el relanzado por zombi lleva freno (backoff/tope de reintentos)" \
     "sin freno, un websocket que nunca abre produce mata-relanza cada ~4 min indefinidamente"
fi

# W3b — el freno debe PERSISTIR entre pasadas: cada pasada del watchdog es un
# proceso PowerShell nuevo, así que un contador en memoria vale cero.
if grep -vE '^\s*#' "$TARGET" | grep -qE "stateFile = Join-Path"; then
  ok "W3b el freno persiste en disco (cada pasada es un proceso nuevo)"
else
  ko "W3b el freno persiste en disco" \
     "un contador en variable se pierde al terminar la pasada: no frena nada"
fi

# ---------------------------------------------------------------------------
# W4 — Nada de ventanas visibles en el mostrador.
#
# El watchdog se invoca con -WindowStyle Hidden (bien), pero Start-Qz llamaba a
# Start-Process SIN -WindowStyle Hidden. Aunque qz-tray.exe es GUI, el lanzador
# NSIS puede mostrar consola en la variante -console y, sobre todo, la propia
# invocación puede parpadear. Se exige explícito.
# ---------------------------------------------------------------------------
# -z: trata el fichero como una sola "línea" para que el test no dependa de si
# la invocación va en una línea o partida con backtick de continuación.
if grep -qzP 'Start-Process(?:(?!Start-Process)[\s\S]){0,300}?-WindowStyle Hidden' "$TARGET"; then
  ok "W4 Start-Qz lanza con -WindowStyle Hidden (sin parpadeo en el mostrador)"
else
  ko "W4 Start-Qz lanza con -WindowStyle Hidden" \
     "una ventana que aparece y desaparece cada 2 min es lo que más molesta en un mostrador"
fi

# W4b — el watchdog en sí (las 3 invocaciones) siempre oculto.
WD_HIDDEN=$(grep -cE '\-NoProfile -WindowStyle Hidden -EncodedCommand' "$TARGET")
if [ "${WD_HIDDEN:-0}" -ge 2 ]; then
  ok "W4b las invocaciones del watchdog son -WindowStyle Hidden ($WD_HIDDEN)"
else
  ko "W4b las invocaciones del watchdog son -WindowStyle Hidden" "encontradas: ${WD_HIDDEN:-0}"
fi

# ---------------------------------------------------------------------------
# W5 — La sonda de salud no puede fiarse de "el puerto habitual".
#
# Test-QzAlive daba por VIVO cualquier TCP que aceptara conexión en 8181..8485,
# aunque fuera otra aplicación (falso POSITIVO: QZ muerto declarado vivo, nadie
# lo relanza, el TPV no imprime). Y los puertos son configurables en las prefs
# de QZ (WebsocketPorts.java lee websocket.secure.ports / websocket.insecure.ports),
# así que la lista fija de 8 da falso NEGATIVO si el usuario los cambió.
# ---------------------------------------------------------------------------
if grep -vE '^\s*#' "$TARGET" | grep -qE 'OwningProcess'; then
  ok "W5 la sonda comprueba QUIÉN escucha el puerto, no solo que esté abierto"
else
  ko "W5 la sonda comprueba QUIÉN escucha el puerto" \
     "otro programa ocupando 8181 hace que un QZ muerto se declare vivo y nadie lo relance"
fi

if grep -vE '^\s*#' "$TARGET" | grep -qE 'websocket\\\.\(secure\|insecure\)\\\.ports|prefs\.properties'; then
  ok "W5b la sonda contempla los puertos configurados, no solo los 8 por defecto"
else
  ko "W5b la sonda contempla los puertos configurados" \
     "los puertos son configurables; con otra config la sonda declara zombi a un QZ sano y lo mata"
fi

# ---------------------------------------------------------------------------
# W9 — El escalonamiento entre capas debe ser REAL, no documental.
#
# BUG REAL: la cabecera describe la capa 3 (HKLM Run) como "+75s" y la capa 1
# (tarea ONLOGON) como "+45s", para que no se pisen. Pero el valor de Run se
# registraba SIN ninguna espera: disparaba en t=0, a la vez que el .lnk nativo.
# El escalonamiento existía solo en el comentario, y dos lanzamientos a la vez
# son la carrera de doble instancia que se quería evitar.
# ---------------------------------------------------------------------------
if grep -vE '^\s*#' "$TARGET" | grep -qE 'Start-Sleep -Seconds 75'; then
  ok "W9 la capa HKLM Run arranca con retardo real (+75s), no solo en el comentario"
else
  ko "W9 la capa HKLM Run arranca con retardo real (+75s)" \
     "el comentario promete +75s pero el valor de Run se ejecutaba en t=0, a la vez que el .lnk nativo"
fi

# W9b — la tarea ONLOGON debe conservar su retardo de 45s.
if grep -q '<Delay>PT45S</Delay>' "$TARGET"; then
  ok "W9b la tarea ONLOGON conserva su retardo de 45s"
else
  ko "W9b la tarea ONLOGON conserva su retardo de 45s" "sin él, tarea y .lnk nativo compiten en t=0"
fi

# ---------------------------------------------------------------------------
# W6 — Rotación de log acotada (720 pasadas/día escriben aquí)
# ---------------------------------------------------------------------------
if grep -vE '^\s*#' "$TARGET" | grep -qE 'Length -gt [0-9]+'; then
  ok "W6 el log del watchdog tiene tope de tamaño"
else
  ko "W6 el log del watchdog tiene tope de tamaño" "720 pasadas al día sin rotación llenan el disco"
fi

# ---------------------------------------------------------------------------
# W7 — Anti-bucle heredado: el gate .autostart debe seguir presente.
# (Regresión: si alguien lo quita, vuelve el bucle de e04a799.)
# ---------------------------------------------------------------------------
if grep -vE '^\s*#' "$TARGET" | grep -q 'Test-QzAutostartWanted' && grep -vE '^\s*#' "$TARGET" | grep -q 'honorautostart'; then
  ok "W7 el gate .autostart y --honorautostart siguen en su sitio"
else
  ko "W7 el gate .autostart y --honorautostart siguen en su sitio" "es el anti-bucle heredado del incidente de Linux"
fi

# ---------------------------------------------------------------------------
# W8 — El mutex global no puede quedarse tomado para siempre.
#
# Si una pasada muere de forma anómala sin liberar el mutex, TODAS las pasadas
# siguientes salen por `exit 0` y el watchdog queda mudo: QZ podría estar caído
# y nadie lo relanzaría. Con WaitOne(0) el riesgo es real; se exige que el
# abandono del mutex se trate (AbandonedMutexException) en vez de propagarse.
# ---------------------------------------------------------------------------
if grep -vE '^\s*#' "$TARGET" | grep -q 'AbandonedMutexException'; then
  ok "W8 se contempla el mutex abandonado (una pasada muerta no deja al watchdog mudo)"
else
  ko "W8 se contempla el mutex abandonado" \
     "WaitOne sobre un mutex abandonado lanza excepción; sin tratarla el watchdog puede quedar inoperante"
fi

echo
echo "== Resultado: $PASS pasados, $FAIL fallidos =="
echo
echo "NOTA: estos tests son ESTÁTICOS (no ejecutan PowerShell). Lo verificable"
echo "      solo en Windows real está en test/win-autostart.Tests.ps1 y en"
echo "      test/MEDICION-WINDOWS.md. Verde aquí NO significa validado en Windows."
[ "$FAIL" -eq 0 ]
