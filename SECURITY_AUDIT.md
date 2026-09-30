# Auditoría de seguridad pasiva — Webapp PWA (alquiler de taquillas turísticas)

> **Modo:** Consultoría de seguridad · verificación **pasiva** sobre artefactos públicos
> **Fecha:** 2026-09-30
> **Alcance:** Bundle JS público, HTML servido, headers HTTP, DNS público, TLS, infraestructura identificable
> **Fuera de alcance:** backend interno, ingeniería social, ataques activos (DoS/fuzzing/fuerza bruta), modificación de recursos en origen
>
> Todos los identificadores están anonimizados (`TU-DOMINIO.com`, `AIzaSy...REDACTED`, `<UUID_REDACTED>`, etc.).
> Los hallazgos ya confirmados empíricamente no se re-explotan: no se repiten llamadas a APIs de Google ni se toca el webhook de Slack.

---

## 0. Resumen ejecutivo

La webapp está **bien construida en la capa de transporte e infraestructura** (TLS 1.3 con híbrido post-cuántico X25519MLKEM768, HTTP/3, cadena de certificados completa de Amazon, RTDB/S3/CORS correctamente cerrados). El problema **no es la infraestructura, es lo que se publica en el cliente y cómo se configura el borde (CloudFront)**.

Dos clases de fallo dominan el riesgo real:

1. **Secretos y claves facturables embebidos en el bundle y sin restricción de uso.** Cualquiera que descargue `/assets/index-*.js` obtiene claves de Google Maps que responden `OK` desde cualquier origen (coste imputable al cliente) y un webhook de Slack funcional (canal de confianza interno abusable para phishing). Esto es explotable **hoy, sin habilidad, en minutos**.
2. **Ausencia total de cabeceras de seguridad HTTP** (0/9) servidas desde CloudFront, lo que amplifica cualquier XSS o inyección de terceros y deja la PWA sin defensa en profundidad.

El resto son deudas técnicas conocidas (jQuery/Bootstrap de 2017-2018, dependencia `@latest`, DMARC en `p=none`) con remediación bien documentada.

**Prioridad absoluta (hoy, < 1 día):** rotar/restringir las claves Google, rotar e mover el webhook de Slack a backend, y desplegar cabeceras de seguridad en CloudFront. Esos tres movimientos eliminan el 80 % del riesgo explotable.

### Cuadro de mando

| Severidad | Nº | Hallazgos |
|---|---|---|
| 🔴 Crítica | 4 | #1 Google keys sin restricción · #2 Slack webhook · #3 token hex · #4 UUID token |
| 🔴 Alta | 6 | #5 0/9 headers · #6 DMARC p=none · #7 SPF ~all · #8 dep @latest · #9 demo expuesto · #10 API backend identificable |
| 🟠 Media | 8 | #11 jQuery 3.2.1 · #12 Bootstrap 4.0.0 · #13 sin SRI · #14 sin CAA · #15 soft-404 · #16 lang="en" · #17 FontAwesome 5.0.8 · #18 rutas enumeradas |
| 🟡 Baja/Info | 3 | #19 sin robots/security.txt/favicon · #20 meta description · #21 sin OG tags |
| ✅ Correcto | 7 | TLS 1.1 rechazado (⚠️ ver #22) · RTDB · S3 · CORS · HTTP/3 · TLS 1.3 · cadena cert |

> ⚠️ **Discrepancia importante detectada en la evidencia** — ver §5 y hallazgo **#22**: la sesión más reciente muestra que `openssl s_client -tls1_1` **negocia** (`tls1_1 → OK`), contradiciendo el "descartado ✅" del estado inicial. Debe reverificarse antes de cerrar la auditoría.

---

## 1. Tarea 1 — Cierre de hallazgos pendientes

### 1.1 Identificación de los dos tokens (`<TOKEN_HEX_REDACTED>`, `<UUID_REDACTED>`)

**Evidencia recogida:**

```bash
grep -aoiE "(api[_-]?key|apikey|secret|token|password|bearer)[\"' :=]+[a-z0-9_\-]{16,}" bundle.js
apiKey:"AIzaSy...REDACTED_1
API_KEY:"AIzaSy...REDACTED_2
API_KEY:"AIzaSy...REDACTED_1
API_KEY:"<TOKEN_HEX_REDACTED>      # token hex 32 chars
TOKEN:"<UUID_REDACTED>             # UUID v4
apiKey:"AIzaSy...REDACTED_1
```

El `grep -aoB2 -A2` de contexto **no devolvió ±100 caracteres legibles** porque el bundle está minificado y los tokens quedan pegados a nombres de variable ofuscados de una sola letra. Para atribuirlos hay que extraer más contexto:

```bash
# Ejecutar para cerrar la atribución (aún pendiente):
grep -aoE '.{120}<TOKEN_HEX_REDACTED>.{120}' bundle.js
grep -aoE '.{120}<UUID_REDACTED>.{120}' bundle.js
# Y buscar el identificador de servicio cercano:
strings bundle.js | grep -iE 'growthbook|amplitude|hotjar|sentry|segment|mapbox|cognito|gtm|paycomet|zendesk|hubspot'
```

**Correlación con las librerías confirmadas en el bundle** (de `grep https?://`):

| Servicio presente en bundle | Formato de credencial cliente | ¿Encaja con token pendiente? |
|---|---|---|
| **GrowthBook** (`cdn.growthbook.io`) | Client key SDK: `sdk-xxxxxxxxxxxxxxxx` (no hex de 32) | Posible para el UUID si es `clientKey` |
| **Amplitude** (`api.eu.amplitude.com`, `api2.amplitude.com`) | **API key = hex de 32 caracteres** | **✅ Fuerte candidato para `<TOKEN_HEX_REDACTED>`** |
| **Hotjar** (`static.hotjar.com`) | Site ID numérico | No (no es hex ni UUID) |
| **GTM** (`googletagmanager.com`) | `GTM-XXXXXXX` | No |
| Firebase (varios `*.googleapis.com`) | `AIzaSy...` (ya identificadas) | No (son las Google keys) |
| **PayComet** (router) | `jetToken` / API token | Posible para el UUID |

**Conclusión provisional (requiere el `grep` de contexto para cerrar):**

- **`<TOKEN_HEX_REDACTED>` (hex 32) → muy probablemente la API key de cliente de Amplitude.** Es **pública por diseño** (se envía en cada evento desde el navegador); el riesgo real es **pollution/spoofing de analítica**, no facturación directa. Mitigación: no es secreto, pero conviene usar un proxy de ingest y validación de dominio en Amplitude.
- **`<UUID_REDACTED>` (UUID v4) → candidato a GrowthBook clientKey o a un token de PayComet/config.** Un clientKey de GrowthBook es **público por diseño** (feature flags de cliente). Si en cambio resultara ser un token de PayComet con capacidad de operación, sería **secreto facturable y crítico**.

> **Acción bloqueante para cerrar #3/#4:** ejecutar los dos `grep` de contexto de arriba y confirmar el servicio. Hasta entonces se mantienen como **Crítico "por confirmar"** (principio de precaución): un UUID asociado a pagos cambia la severidad por completo.

### 1.2 ¿El entorno `demo-saas.*` tiene la misma autenticación que producción?

**Evidencia:** `https://demo-saas.TU-DOMINIO.com` aparece en el bundle junto a `api-saas.smartfleet.TU-DOMINIO.com` y `saas.TU-DOMINIO.com`.

**No verificado aún** (y debe hacerse con cuidado, sin credenciales ajenas). Verificación pasiva propuesta:

```bash
# Solo headers y comportamiento de login, SIN intentar autenticarse con datos ajenos:
curl -sI https://demo-saas.TU-DOMINIO.com/
curl -s  https://demo-saas.TU-DOMINIO.com/ | grep -Eo '<title>[^<]*</title>'
# ¿Mismo bundle? ¿Mismo Firebase project? ¿Mismas claves?
curl -s https://demo-saas.TU-DOMINIO.com/ | grep -Eo 'assets/index-[0-9a-f]+\.js'
```

**Riesgo conceptual (hallazgo #9):** los entornos demo suelen compartir el mismo proyecto Firebase / mismo backend con "datos de ejemplo" que a veces son datos reales anonimizados imperfectamente, y con **menos WAF/rate-limiting**. Si `demo-saas` usa las mismas Google keys o el mismo Firebase project que prod, el demo se convierte en un banco de pruebas gratuito para atacar la lógica de prod.

### 1.3 ¿El WAF de CloudFront tiene reglas activas?

**Evidencia recogida (payloads no destructivos):**

```bash
curl -sI -A "sqlmap/1.7" https://app.TU-DOMINIO.com        → HTTP/2 200   (no bloquea UA de escáner)
curl -sI -A "() { :; }"   https://app.TU-DOMINIO.com        → HTTP/2 200   (no bloquea Shellshock UA)
curl -sI "…/?x=<script>alert(1)</script>"                   → HTTP/2 400   (rechazado)
curl -sI "…/?x=scriptalert1script"                          → HTTP/2 200
curl -sI "…/?x=1' OR '1'='1"                                → (sin salida / conexión)
```

**Conclusión:** el `400` ante `<script>` es casi con seguridad **rechazo de caracteres inválidos en la URL por el propio CloudFront/S3, no una regla WAF administrada** (AWS WAF devolvería `403` con cuerpo de bloqueo y a menudo header `x-amzn-waf-*`, ausente aquí). La no-reacción ante `sqlmap/1.7` y ante la cadena Shellshock indica que **no hay un WAF con reglas administradas de OWASP/bots activas**, o están en modo `count`. Dado que es una SPA servida desde S3+CloudFront (contenido estático), la protección WAF relevante está realmente en el **API backend** (`api-saas.smartfleet.*`), que está fuera de alcance. **Recomendación:** confirmar con el equipo si hay AWS WAF asociado a la distribución y, si no, valorar añadir `AWSManagedRulesCommonRuleSet` + reglas de rate-limit **en la capa API**, no tanto en el front estático.

### 1.4 Auditoría de Firestore (endpoint distinto de RTDB)

**Evidencia:** RTDB ya verificado cerrado (`GET /.json?shallow=true → Permission denied` ✅). Firestore **no se ha probado aún**. Verificación pasiva propuesta (REST, solo lectura, sin datos ajenos):

```bash
# Firestore REST usa la misma API key que Firebase (AIzaSy...REDACTED_1):
curl -s "https://firestore.googleapis.com/v1/projects/TU-PROYECTO-FIREBASE/databases/(default)/documents/PROBE_COLECCION_INEXISTENTE?key=AIzaSy...REDACTED_1"
# Resultado esperado si las reglas están bien: 403 PERMISSION_DENIED
# Resultado preocupante: 200 con documentos → reglas abiertas
```

> Usar una colección de prueba inexistente y **no** enumerar colecciones reales. Objetivo: confirmar que las Security Rules deniegan lectura no autenticada, igual que RTDB.

### 1.5 Búsqueda ampliada de secretos por patrón

**Ejecutado** (resultados del bundle):

| Patrón | Resultado |
|---|---|
| Google API keys `AIzaSy...` | ✅ Encontradas (≥2 distintas, `REDACTED_1` y `REDACTED_2`) |
| Slack webhook `hooks.slack.com/services/...` | ✅ Encontrado, funcional |
| Token hex 32 | ✅ Encontrado (`<TOKEN_HEX_REDACTED>`) |
| UUID token | ✅ Encontrado (`<UUID_REDACTED>`) |
| Firebase RTDB URL | ✅ `TU-PROYECTO-FIREBASE-default-rtdb.europe-west1.firebasedatabase.app` |
| S3 de recursos | ✅ `TU-PROYECTO-FIREBASE-resources.s3.eu-west-1.amazonaws.com` |

**Pendiente de ejecutar** (patrones de la Tarea 1.5 que aún no aparecen en la evidencia):

```bash
grep -aoE 'AKIA[0-9A-Z]{16}'            bundle.js   # AWS access key ID (long-term)
grep -aoE 'ASIA[0-9A-Z]{16}'            bundle.js   # AWS STS temporal
grep -aoE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' bundle.js
grep -aoE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' bundle.js  # JWT
grep -aoE '(sk|pk)_live_[0-9A-Za-z]{16,}' bundle.js  # Stripe live
grep -aoE '[a-z]{2}-[a-z]+-[0-9]_[A-Za-z0-9]{9}' bundle.js  # Cognito pool id (p.ej. eu-west-1_XXXXXXXXX)
```

> El backend usa PayComet (no Stripe), así que `sk_live_/pk_live_` probablemente den vacío — documentarlo igual (§ "aprendizaje"). No se han observado en la evidencia indicios de AWS keys ni private keys en el bundle; **debe confirmarse ejecutando los greps** antes de dar por limpio este punto.

---

## 2. Tarea 2 — Análisis de exposición del bundle

### 2.1 Endpoints backend llamados desde el cliente

De `grep -aoiE "https?://..."` sobre `bundle.js`:

| Host | Rol | Nota de seguridad |
|---|---|---|
| `api-saas.smartfleet.TU-DOMINIO.com` | **API principal** | Nombre interno del producto SaaS ("smartfleet") expuesto → **#10** |
| `saas.TU-DOMINIO.com` | Portal/backend SaaS | — |
| `demo-saas.TU-DOMINIO.com` | **Entorno demo** | **#9** — superficie adicional |
| `firebase.googleapis.com`, `firebaseinstallations.googleapis.com`, `fcmregistrations.googleapis.com` | Firebase Auth/Installations/FCM push | Config pública por diseño |
| `*-default-rtdb.europe-west1.firebasedatabase.app` | Realtime DB | ✅ cerrado |
| `*-resources.s3.eu-west-1.amazonaws.com` | Bucket recursos | ✅ `AccessDenied` |
| `maps.googleapis.com` | Google Maps/Geocoding/Directions | **#1** claves sin restricción |
| `api.eu.amplitude.com`, `api2.amplitude.com` | Analítica | Ver #3 |
| `cdn.growthbook.io` | Feature flags | Ver #4 |
| `static.hotjar.com` | Session replay | **RGPD**: replay puede capturar PII/pantallas |
| `www.googletagmanager.com` | GTM | Cadena de terceros no controlada |
| `hooks.slack.com` | **Webhook interno** | **#2** crítico |

### 2.2 Parámetros ID en rutas → riesgo IDOR

Rutas con `:id` enumeradas desde el router del bundle:

```
/delivery/:id
/delivery/:id/signature
/create-delivery/:id
/create-return/:id
/make-delivery/:id
/make-return/:id
/addons-replacers/recharging-locations/:id
```

**Análisis de riesgo IDOR (OWASP A01:2021 – Broken Access Control / CWE-639):**

Estas rutas son **de cliente** (Angular/Ionic router), no endpoints de API por sí mismas — pero **reflejan** la forma de los endpoints API subyacentes (p.ej. `GET /api/delivery/{id}`, `GET /api/delivery/{id}/signature`). El riesgo:

- Si el backend **autoriza por posesión del ID** en lugar de por propiedad del recurso vinculada al usuario autenticado, un atacante autenticado puede iterar `:id` y leer entregas/firmas de otros clientes.
- **`/delivery/:id/signature` es especialmente sensible**: una firma manuscrita es dato personal (RGPD, potencialmente categoría especial si se usa para identificación). Un IDOR aquí es fuga de PII con impacto legal directo.

> **No verificable pasivamente sin autenticación ni sin tocar datos ajenos** (está fuera de alcance / prohibido). Se documenta como **riesgo a validar en un pentest autenticado autorizado**, con el equipo, usando **dos cuentas de prueba propias** y comprobando si la cuenta A puede leer el `:id` de la cuenta B. Recomendación preventiva: que el API valide `recurso.owner == token.sub` en cada endpoint con `:id`, y use IDs no secuenciales (UUID) para no facilitar la enumeración.

### 2.3 Variables de configuración embebidas

| Config | Valor (anonimizado) | ¿Sensible? |
|---|---|---|
| Firebase project | `TU-PROYECTO-FIREBASE` | Público por diseño (pero revela naming) |
| Firebase RTDB region | `europe-west1` | Info |
| Google Maps key(s) | `AIzaSy...REDACTED_1/2` | **Sí — #1** |
| Amplitude key | `<TOKEN_HEX_REDACTED>` | Público por diseño, spoofeable |
| GrowthBook clientKey | `<UUID_REDACTED>` (probable) | Público por diseño |
| Slack webhook | `hooks.slack.com/services/...` | **Sí — secreto, #2** |
| Pasarela de pago | `paycomet` (ruta `/paycomet`) | Info — PCI-DSS aplica |
| Hotjar | site en `static.hotjar.com` | RGPD (replay) |

---

## 3. Tarea 3 — Análisis de cadena de suministro

### 3.1 Dependencias externas cargadas por el cliente

Del HTML servido y del bundle:

| Recurso | Versión | Origen | Año | Riesgo |
|---|---|---|---|---|
| jQuery | **3.2.1** | `//cdnjs.cloudflare.com` (protocol-relative) | 2017 | **#11** CVE-2019-11358, CVE-2020-11022, CVE-2020-11023 (XSS via `$.htmlPrefilter`/`html()`) |
| Bootstrap JS | **4.0.0** | `//maxcdn.bootstrapcdn.com` (protocol-relative) | 2018 | **#12** CVE-2018-14040/14041/14042, CVE-2019-8331 (XSS en tooltip/popover/data-target) |
| FontAwesome | **5.0.8** | `use.fontawesome.com` | 2018 | **#17** versión antigua |
| bootstrap-icons | 1.11.3 | `cdn.jsdelivr.net` | reciente | OK (solo CSS) |
| @ionic/pwa-elements | **`@latest`** | `unpkg.com` | mutable | **#8** versión no reproducible; unpkg puede servir cualquier build futuro |

**Problemas transversales:**

- **Protocol-relative URLs (`//cdnjs...`)**: en un contexto ya HTTPS no degradan, pero son mala práctica.
- **Sin SRI (`integrity=`)** en ninguno de los `<script>`/`<link>` de terceros (**#13**): si cualquiera de esos CDNs (cdnjs, maxcdn, unpkg, fontawesome) es comprometido o secuestrado, se ejecuta JS arbitrario en el dominio de la app **con acceso a la sesión del usuario**. `@latest` en unpkg es el peor caso: **no hay ni siquiera una versión fija que "pinnear" con SRI**.

### 3.2 Propuesta: auto-hospedaje vs. SRI vs. versión fija

| Opción | Esfuerzo | Beneficio | Recomendación |
|---|---|---|---|
| **Versión fija + SRI** en el CDN actual | Bajo (1 día) | Elimina secuestro de CDN y build mutable | **Mínimo imprescindible** para jQuery, Bootstrap, FontAwesome |
| **Auto-hospedaje** en S3/CloudFront propio | Medio (2-3 días) | Elimina dependencia de 4 orígenes externos; permite CSP `script-src 'self'`; mejora privacidad (no filtra IPs de usuarios a CDNs) | **Objetivo final recomendado** — coherente con CSP estricta |
| Mantener `@latest` | — | — | **Inaceptable** — romper#8 primero |

**Recomendación:** auto-hospedar los 4 recursos de terceros en el mismo bucket S3 de la app. Resultado: se puede aplicar una CSP `script-src 'self'` estricta (ver #5) sin excepciones de CDN, y desaparecen #8 y #13 de golpe.

### 3.3 Plan de migración de jQuery/Bootstrap sin romper la app

Angular/Ionic **no necesita jQuery ni Bootstrap JS**; su presencia suele ser residuo de un template o de un componente concreto. Plan por fases:

1. **Auditar uso real** (1 día): `grep -rE '\$\(|jQuery|\.modal\(|\.tooltip\(|\.popover\(|data-toggle' src/`. Si el uso es nulo o mínimo → **eliminar** ambos directamente (mejor que actualizar).
2. **Si hay uso residual**:
   - jQuery 3.2.1 → **3.7.1** (compatible hacia atrás en la práctica; corrige los 3 CVEs). Fijar versión + SRI.
   - Bootstrap 4.0.0 → **4.6.2** (última de la rama 4, sin salto mayor a 5, corrige CVEs de tooltip/popover). Fijar versión + SRI.
3. **Sustituir componentes** de Bootstrap por sus equivalentes Ionic (`ion-modal`, `ion-popover`) de forma incremental, y retirar Bootstrap por completo en una fase posterior.
4. **FontAwesome 5.0.8 → 6.x** o migrar a `ion-icon`/`bootstrap-icons` (que ya está cargado) para reducir a un solo set de iconos.
5. **@ionic/pwa-elements**: fijar a la versión concreta que use el proyecto (p.ej. `@3.x.x`) + SRI, o auto-hospedar.

Validar en cada fase con la suite E2E existente y un smoke test manual del flujo crítico (reservar → abrir → cerrar taquilla).

---

## 4. Informe estructurado por hallazgo

### [#1] Google API keys sin restricción por referrer/IP
- **Severidad:** 🔴 Crítica
- **Categoría:** OWASP A05:2021 (Security Misconfiguration) / A07 (Identification/Auth failures) · CWE-798 (Use of Hard-coded Credentials), CWE-284
- **Evidencia:**
  ```bash
  curl -s "https://maps.googleapis.com/maps/api/geocode/json?address=Madrid&key=AIzaSy...REDACTED_1"  → "status":"OK"
  curl -s "https://maps.googleapis.com/maps/api/geocode/json?address=Madrid&key=AIzaSy...REDACTED_2"  → "status":"OK"
  # Matriz de APIs habilitadas en REDACTED_1:
  geocode → OK · directions → OK · distancematrix → REQUEST_DENIED · timezone → REQUEST_DENIED · elevation → REQUEST_DENIED · places → HTTP 404
  ```
  La respuesta `OK` **desde un cliente curl sin cabecera `Referer`** demuestra que la restricción "HTTP referrers" no está aplicada (o la key es de servidor sin restricción de IP). Geocoding y Directions están habilitados y facturables.
- **Impacto:** [técnico] cualquiera extrae la key del bundle y la usa. [negocio] **facturación ajena**: Geocoding ≈ 5 $/1000 req, Directions ≈ 5 $/1000 req; un script puede generar **miles de € en horas** contra la cuenta de Google Cloud del cliente hasta agotar cuota o presupuesto.
- **Explotabilidad:** trivial. Atacante sin habilidad, sin acceso privilegiado, en < 5 min (descargar bundle + `curl`).
- **Detección:** **probablemente no** se detectaría hasta la factura de Google Cloud o una alerta de presupuesto. No hay señal en logs de la app (las llamadas van directas de cliente/atacante a Google).
- **Remediación:**
  1. En Google Cloud Console → APIs & Services → Credentials, **restringir cada key**:
     - Keys usadas desde navegador (Maps JS): *Application restriction* = **HTTP referrers** → `https://app.TU-DOMINIO.com/*` (y demo si aplica).
     - *API restriction* = solo las APIs realmente usadas (Maps JS, Geocoding, Directions). Deshabilitar el resto.
  2. **Rotar** ambas keys (ya están comprometidas al estar públicas e indexables).
  3. Fijar **cuotas diarias** y **alertas de presupuesto** como red de contención.
  4. Para llamadas server-side, mover la key al backend y **nunca** exponerla en el bundle.
- **Verificación post-fix:**
  ```bash
  # Debe devolver REQUEST_DENIED sin referer autorizado:
  curl -s "https://maps.googleapis.com/maps/api/geocode/json?address=Madrid&key=NUEVA_KEY" | grep status
  # y OK solo con el referer correcto:
  curl -s -H "Referer: https://app.TU-DOMINIO.com/" "https://maps.googleapis.com/maps/api/js?key=NUEVA_KEY" -o /dev/null -w "%{http_code}"
  ```
- **Referencias:** [Google Maps API key best practices](https://developers.google.com/maps/api-security-best-practices), CWE-798.

### [#2] Slack incoming webhook funcional embebido en el bundle
- **Severidad:** 🔴 Crítica
- **Categoría:** OWASP A05:2021 / A01 · CWE-798, CWE-522 (Insufficiently Protected Credentials)
- **Evidencia:**
  ```bash
  grep -aoiE "https://hooks\.slack\.com/services/[A-Z0-9]{9,}/[A-Z0-9]{9,}/[A-Za-z0-9]{20,}" bundle.js
  https://hooks.slack.com/services/T.../B.../<REDACTED>
  ```
  (No se ha enviado ningún mensaje de prueba — restricción ética explícita. Un incoming webhook de Slack acepta `POST` sin autenticación adicional por diseño.)
- **Impacto:** [técnico] cualquiera con el webhook puede **publicar mensajes arbitrarios en el canal de Slack interno** al que apunta. [negocio] **phishing interno por canal de confianza**: un atacante publica "Alerta: reset de contraseña requerido, pulsa aquí" con la identidad del bot/canal habitual, y los empleados confían porque viene "de dentro". También spam/ruido y posible ingeniería social hacia soporte/ops.
- **Explotabilidad:** trivial (un `POST` con `{"text":"..."}`). Sin habilidad.
- **Detección:** los mensajes aparecen en el canal, pero **sin trazabilidad del origen** (Slack no revela quién posee el webhook). El equipo vería mensajes raros pero no sabría el vector.
- **Remediación:**
  1. **Revocar el webhook inmediatamente** (Slack → App → Incoming Webhooks → eliminar). Esto lo invalida al instante.
  2. Recrear el webhook **solo en el backend**; el cliente nunca debe notificar a Slack directamente. El flujo correcto: cliente → API backend autenticada → Slack.
  3. Auditar el canal por mensajes no legítimos publicados mientras estuvo expuesto.
- **Verificación post-fix:**
  ```bash
  grep -aoiE "hooks\.slack\.com/services/" bundle_nuevo.js   # debe devolver vacío
  # El webhook viejo debe dar 404/no_service (verificable sin enviar contenido real):
  curl -s -o /dev/null -w "%{http_code}\n" -X POST https://hooks.slack.com/services/T.../B.../<REDACTED>  # esperado: 404
  ```
- **Referencias:** [Slack webhook security](https://api.slack.com/messaging/webhooks#handling_errors), CWE-798.

### [#3] Token hexadecimal de 32 caracteres sin contexto cerrado
- **Severidad:** 🔴 Crítica (por confirmar — probable Amplitude, público por diseño → bajaría a Baja)
- **Categoría:** CWE-200 (Exposure of Sensitive Information) — pendiente de clasificar
- **Evidencia:** `API_KEY:"<TOKEN_HEX_REDACTED>"` en `bundle.js`. Atribución provisional: **Amplitude client API key** (formato hex 32 coincide; Amplitude está cargado). Cierre pendiente del `grep` de contexto (§1.1).
- **Impacto:** si es Amplitude → pollution de datos de analítica (falsear eventos), no facturación directa ni fuga. Si fuera otro servicio con capacidad de escritura/facturación → reevaluar.
- **Explotabilidad / Detección / Remediación:** ver §1.1. Si se confirma Amplitude: aceptable como público, pero proteger con validación de dominio en el panel de Amplitude y proxy de ingest opcional.
- **Verificación post-fix:** confirmar servicio con el `grep .{120}` y, si es Amplitude, verificar restricción de dominio en su consola.
- **Referencias:** [Amplitude API key visibility](https://amplitude.com/docs).

### [#4] UUID token sin contexto cerrado
- **Severidad:** 🔴 Crítica (por confirmar — probable GrowthBook clientKey → Baja; si PayComet → se mantiene Crítica)
- **Categoría:** CWE-200 / CWE-798 — pendiente
- **Evidencia:** `TOKEN:"<UUID_REDACTED>"` en `bundle.js`. Candidatos: GrowthBook clientKey (público) o token PayComet (secreto/facturable). **No cerrado.**
- **Impacto / Remediación:** ver §1.1. **Bloqueante:** si se asocia a PayComet con capacidad de operación de pago → Crítico real, rotar y mover a backend de inmediato (PCI-DSS 4.0 req. 6.4.3/12.3).
- **Verificación post-fix:** `grep .{120}<UUID_REDACTED>.{120}` + confirmar con el equipo a qué servicio pertenece.
- **Referencias:** PCI-DSS 4.0, [GrowthBook client keys](https://docs.growthbook.io).

### [#5] Ausencia total de cabeceras de seguridad HTTP (0/9)
- **Severidad:** 🔴 Alta
- **Categoría:** OWASP A05:2021 · CWE-693 (Protection Mechanism Failure), CWE-1021 (clickjacking)
- **Evidencia:**
  ```bash
  H=$(curl -sI https://app.TU-DOMINIO.com)
  # Ausentes: HSTS, CSP, X-Content-Type-Options, X-Frame-Options,
  # Referrer-Policy, Permissions-Policy, COOP, COEP, CORP  → 0/9
  ```
- **Impacto:** [técnico] sin CSP, cualquier XSS (propio o vía CDN comprometido, ver #13) ejecuta sin freno; sin X-Frame-Options/CSP frame-ancestors, la app es **encuadrable → clickjacking** sobre acciones de abrir/cerrar taquilla; sin HSTS, ventana a downgrade/SSL-strip en el primer acceso; sin X-Content-Type-Options, MIME-sniffing. [negocio] amplifica el impacto de cualquier otro fallo de front.
- **Explotabilidad:** habilita/amplifica otros ataques; no explotable por sí solo, pero es defensa en profundidad ausente.
- **Detección:** no genera logs; es una omisión de configuración.
- **Remediación:** añadir un **CloudFront Response Headers Policy** (la evidencia ya contiene un borrador JSON de `SecurityHeadersConfig`). Config recomendada:
  ```
  Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: strict-origin-when-cross-origin
  Content-Security-Policy: default-src 'self'; img-src 'self' data: https:;
      script-src 'self' https://maps.googleapis.com;  (ajustar tras auto-hospedar terceros)
      style-src 'self' 'unsafe-inline'; connect-src 'self' https://*.TU-DOMINIO.com
      https://*.googleapis.com https://*.amplitude.com https://cdn.growthbook.io;
      frame-ancestors 'none'
  Permissions-Policy: geolocation=(self), camera=(), microphone=()
  Cross-Origin-Opener-Policy: same-origin
  ```
  > La CSP debe desplegarse primero en `Content-Security-Policy-Report-Only` unos días para no romper la PWA (geoloc, mapas, Firebase, Hotjar), y luego pasarla a enforcing. `frame-ancestors 'none'` sustituye eficazmente a X-Frame-Options.
- **Verificación post-fix:**
  ```bash
  for h in strict-transport-security content-security-policy x-content-type-options x-frame-options referrer-policy permissions-policy; do
    curl -sI https://app.TU-DOMINIO.com | grep -qi "^$h" && echo "OK $h" || echo "FALTA $h"; done
  ```
- **Referencias:** [OWASP Secure Headers Project](https://owasp.org/www-project-secure-headers/), [MDN CSP](https://developer.mozilla.org/docs/Web/HTTP/CSP).

### [#6] DMARC en `p=none`
- **Severidad:** 🔴 Alta
- **Categoría:** OWASP (email spoofing) · CWE-16 · NIST 800-177
- **Evidencia:**
  ```
  _dmarc.TU-DOMINIO.com TXT "v=DMARC1; p=none; rua=mailto:security@...; ruf=mailto:security@...; fo=1;"
  ```
- **Impacto:** `p=none` solo monitoriza; **no bloquea** correos falsificados que pasen a la bandeja de entrada de clientes/empleados suplantando el dominio. Habilita phishing con remitente `@TU-DOMINIO.com`.
- **Remediación:** endurecer por fases usando los informes `rua` ya activos: `p=none` → `p=quarantine; pct=25` → `pct=100` → `p=reject`. Confirmar antes que SPF+DKIM alinean para todo el correo legítimo (Google Workspace, Zendesk, HubSpot).
- **Verificación post-fix:** `dig TXT _dmarc.TU-DOMINIO.com +short` → debe mostrar `p=reject` (o `quarantine`).
- **Referencias:** RFC 7489, [dmarc.org](https://dmarc.org/overview/).

### [#7] SPF con `~all` (softfail)
- **Severidad:** 🔴 Alta (ligada a #6)
- **Categoría:** email spoofing · CWE-16
- **Evidencia:**
  ```
  TU-DOMINIO.com TXT "v=spf1 include:_spf.google.com include:mail.zendesk.com include:XXXXXXX.spf02.hubspotemail.net ip4:X.X.X.X ~all"
  ```
- **Impacto:** `~all` (softfail) pide a los receptores **aceptar pero marcar**, no rechazar. Muchos MTA entregan igualmente.
- **Remediación:** una vez validado que todos los emisores legítimos están en el registro (Google, Zendesk, HubSpot, la IP), cambiar `~all` → `-all` (hardfail). Hacerlo **coordinado con #6** (DMARC reject depende de SPF/DKIM sólidos). Vigilar el límite de 10 lookups DNS de SPF.
- **Verificación post-fix:** `dig TXT TU-DOMINIO.com +short | grep spf1` → termina en `-all`.
- **Referencias:** RFC 7208.

### [#8] Dependencia `@latest` en unpkg
- **Severidad:** 🔴 Alta
- **Categoría:** OWASP A08:2021 (Software & Data Integrity Failures) · A06 · CWE-1104 (Use of Unmaintained/Unpinned Third-Party Components)
- **Evidencia:**
  ```html
  <script src="https://unpkg.com/@ionic/pwa-elements@latest/dist/.../ionicpwaelements.js">
  ```
- **Impacto:** `@latest` sirve **cualquier build futuro** sin control; una versión maliciosa o con regresión entra en producción automáticamente. Build no reproducible. No permite SRI.
- **Remediación:** fijar versión concreta (la que valide el proyecto) o auto-hospedar (ver §3.2). Añadir SRI tras fijar.
- **Verificación post-fix:** `curl -s https://app.TU-DOMINIO.com | grep pwa-elements` → no debe contener `@latest`.
- **Referencias:** OWASP A08:2021, CWE-1104.

### [#9] Entorno demo expuesto (`demo-saas.*`)
- **Severidad:** 🔴 Alta
- **Categoría:** OWASP A05:2021 · CWE-668 (Exposure of Resource to Wrong Sphere)
- **Evidencia:** `https://demo-saas.TU-DOMINIO.com` referenciado en bundle. Autenticación equivalente a prod **no verificada** (§1.2).
- **Impacto:** superficie de ataque adicional, típicamente con menos hardening/WAF y a veces datos reales. Si comparte Firebase project o keys con prod, es un laboratorio de ataque contra la lógica de prod.
- **Remediación:** confirmar con el equipo si debe estar público; si es solo interno, protegerlo tras VPN/basic-auth/allowlist de IP en CloudFront; garantizar que usa proyecto Firebase y keys **separados** de prod y datos sintéticos.
- **Verificación post-fix:** `curl -sI https://demo-saas.TU-DOMINIO.com` → 401/403 si se restringe, o confirmación de datos sintéticos y proyecto aislado.
- **Referencias:** CWE-668.

### [#10] API SaaS backend identificable (`api-saas.smartfleet.*`)
- **Severidad:** 🔴 Alta (informativa-alta)
- **Categoría:** OWASP A05 · CWE-200
- **Evidencia:** `https://api-saas.smartfleet.TU-DOMINIO.com` en bundle — revela el nombre del producto backend ("smartfleet") y el host de API.
- **Impacto:** reconocimiento facilitado; no es vulnerabilidad per se (toda SPA llama a su API), pero combinado con #2.2 (rutas `:id`) orienta al atacante hacia los endpoints IDOR-candidatos.
- **Remediación:** no es directamente remediable (el cliente debe conocer su API). Mitigar **el impacto**: autorización robusta por recurso en el API (ver #2.2), rate-limiting y WAF en la capa API, no en el front.
- **Verificación post-fix:** revisión de controles de autorización del API en pentest autenticado autorizado.
- **Referencias:** CWE-200.

### [#11] jQuery 3.2.1 (2017) — CVEs conocidos
- **Severidad:** 🟠 Media
- **Categoría:** OWASP A06:2021 (Vulnerable & Outdated Components) · CWE-1104 · CVE-2019-11358, CVE-2020-11022, CVE-2020-11023
- **Evidencia:** `src="//cdnjs.cloudflare.com/ajax/libs/jquery/3.2.1/jquery.min.js"`
- **Impacto:** XSS vía `jQuery.htmlPrefilter`/`.html()`/`.append()` con HTML controlado por atacante; prototype pollution (CVE-2019-11358). Explotable solo si la app pasa HTML no saneado a jQuery.
- **Remediación:** eliminar si no se usa, o actualizar a 3.7.1 + SRI (§3.3).
- **Verificación post-fix:** `curl -s https://app.TU-DOMINIO.com | grep -o 'jquery/[0-9.]*'` → ≥ 3.7.1, o ausente.
- **Referencias:** CVE-2020-11022, CVE-2020-11023, CVE-2019-11358.

### [#12] Bootstrap 4.0.0 (2018) — CVEs conocidos
- **Severidad:** 🟠 Media
- **Categoría:** OWASP A06 · CWE-79 · CVE-2018-14040/14041/14042, CVE-2019-8331
- **Evidencia:** `src="//maxcdn.bootstrapcdn.com/bootstrap/4.0.0/js/bootstrap.min.js"`
- **Impacto:** XSS en tooltip/popover/collapse/scrollspy vía atributos `data-*` controlados por atacante (CVE-2019-8331 en 4.x < 4.3.1).
- **Remediación:** eliminar si no se usa, o actualizar a 4.6.2 + SRI; migrar componentes a Ionic (§3.3).
- **Verificación post-fix:** `curl -s https://app.TU-DOMINIO.com | grep -o 'bootstrap/[0-9.]*'` → ≥ 4.6.2, o ausente.
- **Referencias:** CVE-2019-8331.

### [#13] Sin SRI en scripts/estilos de terceros
- **Severidad:** 🟠 Media
- **Categoría:** OWASP A08:2021 · CWE-353 (Missing Support for Integrity Check)
- **Evidencia:** ninguno de los `<script>`/`<link>` a cdnjs, maxcdn, unpkg, fontawesome lleva `integrity=`.
- **Impacto:** un CDN comprometido o secuestrado ejecuta JS arbitrario en `app.TU-DOMINIO.com` con la sesión del usuario (robo de token Firebase, acciones sobre taquillas).
- **Remediación:** añadir `integrity="sha384-..." crossorigin="anonymous"` a cada recurso de versión fija; para `@latest` (#8) no es posible → fijar versión primero o auto-hospedar (§3.2).
- **Verificación post-fix:** `curl -s https://app.TU-DOMINIO.com | grep -E 'unpkg|cdnjs|maxcdn|fontawesome'` → todos con `integrity=`, o auto-hospedados.
- **Referencias:** [MDN SRI](https://developer.mozilla.org/docs/Web/Security/Subresource_Integrity).

### [#14] Sin registro CAA
- **Severidad:** 🟠 Media
- **Categoría:** CWE-295 (Improper Certificate Validation, preventivo)
- **Evidencia:** `dig CAA TU-DOMINIO.com` → (vacío).
- **Impacto:** cualquier CA pública puede emitir certificados para el dominio; sin CAA no hay barrera declarativa frente a emisión no autorizada (mis-issuance).
- **Remediación:** publicar CAA limitando a Amazon (ya que se usa ACM):
  ```
  TU-DOMINIO.com. CAA 0 issue "amazon.com"
  TU-DOMINIO.com. CAA 0 iodef "mailto:security@TU-DOMINIO.com"
  ```
- **Verificación post-fix:** `dig CAA TU-DOMINIO.com +short` → debe listar `amazon.com`.
- **Referencias:** RFC 8659.

### [#15] SPA fallback total (soft-404)
- **Severidad:** 🟠 Media
- **Categoría:** CWE-200 (info) · calidad
- **Evidencia:** `/`, `/home`, `/login`, `/admin`, `/api`, `/graphql` → todos **HTTP 200** con HTML idéntico (`diff` → IDÉNTICOS). Solo `/robots.txt`, `/favicon.ico`, `/.well-known/security.txt` dan 404 real.
- **Impacto:** toda ruta responde 200, dificultando que crawlers/monitorización distingan rutas reales; facilita enumeración ciega y confunde SEO. Bajo riesgo directo.
- **Remediación:** configurar CloudFront para servir `index.html` en 200 **solo para rutas de app conocidas** y devolver 404 real para el resto, o al menos servir un 404 semántico. Es una decisión de UX/SEO más que de seguridad estricta.
- **Verificación post-fix:** `curl -s -o /dev/null -w "%{http_code}" https://app.TU-DOMINIO.com/ruta-inexistente-xyz` → 404.
- **Referencias:** Google SEO soft-404 guidelines.

### [#16] `<html lang="en">` en app en español
- **Severidad:** 🟠 Media (accesibilidad/SEO, no seguridad)
- **Evidencia:** `curl -s ... | grep '<html'` → `<html lang="en">` pese a rutas en español (`/activa-suscripcion`, `/cambiar-metodo-pago`).
- **Impacto:** lectores de pantalla usan pronunciación inglesa; SEO incorrecto. Sin impacto de seguridad.
- **Remediación:** `<html lang="es">` (o dinámico según i18n).
- **Verificación post-fix:** `curl -s https://app.TU-DOMINIO.com | grep '<html'` → `lang="es"`.
- **Referencias:** WCAG 3.1.1.

### [#17] FontAwesome 5.0.8 (2018)
- **Severidad:** 🟠 Media
- **Categoría:** OWASP A06 · CWE-1104
- **Evidencia:** `href="https://use.fontawesome.com/releases/v5.0.8/css/all.css"`
- **Impacto:** versión antigua sin mantenimiento; superficie menor (principalmente CSS/fuentes).
- **Remediación:** actualizar a 6.x o consolidar en `bootstrap-icons`/`ion-icon` (ya presentes) para reducir dependencias.
- **Verificación post-fix:** `curl -s https://app.TU-DOMINIO.com | grep fontawesome` → v6.x o ausente.
- **Referencias:** CWE-1104.

### [#18] Estructura completa del router enumerada en el bundle
- **Severidad:** 🟠 Media
- **Categoría:** CWE-200 (Information Exposure)
- **Evidencia:** `grep path:"..."` revela todas las rutas: `/accidents`, `/assign-vehicle`, `/create-delivery/:id`, `/delivery/:id/signature`, `/paycomet`, `/logout`, etc.
- **Impacto:** un atacante mapea toda la funcionalidad (incl. flujos de pago, firma, admin) sin esfuerzo. Inherente a las SPA, pero orienta el ataque a los endpoints API sensibles.
- **Remediación:** no se puede ocultar el router de una SPA; **mitigar el impacto** garantizando autorización server-side en cada endpoint (ver #2.2). No exponer rutas de funcionalidad no lanzada.
- **Verificación post-fix:** revisión de autorización en pentest autenticado.
- **Referencias:** CWE-200.

### [#19] Sin `robots.txt`, `security.txt`, `favicon.ico`
- **Severidad:** 🟡 Baja/Info
- **Evidencia:** `/robots.txt → 404`, `/.well-known/security.txt → 404`, `/favicon.ico → 404`.
- **Impacto:** sin `security.txt` no hay canal claro para reportes de vulnerabilidad (mala práctica de divulgación responsable); sin favicon, detalle de pulido.
- **Remediación:** publicar `/.well-known/security.txt` (RFC 9116) con `Contact: mailto:security@TU-DOMINIO.com` y `Expires:`; añadir `robots.txt` y `favicon.ico`.
- **Verificación post-fix:** `curl -s -o /dev/null -w "%{http_code}" https://app.TU-DOMINIO.com/.well-known/security.txt` → 200.
- **Referencias:** RFC 9116.

### [#20] `<meta name="description">` genérico
- **Severidad:** 🟡 Info (SEO) — `content="TU-APP App"`. Remediar con descripción real. Sin impacto de seguridad.

### [#21] Sin Open Graph tags
- **Severidad:** 🟡 Info (social preview) — añadir `og:title/description/image`. Sin impacto de seguridad.

### [#22] ⚠️ Discrepancia TLS 1.1 — verificación contradictoria
- **Severidad:** 🔴 Alta **si se confirma** que TLS 1.1 negocia (RFC 8996 lo prohíbe) · 🟡 falso positivo si no
- **Categoría:** NIST SP 800-52r2, RFC 8996 · CWE-326 (Inadequate Encryption Strength)
- **Evidencia contradictoria:**
  ```bash
  # Estado inicial decía: TLS 1.1 rechazado ✅
  # Pero la sesión posterior muestra:
  for v in tls1_1 tls1_2 tls1_3; do ... ; done
    tls1_1 → OK
    tls1_2 → OK
    tls1_3 → OK
  # Y a la vez:
  echo | openssl s_client ... -tls1_1  →  "New, (NONE), Cipher is (NONE)" / "Protocol: TLSv1.3"
  ```
  El segundo comando sugiere que **la conexión TLS 1.1 no completó handshake** (cipher NONE, protocolo reportado 1.3), lo que indicaría rechazo — pero el bucle `grep "Cipher is"` marcó `OK`. **La evidencia es ambigua y probablemente el `OK` del bucle es un falso positivo del grep** (matchea "Cipher is (NONE)").
- **Impacto:** si TLS 1.1 realmente negociara, incumpliría RFC 8996/NIST 800-52r2/PCI-DSS 4.0. Dado que CloudFront con una security policy moderna (TLSv1.2_2021) rechaza 1.0/1.1, lo más probable es que **esté correctamente rechazado** y el bucle engañe.
- **Remediación / verificación (bloqueante para cerrar):**
  ```bash
  echo | openssl s_client -connect app.TU-DOMINIO.com:443 -tls1_1 2>&1 | grep -E "Protocol|Cipher is|alert|handshake"
  # Rechazo correcto = "no protocols available" / alert / "Cipher is (NONE)" con Protocol (NONE)
  ```
  Confirmar además la **CloudFront security policy** (debe ser `TLSv1.2_2021` o superior).
- **Referencias:** RFC 8996, NIST SP 800-52r2.

---

## 5. Hallazgos "descartados" — revisión

| Servicio | Verificación | Resultado | Nota |
|---|---|---|---|
| Firebase RTDB | `GET /.json?shallow=true` | `Permission denied` ✅ | Correcto |
| S3 recursos | `GET /?list-type=2` | `AccessDenied` ✅ | Correcto |
| CORS | `Origin: evil.example` | no refleja ✅ | Correcto |
| HTTP/3 | `curl --http3` | HTTP/3 200 ✅ | Correcto |
| TLS 1.3 | handshake | `TLS_AES_128_GCM_SHA256` + X25519MLKEM768 ✅ | Excelente (híbrido PQC) |
| Cadena cert | `-showcerts` | 3 niveles, Amazon RSA ✅ | Correcto (cert `*.app.TU-DOMINIO.com` wildcard de 1 nivel) |
| **TLS 1.1** | `-tls1_1` | **⚠️ ambiguo** | **Ver #22 — reverificar** |

> **Nota sobre el certificado:** es wildcard `*.app.TU-DOMINIO.com` (SAN: `*.app.TU-DOMINIO.com`, `app.TU-DOMINIO.com`). Cubre un solo nivel bajo `app`. Correcto, pero conviene vigilar la caducidad (la evidencia calculó "Días restantes: XX" — monitorizar con alerta < 30 días; ACM suele auto-renovar).

---

## 6. Tarea 4 — Modelo de amenazas (críticos y altos)

### Amenaza A — Abuso de Google API keys (#1)
- **Vector:** (1) descargar `/assets/index-*.js`; (2) `grep AIzaSy`; (3) bucle de `curl` a Geocoding/Directions hasta agotar presupuesto.
- **Requisitos:** habilidad nula, sin acceso, < 5 min, sin coste para el atacante.
- **Impacto:** económico directo (factura Google Cloud, miles €); posible interrupción del servicio de mapas si se agota cuota.
- **Detección actual:** ninguna hasta facturación/alerta de presupuesto. Invisible en logs de la app.
- **Mitigación:** quick win = restricción por referrer + cuotas + rotación (15 min–1 h).

### Amenaza B — Phishing interno vía Slack webhook (#2)
- **Vector:** (1) extraer webhook del bundle; (2) `POST {"text":"<mensaje de phishing>"}` al canal interno.
- **Requisitos:** habilidad nula, < 5 min.
- **Impacto:** reputacional/operacional; ingeniería social a empleados desde canal de confianza; posible pivote a credenciales.
- **Detección actual:** el equipo ve mensajes raros pero sin saber el origen ni el vector.
- **Mitigación:** quick win = revocar webhook (5 min); estructural = notificar a Slack solo desde backend.

### Amenaza C — Secuestro de CDN de terceros (#8, #13)
- **Vector:** comprometer/secuestrar unpkg/cdnjs/maxcdn (o esperar a que `@latest` sirva un build malicioso) → JS arbitrario en la app → robo de token Firebase de sesión → operaciones sobre taquillas del usuario.
- **Requisitos:** habilidad alta (comprometer un CDN) **o** baja (si un mantenedor de `@ionic/pwa-elements` publica versión maliciosa, `@latest` la sirve sola). Tiempo variable.
- **Impacto:** compromiso masivo de sesiones de usuario; apertura no autorizada de taquillas; fuga de PII.
- **Detección actual:** ninguna (sin SRI no hay verificación de integridad; sin CSP no hay report-uri).
- **Mitigación:** fijar versiones + SRI (1 día); auto-hospedar + CSP `script-src 'self'` (1 semana).

### Amenaza D — XSS amplificado por ausencia de CSP (#5, #11, #12)
- **Vector:** XSS reflejado/almacenado (propio de la app, o vía #11/#12) sin CSP que lo contenga → ejecución completa en el origen.
- **Requisitos:** habilidad media; requiere encontrar un sink XSS.
- **Impacto:** robo de sesión, clickjacking sobre abrir/cerrar taquilla.
- **Detección:** ninguna sin CSP report-uri.
- **Mitigación:** CSP (report-only → enforce) + actualizar libs (1 día–1 semana).

### Amenaza E — Spoofing de correo (#6, #7)
- **Vector:** enviar email `from: @TU-DOMINIO.com` a clientes/empleados; `~all` + `p=none` no lo rechazan.
- **Requisitos:** habilidad baja.
- **Impacto:** phishing a clientes (robo de credenciales de la app), daño reputacional, posible fraude de pago.
- **Detección:** informes DMARC `rua`/`ruf` ya llegan a `security@` (bueno) — el equipo vería el abuso, pero no se bloquea.
- **Mitigación:** endurecer SPF `-all` + DMARC `quarantine`→`reject` (1 día de cambios, 2-4 semanas de observación de informes).

### Amenaza F — IDOR en API vía rutas `:id` (#2.2, #18)
- **Vector:** usuario autenticado itera `/api/delivery/{id}/signature` con IDs ajenos.
- **Requisitos:** habilidad baja-media; requiere una cuenta válida.
- **Impacto:** fuga masiva de PII (firmas, entregas) → **RGPD (brecha notificable en 72 h)**.
- **Detección:** depende del logging del API (fuera de alcance).
- **Mitigación:** autorización por propiedad de recurso + IDs no secuenciales. **Validar en pentest autenticado autorizado.**

---

## 7. Tarea 5 — Plan de remediación (por ratio impacto/coste)

### ⏱️ < 15 minutos (parar la hemorragia)
1. **Revocar el webhook de Slack** (#2) — Slack Admin, elimina el incoming webhook. *Máximo impacto, coste casi nulo.*
2. **Fijar cuota diaria + alerta de presupuesto** en Google Cloud (#1) — contención inmediata mientras se restringen las keys.
3. Ejecutar los `grep` de contexto/patrón pendientes (§1.1, §1.5) para **cerrar #3, #4** y descartar AWS/JWT/Stripe.

### 📅 < 1 día
4. **Restringir + rotar las Google keys** por referrer y API (#1).
5. **Desplegar CloudFront Response Headers Policy** con HSTS, XCTO, XFO, Referrer-Policy y **CSP en Report-Only** (#5).
6. **Recrear el webhook de Slack solo en backend** (#2).
7. **Fijar versión de `@ionic/pwa-elements`** (quitar `@latest`) (#8).
8. **Publicar CAA** (#14) y `security.txt` (#19).
9. **Reverificar TLS 1.1** y la CloudFront security policy (#22).
10. Cambiar `<html lang="es">` (#16).
11. Verificar Firestore y el entorno demo (§1.2, §1.4).

### 📅 < 1 semana
12. **Añadir SRI** a todos los recursos de terceros de versión fija (#13).
13. **Pasar CSP de Report-Only a enforcing** tras validar que no rompe la PWA (#5).
14. **Actualizar jQuery→3.7.1 y Bootstrap→4.6.2** (o eliminarlos si no se usan) (#11, #12).
15. **Endurecer SPF a `-all`** y arrancar DMARC `p=quarantine; pct=25` (#6, #7).
16. Proteger/aislar el entorno demo si no debe ser público (#9).

### 📅 < 1 mes
17. **Auto-hospedar terceros** en S3/CloudFront y estrechar CSP a `script-src 'self'` (#8, #13).
18. **DMARC `p=reject`** tras observar informes sin falsos positivos (#6).
19. **Pentest autenticado autorizado** del API para validar IDOR en rutas `:id` (#2.2, #18, amenaza F) — con dos cuentas de prueba propias.
20. FontAwesome→6 / consolidar iconos (#17).
21. Configurar 404 real para rutas desconocidas (#15).

### 🧱 Deuda técnica a planificar
22. Migrar componentes Bootstrap → Ionic nativo y **eliminar jQuery/Bootstrap** por completo.
23. Revisar tratamiento **RGPD de Hotjar** (session replay puede capturar PII): consentimiento, masking de inputs sensibles, retención.
24. Confirmar cumplimiento **PCI-DSS 4.0** del flujo PayComet (que la PWA no toque datos de tarjeta; iframe/redirección hospedada por PayComet).
25. Monitorización proactiva: alerta de caducidad de certificado, presupuesto Google Cloud, y escaneo periódico del bundle en CI buscando secretos (`gitleaks`/`trufflehog`).

---

## 8. Preguntas abiertas (a confirmar con el equipo antes de cerrar)

1. **#3 / #4 — atribución de tokens:** ¿`<TOKEN_HEX_REDACTED>` es la API key de Amplitude y `<UUID_REDACTED>` es el clientKey de GrowthBook? **Crítico:** ¿alguno pertenece a PayComet con capacidad de operación de pago? (cambia la severidad de Baja a Crítica). Se cierra con los `grep .{120}` de §1.1.
2. **#22 — TLS 1.1:** ¿la CloudFront security policy es `TLSv1.2_2021`+? La evidencia del bucle `openssl` es ambigua (probable falso positivo del grep). Reverificar.
3. **#9 — demo:** ¿`demo-saas` debe ser público? ¿Comparte proyecto Firebase / keys / datos con producción, o está aislado con datos sintéticos?
4. **#1 — ¿hay keys de servidor?** ¿Alguna de las dos Google keys se usa server-side (no restringible por referrer)? Si sí, debe restringirse por IP y salir del bundle.
5. **WAF:** ¿existe un AWS WAF asociado a la distribución CloudFront o al API `api-saas.smartfleet.*`? El front estático no reaccionó a payloads de escáner.
6. **Firestore:** ¿el proyecto usa Firestore además de RTDB? Confirmar que sus Security Rules deniegan lectura no autenticada (§1.4).
7. **Secretos adicionales:** confirmar (ejecutando los greps de §1.5) que **no** hay AWS keys, private keys ni JWTs en el bundle.
8. **IDOR (#2.2):** ¿el API valida propiedad de recurso en `/delivery/:id` y `/delivery/:id/signature`? Requiere pentest autenticado autorizado para validar.
9. **RGPD/Hotjar:** ¿hay consentimiento y masking configurados para el session replay?
10. **PayComet/PCI-DSS:** ¿el flujo de pago usa iframe/redirección hospedada (SAQ A) o la PWA toca datos de tarjeta (scope mayor)?

---

### Nota metodológica
Esta auditoría es **pasiva** y se limita a artefactos públicos. Los hallazgos de autorización (IDOR) y de backend requieren un **pentest autenticado autorizado** con cuentas de prueba propias, coordinado con el equipo, y quedan fuera del alcance pasivo. No se ha explotado ningún hallazgo más allá del mínimo ya confirmado, no se han enviado mensajes a Slack/correo, ni se han hecho peticiones masivas a APIs de terceros.
