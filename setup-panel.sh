#!/bin/bash

#=================================================================
# AccessLicense Panel Setup — настройка панели через API
# Запускать НА СЕРВЕРЕ после установки панели
#
# Использование:
#   bash setup-panel.sh
#=================================================================

set -e

# ===================== КОНФИГУРАЦИЯ ПАНЕЛИ =====================
PANEL_HOST="127.0.0.1"
PANEL_PORT="3450"
PANEL_BASE="/3deGsFlMgJ4R2yBvbb"
PANEL_USER="7Lw7OD63Yl"
PANEL_PASS="zfg67oAVfF"

# VLESS+Reality параметры
VLESS_PORT=443
DEST="yandex.ru:443"
SNI="yandex.ru"
FINGERPRINT="chrome"
# ===============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

COOKIES=$(mktemp)
BASE_URL="https://${PANEL_HOST}:${PANEL_PORT}${PANEL_BASE}"

api() {
    local method="$1" endpoint="$2" data="$3"
    local url="${BASE_URL}${endpoint}"
    local args=(-sk -b "$COOKIES" -c "$COOKIES" -H "Content-Type: application/json")
    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        args+=(-X POST -d "$data")
    elif [ "$method" = "POST" ]; then
        args+=(-X POST)
    fi
    curl "${args[@]}" "$url" 2>/dev/null
}

# ===================== 1. LOGIN =====================
log "Логинюсь в панель..."
LOGIN_RESP=$(curl -sk -c "$COOKIES" -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${PANEL_USER}&password=${PANEL_PASS}" 2>/dev/null)

if echo "$LOGIN_RESP" | grep -q '"success":true'; then
    log "Успешно залогинился"
else
    err "Не удалось залогиниться! Ответ: ${LOGIN_RESP}"
fi

# ===================== 2. ПОЛУЧАЕМ ТЕКУЩИЕ НАСТРОЙКИ =====================
log "Получаю текущие настройки..."
SETTINGS_RESP=$(api POST "/panel/setting/all")
if ! echo "$SETTINGS_RESP" | grep -q '"success":true'; then
    err "Не удалось получить настройки: ${SETTINGS_RESP}"
fi

# Извлекаем текущие настройки для сохранения тех что не меняем
CURRENT=$(echo "$SETTINGS_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success'):
    print(json.dumps(data['obj']))
else:
    print('{}')
" 2>/dev/null || echo "{}")

log "Текущие настройки получены"

# ===================== 3. ОБНОВЛЯЕМ НАСТРОЙКИ =====================
log "Обновляю настройки панели..."

# Формируем JSON обновления — меняем только нужное, остальное берём из текущих
UPDATED_SETTINGS=$(echo "$CURRENT" | python3 -c "
import sys, json

settings = json.load(sys.stdin)

# Подписки — включаем и настраиваем
settings['subEnable'] = True
settings['subJsonEnable'] = True
settings['subEncrypt'] = True
settings['subShowInfo'] = True
settings['subPort'] = 2096
settings['subPath'] = '/sub/'
settings['subJsonPath'] = '/json/'

# Безопасность
settings['sessionMaxAge'] = 360

# Время
settings['timeLocation'] = 'Europe/Moscow'

print(json.dumps(settings))
" 2>/dev/null)

UPDATE_RESP=$(api POST "/panel/setting/update" "$UPDATED_SETTINGS")
if echo "$UPDATE_RESP" | grep -q '"success":true'; then
    log "Настройки обновлены"
else
    warn "Ошибка обновления настроек: ${UPDATE_RESP}"
fi

# ===================== 4. ГЕНЕРИРУЕМ КЛЮЧИ X25519 =====================
log "Генерирую ключи X25519 для Reality..."
KEYS_RESP=$(api GET "/panel/api/server/getNewX25519Cert")
PRIV_KEY=$(echo "$KEYS_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success'):
    print(data['obj']['privateKey'])
" 2>/dev/null)
PUB_KEY=$(echo "$KEYS_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success'):
    print(data['obj']['publicKey'])
" 2>/dev/null)

if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then
    err "Не удалось сгенерировать ключи! Ответ: ${KEYS_RESP}"
fi

log "Ключи сгенерированы"
info "  Private: ${PRIV_KEY}"
info "  Public:  ${PUB_KEY}"

# ===================== 5. ГЕНЕРИРУЕМ UUID =====================
log "Генерирую UUID для клиента..."
UUID_RESP=$(api GET "/panel/api/server/getNewUUID")
CLIENT_UUID=$(echo "$UUID_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success'):
    print(data['obj'])
" 2>/dev/null)

if [ -z "$CLIENT_UUID" ]; then
    CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
fi

log "UUID: ${CLIENT_UUID}"

# ===================== 6. ГЕНЕРИРУЕМ SHORT ID =====================
SHORT_ID=$(openssl rand -hex 8)
log "Short ID: ${SHORT_ID}"

# ===================== 7. СОЗДАЁМ VLESS+REALITY INBOUND =====================
log "Создаю VLESS+Reality inbound на порту ${VLESS_PORT}..."

INBOUND_JSON=$(python3 -c "
import json

inbound = {
    'up': 0,
    'down': 0,
    'total': 0,
    'remark': 'VLESS-Reality-${SNI}',
    'enable': True,
    'expiryTime': 0,
    'listen': '',
    'port': ${VLESS_PORT},
    'protocol': 'vless',
    'settings': json.dumps({
        'clients': [{
            'id': '${CLIENT_UUID}',
            'flow': 'xtls-rprx-vision',
            'email': 'main-user',
            'limitIp': 0,
            'totalGB': 0,
            'expiryTime': 0,
            'enable': True,
            'tgId': '',
            'subId': '$(openssl rand -hex 8)',
            'comment': 'Main user'
        }],
        'decryption': 'none',
        'fallbacks': []
    }),
    'streamSettings': json.dumps({
        'network': 'tcp',
        'security': 'reality',
        'externalProxy': [],
        'realitySettings': {
            'show': False,
            'xver': 0,
            'dest': '${DEST}',
            'serverNames': ['${SNI}'],
            'privateKey': '${PRIV_KEY}',
            'minClient': '',
            'maxClient': '',
            'maxTimediff': 0,
            'shortIds': ['${SHORT_ID}', '', '0123456789abcdef'],
            'settings': {
                'publicKey': '${PUB_KEY}',
                'fingerprint': '${FINGERPRINT}',
                'serverName': ''
            }
        },
        'tcpSettings': {
            'acceptProxyProtocol': False,
            'header': {'type': 'none'}
        }
    }),
    'sniffing': json.dumps({
        'enabled': True,
        'destOverride': ['http', 'tls', 'quic', 'fakedns'],
        'metadataOnly': False,
        'routeOnly': False
    }),
    'allocate': json.dumps({
        'strategy': 'always',
        'refresh': 5,
        'concurrency': 3
    })
}

print(json.dumps(inbound))
")

ADD_RESP=$(api POST "/panel/api/inbounds/add" "$INBOUND_JSON")

if echo "$ADD_RESP" | grep -q '"success":true'; then
    log "VLESS+Reality inbound создан!"
else
    warn "Ошибка создания inbound: ${ADD_RESP}"
    warn "Возможно порт ${VLESS_PORT} уже занят. Попробуй другой или удали старый через панель."
fi

# ===================== 8. ПОЛУЧАЕМ IP СЕРВЕРА =====================
SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me || curl -s4 --connect-timeout 5 api.ipify.org || echo "UNKNOWN")

# ===================== ИТОГ =====================
echo ""
log "============================================"
log "  НАСТРОЙКА ЗАВЕРШЕНА!"
log "============================================"
echo ""
info "  Панель:     https://${SERVER_IP}:${PANEL_PORT}${PANEL_BASE}/"
info "  Логин:      ${PANEL_USER}"
info "  Пароль:     ${PANEL_PASS}"
echo ""
log "  VLESS+Reality:"
info "    Порт:        ${VLESS_PORT}"
info "    Протокол:    VLESS + Reality + Vision"
info "    Dest:        ${DEST}"
info "    SNI:         ${SNI}"
info "    Fingerprint: ${FINGERPRINT}"
info "    Client UUID: ${CLIENT_UUID}"
info "    Public Key:  ${PUB_KEY}"
info "    Short ID:    ${SHORT_ID}"
echo ""
log "  Подписки:"
info "    Sub port:  2096"
info "    Sub path:  /sub/<subId>"
info "    JSON path: /json/<subId>"
echo ""
warn "  Для подключения клиента используй:"
warn "    - v2rayN / v2rayNG / Nekobox / Hiddify"
warn "    - Адрес:     ${SERVER_IP}"
warn "    - Порт:      ${VLESS_PORT}"
warn "    - UUID:      ${CLIENT_UUID}"
warn "    - Flow:      xtls-rprx-vision"
warn "    - Security:  reality"
warn "    - SNI:       ${SNI}"
warn "    - PublicKey: ${PUB_KEY}"
warn "    - ShortId:   ${SHORT_ID}"
warn "    - Fingerprint: ${FINGERPRINT}"
echo ""
log "============================================"

# Cleanup
rm -f "$COOKIES"
