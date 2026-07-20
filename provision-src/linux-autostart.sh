#!/usr/bin/env bash
# linux-autostart.sh — arranque blindado de QZ Tray en Linux.
#
# QZ ya instala un autostart .desktop (arranca al iniciar sesión gráfica). Este
# script instala UN servicio systemd de usuario que RELANZA QZ si CRASHEA, y —
# clave — DESACTIVA el autostart .desktop para que no haya DOS instancias
# peleándose (QZ mata la 2ª por "single instance" y systemd la relanzaría en
# bucle). El servicio pasa a ser el ÚNICO mecanismo de arranque.
#
# Restart=on-failure (NO on-success): cuando QZ se cierra limpio (p.ej. lo cierras
# tú, o detecta duplicado y sale con código 0) el servicio NO lo relanza. Solo
# revive ante crash real. Idempotente.

set -e

QZ_BIN="/opt/qz-tray/qz-tray"
if [ ! -x "$QZ_BIN" ]; then
  echo "qz-tray no encontrado en $QZ_BIN; omitiendo servicio systemd."
  exit 0
fi

# NOTA: la escritura de security.print.tofile se hace mas abajo, en el
# prefs.properties del USUARIO (tras resolver TARGET_HOME). NO se escribe en el
# qz-tray.properties de /opt porque QZ lo REGENERA al arrancar (saveProperties tras
# crear los keystores SSL) y borra la linea. El prefs.properties de usuario, en
# cambio, QZ no lo sobrescribe.

# Usuario objetivo: el que invocó sudo (instalación gráfica real), no root.
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ]; then
  echo "No se pudo resolver el HOME de $TARGET_USER; omitiendo."
  exit 0
fi

# --- 0) Permitir impresion directa a device path (USB directo por {file}) ---
# El USB directo en Linux imprime a /dev/usb/lpN via {file}, que QZ BLOQUEA por
# defecto (security.print.tofile=false → "Printing to file is not permitted").
# Se escribe en el prefs.properties del USUARIO (QZ lo lee via PrefsSearch y NO lo
# regenera; el qz-tray.properties de /opt SI lo reescribe QZ al arrancar y borraria
# la linea). Idempotente.
QZ_PREFS_DIR="$TARGET_HOME/.qz"
QZ_PREFS="$QZ_PREFS_DIR/prefs.properties"
mkdir -p "$QZ_PREFS_DIR"
touch "$QZ_PREFS"
if grep -q '^security.print.tofile=' "$QZ_PREFS" 2>/dev/null; then
  sed -i 's/^security.print.tofile=.*/security.print.tofile=true/' "$QZ_PREFS"
else
  printf 'security.print.tofile=true\n' >> "$QZ_PREFS"
fi
chown -R "$TARGET_USER":"$TARGET_USER" "$QZ_PREFS_DIR" 2>/dev/null || true
echo "security.print.tofile=true escrito en $QZ_PREFS (USB directo por device path habilitado)."

# --- 1) Desactivar el autostart .desktop de QZ para el usuario (evita duplicado) ---
# Se hace enmascarándolo con un .desktop "Hidden=true" en el autostart DEL USUARIO,
# que tiene prioridad sobre el de /etc/xdg/autostart. NO borramos el del sistema
# (así un uninstall/reinstall de QZ no queda inconsistente).
USER_AUTOSTART="$TARGET_HOME/.config/autostart"
mkdir -p "$USER_AUTOSTART"
cat > "$USER_AUTOSTART/qz-tray.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=QZ Tray
Hidden=true
X-GNOME-Autostart-enabled=false
DESK

# --- 2) Servicio systemd de usuario: relanza SOLO si crashea ---
UNIT_DIR="$TARGET_HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/qz-tray.service" <<UNIT
[Unit]
Description=QZ Tray (relanzado automático si crashea)
After=graphical-session.target

[Service]
Type=simple
ExecStart=$QZ_BIN --honorautostart
# Relanza SOLO en fallo real; NO cuando QZ sale limpio (evita bucle por duplicado).
Restart=on-failure
RestartSec=10
# Cortafuegos anti-bucle: si peta >5 veces en 60s, systemd se rinde en vez de
# reintentar sin fin (te avisa con estado 'failed' en vez de tostar la CPU).
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=default.target
UNIT

chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/systemd" "$USER_AUTOSTART" 2>/dev/null || true

# Lingering: arranca al encender el PC, no solo al iniciar sesión gráfica.
loginctl enable-linger "$TARGET_USER" 2>/dev/null || true

# Recargar y habilitar en el bus del usuario (si hay sesión activa).
if command -v runuser >/dev/null 2>&1; then
  runuser -l "$TARGET_USER" -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user daemon-reload' 2>/dev/null || true
  runuser -l "$TARGET_USER" -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user enable --now qz-tray.service' 2>/dev/null || true
fi

echo "Servicio systemd qz-tray instalado (Restart=on-failure) para $TARGET_USER; autostart .desktop desactivado (evita duplicado)."
exit 0
