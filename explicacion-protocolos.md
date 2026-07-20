# LAB PROXY/VPN — Explicación Técnica de Protocolos

> **Dominio:** freepersonalbyscribax.com | **VPS:** 186.64.123.162
> **Objetivo:** Entender tunelización TLS, SNI spoofing, y protocolos de ofuscación modernos.

---

## 1. ARQUITECTURA GENERAL

```
                        INTERNET
                           │
                    ┌──────▼──────┐
                    │   VPS LAB   │
                    │  186.64...  │
                    │             │
      Puerto 443 ───┤  Xray-core  │─── VLESS + XTLS-Vision
                    │  (VLESS)    │     TLS 1.3 + padding interno
                    │             │
      Puerto 8443 ──┤  Trojan-GFW │─── Protocolo Trojan
                    │             │     TLS wrapper + contraseña SHA-224
                    │             │
      Puerto 80 ────┤  Nginx      │─── Fallback + ACME validation
                    └─────────────┘
```

**Flujo de una conexión:**
1. Cliente (V2RayNG/Nekoray) inicia handshake TLS contra `freepersonalbyscribax.com:443`
2. Xray-core recibe el ClientHello de TLS
3. Si el tráfico es VLESS válido → desencripta y enruta al destino real
4. Si no es VLESS → cae en fallback (nginx sirve página de mantenimiento)
5. Mismo flujo en puerto 8443 para Trojan

---

## 2. VLESS + XTLS-VISION (Explicación detallada)

### 2.1 ¿Qué es VLESS?

VLESS es un protocolo de transporte **sin encriptación propia** (a diferencia de VMess). Delega TODA la encriptación a TLS. Esto es intencional: menos overhead, menos patrones detectables, y se apoya en TLS 1.3 que es indistinguible del tráfico HTTPS normal.

```
VMess:  [VMess header encriptado] → [payload]     ← overhead DETECTABLE
VLESS:  [TLS 1.3] → [VLESS auth (UUID)] → [payload]  ← indistinguible de HTTPS
```

### 2.2 ¿Qué es XTLS-Vision?

**XTLS** (X = eXtreme) es una técnica que elimina el doble encriptado TLS-en-TLS:

```
SIN XTLS:   [TLS externo] → [TLS interno del destino] → MUCHO overhead
CON XTLS:   [TLS externo] → se "roba" el TLS del destino → SIN overhead extra
```

Cuando el cliente quiere conectarse a `google.com:443`:
1. Xray recibe los datos del túnel TLS
2. Detecta que el destino también usa TLS (por el puerto 443)
3. **Extrae el TLS interno** y lo envía directamente al destino
4. La respuesta de Google vuelve y Xray la re-empaqueta en el TLS externo

**Vision** es el "flow" (flujo) que controla cómo se hace este proceso:
- `xtls-rprx-vision`: Usa padding aleatorio dentro del flujo TLS para que el tamaño de los paquetes sea impredecible
- El padding se inserta en posiciones aleatorias, haciendo que el análisis de tráfico por tamaño de paquete sea inútil (anti-DPI por fingerprinting de tamaño)

```
Paquete SIN Vision:  [500 bytes fijos] → patrón predecible
Paquete CON Vision:  [300-700 bytes variables] → aleatorio, como tráfico normal
```

### 2.3 Parámetros críticos en config.json

| Parámetro | Valor | Qué hace |
|-----------|-------|----------|
| `protocol` | `vless` | Protocolo sin encriptación propia, delega a TLS |
| `flow` | `xtls-rprx-vision` | Habilita XTLS + padding aleatorio anti-DPI |
| `encryption` | `none` | Sin cifrado extra (TLS ya cifra todo) |
| `security` | `tls` | Usa TLS 1.3 como capa de transporte |
| `tlsSettings.certificates` | Ruta certs Let's Encrypt | Certificado TLS válido (no self-signed) |
| `tlsSettings.alpn` | `["h2", "http/1.1"]` | Application-Layer Protocol Negotiation — simula un servidor web normal |
| `sniffing.enabled` | `true` | Inspecciona el tráfico interno para detectar TLS/protocolos y optimizar enrutamiento |
| `routing.rules` | Bloquea IPs privadas y ads | Evita fugas de tráfico a la red local |

### 2.4 Flujo del handshake TLS con VLESS

```
CLIENTE                              VPS (Xray)
   │                                      │
   │── ClientHello ──────────────────────►│
   │   • SNI: freepersonalbyscribax.com   │  ← El SNI es CLAVE: le dice a quién
   │   • ALPN: h2, http/1.1              │    se quiere conectar
   │   • Cipher suites TLS 1.3           │
   │                                      │
   │◄─ ServerHello ──────────────────────│
   │   • Certificado: freepersonal...com  │  ← Let's Encrypt válido
   │   • Key share (ECDHE)               │
   │                                      │
   │── Finished (encrypted) ────────────►│
   │   • VLESS auth: UUID incluido       │  ← El UUID viaja DENTRO del túnel TLS
   │   • Comando: CONNECT destino:443    │     invisible para cualquier DPI
   │                                      │
   │◄─ Datos del destino ───────────────│  ← Xray extrae el TLS interno
   │                                      │    y lo forwardea al destino real
```

---

## 3. TROJAN-GFW (Explicación detallada)

### 3.1 Filosofía de diseño

Trojan fue diseñado con un principio simple: **"si no podés vencer al DPI, mimetizate con HTTPS"**. A diferencia de Shadowsocks (que crea un protocolo nuevo), Trojan usa TLS EXACTAMENTE como lo haría un servidor HTTPS.

### 3.2 Cómo funciona

```
Cliente Trojan                         VPS Trojan
     │                                      │
     │── TLS ClientHello ─────────────────►│
     │   • SNI: freepersonalbyscribax.com   │
     │                                      │
     │◄─ TLS ServerHello ──────────────────│
     │   • Certificado válido              │
     │                                      │
     │── TLS Application Data ────────────►│
     │   [SHA224(password) + CRLF          │  ← ESTO es el "proxy protocol"
     │    + SOCKS5 command + CRLF]         │     La password hasheada es lo ÚNICO
     │                                      │     que identifica tráfico Trojan
     │                                      │
     │   Si password OK:                   │
     │◄─ Datos del destino ───────────────│  ← Forwardea al remote_addr:remote_port
     │                                      │
     │   Si password MAL:                  │
     │◄─ Página web normal ───────────────│  ← Se comporta como un servidor HTTPS
     │                                      │    cualquiera. INDISTINGUIBLE.
```

**El "truco" de Trojan:** Si alguien sin la contraseña correcta intenta conectarse, Trojan **no rechaza la conexión** — en su lugar, responde con una página web normal (o redirige a nginx). Para un DPI, es indistinguible de un servidor HTTPS legítimo.

### 3.3 Parámetros críticos

| Parámetro | Qué hace |
|-----------|----------|
| `password` | Se hashea con SHA-224 y se compara en los primeros 56 bytes de la conexión. NO se envía en texto plano. |
| `remote_addr` / `remote_port` | A dónde forwardear tráfico válido (`127.0.0.1:80` → nginx) |
| `ssl.cipher` | Solo cipher suites modernos (ECDHE, GCM, CHACHA20) — exactamente lo que usa un servidor web real |
| `ssl.alpn` | `["h2", "http/1.1"]` — negociación de protocolo HTTP/2, igual que nginx/apache |
| `ssl.reuse_session` | `true` — reutiliza sesiones TLS (comportamiento normal de un servidor web) |
| `ssl.session_ticket` | `false` — deshabilita tickets de sesión (reduce superficie de fingerprinting) |

---

## 4. SNI SPOOFING Y DOMAIN FRONTING (Lo que pediste)

### 4.1 ¿Qué es SNI?

**SNI** (Server Name Indication) es una extensión del handshake TLS que le dice al servidor **a qué dominio quiere conectarse el cliente**. Viaja **EN TEXTO PLANO** dentro del ClientHello.

```
ClientHello:
  ┌─────────────────────────────────┐
  │ SNI: freepersonalbyscribax.com  │  ← CUALQUIER DPI puede leer esto
  │ Cipher Suites: ...              │
  │ Key Share: ...                  │
  └─────────────────────────────────┘
```

### 4.2 ¿Qué es Domain Fronting?

Domain Fronting es una técnica donde:

1. **El SNI visible** apunta a un dominio de alta reputación (ej: `www.microsoft.com`)
2. **El Host header HTTP** (dentro del túnel TLS) apunta al destino real
3. El CDN/proxy intermedio (Cloudflare, Azure, etc.) enruta según el Host header interno

```
Cliente ──TLS──► Cloudflare ──HTTP──► Servidor real
  SNI: microsoft.com          Host: tudominio.com
```

**Para que esto funcione necesitás:**
- Un CDN que no valide que SNI == Host header (Cloudflare lo permite en ciertos planes, Azure CDN clásico también)
- El servidor real detrás del CDN

### 4.3 SNI Spoofing en nuestro LAB

En nuestro setup, **NO estamos haciendo domain fronting real** (porque el dominio es propio, no usamos CDN). Pero podés **experimentar** cambiando el SNI en el cliente:

```
# Cliente dice "quiero conectarme a microsoft.com" (SNI)
# Pero el tráfico va a TU VPS (186.64.123.162)
# El VPS recibe el ClientHello con SNI: microsoft.com
# Xray/Trojan, según configuración, puede ignorar el SNI o validarlo
```

**Para probar SNI spoofing:**
1. En el cliente, cambiá `sni` de `freepersonalbyscribax.com` a `www.microsoft.com`
2. El tráfico sigue yendo a tu VPS (la IP no cambia, solo el SNI)
3. El VPS puede aceptar la conexión si no valida el SNI estrictamente

**Lo que esto demuestra:**
- Un DPI que solo mira el SNI ve `microsoft.com` y clasifica el tráfico como "Microsoft"
- Pero el tráfico real va a tu VPS
- Esto FUNCIONA porque el SNI es solo un campo informativo en TLS — el enrutamiento real lo decide la IP

### 4.4 XTLS-Reality (la evolución del SNI spoofing)

Reality lleva esto al extremo: **no necesita certificado propio**. Usa el certificado DE OTRO SITIO:

```
Cómo funciona Reality:
1. Elegís un sitio "target" (ej: www.microsoft.com)
2. Xray extrae el certificado REAL de Microsoft
3. Cuando el cliente se conecta, Xray presenta EL CERTIFICADO DE MICROSOFT
4. Para un DPI: estás visitando Microsoft. Certificado válido. Todo normal.
5. Pero en realidad estás en un túnel VLESS

El "truco": Xray hace MITM pasivo — deja pasar el handshake sin interferir
y solo después del handshake completo, verifica el UUID de VLESS.
```

**Por qué usamos Vision en vez de Reality en este lab:**
- Tenemos dominio propio con Let's Encrypt (más simple para aprender)
- Reality es más avanzado y requiere que el sitio "target" esté siempre online
- Vision + cert propio es el camino más educativo para entender TLS primero

---

## 5. DIAGRAMA DE FLUJO COMPLETO

```
┌─────────────┐         ┌──────────────────────────────────────┐
│  CLIENTE    │         │              VPS LAB                 │
│  (Android/  │         │                                      │
│   Windows)  │         │  ┌────────┐    ┌────────┐           │
│             │         │  │ XRAY   │    │TROJAN  │           │
│             │         │  │ :443   │    │ :8443  │           │
└──────┬──────┘         │  └───┬────┘    └───┬────┘           │
       │                 │      │             │                │
       │  TLS Handshake  │      │             │                │
       │  SNI: midominio │      │             │                │
       ├────────────────►│      │             │                │
       │                 │      │             │                │
       │  Cert + Key     │      │             │                │
       │◄────────────────┤      │             │                │
       │                 │      │             │                │
       │  VLESS Auth     │      │             │                │
       │  (UUID dentro   │      │             │                │
       │   del túnel)    │      │             │                │
       ├────────────────►│      │             │                │
       │                 │      │             │                │
       │                 │      │  Forward  ┌──▼──────────┐   │
       │                 │      │  tráfico  │  INTERNET   │   │
       │                 │      ├──────────►│  (destino   │   │
       │  Respuesta      │      │           │   real)     │   │
       │◄────────────────┤      │◄──────────┤             │   │
       │                 │      │           └─────────────┘   │
       │                 │      │                             │
       │  Tráfico        │      │  ┌──────────┐              │
       │  INVÁLIDO       │      │  │  NGINX   │              │
       ├────────────────►│      │  │  :80     │              │
       │                 │      │  └────┬─────┘              │
       │  "Maintenance"  │      │       │                     │
       │◄────────────────┤      │       │                     │
       │                 │      │       │                     │
       └─────────────────┘      └───────┴─────────────────────┘
```

---

## 6. COMANDOS DE DIAGNÓSTICO Y APRENDIZAJE

### 6.1 Ver el handshake TLS en vivo

```bash
# En el VPS — capturar tráfico TLS en puerto 443
tcpdump -i any port 443 -A -s 0 | head -100

# Ver los ClientHello con SNI
tcpdump -i any port 443 -A -s 0 2>/dev/null | grep -i "sni\|server_name"
```

### 6.2 Probar el túnel manualmente

```bash
# Conectarse al puerto 443 y ver el certificado
openssl s_client -connect freepersonalbyscribax.com:443 -servername freepersonalbyscribax.com

# Probar con SNI spoofeado (conectarse a tu VPS pero decir que vas a Microsoft)
openssl s_client -connect freepersonalbyscribax.com:443 -servername www.microsoft.com
# ↑ Esto fallará porque el certificado es de freepersonalbyscribax.com, no de microsoft.com
# ¡Justamente lo que un DPI vería como inconsistencia!

# Con Reality (si lo activáramos), esto FUNCIONARÍA porque Xray
# presentaría el cert real de Microsoft.
```

### 6.3 Analizar tamaño de paquetes

```bash
# Ver cómo Vision randomiza tamaños
tcpdump -i any port 443 -nn -q 2>/dev/null | awk '{print $NF}' | head -20
```

---

## 7. PREGUNTAS FRECUENTES DE LABORATORIO

**Q: ¿Por qué VLESS no tiene encriptación?**
A: Porque TLS 1.3 ya provee AES-256-GCM. Agregar otra capa de encriptación (como VMess) crea patrones detectables y overhead innecesario. VLESS confía en que TLS es suficiente.

**Q: ¿Qué pasa si alguien hace un port scan a mi VPS?**
A: El puerto 443 responde con un handshake TLS válido (certificado de Let's Encrypt). Parece un servidor web. El puerto 8443 igual. El puerto 80 responde con HTTP normal. No hay nada sospechoso.

**Q: ¿Se puede detectar VLESS?**
A: En teoría, con TLS 1.3 + Vision + uTLS fingerprint (chrome), el tráfico es indistinguible del de Chrome visitando un sitio web. En práctica, el volumen y patrón de conexiones puede levantar sospechas en redes muy monitoreadas.

**Q: ¿Puedo usar CDN (Cloudflare) con esto?**
A: Sí, pero solo con WebSocket/gRPC como transporte (no TCP puro). Cloudflare no forwardea TCP arbitrario en planes gratuitos. Para TCP necesitás Cloudflare Spectrum (pago) o un CDN que soporte TCP proxy.
