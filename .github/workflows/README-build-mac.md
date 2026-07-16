# Compilar el .pkg de macOS en GitHub Actions

El instalador de Mac (`.pkg`) **no se puede compilar en Linux** (necesita
`pkgbuild`/`productbuild`/`codesign`, exclusivos de macOS). El workflow
`build-mac.yaml` lo compila en un runner `macos-latest` de GitHub, con los
certificados de 100 años de POS Printer, para Intel (`x86_64`) y Apple Silicon
(`aarch64`).

> **Nota de arquitectura**: este repo (`<repo>`) **no contiene el fuente de QZ**,
> solo los binarios (`qz.exe`/`qz.run`) y el provisioning (`provision-src/`). El fuente
> vive en `qzind/tray`. Por eso el workflow **clona `qzind/tray` al commit exacto**
> (`46e404e`, = v2.2.6 + 24 commits, el mismo con el que se compilaron Windows/Linux),
> le copia dentro `provision-src/` + los certs, y compila ahí. Para subir la versión de
> QZ en el futuro, cambia `QZ_SOURCE_REF` en el workflow.

## 1) Cargar los certificados como Secrets (una sola vez)

En GitHub: **repo → Settings → Secrets and variables → Actions → New repository secret**.
Crea estos tres secrets pegando el **contenido completo** de cada fichero de
`<ruta-a-los-certs>/`:

| Secret | Fichero de origen |
|--------|-------------------|
| `QZ_CERT_PEM` | `cert.pem` |
| `QZ_KEY_PEM` | `key.pem` (clave privada del parque) |
| `QZ_OVERRIDE_CRT` | `override.crt` |

Desde la terminal (opcional, con `gh` autenticado):

```bash
gh secret set QZ_CERT_PEM     < <ruta-a-los-certs>/cert.pem
gh secret set QZ_KEY_PEM      < <ruta-a-los-certs>/key.pem
gh secret set QZ_OVERRIDE_CRT < <ruta-a-los-certs>/override.crt
```

> ⚠️ `key.pem` es la clave privada que da confianza a TODO el parque. Al cargarla
> como Secret vive cifrada en GitHub y es accesible a admins del repo y a quien
> pueda editar workflows. Restringe quién administra el repo.

## 2) Lanzar el workflow

**Actions → build-mac → Run workflow.** Deja el campo *release* vacío para solo
obtener artefactos, o pon un tag (p. ej. `v2.2.6-mac`) para adjuntar los `.pkg` a
esa Release.

## 3) Descargar el resultado

Al terminar, en la página del run → **Artifacts**:
- `qz-tray-macos-x86_64` → `.pkg` para Macs Intel.
- `qz-tray-macos-aarch64` → `.pkg` para Macs Apple Silicon (M1/M2/M3…).

## Notas

- **Arranque en Mac**: es nativo (`LaunchAgent`, lanzado con `--honorautostart`),
  robusto por diseño. NO lleva el watchdog de Windows y no le hace falta: el
  `provision.json` no tiene pasos `mac`.
- **Notarización de Apple**: este `.pkg` va firmado con TU certificado (para la
  confianza de QZ), pero NO está notarizado por Apple. En macOS reciente, Gatekeeper
  puede pedir "abrir de todas formas" la primera vez (clic derecho → Abrir). La
  notarización exigiría una cuenta de Apple Developer de pago y credenciales extra;
  se puede añadir después si hace falta.
- El workflow **borra los .pem del workspace** al terminar (paso `if: always()`).
