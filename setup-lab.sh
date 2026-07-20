#!/bin/bash
# =============================================================================
# LAB PROXY/VPN - Setup completo para Ubuntu 22.04 LTS
# Dominio: freepersonalbyscribax.com
# VPS IP:  186.64.123.162
# =============================================================================
# EJECUTAR COMO ROOT en el VPS: bash setup-lab.sh
# =============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}   LAB PROXY/VPN - Setup Xray + Trojan + Let's Encrypt${NC}"
echo -e "${CYAN}   Dominio: freepersonalbyscribax.com${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ──── CREDENCIALES GENERADAS ──────────────────────────────────────────
VLESS_UUID="0f848ac2-a329-4d52-96f2-701c38b5f75b"
TROJAN_PASS="LjC53sJfZSxbIZlchMjappFq23i1Qmkr"
DOMAIN="freepersonalbyscribax.com"
EMAIL="admin@freepersonalbyscribax.com"  # CAMBIAR si tenés email real
SNI_TARGET="www.microsoft.com"           # Dominio de alta reputación para SNI spoofing
XRAY_PORT=443
TROJAN_PORT=8443
SSH_PORT=22

echo -e "${YELLOW}[*] Credenciales generadas:${NC}"
echo -e "    VLESS UUID:      ${GREEN}${VLESS_UUID}${NC}"
echo -e "    Trojan Password: ${GREEN}${TROJAN_PASS}${NC}"
echo -e "    SNI Target:      ${GREEN}${SNI_TARGET}${NC}"
echo ""

# ──── PASO 1: Actualizar sistema ──────────────────────────────────────
echo -e "${YELLOW}[1/8] Actualizando sistema...${NC}"
apt update -qq && apt upgrade -y -qq
echo -e "${GREEN}    ✓ Sistema actualizado${NC}"

# ──── PASO 2: Instalar dependencias ────────────────────────────────────
echo -e "${YELLOW}[2/8] Instalando dependencias...${NC}"
apt install -y -qq curl wget unzip nginx certbot python3-certbot-nginx jq openssl ufw
echo -e "${GREEN}    ✓ Dependencias instaladas${NC}"

# ──── PASO 3: Configurar Nginx como fallback + servidor ACME ───────────
echo -e "${YELLOW}[3/8] Configurando Nginx (fallback + ACME)...${NC}"

cat > /etc/nginx/sites-available/default << 'NGINXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name freepersonalbyscribax.com;

    # Ruta para validación ACME de Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
    }

    # Fallback: página genérica para cualquier otra request
    location / {
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}

server {
    listen 127.0.0.1:8080;
    server_name _;

    # Página de fallback que verá quien llegue sin proxy válido
    location / {
        root /var/www/html;
        index index.html;
    }
}
NGINXEOF

# Crear página de fallback convincente
cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Site Under Maintenance</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
        .card { background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); text-align: center; max-width: 400px; }
        h1 { color: #333; font-size: 24px; }
        p { color: #666; }
    </style>
</head>
<body>
    <div class="card">
        <h1>🚧 Maintenance Mode</h1>
        <p>We're currently performing scheduled maintenance. Please check back later.</p>
    </div>
</body>
</html>
HTMLEOF

systemctl enable nginx --now
nginx -t && systemctl reload nginx
echo -e "${GREEN}    ✓ Nginx configurado${NC}"

# ──── PASO 4: Obtener certificado Let's Encrypt ───────────────────────
echo -e "${YELLOW}[4/8] Obteniendo certificado SSL con Let's Encrypt...${NC}"
echo -e "${RED}    ⚠ Asegurate de que freepersonalbyscribax.com resuelve a 186.64.123.162${NC}"

# Verificar DNS antes de intentar certbot
if host "$DOMAIN" 8.8.8.8 | grep -q "has address"; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" --redirect 2>&1 || {
        echo -e "${RED}    ⚠ certbot --nginx falló, intentando modo standalone...${NC}"
        systemctl stop nginx
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL"
        systemctl start nginx
    }
    echo -e "${GREEN}    ✓ Certificado SSL obtenido${NC}"
else
    echo -e "${RED}    ✗ El dominio NO resuelve. Verificá los DNS de freepersonalbyscribax.com${NC}"
    echo -e "${RED}    ✗ Saltando certificado SSL. Después corré: certbot --nginx -d $DOMAIN${NC}"
fi

# ──── PASO 5: Instalar y configurar Xray-core ─────────────────────────
echo -e "${YELLOW}[5/8] Instalando Xray-core...${NC}"

# Descargar Xray-core
XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "v25.3.6")
echo -e "    Versión: ${XRAY_VERSION}"

cd /tmp
curl -sSL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" -o xray.zip
unzip -o -q xray.zip -d /usr/local/bin/
chmod +x /usr/local/bin/xray
rm -f xray.zip

# Crear directorio de configuración
mkdir -p /usr/local/etc/xray

# Generar claves para XTLS-Vision
XRAY_KEYS=$(/usr/local/bin/xray x25519 2>/dev/null || true)

# Archivo de configuración de Xray
cat > /usr/local/etc/xray/config.json << XRAYEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-vision-in",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision",
            "level": 0,
            "email": "lab-client@${DOMAIN}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h2", "http/1.1"],
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }
    ]
  }
}
XRAYEOF

# Crear directorio de logs
mkdir -p /var/log/xray

echo -e "${GREEN}    ✓ Xray-core instalado y configurado${NC}"

# ──── PASO 6: Instalar y configurar Trojan-GFW ────────────────────────
echo -e "${YELLOW}[6/8] Instalando Trojan-GFW...${NC}"

# Descargar Trojan-GFW
cd /tmp
TROJAN_URL=$(curl -s https://api.github.com/repos/trojan-gfw/trojan/releases/latest | jq -r '.assets[] | select(.name | contains("linux") and contains("amd64")) | .browser_download_url' 2>/dev/null)
if [ -z "$TROJAN_URL" ]; then
    # Fallback a una versión conocida
    TROJAN_URL="https://github.com/trojan-gfw/trojan/releases/download/v1.16.0/trojan-1.16.0-linux-amd64.tar.xz"
fi
echo -e "    URL: ${TROJAN_URL}"

curl -sSL "$TROJAN_URL" -o trojan.tar.xz
tar -xf trojan.tar.xz -C /usr/local/bin/
chmod +x /usr/local/bin/trojan/trojan
ln -sf /usr/local/bin/trojan/trojan /usr/local/bin/trojan-go
rm -f trojan.tar.xz

# Crear directorio de configuración
mkdir -p /usr/local/etc/trojan

# Configuración de Trojan
cat > /usr/local/etc/trojan/config.json << TROJANEOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": ${TROJAN_PORT},
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "${TROJAN_PASS}"
    ],
    "log_level": 1,
    "ssl": {
        "cert": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
        "key": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem",
        "key_password": "",
        "cipher": "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384",
        "cipher_tls13": "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
        "prefer_server_cipher": true,
        "alpn": [
            "h2",
            "http/1.1"
        ],
        "alpn_port_override": {
            "h2": 81
        },
        "reuse_session": true,
        "session_ticket": false,
        "session_timeout": 600,
        "plain_http_response": "",
        "curves": "",
        "dhparam": ""
    },
    "tcp": {
        "prefer_ipv4": false,
        "no_delay": true,
        "keep_alive": true,
        "reuse_port": false,
        "fast_open": false,
        "fast_open_qlen": 20
    },
    "mysql": {
        "enabled": false,
        "server_addr": "127.0.0.1",
        "server_port": 3306,
        "database": "trojan",
        "username": "trojan",
        "password": ""
    }
}
TROJANEOF

echo -e "${GREEN}    ✓ Trojan-GFW instalado y configurado${NC}"

# ──── PASO 7: Crear servicios systemd ──────────────────────────────────
echo -e "${YELLOW}[7/8] Creando servicios systemd...${NC}"

# Servicio Xray
cat > /etc/systemd/system/xray.service << 'SVCXRAY'
[Unit]
Description=Xray-core Service (VLESS + XTLS-Vision)
Documentation=https://xtls.github.io
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCXRAY

# Servicio Trojan
cat > /etc/systemd/system/trojan.service << 'SVCTROJAN'
[Unit]
Description=Trojan-GFW Service
Documentation=https://trojan-gfw.github.io/trojan/
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/trojan /usr/local/etc/trojan/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCTROJAN

systemctl daemon-reload
systemctl enable xray trojan
echo -e "${GREEN}    ✓ Servicios systemd creados${NC}"

# ──── PASO 8: Configurar Firewall (UFW) ────────────────────────────────
echo -e "${YELLOW}[8/8] Configurando firewall...${NC}"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow 80/tcp   comment 'HTTP / ACME'
ufw allow 443/tcp  comment 'HTTPS / Xray VLESS+Vision'
ufw allow 8443/tcp comment 'Trojan-GFW'
ufw --force enable

echo -e "${GREEN}    ✓ Firewall configurado${NC}"
ufw status verbose

# ──── INICIAR SERVICIOS ────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[*] Iniciando servicios...${NC}"
systemctl restart xray
systemctl restart trojan

sleep 2

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}   ESTADO DE SERVICIOS${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${YELLOW}── Xray-core ──${NC}"
systemctl status xray --no-pager -l 2>&1 | head -5
echo ""
echo -e "${YELLOW}── Trojan-GFW ──${NC}"
systemctl status trojan --no-pager -l 2>&1 | head -5
echo ""
echo -e "${YELLOW}── Nginx ──${NC}"
systemctl status nginx --no-pager -l 2>&1 | head -5
echo ""
echo -e "${YELLOW}── Puertos en escucha ──${NC}"
ss -tlnp | grep -E ':(443|8443|80|22) '
echo ""

# ──── GENERAR URLs DE CONEXIÓN ─────────────────────────────────────────
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}   URLs DE CONEXIÓN PARA CLIENTES${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

VLESS_URL="vless://${VLESS_UUID}@${DOMAIN}:${XRAY_PORT}?encryption=none&security=tls&sni=${DOMAIN}&alpn=h2,http/1.1&flow=xtls-rprx-vision&type=tcp#LAB-VLESS-Vision"
TROJAN_URL="trojan://${TROJAN_PASS}@${DOMAIN}:${TROJAN_PORT}?security=tls&sni=${DOMAIN}&alpn=h2,http/1.1&type=tcp#LAB-Trojan"

echo -e "${GREEN}[VLESS + XTLS-Vision]${NC}"
echo -e "${VLESS_URL}"
echo ""
echo -e "${GREEN}[Trojan-GFW]${NC}"
echo -e "${TROJAN_URL}"
echo ""

# ──── GUARDAR CREDENCIALES ─────────────────────────────────────────────
cat > /root/lab-credentials.txt << CREEEOF
========================================
LAB PROXY/VPN - CREDENCIALES
========================================
Dominio:    ${DOMAIN}
VPS IP:     186.64.123.162

── Xray-core (VLESS + XTLS-Vision) ──
Puerto:     ${XRAY_PORT}
UUID:       ${VLESS_UUID}
Flow:       xtls-rprx-vision
Security:   tls
Transport:  tcp
ALPN:       h2,http/1.1

── Trojan-GFW ──
Puerto:     ${TROJAN_PORT}
Password:   ${TROJAN_PASS}
Security:   tls

── URLs ──
VLESS:  ${VLESS_URL}
Trojan: ${TROJAN_URL}
CREEEOF

echo -e "${YELLOW}[*] Credenciales guardadas en /root/lab-credentials.txt${NC}"
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}   ✓ SETUP COMPLETO${NC}"
echo -e "${CYAN}============================================================${NC}"
