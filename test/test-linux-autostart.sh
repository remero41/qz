#!/usr/bin/env bash
# Tests de provision-src/linux-autostart.sh
#
# Ejecuta el script contra un HOME de mentira y afirma sobre la unidad systemd
# y el wrapper de guard generados. No necesita root, no toca el systemd real ni
# el ~ real: todo lo que el script invoca del sistema (systemctl, loginctl,
# runuser, chown, usermod, id, getent, logname) se stubbea via PATH.
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

  mkdir -p "$SANDBOX/home/tester" "$SANDBOX/bin" "$SANDBOX/opt" "$SANDBOX/xdg-autostart"

  # Stub del binario de QZ (supera el guard de existencia). Registra cada
  # lanzamiento con su entorno gráfico: los tests del wrapper afirman sobre él.
  cat > "$SANDBOX/opt/qz-tray" <<STUB
#!/bin/sh
echo "launched DISPLAY=\${DISPLAY:-} WAYLAND=\${WAYLAND_DISPLAY:-} args=\$*" >> "$SANDBOX/launched.txt"
exit 0
STUB
  chmod +x "$SANDBOX/opt/qz-tray"

  # Stub del qz-tray.properties (el script lo edita con sed).
  printf 'security.print.tofile=false\n' > "$SANDBOX/opt/qz-tray.properties"

  # .desktop de autostart de SISTEMA como lo deja addStartupEntry() de QZ
  # (con la doble barra real de /opt//qz-tray incluida).
  cat > "$SANDBOX/xdg-autostart/qz-tray.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=QZ Tray
Exec="/opt//qz-tray/qz-tray" --honorautostart
Terminal=false
DESK

  # Stubs de comandos del sistema: no deben tocar nada real.
  for cmd in systemctl loginctl runuser chown; do
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$cmd"
    chmod +x "$SANDBOX/bin/$cmd"
  done
  # logname falla a propósito: fuerza a los tests de derivación de usuario a
  # pasar por loginctl, y al resto los deja en SUDO_USER (la vía normal).
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/logname"; chmod +x "$SANDBOX/bin/logname"
  # usermod registra la llamada (el sandbox no tiene root ni usuario real).
  cat > "$SANDBOX/bin/usermod" <<USERMOD
#!/bin/sh
echo "\$@" >> "$SANDBOX/usermod.log"
exit 0
USERMOD
  chmod +x "$SANDBOX/bin/usermod"
  # id: -nG sin 'lp' (obliga al script a llamar a usermod); -un para el wrapper.
  cat > "$SANDBOX/bin/id" <<'ID'
#!/bin/sh
case "${1:-}" in
  -nG) echo "tester users" ;;
  -un) echo "tester" ;;
  *)   echo "tester" ;;
esac
exit 0
ID
  chmod +x "$SANDBOX/bin/id"
  # getent resuelve el HOME falso y el grupo lp.
  cat > "$SANDBOX/bin/getent" <<GETENT
#!/bin/sh
[ "\$1" = passwd ] && echo "tester:x:1000:1000::$SANDBOX/home/tester:/bin/bash"
[ "\$1" = group ]  && echo "lp:x:7:"
exit 0
GETENT
  chmod +x "$SANDBOX/bin/getent"

  UNIT="$SANDBOX/home/tester/.config/systemd/user/qz-tray.service"
  WRAPPER="$SANDBOX/opt/qz-tray-session.sh"
}

# Invoca el script contra el sandbox ACTUAL. Separado de new_sandbox porque T5
# (idempotencia) necesita ejecutar dos veces sobre el MISMO sandbox: si cada
# ejecución montara uno nuevo, la ruta de mktemp -d se colaría en el ExecStart
# (via QZ_BIN) y las unidades diferirían por el arnés, no por el script.
invoke_script() {
  QZ_BIN="$SANDBOX/opt/qz-tray" \
  QZ_PROPS="$SANDBOX/opt/qz-tray.properties" \
  QZ_SYS_AUTOSTART="$SANDBOX/xdg-autostart/qz-tray.desktop" \
  SUDO_USER=tester \
  USER=tester \
  PATH="$SANDBOX/bin:$PATH" \
    bash "$TARGET" > "$SANDBOX/stdout.txt" 2> "$SANDBOX/stderr.txt"
  RC=$?
  return $RC
}

# Ejecuta el WRAPPER generado, sin entorno gráfico heredado y sin esperas.
# $1..$n: pares VAR=VAL extra (p.ej. DISPLAY=:5).
invoke_wrapper() {
  rm -f "$SANDBOX/launched.txt"
  env -u DISPLAY -u WAYLAND_DISPLAY "$@" \
    QZ_SESSION_WAIT=0 \
    PATH="$SANDBOX/bin:$PATH" \
    bash "$WRAPPER" > "$SANDBOX/wrapper-out.txt" 2>&1
  WRC=$?
  return $WRC
}

# Sandbox limpio + una ejecución (el caso normal de casi todos los tests).
run_script() { new_sandbox; invoke_script; }

cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

echo "== Tests de linux-autostart.sh =="
echo

# --- T0: el script corre y genera unidad + wrapper (precondición del resto) --
run_script
if [ $RC -ne 0 ]; then
  ko "T0 el script termina con éxito" "rc=$RC; stderr: $(cat "$SANDBOX/stderr.txt")"
elif [ ! -f "$UNIT" ]; then
  ko "T0 genera la unidad systemd" "no existe $UNIT — ¿QZ_BIN no es inyectable?"
elif [ ! -x "$WRAPPER" ]; then
  ko "T0 genera el wrapper de guard ejecutable" "no existe (o no es ejecutable) $WRAPPER"
else
  ok "T0 el script corre y genera unidad + wrapper"
fi

# Si no hay unidad, el resto no tiene sentido.
if [ ! -f "$UNIT" ]; then
  echo; echo "ABORTADO: sin unidad generada no se puede afirmar nada más."
  exit 1
fi

# --- T1: la unidad NO hardcodea el entorno gráfico ---------------------------
# DECISIÓN 2026-08-10 (medida en kim): el DISPLAY se resuelve en RUNTIME (el
# wrapper). Un Environment=DISPLAY fijado en INSTALACIÓN pisa al de la sesión
# real (systemd da prioridad a Environment= sobre el entorno del manager) y no
# cubre Wayland ni cambios de display entre arranques.
if grep -qE '^Environment=DISPLAY=' "$UNIT"; then
  ko "T1 la unidad no hardcodea DISPLAY" "un DISPLAY de instalación pisa el de la sesión real"
else
  ok "T1 la unidad no hardcodea DISPLAY (lo deriva el wrapper en runtime)"
fi

if grep -qE '^Environment=WAYLAND_DISPLAY=' "$UNIT"; then
  ko "T1b la unidad no hardcodea WAYLAND_DISPLAY" "el wrapper lo deriva del socket en runtime"
else
  ok "T1b la unidad no hardcodea WAYLAND_DISPLAY"
fi

if grep -qE "^ExecStart=.*qz-tray-session\.sh$" "$UNIT"; then
  ok "T1c ExecStart pasa por el wrapper de guard"
else
  ko "T1c ExecStart pasa por el wrapper de guard" "ExecStart actual: $(grep '^ExecStart=' "$UNIT" || echo '(nada)')"
fi

# --- T1d: GUARD — sin sesión gráfica NO se lanza QZ y se sale LIMPIO ---------
# La instancia fantasma de kim (10-08): sin DISPLAY, QZ corre sin icono y sin
# atender al navegador pero OCUPA el 8181. El wrapper debe negarse (exit 0,
# para que Restart=on-failure no relance en bucle).
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/ps"; chmod +x "$SANDBOX/bin/ps"  # ps mudo: no hay servidor X
invoke_wrapper
if [ $WRC -ne 0 ]; then
  ko "T1d sin sesión gráfica el wrapper sale LIMPIO (exit 0)" "rc=$WRC — on-failure lo relanzaría en bucle"
elif [ -f "$SANDBOX/launched.txt" ]; then
  ko "T1d sin sesión gráfica NO se lanza QZ" "se lanzó: $(cat "$SANDBOX/launched.txt")"
else
  ok "T1d sin sesión gráfica: no se lanza QZ y exit 0 (8181 libre)"
fi

# --- T1e: el DISPLAY se DERIVA en runtime del servidor X del usuario ---------
# El stub de ps finge un Xwayland del usuario en :7 (valor imposible de acertar
# por casualidad): si QZ recibe :7, el wrapper lo preguntó de verdad.
cat > "$SANDBOX/bin/ps" <<'PS'
#!/bin/sh
echo "/usr/bin/Xwayland :7 -rootless"
PS
chmod +x "$SANDBOX/bin/ps"
invoke_wrapper
if grep -q 'launched DISPLAY=:7' "$SANDBOX/launched.txt" 2>/dev/null; then
  ok "T1e el wrapper deriva el DISPLAY en runtime (no hardcodeado)"
else
  ko "T1e el wrapper deriva el DISPLAY en runtime" "launched: $(cat "$SANDBOX/launched.txt" 2>/dev/null || echo '(nada)')"
fi

# --- T1e2: REGRESIÓN medida en kaz ------------------------------------------
# Coexisten X0 (Xorg del greeter SDDM, de ROOT, socket residual) y X1 (el
# Xwayland de la sesión real). 'ps -u tester' solo ve los procesos del usuario:
# el Xorg de root NO sale, así que el wrapper debe coger :1, nunca :0.
cat > "$SANDBOX/bin/ps" <<'PS'
#!/bin/sh
echo "/usr/bin/Xwayland :1 -rootless -wm 76"
PS
chmod +x "$SANDBOX/bin/ps"
invoke_wrapper
if grep -q 'launched DISPLAY=:1' "$SANDBOX/launched.txt" 2>/dev/null; then
  ok "T1e2 ignora el X0 residual del greeter y coge el display del usuario"
else
  ko "T1e2 ignora el X0 residual del greeter y coge el display del usuario" \
     "launched: $(cat "$SANDBOX/launched.txt" 2>/dev/null || echo '(nada)') — se esperaba :1"
fi

# --- T1f: si la sesión YA trae DISPLAY, el wrapper lo respeta ----------------
# (KDE/GNOME importan DISPLAY al user manager; derivar por encima sería pisarlo)
invoke_wrapper DISPLAY=:42
if grep -q 'launched DISPLAY=:42' "$SANDBOX/launched.txt" 2>/dev/null; then
  ok "T1f respeta el DISPLAY que ya trae el entorno de la sesión"
else
  ko "T1f respeta el DISPLAY que ya trae el entorno de la sesión" \
     "launched: $(cat "$SANDBOX/launched.txt" 2>/dev/null || echo '(nada)')"
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

# --- T3: la unidad vive y muere CON la sesión gráfica ------------------------
# DECISIÓN 2026-08-10 (invierte la del 2026-08-05 "QZ nunca falta"): la medición
# en vivo en kim demostró que la instancia de default.target+linger arranca SIN
# sesión gráfica, no muestra icono, no atiende al navegador… y SECUESTRA el
# 8181, bloqueando a la instancia buena. "Nunca falta" producía justo lo
# contrario: QZ nunca FUNCIONA tras reiniciar. QZ solo debe arrancar dentro de
# una sesión gráfica viva.
if grep -q '^WantedBy=graphical-session.target' "$UNIT"; then
  ok "T3 la unidad arranca con la sesión gráfica (WantedBy=graphical-session.target)"
else
  ko "T3 la unidad arranca con la sesión gráfica" "WantedBy actual: $(grep '^WantedBy=' "$UNIT" || echo '(nada)')"
fi

if grep -q '^WantedBy=default.target' "$UNIT"; then
  ko "T3b la unidad NO cuelga de default.target" "con linger, default.target arranca QZ al boot sin sesión (instancia fantasma de kim)"
else
  ok "T3b la unidad no cuelga de default.target"
fi

if grep -q '^PartOf=graphical-session.target' "$UNIT"; then
  ok "T3c PartOf: al cerrar la sesión gráfica QZ se para (suelta el 8181)"
else
  ko "T3c PartOf: al cerrar la sesión gráfica QZ se para" "sin PartOf, QZ sobrevive al logout ocupando el puerto"
fi

if grep -q 'enable-linger' "$TARGET"; then
  ko "T3d el script no activa linger" "linger era la causa raíz de la instancia fantasma al boot"
else
  ok "T3d el script no activa linger"
fi

if grep -q 'disable-linger' "$TARGET"; then
  ok "T3e migración: desactiva el linger que activó la versión anterior"
else
  ko "T3e migración: desactiva el linger que activó la versión anterior" "las instalaciones previas seguirían arrancando al boot"
fi

# --- T3f: migración del enable viejo + enable manual del nuevo ---------------
# Instalaciones previas dejaron default.target.wants/qz-tray.service: si
# sobrevive, QZ sigue arrancando fuera de sesión aunque la unidad nueva esté
# bien. Y el enable del nuevo no puede depender del bus (puede no haber sesión
# durante la instalación): symlink manual.
new_sandbox
OLD_WANTS="$SANDBOX/home/tester/.config/systemd/user/default.target.wants"
mkdir -p "$OLD_WANTS"
ln -s ../qz-tray.service "$OLD_WANTS/qz-tray.service"
invoke_script
NEW_WANTS="$SANDBOX/home/tester/.config/systemd/user/graphical-session.target.wants/qz-tray.service"
if [ -e "$OLD_WANTS/qz-tray.service" ] || [ -L "$OLD_WANTS/qz-tray.service" ]; then
  ko "T3f borra el enable viejo de default.target.wants" "sigue existiendo: QZ arrancaría al boot sin sesión"
elif [ ! -L "$NEW_WANTS" ]; then
  ko "T3f crea el enable nuevo en graphical-session.target.wants" "no existe el symlink $NEW_WANTS"
else
  ok "T3f migración de enable: default.target.wants → graphical-session.target.wants"
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
# Environment= duplicados) y el mismo .desktop de sistema (sin apilar
# Hidden=true una y otra vez).
FIRST="$(cat "$UNIT")"
FIRST_SYS="$(cat "$SANDBOX/xdg-autostart/qz-tray.desktop")"
invoke_script   # 2ª pasada sobre la MISMA instalación (reinstalar encima)
SECOND="$(cat "$UNIT" 2>/dev/null)"
SECOND_SYS="$(cat "$SANDBOX/xdg-autostart/qz-tray.desktop" 2>/dev/null)"
if [ "$FIRST" = "$SECOND" ]; then
  ok "T5 idempotente (dos ejecuciones → misma unidad)"
else
  ko "T5 idempotente" "la unidad difiere entre ejecuciones"
fi
if [ "$FIRST_SYS" = "$SECOND_SYS" ]; then
  ok "T5b idempotente el .desktop de sistema (no apila Hidden=true)"
else
  ko "T5b idempotente el .desktop de sistema" "difiere entre ejecuciones"
fi

# Nota: `grep -c ... || echo 0` sin -f devolvía "0\n0" (grep imprime su 0 y el
# `|| echo 0` añade otro), y el `[ -le ]` reventaba con "se esperaba entero".
DUPES="$(grep -c '^Environment=QZ_OPTS' "$UNIT" 2>/dev/null | head -1)"
DUPES="${DUPES:-0}"
if [ "$DUPES" -le 1 ]; then
  ok "T5c sin Environment=QZ_OPTS duplicados"
else
  ko "T5c sin Environment=QZ_OPTS duplicados" "aparece $DUPES veces"
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

# --- T7: grupo lp (USB directo /dev/usb/lpN, medido en kim) ------------------
# El arnés finge que tester NO está en lp: el script debe llamar a usermod -aG
# lp tester y avisar de que hace falta relogin.
run_script
if grep -q '\-aG lp tester' "$SANDBOX/usermod.log" 2>/dev/null; then
  ok "T7 añade el usuario real al grupo lp"
else
  ko "T7 añade el usuario real al grupo lp" "usermod.log: $(cat "$SANDBOX/usermod.log" 2>/dev/null || echo '(vacío)') — sin lp, /dev/usb/lpN da Permiso denegado"
fi
if grep -qiE 'sesión' "$SANDBOX/stdout.txt" && grep -qi 'lp' "$SANDBOX/stdout.txt"; then
  ok "T7b avisa de que el grupo lp exige reiniciar sesión"
else
  ko "T7b avisa de que el grupo lp exige reiniciar sesión" "sin aviso, el operador no sabe por qué sigue fallando"
fi

# --- T8: doble autostart — neutraliza el .desktop de SISTEMA -----------------
# addStartupEntry() de QZ recrea /etc/xdg/autostart/qz-tray.desktop en cada
# install; si queda activo es el 2º lanzador (2 iconos medidos en kim).
if grep -q '^Hidden=true' "$SANDBOX/xdg-autostart/qz-tray.desktop"; then
  ok "T8 el .desktop de sistema queda neutralizado (Hidden=true)"
else
  ko "T8 el .desktop de sistema queda neutralizado (Hidden=true)" \
     "$(cat "$SANDBOX/xdg-autostart/qz-tray.desktop")"
fi

# … y el override del usuario sigue existiendo (cinturón y tirantes: QZ lo
# borra en cada reinstalación con removeLegacyStartup y aquí debe renacer).
OVERRIDE="$SANDBOX/home/tester/.config/autostart/qz-tray.desktop"
if [ -f "$OVERRIDE" ] && grep -q '^Hidden=true' "$OVERRIDE"; then
  ok "T8b el override de usuario existe y oculta el autostart"
else
  ko "T8b el override de usuario existe y oculta el autostart" "no existe o no trae Hidden=true"
fi

# --- T9: usuario objetivo sin SUDO_USER (instalación gráfica pkexec/kdesu) ---
# Sin SUDO_USER (y logname roto), el script debe caer a loginctl y aprovisionar
# al usuario de la sesión gráfica, NUNCA a root (antes acababa en /root y el
# usuario real se quedaba sin servicio ni override → doble instancia).
new_sandbox
cat > "$SANDBOX/bin/loginctl" <<'LOGINCTL'
#!/bin/sh
if [ "${1:-}" = "list-sessions" ]; then
  echo "     3 1000 tester seat0 tty2"
fi
exit 0
LOGINCTL
chmod +x "$SANDBOX/bin/loginctl"
QZ_BIN="$SANDBOX/opt/qz-tray" \
QZ_PROPS="$SANDBOX/opt/qz-tray.properties" \
QZ_SYS_AUTOSTART="$SANDBOX/xdg-autostart/qz-tray.desktop" \
SUDO_USER= \
USER=root \
PATH="$SANDBOX/bin:$PATH" \
  bash "$TARGET" > "$SANDBOX/stdout.txt" 2> "$SANDBOX/stderr.txt"
if [ -f "$UNIT" ]; then
  ok "T9 sin SUDO_USER deriva el usuario de la sesión gráfica (loginctl)"
else
  ko "T9 sin SUDO_USER deriva el usuario de la sesión gráfica (loginctl)" \
     "la unidad no acabó en el HOME de tester; stdout: $(tail -2 "$SANDBOX/stdout.txt" 2>/dev/null | tr '\n' ' ')"
fi

echo
echo "== Resultado: $PASS pasados, $FAIL fallidos =="
[ "$FAIL" -eq 0 ]
