#!/bin/bash

#=================================================================
# AccessLicense Deployment Script
# Устанавливает панель с оптимальными anti-detection настройками
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
# ========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# Проверка root
[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash deploy.sh"

log "============================================"
log "  AccessLicense Deploy"
log "  Порт панели: ${PANEL_PORT}"
log "  Порт подписок: ${SUB_PORT}"
log "============================================"

# 1. Остановить и удалить старую версию
log "Останавливаю старую сборку..."
systemctl stop x-ui 2>/dev/null || true
systemctl disable x-ui 2>/dev/null || true

# 2. Зависимости
log "Устанавливаю зависимости..."
apt-get update -qq
apt-get install -y -qq curl tar wget socat unzip ca-certificates tzdata fail2ban >/dev/null 2>&1

# 3. Определяем архитектуру
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  PLATFORM="amd64" ;;
    aarch64) PLATFORM="arm64" ;;
    armv7l)  PLATFORM="armv7" ;;
    *)       err "Архитектура $ARCH не поддерживается" ;;
esac
log "Архитектура: ${PLATFORM}"

# 4. Скачиваем последний релиз
log "Скачиваю AccessLicense..."
RELEASE_URL="https://api.github.com/repos/tarik1377/AccessLicense/releases/latest"
TAG=$(curl -sL "$RELEASE_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null)

if [ -z "$TAG" ]; then
    warn "Нет релизов — собираю из исходников..."

    # Устанавливаем Go если нет
    if ! command -v go &>/dev/null; then
        log "Устанавливаю Go..."
        GO_VERSION="1.23.6"
        wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${PLATFORM}.tar.gz" -O /tmp/go.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        rm /tmp/go.tar.gz
    fi

    # Клонируем и собираем
    log "Клонирую репозиторий..."
    cd /tmp
    rm -rf AccessLicense
    git clone --depth=1 https://github.com/tarik1377/AccessLicense.git
    cd AccessLicense

    log "Собираю бинарник..."
    export CGO_ENABLED=1
    go build -ldflags "-w -s" -o x-ui main.go

    # Создаем структуру
    rm -rf ${XUI_FOLDER}
    mkdir -p ${XUI_FOLDER}/bin
    cp x-ui ${XUI_FOLDER}/
    cp x-ui.sh ${XUI_FOLDER}/
    cp x-ui.service.debian /etc/systemd/system/x-ui.service
    chmod +x ${XUI_FOLDER}/x-ui ${XUI_FOLDER}/x-ui.sh

    # Скачиваем Xray
    log "Скачиваю Xray-core..."
    XRAY_VER="v26.2.6"
    cd ${XUI_FOLDER}/bin
    case "$PLATFORM" in
        amd64) XRAY_FILE="Xray-linux-64.zip" ;;
        arm64) XRAY_FILE="Xray-linux-arm64-v8a.zip" ;;
        armv7) XRAY_FILE="Xray-linux-arm32-v7a.zip" ;;
    esac
    wget -q "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_FILE}"
    unzip -qo "${XRAY_FILE}"
    rm -f "${XRAY_FILE}"
    mv xray "xray-linux-${PLATFORM}"

    # Geo файлы
    log "Скачиваю geo-данные..."
    wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    wget -q -O geoip_RU.dat "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
    wget -q -O geosite_RU.dat "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"

    cd /tmp
    rm -rf AccessLicense
else
    log "Найден релиз: ${TAG}"
    DL_URL="https://github.com/tarik1377/AccessLicense/releases/download/${TAG}/x-ui-linux-${PLATFORM}.tar.gz"
    wget -q "${DL_URL}" -O /tmp/x-ui.tar.gz

    rm -rf ${XUI_FOLDER}
    cd /usr/local
    tar -xzf /tmp/x-ui.tar.gz
    chmod +x ${XUI_FOLDER}/x-ui ${XUI_FOLDER}/x-ui.sh

    cp ${XUI_FOLDER}/x-ui.service.debian /etc/systemd/system/x-ui.service 2>/dev/null || true
    rm /tmp/x-ui.tar.gz
fi

# 5. Настраиваем директории
mkdir -p /etc/x-ui /var/log/x-ui

# 6. Systemd service
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
systemctl enable x-ui

# 7. Первый запуск — создание БД
log "Первый запуск для инициализации БД..."
cd ${XUI_FOLDER}
timeout 10 ./x-ui 2>/dev/null || true
sleep 2

# 8. Настраиваем панель через sqlite3
log "Настраиваю параметры панели..."
apt-get install -y -qq sqlite3 >/dev/null 2>&1

# Хешируем пароль (bcrypt через python3)
HASHED_PASS=$(python3 -c "
import hashlib, base64, os
try:
    import bcrypt
    print(bcrypt.hashpw(b'${PANEL_PASS}', bcrypt.gensalt()).decode())
except ImportError:
    # Fallback - plain (panel will hash on first login)
    print('${PANEL_PASS}')
" 2>/dev/null || echo "${PANEL_PASS}")

sqlite3 "${DB_PATH}" << SQLEOF
UPDATE users SET username='${PANEL_USER}', password='${HASHED_PASS}' WHERE id=1;

-- Порт панели
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='webPort'), 'webPort', '${PANEL_PORT}');

-- Базовый путь панели (скрытый)
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='webBasePath'), 'webBasePath', '${PANEL_PATH}');

-- Порт подписок
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subPort'), 'subPort', '${SUB_PORT}');

-- Пути подписок
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subPath'), 'subPath', '${SUB_PATH}');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subJsonPath'), 'subJsonPath', '${SUB_JSON_PATH}');

-- Включить подписки
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subEnable'), 'subEnable', 'true');
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subJsonEnable'), 'subJsonEnable', 'true');

-- Шифрование подписок
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='subEncrypt'), 'subEncrypt', 'true');

-- Время сессии (6 часов)
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='sessionMaxAge'), 'sessionMaxAge', '360');

-- IP limit tracking
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='ipLimitEnable'), 'ipLimitEnable', 'true');
SQLEOF

# 9. Firewall
log "Настраиваю firewall..."
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
    ufw allow ${SUB_PORT}/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
fi

# 10. Sysctl оптимизация (anti-fingerprint + производительность)
log "Оптимизирую сетевой стек..."
cat > /etc/sysctl.d/99-accesslicense.conf << 'SYSEOF'
# BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP optimization
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10

# Buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Connection tracking
net.netfilter.nf_conntrack_max = 131072
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# Anti-fingerprint: don't reveal uptime
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1

# IPv6
net.ipv6.conf.all.disable_ipv6 = 0
SYSEOF
sysctl -p /etc/sysctl.d/99-accesslicense.conf >/dev/null 2>&1

# 11. Запускаем панель
log "Запускаю AccessLicense..."
systemctl start x-ui
sleep 3

# 12. Проверяем статус
if systemctl is-active --quiet x-ui; then
    log "============================================"
    log "  УСТАНОВКА ЗАВЕРШЕНА!"
    log "============================================"
    log ""
    log "  Панель: http://$(curl -s4 ifconfig.me):${PANEL_PORT}${PANEL_PATH}"
    log "  Логин:  ${PANEL_USER}"
    log "  Пароль: ${PANEL_PASS}"
    log ""
    log "  Подписки: порт ${SUB_PORT}"
    log "  Sub path: ${SUB_PATH}"
    log "  JSON path: ${SUB_JSON_PATH}"
    log ""
    warn "  ДОМЕН НЕ НУЖЕН — Reality маскируется под чужой домен."
    warn "  При белых списках используй VLESS+Reality+XHTTP."
    log ""
    log "  Следующий шаг:"
    log "  1. Зайди в панель"
    log "  2. Создай inbound: VLESS + TCP + Reality"
    log "  3. Target: www.google.com:443"
    log "  4. uTLS: chrome_auto"
    log "  5. Flow: xtls-rprx-vision"
    log "============================================"
else
    err "Панель не запустилась! Проверь: journalctl -u x-ui -n 50"
fi
