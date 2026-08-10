#!/usr/bin/env bash
# linux-autostart.sh — arranque blindado de QZ Tray en Linux.
#
# QZ ya instala un autostart .desktop (arranca al iniciar sesión gráfica). Este
# script instala UN servicio systemd de usuario que RELANZA QZ si CRASHEA, y —
# clave — NEUTRALIZA los autostart .desktop (el del usuario Y el de sistema)
# para que no haya DOS instancias peleándose (QZ mata la 2ª por "single
# instance" y systemd la relanzaría en bucle). El servicio pasa a ser el ÚNICO
# mecanismo de arranque.
#
# REGLA DE ORO (medida en vivo en kim, 2026-08-10): QZ solo arranca DENTRO de
# una sesión gráfica viva. Una instancia sin sesión gráfica no muestra icono NI
# atiende al navegador, pero SÍ ocupa el 8181 y bloquea a cualquier instancia
# posterior ("Necesitas QZ" + qz:launch que no puede bindear). Por eso:
#   - la unidad se engancha a graphical-session.target (After+PartOf+WantedBy),
#     NUNCA a default.target;
#   - NO se activa linger (era justo lo que arrancaba QZ al boot sin sesión);
#   - un wrapper de guard se niega a lanzar QZ si no hay DISPLAY derivable.
#
# Restart=on-failure (NO on-success): cuando QZ se cierra limpio (p.ej. lo cierras
# tú, detecta duplicado y sale con código 0, o el guard no ve sesión gráfica)
# el servicio NO lo relanza. Solo revive ante crash real. Idempotente.

set -e

# Sobreescribibles por entorno SOLO para poder testear el script contra un
# sandbox (test/test-linux-autostart.sh). En instalación real nadie las define,
# así que se comportan igual que las rutas fijas de siempre.
QZ_BIN="${QZ_BIN:-/opt/qz-tray/qz-tray}"
if [ ! -x "$QZ_BIN" ]; then
  echo "qz-tray no encontrado en $QZ_BIN; omitiendo servicio systemd."
  exit 0
fi

# --- 0) Permitir impresion directa a device path (USB directo por {file}) ---
# El USB directo en Linux imprime a /dev/usb/lpN via {file}, que QZ BLOQUEA por
# defecto (security.print.tofile=false → "Printing to file is not permitted").
# Se escribe en el qz-tray.properties de SISTEMA, que es el UNICO que QZ lee para
# esta property (CertificateManager.loadProperties → SOLO qz-tray.properties, nunca
# prefs.properties). QZ regenera ese fichero al arrancar, PERO el parche añadio
# 'security.print.tofile' a PERSIST_PROPS (Constants.java), asi que ahora QZ la
# PRESERVA entre arranques. Idempotente.
QZ_PROPS="${QZ_PROPS:-/opt/qz-tray/qz-tray.properties}"
if [ -f "$QZ_PROPS" ]; then
  if grep -q '^security.print.tofile=' "$QZ_PROPS" 2>/dev/null; then
    sed -i 's/^security.print.tofile=.*/security.print.tofile=true/' "$QZ_PROPS"
  else
    printf 'security.print.tofile=true\n' >> "$QZ_PROPS"
  fi
  echo "security.print.tofile=true escrito en $QZ_PROPS (USB directo por device path habilitado)."
fi

# --- Usuario objetivo -------------------------------------------------------
# El que instala de verdad, no root. SUDO_USER solo existe si se instaló con
# `sudo` desde terminal; una instalación gráfica (pkexec/kdesu, medible en kim)
# no lo define y ANTES este script acababa aprovisionando /root en silencio:
# ni override de autostart ni servicio para el usuario real → doble instancia.
# Cadena de derivación: SUDO_USER → logname → sesión gráfica de loginctl.
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  TARGET_USER="$(logname 2>/dev/null || true)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  TARGET_USER="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -vx root | head -1)"
fi
[ -z "$TARGET_USER" ] && TARGET_USER="$USER"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ]; then
  echo "No se pudo resolver el HOME de $TARGET_USER; omitiendo."
  exit 0
fi

# --- 1) Neutralizar el autostart .desktop del USUARIO (evita duplicado) -----
# Se enmascara con un .desktop "Hidden=true" en el autostart DEL USUARIO, que
# tiene prioridad sobre el de /etc/xdg/autostart.
# OJO: removeLegacyStartup() de QZ BORRA este override en CADA reinstalación
# (barre /home/*/.config/autostart/qz-tray.desktop); como el provisioning corre
# DESPUÉS (invokeProvisioning va tras removeLegacyStartup y addStartupEntry en
# Installer.install), aquí se recrea y queda firme.
USER_AUTOSTART="$TARGET_HOME/.config/autostart"
mkdir -p "$USER_AUTOSTART"
cat > "$USER_AUTOSTART/qz-tray.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=QZ Tray
Hidden=true
X-GNOME-Autostart-enabled=false
DESK

# --- 1b) Neutralizar el autostart .desktop de SISTEMA (segunda vía) ---------
# addStartupEntry() de QZ (re)crea /etc/xdg/autostart/qz-tray.desktop en cada
# instalación: con el servicio de usuario activo es un SEGUNDO lanzador (doble
# icono medido en kim 2026-08-10 y ya el 20-07). El override del usuario (1) lo
# tapa, pero solo para ESE usuario y solo si (1) llegó a ejecutarse: cinturón y
# tirantes. No se BORRA (un reinstall quedaría inconsistente): se le añade
# Hidden=true, que para XDG autostart equivale a no existir. Idempotente.
SYS_AUTOSTART="${QZ_SYS_AUTOSTART:-/etc/xdg/autostart/qz-tray.desktop}"
if [ -f "$SYS_AUTOSTART" ] && ! grep -q '^Hidden=true' "$SYS_AUTOSTART"; then
  printf 'Hidden=true\nX-GNOME-Autostart-enabled=false\n' >> "$SYS_AUTOSTART"
  echo "Autostart de sistema neutralizado: $SYS_AUTOSTART"
fi

# --- 2) Grupo lp: sin él, el USB directo muere con 'Permiso denegado' -------
# /dev/usb/lpN es root:lp 660. Medido en kim: printf > /dev/usb/lp0 →
# "Permission denied"; tras usermod -aG lp + relogin → papel. El TPV muestra
# una guía 1-2-3 como red de seguridad, pero el instalador debe dejarlo hecho.
if [ "$TARGET_USER" != "root" ] && getent group lp >/dev/null 2>&1; then
  if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx lp; then
    echo "El usuario $TARGET_USER ya pertenece al grupo lp."
  elif usermod -aG lp "$TARGET_USER" 2>/dev/null; then
    echo "Usuario $TARGET_USER añadido al grupo lp (USB directo /dev/usb/lpN). Hace falta CERRAR E INICIAR SESIÓN para que surta efecto."
  else
    echo "AVISO: no se pudo añadir $TARGET_USER al grupo lp; el USB directo fallará con 'Permiso denegado'. A mano: sudo usermod -aG lp $TARGET_USER"
  fi
fi

# --- 3) Wrapper de guard: QZ solo dentro de sesión gráfica viva -------------
# La unidad NO fija DISPLAY/WAYLAND_DISPLAY (un valor derivado en INSTALACIÓN
# pisaría al de la sesión real y no cubre Wayland). El wrapper los resuelve en
# RUNTIME: usa el entorno de la sesión si llegó al user manager y, si no,
# deriva el display del servidor X/Xwayland DEL PROPIO usuario (el X0 residual
# del greeter es de root y no aparece en `ps -u`). Sin sesión gráfica sale
# LIMPIO (exit 0): con Restart=on-failure systemd no relanza y el 8181 queda
# libre para la instancia buena.
WRAPPER="$(dirname "$QZ_BIN")/qz-tray-session.sh"
cat > "$WRAPPER" <<'WRAP'
#!/bin/bash
# Guard de sesión gráfica para el servicio de usuario de QZ Tray.
# QZ_SESSION_WAIT: segundos de espera a que aparezca la sesión (test: 0).
# Siempre se intenta derivar al menos UNA vez, aunque la espera sea 0.
tries=$(( ${QZ_SESSION_WAIT:-30} + 1 ))
while [ "$tries" -gt 0 ]; do
  [ -n "${DISPLAY:-}" ] && break
  D=$(ps -u "$(id -un)" -o args= 2>/dev/null \
    | sed -n 's/.*[Xx]wayland[[:space:]]\+\(:[0-9]\+\).*/\1/p;s/.*Xorg[[:space:]]\+\(:[0-9]\+\).*/\1/p' \
    | head -1)
  if [ -n "$D" ]; then export DISPLAY="$D"; break; fi
  tries=$((tries-1))
  [ "$tries" -gt 0 ] && sleep 1
done
if [ -z "${DISPLAY:-}" ]; then
  echo "qz-tray-session: sin sesión gráfica (DISPLAY); no se arranca QZ (8181 libre)."
  exit 0
fi
# Sesión Wayland: si el entorno no trajo WAYLAND_DISPLAY, derivarlo del socket.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  for s in "$XDG_RUNTIME_DIR"/wayland-*; do
    if [ -S "$s" ]; then export WAYLAND_DISPLAY="$(basename "$s")"; break; fi
  done
fi
WRAP
printf 'exec "%s" --honorautostart\n' "$QZ_BIN" >> "$WRAPPER"
chmod 755 "$WRAPPER"

# --- 4) Servicio systemd de usuario: relanza SOLO si crashea ----------------
UNIT_DIR="$TARGET_HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/qz-tray.service" <<UNIT
[Unit]
Description=QZ Tray (solo en sesión gráfica; relanzado automático si crashea)
# Atado a la SESIÓN GRÁFICA, no a default.target: con linger/default.target QZ
# arrancaba al boot SIN sesión, sin icono y SECUESTRANDO el 8181 (kim 10-08).
# PartOf: al cerrar la sesión gráfica, QZ se para y suelta el puerto.
After=graphical-session.target
PartOf=graphical-session.target
# Cortafuegos anti-bucle: si peta >5 veces en 60s, systemd se rinde en vez de
# reintentar sin fin (te avisa con estado 'failed' en vez de tostar la CPU).
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
# Techo de heap: sin -Xmx la JVM se autoasigna 1/4 de la RAM (3,9 GB en 15,7 GB),
# lo que engorda el RSS y arrastra ~850 MB a swap estando inactiva. SerialGC
# porque G1 no devuelve memoria al SO en una app que pasa el día parada.
# Las comillas son OBLIGATORIAS: sin ellas systemd parte el valor por espacios y
# trata cada trozo como una asignacion aparte, asi que QZ_OPTS llegaria valiendo
# solo '-Xmx512m' y los otros dos flags se descartarian en SILENCIO.
Environment="QZ_OPTS=-Xmx512m -XX:+UseSerialGC -XX:MaxMetaspaceSize=128m"
# El wrapper deriva DISPLAY/WAYLAND_DISPLAY en runtime y se NIEGA a arrancar QZ
# sin sesión gráfica (sale limpio → on-failure no relanza).
ExecStart=$WRAPPER
# Relanza SOLO en fallo real; NO cuando QZ sale limpio (evita bucle por duplicado).
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical-session.target
UNIT

# Enable manual (symlink): funciona aunque no haya bus de usuario durante la
# instalación. MIGRACIÓN: se borra el symlink viejo de default.target.wants
# (instalaciones previas), que era el que arrancaba QZ fuera de sesión.
mkdir -p "$UNIT_DIR/graphical-session.target.wants"
ln -sf ../qz-tray.service "$UNIT_DIR/graphical-session.target.wants/qz-tray.service"
rm -f "$UNIT_DIR/default.target.wants/qz-tray.service"

chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/systemd" "$USER_AUTOSTART" 2>/dev/null || true

# MIGRACIÓN linger: lo activaba una versión anterior de este script para
# "arrancar al encender el PC" — justo la causa de la instancia fantasma sin
# sesión gráfica (kim 10-08). QZ es una app de bandeja: sin sesión no sirve.
loginctl disable-linger "$TARGET_USER" 2>/dev/null || true

# Recargar y (re)arrancar en el bus del usuario (si hay sesión activa).
# restart y no start: si venía corriendo la unidad vieja, coge la nueva. Si no
# hay sesión gráfica, el wrapper sale limpio y no ocupa el 8181.
if command -v runuser >/dev/null 2>&1; then
  runuser -l "$TARGET_USER" -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user daemon-reload' 2>/dev/null || true
  runuser -l "$TARGET_USER" -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user restart qz-tray.service' 2>/dev/null || true
fi

echo "Servicio systemd qz-tray instalado (graphical-session.target, Restart=on-failure) para $TARGET_USER; autostarts .desktop neutralizados (evita duplicado)."
exit 0
