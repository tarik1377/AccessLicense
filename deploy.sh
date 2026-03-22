#!/bin/bash

#=================================================================
# AccessLicense Deploy — быстрая установка из GitHub Releases
# Без Go, без сборки — скачивает готовый бинарник за секунды
# + настройка панели, nginx, firewall, sysctl, VLESS+Reality
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
DB_PATH="/etc/x-ui/x-ui.db"
GITHUB_REPO="tarik1377/AccessLicense"
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
log "  AccessLicense Fast Deploy"
log "  Server: ${SERVER_IP}"
log "  Panel: ${PANEL_PORT} | Subs: ${SUB_PORT}"
log "============================================"

# 1. Ставим x-ui из GitHub Releases (как в оригинале — быстро)
log "Устанавливаю AccessLicense из releases..."
bash <(curl -Ls "https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh")

# Ждём чтобы сервис стартовал и создал БД
sleep 3

# 2. Дополнительные зависимости для наших надстроек
log "Ставлю доп. зависимости..."
if command -v apt-get &>/dev/null; then
    apt-get install -y -qq fail2ban sqlite3 python3 nginx >/dev/null 2>&1
elif command -v dnf &>/dev/null; then
    dnf install -y -q fail2ban sqlite nginx >/dev/null 2>&1
elif command -v yum &>/dev/null; then
    yum install -y -q fail2ban sqlite nginx >/dev/null 2>&1
fi

# 3. Останавливаем для настройки БД
systemctl stop x-ui 2>/dev/null || true
sleep 1

# 4. Настраиваем панель через БД
log "Настраиваю панель..."

# Проверяем что БД создалась
if [ ! -f "${DB_PATH}" ]; then
    FOUND_DB=$(find /etc/x-ui -name "*.db" -type f 2>/dev/null | head -1)
    if [ -n "${FOUND_DB}" ]; then
        DB_PATH="${FOUND_DB}"
        warn "БД: ${DB_PATH}"
    else
        err "БД не создалась! Проверь: journalctl -u x-ui -n 50"
    fi
fi

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

-- Порт панели
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

-- Xray шаблон: оптимизирован для VLESS+Reality скорости
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='xrayTemplateConfig'), 'xrayTemplateConfig', '{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/x-ui/access.log",
    "error": "/var/log/x-ui/error.log"
  },
  "api": {
    "services": ["HandlerService", "LoggerService", "StatsService"],
    "tag": "api"
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "handshake": 2,
        "connIdle": 120,
        "uplinkOnly": 1,
        "downlinkOnly": 1,
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "bufferSize": 4
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" },
      "tag": "api",
      "sniffing": null
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "ip": ["geoip:private"],
        "outboundTag": "blocked",
        "type": "field"
      },
      {
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "blocked",
        "type": "field"
      }
    ]
  }
}');
SQLEOF

log "Панель настроена"

# 5. Nginx — камуфляж
log "Настраиваю nginx-камуфляж..."
if command -v nginx &>/dev/null; then
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    cat > /etc/nginx/sites-available/camouflage << NGXEOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_pass https://www.google.com;
        proxy_set_header Host www.google.com;
        proxy_set_header Accept-Encoding "";
        proxy_ssl_server_name on;
        sub_filter 'google.com' '${SERVER_IP}';
        sub_filter_once off;
    }

    location ~* \.(env|git|svn|htaccess|htpasswd|bak|old|orig|save|conf|cfg|ini|log|sql|db)\$ {
        return 404;
    }
}
NGXEOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/camouflage /etc/nginx/sites-enabled/
    nginx -t >/dev/null 2>&1 && systemctl restart nginx
    log "Nginx: порт 80 → камуфляж"
fi

# 6. Firewall
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

# 7. Sysctl — агрессивная оптимизация для VLESS+Reality скорости
log "Оптимизирую сетевой стек для максимальной скорости..."
cat > /etc/sysctl.d/99-accesslicense.conf << 'SYSEOF'
# === BBR v3 Congestion Control (максимальная скорость) ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === TCP Fast Open (меньше рукопожатий = быстрее) ===
net.ipv4.tcp_fastopen = 3

# === Отключить медленный старт после idle (критично для VPN!) ===
net.ipv4.tcp_slow_start_after_idle = 0

# === MTU Probing (находит оптимальный MTU = меньше фрагментации) ===
net.ipv4.tcp_mtu_probing = 1

# === TCP keepalive (держим соединения живыми) ===
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# === Быстрый переход TIME-WAIT ===
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_tw_reuse = 1

# === TCP Window Scaling (большие окна = быстрее) ===
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_notsent_lowat = 131072

# === Огромные буферы (для 1Gbps+) ===
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.optmem_max = 65536

# === Backlog (обрабатываем больше пакетов без потерь) ===
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# === Соединения ===
net.ipv4.tcp_max_syn_backlog = 65536
net.core.somaxconn = 65536
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = 65536

# === Conntrack (больше одновременных соединений) ===
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# === Security (минимум без ущерба скорости) ===
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# === IPv6 ===
net.ipv6.conf.all.disable_ipv6 = 0
SYSEOF
sysctl -p /etc/sysctl.d/99-accesslicense.conf >/dev/null 2>&1
log "Sysctl: BBR + буферы 64MB + fast open + оптимизация"

# 8. Fail2ban
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

# 9. Запускаем с нашими настройками
log "Запускаю AccessLicense..."
systemctl restart x-ui
sleep 3

# 10. Архитектура для вывода
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  PLATFORM="amd64" ;;
    aarch64) PLATFORM="arm64" ;;
    armv7l)  PLATFORM="armv7" ;;
    *)       PLATFORM="$ARCH" ;;
esac

# 11. Проверка
if systemctl is-active --quiet x-ui; then
    XRAY_VER_ACTUAL=$(${XUI_FOLDER}/bin/xray-linux-${PLATFORM} -version 2>/dev/null | head -1 | awk '{print $2}' || echo "latest")

    echo ""
    log "============================================"
    log "  УСТАНОВКА ЗАВЕРШЕНА!"
    log "============================================"
    echo ""
    info "  Server:  ${SERVER_IP}"
    info "  Xray:    ${XRAY_VER_ACTUAL}"
    info "  Arch:    ${PLATFORM}"
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
    echo ""
    log "  ═══ VLESS+Reality (максимальная скорость) ═══"
    log "    1. Панель → Inbounds → Add Inbound"
    log "    2. Protocol: VLESS"
    log "    3. Port: 443"
    log "    4. Transport: TCP"
    log "    5. Security: Reality"
    log "    6. Target (dest): www.microsoft.com:443"
    log "    7. SNI (serverNames): www.microsoft.com"
    log "    8. uTLS (fingerprint): chrome"
    log "    9. Client → Flow: xtls-rprx-vision"
    log "   10. Нажми x-ui x25519 для генерации ключей"
    echo ""
    info "  Почему microsoft.com а не google.com:"
    info "    - CDN ближе к серверу = меньше latency"
    info "    - TLS 1.3 + H2 по дефолту"
    info "    - Реже блокируется DPI"
    echo ""
    log "  Оптимизации скорости (применены):"
    log "    - BBR congestion control"
    log "    - TCP Fast Open (client+server)"
    log "    - Буферы 64MB (для 1Gbps+)"
    log "    - Отключен slow start after idle"
    log "    - MTU Probing"
    log "    - conntrack оптимизирован"
    echo ""
    log "  Управление: x-ui"
    log "============================================"
else
    err "Панель не запустилась! Проверь: journalctl -u x-ui -n 50"
fi
