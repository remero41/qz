#!/usr/bin/env bash
# Tests de provision-src/linux-autostart.sh
#
# Ejecuta el script contra un HOME de mentira y afirma sobre la unidad systemd
# generada. No necesita root, no toca el systemd real ni el ~ real: todo lo que
# el script invoca del sistema (systemctl, loginctl, runuser, chown, sudo) se
# stubbea via PATH.
#
# Uso:  bash test/test-linux-autostart.sh
# Salida: 0 si todo pasa; 1 al primer fallo (con diff util).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_DIR/provision-src/linux-autostart.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[1;32mPASS\033[0m %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# ---------------------------------------------------------------------------
# Arnés: entorno de mentira aislado.
#
# El script hardcodea QZ_BIN=/opt/qz-tray/qz-tray y sale (exit 0) si no es
# ejecutable, así que sin poder inyectar esa ruta el script es INTESTEABLE.
# El fix lo hace sobreescribible por entorno; el arnés depende de ello.
# ---------------------------------------------------------------------------
new_sandbox() {
  SANDBOX="$(mktemp -d)"
  export SANDBOX

  mkdir -p "$SANDBOX/home/tester" "$SANDBOX/bin" "$SANDBOX/opt"

  # Stub del binario de QZ (supera el guard de existencia).
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/opt/qz-tray"
  chmod +x "$SANDBOX/opt/qz-tray"

  # Stub del qz-tray.properties (el script lo edita con sed).
  printf 'security.print.tofile=false\n' > "$SANDBOX/opt/qz-tray.properties"

  # Stubs de comandos del sistema: no deben tocar nada real.
  for cmd in systemctl loginctl runuser chown; do
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$cmd"
    chmod +x "$SANDBOX/bin/$cmd"
  done
  # getent debe resolver el HOME falso del usuario de prueba.
  cat > "$SANDBOX/bin/getent" <<GETENT
#!/bin/sh
[ "\$1" = passwd ] && echo "tester:x:1000:1000::$SANDBOX/home/tester:/bin/bash"
exit 0
GETENT
  chmod +x "$SANDBOX/bin/getent"

  UNIT="$SANDBOX/home/tester/.config/systemd/user/qz-tray.service"
}

# Invoca el script contra el sandbox ACTUAL. Separado de new_sandbox porque T5
# (idempotencia) necesita ejecutar dos veces sobre el MISMO sandbox: si cada
# ejecución montara uno nuevo, la ruta de mktemp -d se colaría en el ExecStart
# (via QZ_BIN) y las unidades diferirían por el arnés, no por el script.
invoke_script() {
  QZ_BIN="$SANDBOX/opt/qz-tray" \
  QZ_PROPS="$SANDBOX/opt/qz-tray.properties" \
  SUDO_USER=tester \
  USER=tester \
  PATH="$SANDBOX/bin:$PATH" \
    bash "$TARGET" > "$SANDBOX/stdout.txt" 2> "$SANDBOX/stderr.txt"
  RC=$?
  return $RC
}

# Sandbox limpio + una ejecución (el caso normal de casi todos los tests).
run_script() { new_sandbox; invoke_script; }

cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

echo "== Tests de linux-autostart.sh =="
echo

# --- T0: el script corre y genera la unidad (precondición del resto) --------
run_script
if [ $RC -ne 0 ]; then
  ko "T0 el script termina con éxito" "rc=$RC; stderr: $(cat "$SANDBOX/stderr.txt")"
elif [ ! -f "$UNIT" ]; then
  ko "T0 genera la unidad systemd" "no existe $UNIT — ¿QZ_BIN no es inyectable?"
else
  ok "T0 el script corre y genera la unidad"
fi

# Si no hay unidad, el resto no tiene sentido.
if [ ! -f "$UNIT" ]; then
  echo; echo "ABORTADO: sin unidad generada no se puede afirmar nada más."
  exit 1
fi

# --- T1 (D2): la unidad exporta el entorno gráfico -------------------------
# Se afirma sobre la PRESENCIA de la variable, no sobre un valor concreto,
# para no atar el test a la estrategia (fija vs dinámica).
# Ojo: '^Environment=.*DISPLAY' hace match con WAYLAND_DISPLAY (contiene la
# subcadena), asi que T1 pasaba aunque se borrara DISPLAY. Se ancla al nombre
# exacto de la variable.
if grep -qE '^Environment=DISPLAY=' "$UNIT"; then
  ok "T1 la unidad exporta DISPLAY"
else
  ko "T1 la unidad exporta DISPLAY" "sin DISPLAY, AWT no conecta al servidor gráfico y no hay icono"
fi

if grep -qE '^Environment=WAYLAND_DISPLAY=' "$UNIT"; then
  ok "T1b la unidad exporta WAYLAND_DISPLAY"
else
  ko "T1b la unidad exporta WAYLAND_DISPLAY" "necesario en sesiones Wayland (KDE)"
fi

# --- T1c: el DISPLAY se DERIVA del equipo, no está hardcodeado -------------
# Un DISPLAY equivocado es un fallo SILENCIOSO: QZ arranca, pero sin icono.
# El stub de ps finge un Xwayland del usuario en :7 (valor imposible de acertar
# por casualidad): si la unidad sale con :7, el script lo preguntó de verdad.
new_sandbox
cat > "$SANDBOX/bin/ps" <<'PS'
#!/bin/sh
echo "/usr/bin/Xwayland :7 -rootless"
PS
chmod +x "$SANDBOX/bin/ps"
invoke_script >/dev/null 2>&1   # invoke_, NO run_: run_script remonta el sandbox y borraría el stub
if grep -qE '^Environment=DISPLAY=:7$' "$UNIT"; then
  ok "T1c el DISPLAY se deriva del equipo (no hardcodeado)"
else
  ko "T1c el DISPLAY se deriva del equipo (no hardcodeado)" \
     "unidad trae: $(grep -E '^Environment=DISPLAY=' "$UNIT" 2>/dev/null || echo '(nada)') — en un equipo con otro display no habría icono"
fi

# --- T1c2: REGRESIÓN medida en kaz -----------------------------------------
# Coexisten X0 (Xorg del greeter SDDM, de ROOT, socket residual) y X1 (el
# Xwayland de la sesión real). Elegir "el socket de menor número" da :0, que
# está muerto para el usuario: el icono no aparecería justo en el equipo donde
# se midió el fix. Solo cuenta el servidor X DEL USUARIO OBJETIVO.
new_sandbox
mkdir -p "$SANDBOX/x11"; : > "$SANDBOX/x11/X0"; : > "$SANDBOX/x11/X1"
cat > "$SANDBOX/bin/ps" <<'PS'
#!/bin/sh
# 'ps -u tester' solo ve los procesos del usuario: el Xorg de root NO sale.
echo "/usr/bin/Xwayland :1 -rootless -wm 76"
PS
chmod +x "$SANDBOX/bin/ps"
invoke_script >/dev/null 2>&1
if grep -qE '^Environment=DISPLAY=:1$' "$UNIT"; then
  ok "T1c2 ignora el X0 residual del greeter y coge el display del usuario"
else
  ko "T1c2 ignora el X0 residual del greeter y coge el display del usuario" \
     "unidad trae: $(grep -E '^Environment=DISPLAY=' "$UNIT" 2>/dev/null || echo '(nada)') — se esperaba :1"
fi

# --- T1d: sin servidor X detectable, cae a un DISPLAY válido (nunca vacío) --
# Environment=DISPLAY= (vacío) es peor que no ponerlo: AWT falla igual y el
# test de presencia T1 pasaría en falso.
new_sandbox
# ps mudo A PROPÓSITO: sin stub heredaríamos el ps real de la máquina de test
# y T1d pasaría por la razón equivocada (viendo el Xwayland de quien lo lanza).
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/ps"; chmod +x "$SANDBOX/bin/ps"
invoke_script >/dev/null 2>&1
if grep -qE '^Environment=DISPLAY=:[0-9]+$' "$UNIT"; then
  ok "T1d fallback a un DISPLAY concreto cuando no se detecta servidor X"
else
  ko "T1d fallback a un DISPLAY concreto cuando no se detecta servidor X" \
     "unidad trae: $(grep -E '^Environment=DISPLAY=' "$UNIT" 2>/dev/null || echo '(nada)')"
fi

# --- T2 (D1/D3): techo de heap ---------------------------------------------
if grep -qE '^Environment="?QZ_OPTS=.*-Xmx' "$UNIT"; then
  ok "T2 la unidad fija techo de heap (-Xmx)"
else
  ko "T2 la unidad fija techo de heap (-Xmx)" "sin -Xmx la JVM usa 1/4 de la RAM (3,9 GB en 15,7 GB)"
fi

if grep -qE '^Environment="?QZ_OPTS=.*UseSerialGC' "$UNIT"; then
  ok "T2b la unidad selecciona SerialGC"
else
  ko "T2b la unidad selecciona SerialGC" "G1 no devuelve memoria al SO en una app inactiva"
fi

# --- T2c: systemd debe ENTENDER el valor entero, no solo que esté en el fichero.
# Un Environment= con espacios SIN comillas se parte por espacios y systemd
# descarta los trozos que no son 'K=V', dejando QZ_OPTS con solo el primer flag.
# T2/T2b hacen grep sobre el FICHERO y no ven eso; esto sí.
if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify "$UNIT" 2>&1 | grep -qi 'Invalid environment assignment'; then
    ko "T2c systemd acepta QZ_OPTS entero" \
       "$(systemd-analyze verify "$UNIT" 2>&1 | grep -i 'Invalid environment assignment' | head -2 | tr '\n' ' ')"
  else
    ok "T2c systemd acepta QZ_OPTS entero (sin asignaciones descartadas)"
  fi
else
  echo "  SKIP T2c systemd-analyze no disponible"
fi

# --- T3: se preserva el arranque sin sesión gráfica (linger) ---------------
# DECISIÓN 2026-08-05: prevalece "QZ nunca falta". La unidad NO debe depender
# de graphical-session.target, y el linger debe seguir activándose.
if grep -q '^WantedBy=default.target' "$UNIT"; then
  ok "T3 la unidad arranca sin sesión gráfica (default.target)"
else
  ko "T3 la unidad arranca sin sesión gráfica (default.target)" "se rompería el arranque al encender el PC"
fi

if grep -q 'enable-linger' "$TARGET"; then
  ok "T3b el script mantiene enable-linger"
else
  ko "T3b el script mantiene enable-linger" "sin linger QZ no arranca hasta iniciar sesión"
fi

# --- T4 (D5): no queda rastro de la variable inexistente $QZ_PREFS ---------
if grep -q 'QZ_PREFS' "$TARGET"; then
  ko "T4 sin referencias a \$QZ_PREFS (variable inexistente)" "línea con ruta vacía en el log de instalación"
else
  ok "T4 sin referencias a \$QZ_PREFS"
fi

# El síntoma observable: ninguna línea de salida acaba en "en " (ruta vacía).
if grep -qE 'escrito en $' "$SANDBOX/stdout.txt"; then
  ko "T4b ninguna traza imprime ruta vacía" "$(grep -nE 'escrito en $' "$SANDBOX/stdout.txt" | head -1)"
else
  ok "T4b ninguna traza imprime ruta vacía"
fi

# --- T5: idempotencia -------------------------------------------------------
# Ejecutar dos veces debe dar exactamente la misma unidad (sin acumular
# Environment= duplicados).
FIRST="$(cat "$UNIT")"
invoke_script   # 2ª pasada sobre la MISMA instalación (reinstalar encima)
SECOND="$(cat "$UNIT" 2>/dev/null)"
if [ "$FIRST" = "$SECOND" ]; then
  ok "T5 idempotente (dos ejecuciones → misma unidad)"
else
  ko "T5 idempotente" "la unidad difiere entre ejecuciones"
fi

# Nota: `grep -c ... || echo 0` sin -f devolvía "0\n0" (grep imprime su 0 y el
# `|| echo 0` añade otro), y el `[ -le ]` reventaba con "se esperaba entero".
DUPES="$(grep -c '^Environment=QZ_OPTS' "$UNIT" 2>/dev/null | head -1)"
DUPES="${DUPES:-0}"
if [ "$DUPES" -le 1 ]; then
  ok "T5b sin Environment=QZ_OPTS duplicados"
else
  ko "T5b sin Environment=QZ_OPTS duplicados" "aparece $DUPES veces"
fi

# --- T6: la unidad es sintácticamente válida para systemd ------------------
if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify "$UNIT" >/dev/null 2>&1; then
    ok "T6 systemd-analyze verify"
  else
    # verify se queja de dependencias ausentes en un sandbox; solo importan
    # los errores de sintaxis del propio fichero.
    if systemd-analyze verify "$UNIT" 2>&1 | grep -qiE 'invalid|unknown (lvalue|section)|syntax'; then
      ko "T6 systemd-analyze verify" "$(systemd-analyze verify "$UNIT" 2>&1 | head -3)"
    else
      ok "T6 systemd-analyze verify (solo avisos de entorno)"
    fi
  fi
else
  echo "  SKIP systemd-analyze no disponible"
fi

echo
echo "== Resultado: $PASS pasados, $FAIL fallidos =="
[ "$FAIL" -eq 0 ]
