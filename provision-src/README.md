# Provisioning de compilación de QZ Tray (POS Printer)

Estos son los scripts de **provisioning** con los que se compilan `qz.exe` (Windows)
y `qz.run` (Linux) de este repo. Se copian a `~/qzcompilation/tray/provision/` y se
pasan a `ant` con `-Dprovision.file="provision/provision.json"`.

> **No son los binarios**: `qz.exe`/`qz.run` (raíz del repo, en Git LFS) llevan estos
> scripts ya embebidos. Esta carpeta es la **fuente/receta** para trazabilidad.

## Certificados

Se compila con los certificados de 100 años en `<ruta-a-los-certs>`
(`cert.pem` `CN=*.this-repo.com`, `key.pem`, `override.crt`). **NO regenerar** —
rompería la confianza de todo el parque ya instalado.

## Comandos de compilación

```bash
cd ~/qzcompilation/tray
cp <ruta-a-los-certs>/cert.pem <ruta-a-los-certs>/key.pem <ruta-a-los-certs>/override.crt .
cp <ruta-a-esta-carpeta>/*.ps1 <ruta>/*.sh <ruta>/provision.json provision/

# Windows (NSIS) — deja out/qz-tray-2.2.6-x86_64.exe
ant nsis     -Dauthcert.use="cert.pem" -Dprovision.file="provision/provision.json"
# Linux (makeself) — deja out/qz-tray-2.2.6-x86_64.run
ant makeself -Dauthcert.use="cert.pem" -Dprovision.file="provision/provision.json"
```

> **Ojo**: `nsis` y `makeself` comparten `out/` y cada uno regenera su árbol `dist`,
> lo que **borra el binario del otro SO**. Compila uno, **copia su binario a sitio
> seguro**, y luego compila el otro. No los encadenes esperando ambos en `out/` a la vez.

## Arranque BLINDADO en Windows (win-autostart.ps1 v2)

El objetivo es que QZ arranque **sí o sí** al encender el PC, con recuperación
automática. En vez de una sola vía (que Windows rompe a menudo), se apilan capas
redundantes; **basta con que una viva**. Todas las capas añadidas pasan por un
**watchdog** único con dedupe, para no crear dobles instancias.

| Capa | Mecanismo | Cuándo dispara |
|------|-----------|----------------|
| 0 | `.lnk` en Startup común (nativo de QZ) | login, t=0 |
| 1 | Tarea `QZ Tray Autostart` (XML, GroupId `S-1-5-32-545`) → watchdog | login +45 s, **cualquier** usuario interactivo |
| 2 | Tarea `QZ Tray Watchdog` (XML) → watchdog | cada 2 min |
| 3 | `HKLM\...\Run` `QZ Tray Watchdog` (EncodedCommand) → watchdog | login +75 s, aun con Task Scheduler roto |

### Decisiones de diseño (el "por qué")

- **Principal de grupo `Users` (S-1-5-32-545) vía XML**, no `schtasks` clásico: si el
  instalador se ejecuta con UAC elevando **otra** cuenta admin, `schtasks /SC ONLOGON`
  ata la tarea a esa cuenta y **nunca dispara** en la sesión del cajero. El XML con
  `GroupId` dispara para todo usuario interactivo.
- **Watchdog por `-EncodedCommand` (base64 UTF-16LE)**, no `-File`: la `ExecutionPolicy`
  de PowerShell sólo bloquea `-File`; `-EncodedCommand` es **inmune** a ella. Así no
  hace falta debilitar ninguna política de la máquina ni depender de su configuración.
- **Sonda de salud real (websocket)**, no `Get-Process`: QZ puede quedar **zombi**
  (proceso vivo, puerto muerto). El watchdog conecta a `127.0.0.1` en los puertos de QZ
  (8181/8282/… y 8182/…) y, si no responde tras 4 min de gracia (JVM fría), lo mata y
  relanza.
- **`win-cleanup.ps1`** (fase `uninstall`) retira tareas y clave Run al desinstalar.

### ANTI-BUCLE (crítico — aprendido del bucle de reinicio en Linux, commit `e04a799`)

QZ es **singleton**: cuando arranca una 2ª instancia y detecta que ya hay una viva
(el websocket responde al *probe*), **la 2ª se autocierra con `exit 0`**. Y si arranca
con `--honorautostart` y el usuario tenía el autostart en `0`, **sale sin abrir el puerto**.
Un watchdog ingenuo que "relanza lo que no responde" entra en **bucle abrir/cerrar infinito**.
Salvaguardas del watchdog v2:

1. **Respeta la preferencia `.autostart` de QZ.** Lee `%APPDATA%\qz\.autostart` (y si no,
   `%PROGRAMDATA%\qz\.autostart`), misma lógica que `FileUtilities.readAutoStartFile`. Si
   vale `0` (el usuario apagó "Iniciar automáticamente"), el watchdog **no relanza nada** y
   **no reactiva** las entradas de arranque. Sin este gate, QZ lanzado con `--honorautostart`
   se autocierra y el watchdog lo relanzaría cada 2 min para siempre.
2. **Lanza QZ con `--honorautostart`** (igual que el `.lnk` nativo): misma semántica, sin
   pelearse con la preferencia.
3. **Dedupe sólo de duplicados ESTABLES.** Sólo poda si hay >1 proceso y **todos** llevan
   vivos >90 s (pasada la ventana de arranque de la JVM). Si alguno es joven, es el arranque
   normal en curso y **no toca nada** — deja que el `SingleInstanceChecker` de QZ se
   autoresuelva. Evita matar la instancia buena en el margen de arranque.
4. **Al reiniciar un zombi, espera a que muera de verdad** (hasta 15 s) antes de relanzar,
   para no solapar el proceso agonizante con el nuevo (otra fuente de doble instancia).
5. **Mutex global** `Global\QZTrayWatchdog`: dos capas nunca ejecutan el watchdog a la vez.

> **Para PARAR QZ de verdad**: apagar "Iniciar automáticamente" desde el icono de QZ
> (escribe `.autostart=0` y el watchdog lo respeta). Alternativa dura: deshabilitar la
> tarea `QZ Tray Watchdog`.

### Parche al fuente de QZ

`src/qz/installer/provision/invoker/ScriptInvoker.java` — sin cambios en esta versión
(el bypass de ExecutionPolicy no es necesario porque el watchdog usa `-EncodedCommand`).

## Verificación manual en Windows (la hace el usuario)

1. Instalar `qz.exe` en un Windows de prueba y **reiniciar la sesión**.
2. Confirmar que QZ **arranca solo** (icono en la bandeja) tras el login.
3. Matar `qz-tray.exe` desde el Administrador de tareas → debe **relanzarse en < 2 min**.
4. Comprobar el log del watchdog en `%LOCALAPPDATA%\qz-watchdog.log`.
5. Desde el TPV, confirmar impresión y `qz.usb.listDevices()` (WinUSB).
