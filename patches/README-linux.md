# Parche 0002 — USB directo en Linux (sysfs → devicePath/serial/ieee1284)

**Base:** `qzind/tray@46e404e4d50d92b84ee3a817d29ce0f5225907bb`, **sobre el parche 0001** (Windows).
El 0002 fue generado con `pin + 0001` ya aplicado, así que el **orden de aplicación es obligatorio**:

```bash
git apply patches/0001-usb-details-windows-devicepath.patch
git apply patches/0002-usb-details-linux-devicepath.patch
```

## Qué toca

| Fichero | Cambio |
|---------|--------|
| `src/qz/utils/LinuxUsbInfo.java` (NUEVO) | Lee sysfs y produce, por dispositivo, `devicePath` (`/dev/usb/lpN` real), `serial`, `ieee1284` y `friendlyName`. |
| `src/qz/utils/WindowsUsbInfo.java` | Añade el campo `serial` (= instance ID del device path) a `DeviceInfo`/`applyTo`, para que la identidad `{vid,pid,serial}` funcione igual en Windows. |
| `src/qz/utils/UsbUtilities.java` | En `getUsbDevicesJSON`, junto a la rama Windows ya existente, añade una rama Linux: `LinuxUsbInfo.readSysfs()` (tras `isLinux()`) y `applyTo` por `vid:pid`. |
| `test/qz/utils/LinuxUsbInfoTest.java` (NUEVO) | TDD del `parse` puro (3 térmicas del informe 07-18, desempate por serial, sin ieee1284, nodo sin vid/pid omitido, `applyTo`, cruce por clave `vid:pid` en minúsculas). |
| `test/qz/utils/WindowsUsbInfoTest.java` | +1 caso: `pos80_expone_serial`. |

## Por qué sysfs

Cuando el módulo `usblp` engancha una impresora USB, el kernel crea `/sys/class/usbmisc/lpN/`,
cuyo symlink `device/` apunta al dispositivo USB real. De ahí se leen:
`device/idVendor`, `device/idProduct`, `device/serial`, `device/ieee1284_id`
(+ `product`/`manufacturer` para el friendlyName). El nombre del nodo (`lpN`) da el
device path REAL `/dev/usb/lpN` — **NO se adivina el orden de enumeración** (que es volátil
entre arranques): el kernel ya lo mapeó, y el serial permite seguir a la impresora correcta
aunque el `lpN` cambie tras un reboot.

Todo campo es **ADITIVO**: si el QZ no forkeado no los emite, el TPV degrada a cola.
La lectura real (`readSysfs`) va tras `SystemUtilities.isLinux()` y es defensiva (un `lpN`
ilegible se omite con `log.warn`, nunca lanza), mismo blindaje que `WindowsUsbInfo.readRegistry`.

## Cómo re-aplicar a un QZ upstream nuevo

Si el pin sube y `git apply` del 0002 falla, los **anclajes** son:

1. `UsbUtilities.getUsbDevicesJSON`: tras el bloque que declara `usbInfo` (Windows), añadir la
   declaración análoga `linuxInfo` (`isLinux() ? LinuxUsbInfo.readSysfs() : emptyMap()`); y dentro
   del bucle de dispositivos, tras el `if(!usbInfo.isEmpty()){…WindowsUsbInfo.applyTo…}`, un
   `if(!linuxInfo.isEmpty()){…LinuxUsbInfo.applyTo…}` con la misma clave `vid:pid` en minúsculas.
2. `WindowsUsbInfo`: `DeviceInfo` gana `serial`; en `parse`, `d.serial = instanceId`; en `applyTo`,
   `if(d.serial!=null) o.put("serial", d.serial)`.
3. `LinuxUsbInfo.java` se copia tal cual (no depende del resto del árbol salvo `SystemUtilities`,
   `jettison` y `log4j`).

## Regenerar el patch

El 0002 debe ser el diff **de `pin+0001` a `pin+0001+linux`** (no del pin pelado, o mezclaría
el 0001). Método reproducible: extraer el árbol al pin en un tmp, aplicar 0001, `git init`+commit
como base, copiar encima los 5 ficheros del árbol de trabajo, `git diff --cached --binary`.

## Arranque / CI

- **Arranque NO se toca:** `provision-src/linux-autostart.sh` ya está blindado anti-bucle. El
  0002 solo añade lectura de sysfs en `listDevices` (bajo petición del cliente, no en arranque).
- **CI:** `.github/workflows/build-linux.yaml` clona el pin, aplica 0001+0002, corre `ant unit-tests`
  y compila el `.run` con `ant makeself` (Java 11 liberica, igual que win/mac).

## 0006 — Timeout en escritura a fichero/device (`printToFile`)

**Bug cazado en vivo (kim, 2026-08-10):** con la impresora sin consumir datos (apagada a
mitad de job, en error, buffer lleno), `printToFile` se quedaba bloqueado PARA SIEMPRE en
`FileOutputStream.write()` **reteniendo `/dev/usb/lpN`**. `usblp` solo admite un abridor:
todos los trabajos posteriores (de cualquier proceso) morían con «Device or resource busy»
hasta reiniciar QZ, y el TPV solo veía un spinner infinito. Medido con `fuser`: el `java`
de QZ era quien retenía el device.

**Fix:** la escritura pasa a `FileChannel` (canal interrumpible) con un watchdog que cierra
el canal al vencer el timeout (`-Dqz.print.tofile.timeout`, 30 s por defecto, ajustable vía
`QZ_OPTS`): la escritura bloqueada aborta con `IOException` clara («the device is not
consuming data»), el descriptor se libera solo y el error llega al TPV por el websocket
(`PrintException`). Cerrar un canal interrumpible SÍ desbloquea un `write()` clavado en el
kernel (señal → EINTR), cosa que un `close()` normal desde otro hilo no garantiza. Mismos
flags de apertura que `FileOutputStream` (WRITE|CREATE|TRUNCATE): el camino feliz no cambia.

**Test:** `PrintRawToFileTimeoutTest` reproduce el secuestro con un FIFO cuyo lector no
consume (misma syscall bloqueada) y afirma: aborta al vencer (no antes, no eternamente),
mensaje explicativo, y camino feliz intacto (escribe y trunca igual). Se regenera desde
`pin+0001..0005`, solo toca `PrintRaw.java` + test nuevo.
