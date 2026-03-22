#!/bin/bash

#=================================================================
# AccessLicense Deployment Script
# Устанавливает панель с Go 1.26, Xray-core latest, anti-detection
# Использование: bash deploy.sh
#=================================================================

set -e

# ===================== КОНФИГУРАЦИЯ =====================
PANEL_PORT=9443
SUB_PORT=9444
PANEL_USER="e.allahverdiev"
PANEL_PASS='L@debaR2324!'
PANEL_PATH="/secretpanel/"
SUB_PATH="/feed/"
SUB_JSON_PATH="/config/"
XUI_FOLDER="/usr/local/x-ui"
DB_PATH="/etc/x-ui/3xui.db"
GO_VERSION="1.26.0"
XRAY_VERSION="v26.2.6"
REPO_URL="https://github.com/tarik1377/AccessLicense.git"
REPO_BRANCH="claude/repository-work-HtU4s"
# ========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# Проверка root
[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash deploy.sh"

SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me || curl -s4 --connect-timeout 5 api.ipify.org || echo "UNKNOWN")

log "============================================"
log "  AccessLicense Deploy"
log "  Server: ${SERVER_IP}"
log "  Go: ${GO_VERSION} | Xray: ${XRAY_VERSION}"
log "  Panel: ${PANEL_PORT} | Subs: ${SUB_PORT}"
log "============================================"

# 1. Остановить старую версию
log "Останавливаю старую сборку..."
systemctl stop x-ui 2>/dev/null || true
systemctl disable x-ui 2>/dev/null || true
# Убить если зомби
pkill -f "x-ui" 2>/dev/null || true
sleep 1

# 2. Зависимости
log "Устанавливаю зависимости..."
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq curl tar wget git socat unzip ca-certificates \
        tzdata fail2ban sqlite3 python3 gcc make >/dev/null 2>&1
elif command -v yum &>/dev/null; then
    yum install -y -q curl tar wget git socat unzip ca-certificates \
        tzdata fail2ban sqlite gcc make >/dev/null 2>&1
fi

# 3. Архитектура
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  PLATFORM="amd64"; GO_ARCH="amd64" ;;
    aarch64) PLATFORM="arm64"; GO_ARCH="arm64" ;;
    armv7l)  PLATFORM="armv7"; GO_ARCH="armv6l" ;;
    *)       err "Архитектура $ARCH не поддерживается" ;;
esac
log "Архитектура: ${PLATFORM}"

# 4. Устанавливаем Go 1.26
install_go() {
    local CURRENT_GO=""
    if command -v go &>/dev/null; then
        CURRENT_GO=$(go version 2>/dev/null | grep -oP 'go\K[0-9.]+' || echo "")
    fi

    if [ "$CURRENT_GO" = "$GO_VERSION" ]; then
        log "Go ${GO_VERSION} уже установлен"
        return
    fi

    log "Устанавливаю Go ${GO_VERSION}..."
    rm -rf /usr/local/go
    wget -q --show-progress "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -O /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz

    # Добавляем в PATH глобально
    if ! grep -q '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null; then
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    fi
    export PATH=$PATH:/usr/local/go/bin

    log "Go $(go version) установлен"
}

install_go

# 5. Клонируем и собираем
log "Клонирую репозиторий AccessLicense..."
cd /tmp
rm -rf AccessLicense
git clone --depth=1 -b "${REPO_BRANCH}" "${REPO_URL}" AccessLicense
cd AccessLicense

log "Собираю бинарник (Go ${GO_VERSION}, CGO enabled)..."
export CGO_ENABLED=1
go build -ldflags "-w -s" -o x-ui main.go
log "Бинарник собран: $(file x-ui | cut -d: -f2)"

# 6. Устанавливаем
log "Устанавливаю в ${XUI_FOLDER}..."
rm -rf ${XUI_FOLDER}
mkdir -p ${XUI_FOLDER}/bin

cp x-ui ${XUI_FOLDER}/
cp x-ui.sh ${XUI_FOLDER}/
chmod +x ${XUI_FOLDER}/x-ui ${XUI_FOLDER}/x-ui.sh

# 7. Xray-core
log "Скачиваю Xray-core ${XRAY_VERSION}..."
cd ${XUI_FOLDER}/bin
case "$PLATFORM" in
    amd64) XRAY_FILE="Xray-linux-64.zip" ;;
    arm64) XRAY_FILE="Xray-linux-arm64-v8a.zip" ;;
    armv7) XRAY_FILE="Xray-linux-arm32-v7a.zip" ;;
esac
wget -q --show-progress "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_FILE}"
unzip -qo "${XRAY_FILE}"
rm -f "${XRAY_FILE}" README.md LICENSE
mv xray "xray-linux-${PLATFORM}"
chmod +x "xray-linux-${PLATFORM}"

# 8. Geo-данные (включая RU для split tunneling)
log "Скачиваю geo-данные..."
rm -f geoip.dat geosite.dat geoip_RU.dat geosite_RU.dat
wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
wget -q -O geoip_RU.dat "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
wget -q -O geosite_RU.dat "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
log "Geo-данные: $(ls -1 *.dat | wc -l) файлов"

# 9. Директории и логи
mkdir -p /etc/x-ui /var/log/x-ui

# 10. Systemd service
log "Настраиваю systemd..."
cat > /etc/systemd/system/x-ui.service << 'SVCEOF'
[Unit]
Description=AccessLicense Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/usr/local/x-ui/
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable x-ui >/dev/null 2>&1

# 11. Первый запуск — создание БД
log "Первый запуск для инициализации БД..."
cd ${XUI_FOLDER}
timeout 15 ./x-ui 2>/dev/null || true
sleep 2

# Проверяем что БД создалась
if [ ! -f "${DB_PATH}" ]; then
    err "БД не создалась! Проверь логи: ${XUI_FOLDER}"
fi
log "БД создана: $(ls -lh ${DB_PATH} | awk '{print $5}')"

# 12. Настраиваем панель
log "Настраиваю панель..."

# Пароль — bcrypt через python3
HASHED_PASS=$(python3 -c "
try:
    import bcrypt
    print(bcrypt.hashpw(b'${PANEL_PASS}', bcrypt.gensalt()).decode())
except ImportError:
    print('${PANEL_PASS}')
" 2>/dev/null || echo "${PANEL_PASS}")

sqlite3 "${DB_PATH}" << SQLEOF
-- Логин/пароль
UPDATE users SET username='${PANEL_USER}', password='${HASHED_PASS}' WHERE id=1;

-- Порт панели (скрытый)
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='webPort'), 'webPort', '${PANEL_PORT}');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='webBasePath'), 'webBasePath', '${PANEL_PATH}');

-- Подписки
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subPort'), 'subPort', '${SUB_PORT}');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subPath'), 'subPath', '${SUB_PATH}');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subJsonPath'), 'subJsonPath', '${SUB_JSON_PATH}');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subEnable'), 'subEnable', 'true');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subJsonEnable'), 'subJsonEnable', 'true');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subEncrypt'), 'subEncrypt', 'true');

-- Безопасность
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='sessionMaxAge'), 'sessionMaxAge', '360');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='ipLimitEnable'), 'ipLimitEnable', 'true');
SQLEOF

log "Панель настроена"

# 13. Nginx — камуфляж (сервер выглядит как обычный сайт)
log "Настраиваю nginx-камуфляж..."
if command -v apt-get &>/dev/null; then
    apt-get install -y -qq nginx >/dev/null 2>&1
fi

if command -v nginx &>/dev/null; then
    cat > /etc/nginx/sites-available/camouflage << NGXEOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # Выглядит как обычный сайт
    location / {
        proxy_pass https://www.google.com;
        proxy_set_header Host www.google.com;
        proxy_set_header Accept-Encoding "";
        proxy_ssl_server_name on;
        sub_filter 'google.com' '${SERVER_IP}';
        sub_filter_once off;
    }

    # Блокируем сканеры
    location ~* \.(env|git|svn|htaccess|htpasswd|bak|old|orig|save|conf|cfg|ini|log|sql|db)$ {
        return 404;
    }
}
NGXEOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/camouflage /etc/nginx/sites-enabled/
    nginx -t >/dev/null 2>&1 && systemctl restart nginx
    log "Nginx-камуфляж активен (порт 80 → проксирует google.com)"
fi

# 14. Firewall
log "Настраиваю firewall..."
if command -v ufw &>/dev/null; then
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 80/tcp >/dev/null 2>&1       # nginx камуфляж
    ufw allow 443/tcp >/dev/null 2>&1      # Reality inbound
    ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
    ufw allow ${SUB_PORT}/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    log "UFW: $(ufw status | grep -c ALLOW) правил"
fi

# 15. Sysctl — производительность + anti-fingerprint
log "Оптимизирую сетевой стек..."
cat > /etc/sysctl.d/99-accesslicense.conf << 'SYSEOF'
# === BBR Congestion Control ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === TCP Performance ===
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 0

# === Buffers ===
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 16384

# === Connections ===
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 32768
net.ipv4.ip_local_port_range = 1024 65535

# === Security ===
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# === IPv6 ===
net.ipv6.conf.all.disable_ipv6 = 0
SYSEOF
sysctl -p /etc/sysctl.d/99-accesslicense.conf >/dev/null 2>&1
log "Sysctl оптимизирован (BBR + буферы + anti-fingerprint)"

# 16. Fail2ban для x-ui
log "Настраиваю Fail2ban..."
cat > /etc/fail2ban/filter.d/x-ui-iplimit.conf << 'F2BEOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\].*Disconnecting OLD IP = <HOST>
ignoreregex =
F2BEOF

cat > /etc/fail2ban/jail.d/x-ui-iplimit.conf << 'F2BJEOF'
[x-ui-iplimit]
enabled  = true
filter   = x-ui-iplimit
port     = http,https
logpath  = /var/log/x-ui/3xipl.log
maxretry = 3
findtime = 120
bantime  = 600
F2BJEOF

systemctl restart fail2ban 2>/dev/null || true

# 17. Запускаем
log "Запускаю AccessLicense..."
systemctl start x-ui
sleep 3

# 18. Проверка
if systemctl is-active --quiet x-ui; then
    XRAY_VER_ACTUAL=$(${XUI_FOLDER}/bin/xray-linux-${PLATFORM} -version 2>/dev/null | head -1 | awk '{print $2}' || echo "${XRAY_VERSION}")

    echo ""
    log "============================================"
    log "  УСТАНОВКА ЗАВЕРШЕНА!"
    log "============================================"
    echo ""
    info "  Server:  ${SERVER_IP}"
    info "  Go:      $(go version 2>/dev/null | awk '{print $3}')"
    info "  Xray:    ${XRAY_VER_ACTUAL}"
    echo ""
    log "  Панель:  http://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}"
    log "  Логин:   ${PANEL_USER}"
    log "  Пароль:  ${PANEL_PASS}"
    echo ""
    log "  Подписки:"
    log "    Links: http://${SERVER_IP}:${SUB_PORT}${SUB_PATH}<subId>"
    log "    JSON:  http://${SERVER_IP}:${SUB_PORT}${SUB_JSON_PATH}<subId>"
    echo ""
    warn "  Nginx:   порт 80 → google.com (камуфляж)"
    warn "  Reality: используй порт 443 для inbound"
    echo ""
    log "  Настройка VLESS+Reality:"
    log "    1. Панель → Inbounds → Add"
    log "    2. Protocol: VLESS"
    log "    3. Port: 443"
    log "    4. Transport: TCP"
    log "    5. Security: Reality"
    log "    6. Target: www.google.com:443"
    log "    7. SNI: www.google.com"
    log "    8. uTLS: chrome_auto"
    log "    9. Client Flow: xtls-rprx-vision"
    log "============================================"
else
    err "Панель не запустилась! Проверь: journalctl -u x-ui -n 50"
fi

# Чистим за собой
cd /
rm -rf /tmp/AccessLicense
