#!/bin/bash

#=================================================================
# AccessLicense Deploy Script (non-interactive)
# Скачивает release (как install.sh), настраивает панель,
# ставит x-ui меню, nginx-камуфляж, firewall, sysctl, fail2ban
# Использование: bash deploy.sh [version]
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
XUI_SERVICE="/etc/systemd/system"
DB_PATH="/etc/x-ui/3xui.db"
REPO="tarik1377/AccessLicense"
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

# OS detection
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    err "Не удалось определить ОС"
fi

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) err "Архитектура $(uname -m) не поддерживается" ;;
    esac
}

PLATFORM=$(arch)
SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me || curl -s4 --connect-timeout 5 api.ipify.org || echo "UNKNOWN")

log "============================================"
log "  AccessLicense Deploy"
log "  Server: ${SERVER_IP} | Arch: ${PLATFORM}"
log "  Panel: ${PANEL_PORT} | Subs: ${SUB_PORT}"
log "============================================"

# 1. Остановить старую версию
log "Останавливаю старую версию..."
systemctl stop x-ui 2>/dev/null || true
systemctl disable x-ui 2>/dev/null || true
pkill -f "x-ui" 2>/dev/null || true
sleep 1

# 2. Зависимости
log "Устанавливаю зависимости..."
case "${release}" in
    ubuntu | debian | armbian)
        apt-get update -qq
        apt-get install -y -qq curl tar wget socat unzip ca-certificates \
            tzdata fail2ban sqlite3 nginx cron >/dev/null 2>&1
    ;;
    fedora | amzn | rhel | almalinux | rocky | ol)
        dnf -y update -q
        dnf install -y -q curl tar wget socat unzip ca-certificates \
            tzdata fail2ban sqlite nginx cronie >/dev/null 2>&1
    ;;
    centos)
        if [[ "${VERSION_ID}" =~ ^7 ]]; then
            yum install -y curl tar wget socat unzip ca-certificates \
                tzdata fail2ban sqlite nginx cronie >/dev/null 2>&1
        else
            dnf install -y -q curl tar wget socat unzip ca-certificates \
                tzdata fail2ban sqlite nginx cronie >/dev/null 2>&1
        fi
    ;;
    arch | manjaro | parch)
        pacman -Syu --noconfirm curl tar wget socat unzip ca-certificates \
            tzdata fail2ban sqlite nginx >/dev/null 2>&1
    ;;
    *)
        apt-get update -qq && apt-get install -y -qq curl tar wget socat unzip \
            ca-certificates tzdata fail2ban sqlite3 nginx cron >/dev/null 2>&1
    ;;
esac

# 3. Скачиваем release (как install.sh — готовый бинарник, без Go build)
log "Скачиваю release..."
cd ${XUI_FOLDER%/x-ui}/

if [ $# -ge 1 ]; then
    TAG="$1"
else
    TAG=$(curl -4Ls "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$TAG" ]]; then
        err "Не удалось получить последнюю версию. Проверь GitHub Releases: https://github.com/${REPO}/releases"
    fi
fi
log "Версия: ${TAG}"

TARBALL="x-ui-linux-${PLATFORM}.tar.gz"
curl -4fLRo "${TARBALL}" "https://github.com/${REPO}/releases/download/${TAG}/${TARBALL}"
if [[ $? -ne 0 ]]; then
    err "Не удалось скачать release ${TAG}. Убедись что release существует: https://github.com/${REPO}/releases"
fi

# 4. Устанавливаем
log "Устанавливаю в ${XUI_FOLDER}..."
rm -rf ${XUI_FOLDER}
tar zxf "${TARBALL}"
rm -f "${TARBALL}"

cd x-ui
chmod +x x-ui x-ui.sh

# ARM rename
if [[ "${PLATFORM}" == "armv5" || "${PLATFORM}" == "armv6" || "${PLATFORM}" == "armv7" ]]; then
    mv bin/xray-linux-${PLATFORM} bin/xray-linux-arm
    chmod +x bin/xray-linux-arm
fi
chmod +x bin/xray-linux-${PLATFORM} 2>/dev/null || true

# 5. Ставим x-ui.sh как команду /usr/bin/x-ui (интерактивное меню)
log "Устанавливаю команду x-ui..."
curl -4fLRo /usr/bin/x-ui "https://raw.githubusercontent.com/${REPO}/main/x-ui.sh"
chmod +x /usr/bin/x-ui
chmod +x ${XUI_FOLDER}/x-ui.sh

# 6. Директории
mkdir -p /etc/x-ui /var/log/x-ui

# 7. Systemd service
log "Настраиваю systemd..."

# Пробуем из tar.gz, потом с GitHub
SERVICE_INSTALLED=false
for svc_file in "x-ui.service" "x-ui.service.debian" "x-ui.service.rhel"; do
    if [ -f "${svc_file}" ]; then
        cp -f "${svc_file}" ${XUI_SERVICE}/x-ui.service
        SERVICE_INSTALLED=true
        break
    fi
done

if [ "$SERVICE_INSTALLED" = false ]; then
    case "${release}" in
        ubuntu | debian | armbian)
            curl -4fLRo ${XUI_SERVICE}/x-ui.service "https://raw.githubusercontent.com/${REPO}/main/x-ui.service.debian" ;;
        arch | manjaro | parch)
            curl -4fLRo ${XUI_SERVICE}/x-ui.service "https://raw.githubusercontent.com/${REPO}/main/x-ui.service.arch" ;;
        *)
            curl -4fLRo ${XUI_SERVICE}/x-ui.service "https://raw.githubusercontent.com/${REPO}/main/x-ui.service.rhel" ;;
    esac
fi

chown root:root ${XUI_SERVICE}/x-ui.service
chmod 644 ${XUI_SERVICE}/x-ui.service
systemctl daemon-reload
systemctl enable x-ui >/dev/null 2>&1

# 8. Первый запуск — инициализация БД
log "Инициализирую БД..."
cd ${XUI_FOLDER}
timeout 15 ./x-ui 2>/dev/null || true
sleep 2

if [ ! -f "${DB_PATH}" ]; then
    err "БД не создалась! Проверь логи: journalctl -u x-ui -n 50"
fi
log "БД создана: $(ls -lh ${DB_PATH} | awk '{print $5}')"

# 9. Миграция БД
${XUI_FOLDER}/x-ui migrate 2>/dev/null || true

# 10. Настраиваем панель через x-ui CLI + sqlite3
log "Настраиваю панель..."

# Через встроенный CLI
${XUI_FOLDER}/x-ui setting -username "${PANEL_USER}" -password "${PANEL_PASS}" -port "${PANEL_PORT}" -webBasePath "${PANEL_PATH}" 2>/dev/null || true

# Дополнительные настройки через sqlite3
sqlite3 "${DB_PATH}" << 'SQLEOF'
-- Подписки
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subPort'), 'subPort', '9444');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subPath'), 'subPath', '/feed/');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subJsonPath'), 'subJsonPath', '/config/');
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

# 11. Nginx — камуфляж
log "Настраиваю nginx-камуфляж..."
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

    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    ln -sf /etc/nginx/sites-available/camouflage /etc/nginx/sites-enabled/
    nginx -t >/dev/null 2>&1 && systemctl restart nginx
    log "Nginx-камуфляж активен (порт 80 → google.com)"
fi

# 12. Firewall
log "Настраиваю firewall..."
if command -v ufw &>/dev/null; then
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
    ufw allow ${SUB_PORT}/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    log "UFW: $(ufw status | grep -c ALLOW) правил"
fi

# 13. Sysctl — BBR + производительность
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
log "BBR + оптимизация применены"

# 14. Fail2ban для x-ui
log "Настраиваю Fail2ban..."
mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d

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

# 15. Запускаем
log "Запускаю AccessLicense..."
systemctl start x-ui
sleep 3

# 16. Проверка
if systemctl is-active --quiet x-ui; then
    XRAY_VER=$(${XUI_FOLDER}/bin/xray-linux-${PLATFORM} -version 2>/dev/null | head -1 | awk '{print $2}' || echo "n/a")

    echo ""
    log "============================================"
    log "  УСТАНОВКА ЗАВЕРШЕНА!"
    log "============================================"
    echo ""
    info "  Server:  ${SERVER_IP}"
    info "  Arch:    ${PLATFORM}"
    info "  Version: ${TAG}"
    info "  Xray:    ${XRAY_VER}"
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
    log "  Команда x-ui — полное меню управления"
    log "  SSL:  x-ui → пункт 16 (SSL Certificate Management)"
    echo ""
    log "  Настройка VLESS+Reality:"
    log "    1. Панель → Inbounds → Add"
    log "    2. Protocol: VLESS | Port: 443"
    log "    3. Transport: TCP | Security: Reality"
    log "    4. Target: www.google.com:443"
    log "    5. SNI: www.google.com | uTLS: chrome_auto"
    log "    6. Client Flow: xtls-rprx-vision"
    log "============================================"
else
    err "Панель не запустилась! Проверь: journalctl -u x-ui -n 50"
fi

# Чистим
cd /
rm -rf /tmp/AccessLicense
