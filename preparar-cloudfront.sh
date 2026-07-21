#!/bin/bash
# =============================================================================
# FASE 7 — Preparar VPS para AWS CloudFront
# Ejecutar como root: bash preparar-cloudfront.sh
# =============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}   FASE 7 — Preparar VPS para CloudFront${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ──── PASO 1: Backup de Nginx actual ──────────────────────────────────
echo -e "${YELLOW}[1/4] Backup de Nginx actual...${NC}"
cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak.$(date +%Y%m%d%H%M%S)
echo -e "${GREEN}    ✓ Backup guardado${NC}"

# ──── PASO 2: Actualizar config de Nginx ──────────────────────────────
echo -e "${YELLOW}[2/4] Actualizando Nginx con WebSocket en puerto 80...${NC}"

cat > /etc/nginx/sites-available/default << 'NGINXEOF'
# ═══════════════════════════════════════════════════════════════════════
# Nginx config — VPS freepersonalbyscribax.com
# Actualizado para FASE 7: soporte WebSocket en puerto 80 (CloudFront)
# ═══════════════════════════════════════════════════════════════════════

# ── Server público :80 (HTTP) ──
# CloudFront conecta aquí como origin
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name freepersonalbyscribax.com _;

    # ACME validation (Let's Encrypt)
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
    }

    # WebSocket bridge — CloudFront forwardea aquí
    # Ruta: /ssh-ws → proxy a ssh-ws bridge (127.0.0.1:10080)
    location /ssh-ws {
        proxy_pass         http://127.0.0.1:10080;
        proxy_http_version 1.1;

        # Headers WebSocket upgrade (CRÍTICOS)
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # Timeouts largos para mantener el túnel SSH vivo
        proxy_read_timeout    86400s;
        proxy_send_timeout    86400s;
        proxy_connect_timeout 7s;
    }

    # Fallback genérico (para health checks de CloudFront)
    location / {
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}

# ── Server interno :8080 (fallback Trojan/Xray) ──
server {
    listen 127.0.0.1:8080;
    server_name _;

    location / {
        root /var/www/html;
        index index.html;
    }
}
NGINXEOF

echo -e "${GREEN}    ✓ Config actualizada${NC}"

# ──── PASO 3: Verificar y recargar Nginx ──────────────────────────────
echo -e "${YELLOW}[3/4] Verificando config de Nginx...${NC}"

if /usr/sbin/nginx -t 2>&1; then
    systemctl reload nginx
    echo -e "${GREEN}    ✓ Nginx recargado exitosamente${NC}"
else
    echo -e "${RED}    ✗ Error en la config de Nginx. Restaurando backup...${NC}"
    LATEST_BAK=$(ls -t /etc/nginx/sites-available/default.bak.* 2>/dev/null | head -1)
    if [ -n "$LATEST_BAK" ]; then
        cp "$LATEST_BAK" /etc/nginx/sites-available/default
        /usr/sbin/nginx -t && systemctl reload nginx
        echo -e "${RED}    ✗ Backup restaurado. Revisá el error arriba.${NC}"
    fi
    exit 1
fi

# ──── PASO 4: Verificación ────────────────────────────────────────────
echo -e "${YELLOW}[4/4] Verificando...${NC}"
echo ""

# Puerto 80
echo -e "${CYAN}── Puerto 80 ──${NC}"
if ss -tlnp | grep -q ':80 '; then
    echo -e "${GREEN}    ✓ Nginx escuchando en :80${NC}"
else
    echo -e "${RED}    ✗ Nginx NO escucha en :80${NC}"
fi

# Firewall
echo -e "${CYAN}── Firewall ──${NC}"
if command -v ufw &>/dev/null && ufw status | grep -q "80/tcp.*ALLOW"; then
    echo -e "${GREEN}    ✓ Puerto 80 permitido en UFW${NC}"
elif iptables -L INPUT -n 2>/dev/null | grep -q "dpt:80.*ACCEPT"; then
    echo -e "${GREEN}    ✓ Puerto 80 permitido en iptables${NC}"
else
    echo -e "${YELLOW}    ⚠ Puerto 80 podría estar bloqueado. Verificá manualmente.${NC}"
    echo -e "${YELLOW}      Ejecutá: ufw allow 80/tcp  (o)  iptables -A INPUT -p tcp --dport 80 -j ACCEPT${NC}"
fi

# Test WebSocket local
echo -e "${CYAN}── WebSocket bridge ──${NC}"
if ss -tlnp | grep -q ':10080 '; then
    echo -e "${GREEN}    ✓ ssh-ws bridge corriendo en :10080${NC}"

    # Test HTTP a /ssh-ws
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Upgrade: websocket" \
        -H "Connection: Upgrade" \
        http://127.0.0.1/ssh-ws 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "101" ] || [ "$HTTP_CODE" = "400" ]; then
        echo -e "${GREEN}    ✓ Nginx forwardea /ssh-ws correctamente (HTTP $HTTP_CODE)${NC}"
    else
        echo -e "${RED}    ✗ /ssh-ws devuelve HTTP $HTTP_CODE (esperado: 101 o 400)${NC}"
    fi
else
    echo -e "${RED}    ✗ ssh-ws bridge NO está corriendo en :10080${NC}"
    echo -e "${RED}      Ejecutá: systemctl start ssh-ws${NC}"
fi

# Dropbear
echo -e "${CYAN}── Dropbear SSH ──${NC}"
if ss -tlnp | grep -q ':2222 '; then
    echo -e "${GREEN}    ✓ Dropbear SSH corriendo en :2222${NC}"
else
    echo -e "${RED}    ✗ Dropbear NO está en :2222${NC}"
fi

# badvpn-udpgw
echo -e "${CYAN}── badvpn-udpgw ──${NC}"
if ss -ulnp | grep -q ':7300 '; then
    echo -e "${GREEN}    ✓ badvpn-udpgw corriendo en :7300${NC}"
else
    echo -e "${YELLOW}    ⚠ badvpn-udpgw NO detectado en :7300 (UDP podría no mostrarse)${NC}"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}   ✓ VPS PREPARADO PARA CLOUDFRONT${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${YELLOW}Próximo paso:${NC}"
echo -e "  1. Crear distribución en AWS CloudFront"
echo -e "  2. Origin: 186.64.123.162 | Protocol: HTTP only"
echo -e "  3. Cache Policy: CachingDisabled"
echo -e "  4. Origin Request Policy: AllViewer"
echo -e ""
echo -e "${YELLOW}Test desde tu PC (PowerShell):${NC}"
echo -e "  curl.exe -s http://186.64.123.162/ssh-ws"
echo -e "  → Debe devolver algo (no 'OK' del fallback)"
echo ""
