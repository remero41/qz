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

# Usuario objetivo: el que invocó sudo (instalación gráfica real), no root.
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ]; then
  echo "No se pudo resolver el HOME de $TARGET_USER; omitiendo."
  exit 0
fi

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
# Entorno gráfico: systemd sustituye al autostart .desktop, y una unidad de
# usuario NO hereda el DISPLAY de la sesión. Sin esto AWT no conecta al servidor
# gráfico y QZ corre SIN icono de bandeja.
Environment=DISPLAY=:1
Environment=WAYLAND_DISPLAY=wayland-0
# Techo de heap: sin -Xmx la JVM se autoasigna 1/4 de la RAM (3,9 GB en 15,7 GB),
# lo que engorda el RSS y arrastra ~850 MB a swap estando inactiva. SerialGC
# porque G1 no devuelve memoria al SO en una app que pasa el día parada.
# Las comillas son OBLIGATORIAS: sin ellas systemd parte el valor por espacios y
# trata cada trozo como una asignacion aparte, asi que QZ_OPTS llegaria valiendo
# solo '-Xmx512m' y los otros dos flags se descartarian en SILENCIO.
Environment="QZ_OPTS=-Xmx512m -XX:+UseSerialGC -XX:MaxMetaspaceSize=128m"
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
