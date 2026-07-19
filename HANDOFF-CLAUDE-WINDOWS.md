# HANDOFF → Claude en Windows: por qué `WindowsUsbInfo.readRegistry()` devuelve vacío

## Contexto en 30 segundos

Parche a QZ Tray (fork de `qzind/tray@46e404e`) para que en Windows exponga, por cada
dispositivo USB, el **device path usbprint REAL** (con el *instance ID* del equipo, no
un `#Printer#` inventado) + `printerClass` + `ieee1284` + `friendlyName`. El TPV consume
esos campos e imprime directo sin adivinar el path.

- Repo: `remero41/qz`, rama `feat/usb-devicepath-windows` (YA pusheada, último commit `9f448cb`).
- El parche está en `patches/0001-usb-details-windows-devicepath.patch` y se aplica sobre
  `qzind/tray@46e404e` en el CI `.github/workflows/build-win.yaml`.
- Clase clave: `src/qz/utils/WindowsUsbInfo.java` (dentro del árbol `tray/` tras aplicar el parche).
- `.exe` de prueba (self-signed, 2.2.6) ya instalado en este Windows:
  Release `qz-devicepath-win-test-2026-07-19` de `remero41/qz`.

## EL PROBLEMA (confirmado empíricamente hoy 2026-07-19)

QZ ya es **2.2.6** (el parcheado corre), PERO `qz.usb.listDevices(false)` sigue devolviendo
SOLO `{vendorId, productId, hub}` — **NO** aparecen `printerClass`, `devicePath`, `friendlyName`.
Es decir: **`WindowsUsbInfo.readRegistry()` está devolviendo un mapa vacío `{}`** en este equipo.

Prueba: `listDevices` dio 8 dispositivos, todos solo con vid/pid:
```
04f3:2398, 0bda:0316, 8087:0a2b, 0416:5011, 04b8:0202, 046d:c542, 1fc9:2016, 5986:2113
```
Las 3 térmicas objetivo: **POS58 = 0416:5011**, **POS80 = 1fc9:2016**, **Epson TM = 04b8:0202**.

Al imprimir directo (con el path DERIVADO `#Printer#` como fallback, porque no hay devicePath real):
- POS58 `0416:5011` → OK (su instance ID real es literalmente `PRINTER`, casa por suerte).
- POS80 `1fc9:2016` → `FileNotFoundException` (su instance ID real es `702D07693632`, NO `Printer`).
- Epson `04b8:0202` → `FileNotFoundException` (es TMUSB, no usbprint).

Esto es EXACTAMENTE lo que el parche debía arreglar leyendo el instance ID real del registro.

## LO QUE HACE EL PARCHE (y dónde sospecho el fallo)

`WindowsUsbInfo.readRegistry()` (ver el fichero, tiene trazas de log añadidas en el commit `9f448cb`):
1. `Advapi32Util.registryGetKeys(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Enum\\USB")`
   → lista subclaves tipo `VID_1FC9&PID_2016`.
2. Por cada una, `registryGetKeys(...\VID_..&PID_..)` → lista instancias (`702D07693632`, `PRINTER`, ...).
3. Por cada instancia lee los valores `Service`, `FriendlyName`, `DeviceDesc` y (bajo `\Device Parameters`) `CompatibleIDs`.
4. `parse()` filtra: solo `Service=usbprint`/`tmusb` o con IEEE-1284 → construye el devicePath con el instance ID real.

**HIPÓTESIS PRINCIPAL: permisos.** Leer valores bajo `HKLM\SYSTEM\CurrentControlSet\Enum\USB\...\<instance>`
suele requerir privilegios que el proceso QZ (usuario normal, no admin) no tiene sobre ciertas
subclaves → `Advapi32Util` lanza `Win32Exception (Access is denied, code 5)` → el `catch` de
`readRegistry` devuelve `{}`. Antes el catch era MUDO; en `9f448cb` añadí `log.error/warn/info`.

**HIPÓTESIS 2:** la estructura del registro no es la que asumo (p.ej. los valores no están en
`...\VID&PID\<instance>` sino un nivel más abajo, o `Service` está vacío para estas impresoras).

## LO QUE NECESITO QUE HAGAS EN ESTE WINDOWS (diagnóstico, sin recompilar)

### Paso 1 — Leer el debug.log de QZ (dirá la causa directa)
El log está en `%APPDATA%\qz\debug.log` (o `C:\Users\<tú>\AppData\Roaming\qz\debug.log`).
Reinicia QZ, abre el TPV/diag para que llame a `listDevices`, y busca líneas de `WindowsUsbInfo`:
```
powershell -c "Get-Content \"$env:APPDATA\qz\debug.log\" -Tail 200 | Select-String WindowsUsbInfo"
```
Interpretación:
- Si ves `readRegistry falló leyendo ... (¿permisos?): ...Win32Exception...Access is denied` → **es permisos** (hipótesis 1). Ve al Paso 3.
- Si ves `0 claves VID/PID` → `registryGetKeys` sobre `Enum\USB` devolvió vacío (permisos en la raíz, o WOW6432).
- Si ves `N claves, M instancias, 0 impresoras detectadas` → lee las claves pero el FILTRO `parse()` descarta todo → **es la estructura/Service** (hipótesis 2). Ve al Paso 2.
- Si ves `→ 1fc9:2016 class=usbprint devicePath=...702D07693632...` → ¡funciona! entonces el problema es de CACHÉ del navegador/TPV, no del parche.

### Paso 2 — Ver la estructura REAL del registro (confirma qué lee y qué falta)
```
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_1FC9&PID_2016" /s
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_0416&PID_5011" /s
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_04B8&PID_0202" /s
```
Anota: ¿el 3er tramo (instance ID) es `702D07693632` para la POS80? ¿existe el valor `Service`
en esa clave y vale `usbprint`? ¿existe `FriendlyName`? ¿hay subclave `Device Parameters`?
Compara con lo que `WindowsUsbInfo.parse()` espera (Service en la clave de la instancia).

### Paso 3 — Confirmar si es permisos (si el log apunta ahí)
Ejecuta QZ **como administrador** una vez y repite `listDevices`. Si con admin SÍ aparecen los
campos → confirmado que es permisos y hay que cambiar el enfoque (ver "FIX PROBABLE").

## FIX PROBABLE (según lo que salga)

- **Si es permisos (lo más probable):** NO usar `Enum\USB` (subárbol restringido). Usar en su
  lugar `HKLM\SYSTEM\CurrentControlSet\Control\DeviceClasses\{28d78fad-5a12-11d1-ae5b-0000f803a8c2}`
  (la clase de interfaz usbprint) — es LEGIBLE por usuarios y da el **symbolic link name** que
  ES el device path usbprint completo (contiene VID/PID + instance ID + GUID). Es la fuente
  canónica del path que QZ necesita, y evita `Enum`. Reescribir `readRegistry()` para enumerar
  esa clave y parsear el `## ?? #USB#VID_...#<instance>#{GUID}` de cada symbolic link.
- **Si es la estructura (Service vacío / otro nivel):** ajustar `parse()`/`readRegistry` a la
  ruta real que hayas visto en el Paso 2.

## Cómo iterar el fix
1. Editas `WindowsUsbInfo.java` en el árbol `tray` (clona `qzind/tray@46e404e` + `git apply` el parche).
2. Compilas SOLO tu clase o el jar (`ant nsis` completo tarda; para probar rápido puedes recompilar
   el jar y reemplazar `qz-tray.jar` dentro de la instalación).
3. Regeneras el parche: `git diff 46e404e HEAD -- src/ test/ > patches/0001-usb-details-windows-devicepath.patch`
4. Push a `feat/usb-devicepath-windows` → el CI `build-win` recompila el `.exe`.

## Reglas del usuario (IMPORTANTES)
- Español siempre. NO merge a main sin que lo pida. NO push autónomo "porque terminaste" —
  solo cuando el usuario lo pida. Firma con YubiKey (agente del sistema `/run/user/1000/openssh_agent`).
- Los tests Java (TestNG) están en `test/qz/utils/WindowsUsbInfoTest.java` — 7 casos, deben seguir verdes.

## Estado del TPV (la otra mitad, ya desplegada)
- Rama `feat/qz-usb-directo` del repo `tpv`, desplegada en `elc21f74e.remero.io`
  (`/var/www/elc21f74e.remero.io/public_html/tpv/zq/`, backup en `.bak-devicepath-*`).
- El TPV YA consume `devicePath`/`printerClass` de QZ correctamente; degrada a cola si no vienen.
  O sea: en cuanto QZ devuelva los campos, el TPV imprime directo sin más cambios.
- Diag de prueba: `https://elc21f74e.remero.io/tpv/zq/diag-impresora.html` (botón 1 y 4).
```
