# SM-T510 (PHE) — Actualización a firmware oficial desde macOS Apple Silicon

Guía de actualización y diagnóstico para **Galaxy Tab A 10.1 2019 WiFi (SM-T510, Exynos 7904)**.
Solo firmware oficial firmado por Samsung. **No cubre ni contempla bypass de FRP.**

## Punto de partida

Firmware instalado: **T510XXU3BTK1** (Android 10, binario 3, noviembre 2020).

Estado leído en Download Mode:

```
PRODUCT NAME:    SM-T510
CURRENT BINARY:  Samsung Official
RP SWREV:        B:3 K:3 S:3
KG STATE:        Prenormal
FRP LOCK:        ON
OEM LOCK:        ON(L)
SECURE DOWNLOAD: Enabled
```

Contexto del equipo: región **PHE (España)**, la tablet **no arranca** (bootloop, solo entra en Download Mode),
y se trabaja desde un **Mac Apple Silicon** con la tablet conectada por USB-C.

> **Requisito previo innegociable.** Como el dispositivo no arranca, el flasheo con borrado es obligatorio. Y como
> `FRP LOCK: ON`, hace falta **la cuenta Google que estaba configurada en la tablet**: sobrevive al flasheo y el
> asistente la pedirá al terminar. Sin esa cuenta el dispositivo queda igual de inutilizable después, y la única
> vía legítima es el Servicio Técnico de Samsung con factura de compra a nombre del propietario.

---

## 1. Firmware objetivo

| Campo | Valor |
|---|---|
| PDA / AP | **T510XXU5CWA1** |
| CSC | **T510OXM5CVG2** (multi-CSC OXM, incluye PHE) |
| Android | **11** — One UI 3.1 Core |
| Binario | **U5** |
| Parche de seguridad | **2022-12-01** |
| Publicación | enero–febrero 2023 |

Es el **último firmware oficial** del SM-T510. El modelo salió del calendario de actualizaciones de Samsung tras esa
build, así que el parche de diciembre de 2022 es el techo real y no existe Android 12 para este SoC. Conviene asumir
que el dispositivo queda **fuera de soporte de seguridad**, algo relevante si va a usarse con navegador o correo.

Salto previsto: `U3 / Android 10` → `U5 / Android 11`. Se saltan dos binarios de una vez, lo cual es correcto y
soportado: las herramientas de flasheo escriben el conjunto completo, no incrementos.

### Descarga

En macOS lo más limpio es `samfirm.js`, que descarga directamente de los servidores FUS de Samsung y desencripta
el `.enc4`:

```sh
npx samfirm -m SM-T510 -r PHE
```

Alternativa: samfw.com, sammobile.com o samfrew.com buscando `SM-T510` región `PHE`.

Verificaciones obligatorias antes de flashear nada:

- El nombre del ZIP contiene `SM-T510`. **No T515 ni T517** — son variantes LTE y brickean el equipo.
- Al descomprimir hay **cuatro** ficheros: `BL_….tar.md5`, `AP_….tar.md5`, `CSC_OXM_….tar.md5`,
  `HOME_CSC_OXM_….tar.md5`.
- **No debe haber fichero `CP_`.** El T510 es solo WiFi y no lleva módem; si tu descarga trae un CP, es firmware
  equivocado.
- Comprobar el MD5 (`md5 AP_*.tar.md5`) contra el publicado por la fuente. Un AP corrupto a mitad de escritura es
  la vía rápida al brick.

## 2. Compatibilidad de binario con RP SWREV B:3

- `RP SWREV B:3 K:3 S:3` es el contador **anti-rollback** grabado en fusibles: bootloader, kernel y system.
- La regla es unidireccional: se admite firmware de binario **igual o superior**, nunca inferior.
- Binario objetivo **5 ≥ 3** → **compatible**. No hace falta paso intermedio por U4.
- `SECURE DOWNLOAD: Enabled` solo exige que el firmware esté **firmado por Samsung**; no bloquea esta subida.
- `OEM LOCK: ON(L)` tampoco lo impide: el OEM lock bloquea binarios *no firmados* (recovery custom, ROMs), no el
  firmware oficial. Para esta operación no hay que tocarlo.
- Tras el flasheo, `RP SWREV` subirá al nivel del nuevo bootloader — previsiblemente **B:5 K:5 S:5** — de forma
  **irreversible**. A partir de ahí la tablet no aceptará ningún firmware U3/U4 ni volver a Android 10.

## 3. HOME_CSC vs CSC

| Fichero | Qué hace | Cuándo usarlo |
|---|---|---|
| `HOME_CSC_OXM_…` | Actualiza **sin** formatear `/data`. Solo válido si la CSC actual ya es de la misma región. | Actualización normal conservando datos |
| `CSC_OXM_…` | Reescribe la CSC **y formatea `/data`** (wipe completo). | Cambio de región, o sistema corrupto |

**Para este caso: `CSC_OXM_…`, el completo con borrado.** La tablet está en bootloop y la causa habitual es
precisamente una partición de datos corrupta o incompatible tras una actualización fallida; `HOME_CSC` conservaría
justo aquello que probablemente provoca el fallo. Además hay salto de dos binarios y de versión de Android, con lo
que el wipe es lo esperado.

Consecuencia: se **pierden todos los datos** (no hay forma de extraerlos si el equipo no arranca) y al reiniciar
aparecerá el asistente de configuración, que **pedirá la cuenta Google del FRP**.

## 4. Procedimiento de flasheo

Conviene decirlo sin rodeos: **Odin es solo Windows y en un Mac Apple Silicon no hay ruta cómoda.** Una VM de
Windows ARM (Parallels, UTM) ejecuta el `.exe` por emulación, pero el **driver USB de Samsung es un driver de
kernel x86 sin versión ARM64**, así que Odin nunca verá el dispositivo. Esa vía está descartada.

### Antes de empezar

- Batería de la tablet ≥ 60 % (en bootloop puede haberse descargado; déjala cargando un par de horas).
- Credenciales de la cuenta Google del FRP a mano.
- Firmware descargado, descomprimido y con MD5 verificado.
- Mac conectado a corriente y con el reposo desactivado.

### Opción A — recomendada: PC Windows x86

La de menor riesgo de brick. Tratándose de escribir el **bootloader**, ese criterio manda sobre la comodidad.

1. Instalar **Samsung USB Driver for Mobile Phones** (v1.7.x) y reiniciar.
2. Usar **Odin3 v3.14.4** (o 3.13.3) original, nunca versiones "mod".
3. Cargar: `BL` → botón **BL** · `AP` → botón **AP** · `CSC_OXM_…` → botón **CSC**. Casilla **CP vacía**.
4. Opciones: `Auto Reboot` ✅ · `F. Reset Time` ✅ · `Re-Partition` ❌ (sin PIT).
5. Tablet en Download Mode, cable a un **puerto USB trasero directo, sin hub**. Odin debe mostrar `ID:COM` en azul.
6. `Start`. El AP tarda varios minutos (~2,5 GB). **No desconectar bajo ningún concepto.**
7. Esperar `PASS!` y el reinicio. El primer arranque puede tardar hasta 15 minutos: es normal.

### Opción B — nativa en macOS: Thor

[`Samsung-Loki/Thor`](https://github.com/Samsung-Loki/Thor) es un flasher open source en .NET que reimplementa el
protocolo Odin y publica binarios para macOS. Usa libusb en espacio de usuario, así que no necesita kexts (que
macOS reciente bloquearía). Es la única vía nativa razonable hoy en Apple Silicon.

Heimdall queda como último recurso: está prácticamente sin mantenimiento, no digiere `.tar.md5` directamente y
falla con frecuencia en dispositivos de esta generación con Secure Download activo.

```sh
brew install libusb                       # dependencia de LibUsbDotNet
# descargar el release osx-arm64 de Thor y retirar la cuarentena de Gatekeeper:
xattr -dr com.apple.quarantine ./TheAirBlow.Thor.Shell
./TheAirBlow.Thor.Shell
```

En la shell interactiva de Thor:

```
connect                 # detecta la tablet en Download Mode
begin odin              # inicia la sesión de protocolo Odin
flashTar                # seleccionar BL, AP y CSC_OXM  (NO HOME_CSC, NO CP)
                        # dejar sin marcar cualquier opción de repartición
end                     # cierra la sesión y reinicia
```

Precauciones específicas de esta vía:

- Conectar la tablet **directamente al puerto USB-C del Mac** con un cable **de datos**; muchos cables USB-C son
  solo de carga. Sin hubs, sin docks, sin adaptadores intermedios.
- Impedir el reposo del Mac durante todo el proceso (`caffeinate -i` en otra terminal). Que el Mac suspenda a mitad
  de la escritura del bootloader es el peor escenario posible.
- Si `connect` no detecta nada, revisar el cable antes que cualquier otra cosa: en
  *Información del Sistema → USB* debe aparecer un dispositivo Samsung mientras la tablet está en Download Mode.
- Thor no es Odin. El riesgo de escritura parcial es estructuralmente mayor; si hay un PC disponible, mejor la
  opción A.

### Opción C — Linux con `odin4`

`odin4` es el flasher CLI oficial de Samsung para Linux, pero es un binario **x86_64**. En Apple Silicon exige una
VM Linux con emulación y passthrough USB. Funciona, pero es la configuración más frágil de las tres. Solo si A y B
fallan.

## 5. Riesgos de subir de binario

| Riesgo | Detalle | Mitigación |
|---|---|---|
| **Anti-rollback irreversible** | Al quemar los fusibles a SWREV 5 se pierde para siempre la posibilidad de volver a Android 10 o a binarios 3/4. | Asumirlo conscientemente. Es el riesgo principal y el único que se materializa con total seguridad. |
| **Hard brick por interrupción en BL** | Si se corta la escritura del bootloader (cable, suspensión del Mac, batería), el equipo puede quedar sin recuperación por software: solo JTAG o cambio de placa. | Cable de datos bueno, puerto directo, `caffeinate`, batería cargada, no tocar nada durante el proceso. |
| **Firmware equivocado** | Un paquete de SM-T515/T517 (LTE) o de otro modelo brickea el equipo. | Verificar `SM-T510` y la ausencia de fichero `CP_`. |
| **`SW REV CHECK FAIL`** | Si el flasheo queda a medias con binarios mezclados, el arranque falla con este error. | No es un brick: volver a flashear el paquete **completo** U5 (BL + AP + CSC). |
| **CSC de otra región** | Una CSC ajena a PHE puede dar problemas de idioma, funciones regionales u operador. | Usar el paquete `OXM`, que incluye PHE. |
| **Herramienta no oficial** | Thor y Heimdall no son de Samsung; una implementación imperfecta del protocolo eleva la probabilidad de escritura parcial justo en la partición más crítica. | Preferir Odin en PC Windows siempre que sea posible. |
| **Rendimiento** | One UI 3.1 Core sobre Exynos 7904 con 2 GB de RAM va perceptiblemente más justo que Android 10 en algunos escenarios. | Es el precio de estar en la última versión oficial, e irreversible por el primer punto. |

Lo que **no** es un riesgo aquí: perder la garantía (el firmware oficial firmado no activa Knox) ni que
`CURRENT BINARY` pase a `Custom` (eso solo lo provocan binarios no firmados).

## 6. Comprobaciones en Download Mode después del flasheo

Para reentrar en Download Mode con la tablet apagada: **Vol− + Vol+ mantenidos mientras se conecta el cable USB**,
y confirmar con Vol↑.

| Campo | Antes | Esperado después | Lectura |
|---|---|---|---|
| `CURRENT BINARY` | Samsung Official | **Samsung Official** | Si apareciera `Custom`, se escribió algo no oficial → reflashear. |
| `RP SWREV` | B:3 K:3 S:3 | **B:5 K:5 S:5** (previsiblemente) | Confirma que el binario subió. Ya no se puede bajar. |
| `KG STATE` | Prenormal | **Prenormal**, sin cambios | Ver nota abajo. |
| `FRP LOCK` | ON | **ON** | Sigue activo. No cambia con el flasheo: es el comportamiento correcto y esperado. |
| `OEM LOCK` | ON(L) | **ON(L)** | Sigue bloqueado. `(L)` = bloqueado por política; el conmutador «Desbloqueo de OEM» no aparece hasta tener la tablet configurada con cuenta y pasados ~7 días. No hay que tocarlo. |
| `SECURE DOWNLOAD` | Enabled | **Enabled** | Sin cambios. |
| `Warranty Void` | 0 | **0** | Debe seguir en 0. |

Ya arrancado, en **Ajustes → Información de la tablet → Información de software** debe leerse:
`Versión de Android 11`, `Número de compilación T510XXU5CWA1`, `Nivel de parche de seguridad 1 de diciembre de 2022`.

### Nota sobre `KG STATE: Prenormal`

Es el estado por defecto de Knox Guard en la inmensa mayoría de unidades retail y **no significa que el dispositivo
esté bloqueado ni marcado**. Solo indica que el equipo aún no ha hecho *check-in* con el servidor de Knox Guard.
Los estados problemáticos son `Locked` y `Lock Pending`. Al ser un valor controlado por servidor, **flashear
firmware no lo modifica en ningún sentido**, ni para bien ni para mal. Si tras conectarse a internet pasara a
`Checking` y luego a `Normal`, es el comportamiento normal.

## 7. Efecto de la actualización sobre el bloqueo FRP

**Ninguno, y es por diseño.**

- El flag de FRP reside en una **partición persistente independiente** (`persistent` / `frp`) que el firmware
  oficial **no toca**, ni siquiera flasheando con `CSC` completo y formateando `/data`.
- Por tanto la actualización ni lo activa, ni lo desactiva, ni lo elude. Subir de Android 10 a 11 y de binario 3 a 5
  es **neutro** respecto al FRP. Cualquier guía que afirme lo contrario está describiendo un bypass.
- Efecto práctico: al terminar el flasheo con wipe, el asistente de configuración **pedirá la cuenta Google que
  estaba sincronizada** en la tablet antes del bootloop. Con esa cuenta el equipo queda plenamente operativo.
- Formas legítimas de retirar el FRP:
  1. **Iniciar sesión con la cuenta original** en el asistente. Después, para dejarlo limpio, eliminar la cuenta
     desde Ajustes *antes* de hacer un reset: así el flag queda en `OFF`.
  2. **Servicio Técnico Samsung** con factura de compra a nombre del propietario, si la cuenta es irrecuperable.
- El estado `OEM LOCK: ON(L)` es coherente con FRP activo: mientras el FRP esté ON, el sistema mantiene el OEM lock
  forzado. Se relaja solo al completar la configuración con una cuenta válida.

---

## Verificación de extremo a extremo

1. **Antes.** MD5 de los ficheros verificado, y el dispositivo Samsung visible en *Información del Sistema → USB*
   del Mac con la tablet en Download Mode.
2. **Durante.** La herramienta reporta la escritura de `sboot`, `boot`, `recovery`, `super`/`system` y `cache`, y
   termina con `PASS!` (Odin) o `end` sin errores (Thor).
3. **Después.** Arranque completo hasta el asistente (hasta 15 minutos el primer boot) y pantalla de FRP pidiendo la
   cuenta Google: señal inequívoca de que el flasheo fue correcto y el FRP sigue intacto.
4. **Versión.** Build `T510XXU5CWA1`, Android 11, parche 2022-12-01.
5. **Estado de seguridad.** Reentrar en Download Mode y contrastar la tabla del apartado 6, en especial
   `RP SWREV` a 5 y `CURRENT BINARY: Samsung Official`.
6. **Si el bootloop persiste.** Entrar en Recovery (Vol+ + Power), `Wipe data/factory reset`, y si aun así falla,
   repetir el flasheo completo. Si el fallo continúa, apunta a hardware (eMMC degradada), avería conocida en esta
   gama que no se resuelve por software.

---

## Referencias

- [Samfw — SM-T510 T510XXU5CWA1](https://samfw.com/firmware/SM-T510/XEF/T510XXU5CWA1)
- [SamMobile — SM-T510 SEB T510XXU5CWA1](https://www.sammobile.com/samsung/galaxy-tab-a-101/firmware/SM-T510/SEB/download/T510XXU5CWA1/1721663/)
- [Samfrew — listado de firmware SM-T510](https://samfrew.com/firmware/model/SM-T510/upload/Desc/0/10)
- [Samsung-Loki/Thor](https://github.com/Samsung-Loki/Thor)
