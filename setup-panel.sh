#!/bin/bash

#=================================================================
# AccessLicense Panel Setup — настройка панели через API
# Запускать НА СЕРВЕРЕ после установки панели
#
# Креды зашифрованы AES-256-CBC. При запуске вводишь мастер-пароль.
#
# Первый запуск (сохранить креды):
#   bash setup-panel.sh --encrypt
#
# Обычный запуск (настройка панели):
#   bash setup-panel.sh
#
# Мониторинг девайсов:
#   bash setup-panel.sh --devices
#=================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDS_FILE="${SCRIPT_DIR}/.credentials.enc"

# ===================== ШИФРОВАНИЕ КРЕДОВ =====================

encrypt_credentials() {
    echo ""
    log "Шифрование кредов (AES-256-CBC + PBKDF2)"
    echo ""

    read -rp "  Panel Host [127.0.0.1]: " INPUT_HOST
    PANEL_HOST="${INPUT_HOST:-127.0.0.1}"

    read -rp "  Panel Port: " PANEL_PORT
    [ -z "$PANEL_PORT" ] && err "Порт обязателен"

    read -rp "  WebBasePath (без слешей): " PANEL_BASE_RAW
    [ -z "$PANEL_BASE_RAW" ] && err "WebBasePath обязателен"

    read -rp "  Username: " PANEL_USER
    [ -z "$PANEL_USER" ] && err "Username обязателен"

    read -rsp "  Password: " PANEL_PASS
    echo ""
    [ -z "$PANEL_PASS" ] && err "Password обязателен"

    echo ""
    warn "Задай мастер-пароль для шифрования (запомни его!):"
    read -rsp "  Мастер-пароль: " MASTER_PASS
    echo ""
    read -rsp "  Повтори:       " MASTER_PASS2
    echo ""

    [ "$MASTER_PASS" != "$MASTER_PASS2" ] && err "Пароли не совпадают"
    [ ${#MASTER_PASS} -lt 8 ] && err "Мастер-пароль минимум 8 символов"

    # JSON с кредами → шифруем AES-256-CBC с PBKDF2 (100k итераций)
    PLAIN_JSON=$(python3 -c "
import json
print(json.dumps({
    'host': '${PANEL_HOST}',
    'port': '${PANEL_PORT}',
    'base': '/${PANEL_BASE_RAW}',
    'user': '${PANEL_USER}',
    'pass': '''${PANEL_PASS}'''
}))
")

    echo "$PLAIN_JSON" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -salt -pass "pass:${MASTER_PASS}" -base64 -out "$CREDS_FILE"

    chmod 600 "$CREDS_FILE"

    log "Креды зашифрованы → ${CREDS_FILE}"
    info "Файл .credentials.enc добавлен в .gitignore"

    # Добавляем в .gitignore
    if [ -f "${SCRIPT_DIR}/.gitignore" ]; then
        grep -qF '.credentials.enc' "${SCRIPT_DIR}/.gitignore" || echo '.credentials.enc' >> "${SCRIPT_DIR}/.gitignore"
    else
        echo '.credentials.enc' > "${SCRIPT_DIR}/.gitignore"
    fi

    echo ""
    log "Готово! Теперь запусти:  bash setup-panel.sh"
    exit 0
}

# ===================== РАСШИФРОВКА КРЕДОВ =====================

decrypt_credentials() {
    [ ! -f "$CREDS_FILE" ] && err "Файл ${CREDS_FILE} не найден. Сначала: bash setup-panel.sh --encrypt"

    read -rsp "Мастер-пароль: " MASTER_PASS
    echo ""

    PLAIN_JSON=$(openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -d -salt -pass "pass:${MASTER_PASS}" -base64 -in "$CREDS_FILE" 2>/dev/null) \
        || err "Неверный мастер-пароль!"

    PANEL_HOST=$(echo "$PLAIN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['host'])")
    PANEL_PORT=$(echo "$PLAIN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['port'])")
    PANEL_BASE=$(echo "$PLAIN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['base'])")
    PANEL_USER=$(echo "$PLAIN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['user'])")
    PANEL_PASS=$(echo "$PLAIN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['pass'])")

    BASE_URL="https://${PANEL_HOST}:${PANEL_PORT}${PANEL_BASE}"
}

# ===================== API ХЕЛПЕР =====================

COOKIES=""

api_login() {
    COOKIES=$(mktemp)
    LOGIN_RESP=$(curl -sk -c "$COOKIES" -X POST "${BASE_URL}/login" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${PANEL_USER}&password=${PANEL_PASS}" 2>/dev/null)

    if echo "$LOGIN_RESP" | grep -q '"success":true'; then
        log "Залогинился"
    else
        err "Ошибка логина: ${LOGIN_RESP}"
    fi
}

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

api_cleanup() {
    rm -f "$COOKIES" 2>/dev/null
}

# ===================== МОНИТОРИНГ ДЕВАЙСОВ =====================

monitor_devices() {
    decrypt_credentials
    api_login

    echo ""
    log "============================================"
    log "  МОНИТОРИНГ ДЕВАЙСОВ"
    log "============================================"

    # 1. Онлайн клиенты
    echo ""
    log "Онлайн сейчас:"
    ONLINE_RESP=$(api POST "/panel/api/inbounds/onlines")
    echo "$ONLINE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success') and data.get('obj'):
    clients = data['obj']
    if not clients:
        print('  (никого нет онлайн)')
    else:
        for email in clients:
            print(f'  ● {email}')
        print(f'\n  Всего онлайн: {len(clients)}')
else:
    print('  (никого нет онлайн)')
" 2>/dev/null

    # 2. Все inbound'ы и клиенты
    echo ""
    log "Все inbound'ы и клиенты:"
    LIST_RESP=$(api GET "/panel/api/inbounds/list")
    echo "$LIST_RESP" | python3 -c "
import sys, json

data = json.load(sys.stdin)
if not data.get('success') or not data.get('obj'):
    print('  (нет inbound-ов)')
    sys.exit()

for ib in data['obj']:
    remark = ib.get('remark', 'N/A')
    port = ib.get('port', '?')
    proto = ib.get('protocol', '?')
    enabled = '✓' if ib.get('enable') else '✗'
    up = ib.get('up', 0) / (1024**3)
    down = ib.get('down', 0) / (1024**3)

    print(f'\n  ═══ {remark} ({proto}:{port}) [{enabled}] ═══')
    print(f'  ↑ {up:.2f} GB  ↓ {down:.2f} GB')

    # Клиенты
    settings = json.loads(ib.get('settings', '{}'))
    clients = settings.get('clients', [])
    client_stats = {cs['email']: cs for cs in ib.get('clientStats', []) if cs.get('email')}

    if not clients:
        print('  (нет клиентов)')
        continue

    for cl in clients:
        email = cl.get('email', 'N/A')
        enabled_cl = '✓' if cl.get('enable', True) else '✗'
        limit_ip = cl.get('limitIp', 0)
        total_gb = cl.get('totalGB', 0) / (1024**3) if cl.get('totalGB', 0) > 0 else 0
        sub_id = cl.get('subId', '')

        stats = client_stats.get(email, {})
        cl_up = stats.get('up', 0) / (1024**3)
        cl_down = stats.get('down', 0) / (1024**3)

        print(f'    ├─ {email} [{enabled_cl}]')
        print(f'    │  ↑ {cl_up:.2f} GB  ↓ {cl_down:.2f} GB', end='')
        if total_gb > 0:
            print(f'  (лимит: {total_gb:.1f} GB)', end='')
        print()
        if limit_ip > 0:
            print(f'    │  Лимит IP: {limit_ip}')
        if sub_id:
            print(f'    │  Sub ID: {sub_id}')
" 2>/dev/null

    # 3. Девайсы по каждому клиенту
    echo ""
    log "Девайсы по клиентам:"
    echo "$LIST_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data.get('success'):
    sys.exit()
emails = []
for ib in data.get('obj', []):
    settings = json.loads(ib.get('settings', '{}'))
    for cl in settings.get('clients', []):
        email = cl.get('email')
        if email and email not in emails:
            emails.append(email)
for e in emails:
    print(e)
" 2>/dev/null | while read -r CLIENT_EMAIL; do
        [ -z "$CLIENT_EMAIL" ] && continue

        info "  ${CLIENT_EMAIL}:"

        # IP адреса
        IPS_RESP=$(api POST "/panel/api/inbounds/clientIps/${CLIENT_EMAIL}")
        echo "$IPS_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success') and data.get('obj'):
    obj = data['obj']
    if isinstance(obj, str):
        if obj.strip() and obj.strip() != 'null':
            for ip in obj.strip().split(','):
                ip = ip.strip()
                if ip:
                    print(f'      IP: {ip}')
        else:
            print('      (нет данных по IP)')
    elif isinstance(obj, list):
        for item in obj:
            print(f'      IP: {item}')
    elif isinstance(obj, dict):
        for ip, ts in obj.items():
            print(f'      IP: {ip} (last: {ts})')
else:
    print('      (нет данных по IP)')
" 2>/dev/null

        # Устройства
        DEVS_RESP=$(api POST "/panel/api/inbounds/clientDevices/${CLIENT_EMAIL}")
        echo "$DEVS_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success') and data.get('obj'):
    devs = data['obj']
    if isinstance(devs, list) and devs:
        for d in devs:
            print(f'      Device: {d}')
    elif isinstance(devs, dict) and devs:
        for k, v in devs.items():
            print(f'      Device: {k} → {v}')
    else:
        print('      (нет девайсов)')
else:
    print('      (нет девайсов)')
" 2>/dev/null
    done

    echo ""
    log "============================================"

    api_cleanup
    exit 0
}

# ===================== ЛИМИТ УСТРОЙСТВ =====================

set_device_limit() {
    local client_email="$1"
    local max_devices="$2"

    [ -z "$client_email" ] && err "Укажи email клиента: --limit <email> <число>"
    [ -z "$max_devices" ] && err "Укажи макс. устройств: --limit <email> <число>"

    decrypt_credentials
    api_login

    # Получаем все inbound'ы, находим клиента, обновляем limitIp
    LIST_RESP=$(api GET "/panel/api/inbounds/list")

    RESULT=$(echo "$LIST_RESP" | python3 -c "
import sys, json

data = json.load(sys.stdin)
if not data.get('success'):
    print('ERROR:Не удалось получить inbound-ы')
    sys.exit()

email = '${client_email}'
limit = int('${max_devices}')
found = False

for ib in data['obj']:
    settings = json.loads(ib.get('settings', '{}'))
    clients = settings.get('clients', [])
    for cl in clients:
        if cl.get('email') == email:
            cl['limitIp'] = limit
            found = True
            break
    if found:
        ib_id = ib['id']
        ib['settings'] = json.dumps(settings)
        print(f'FOUND:{ib_id}')
        # Выводим обновлённый inbound как JSON
        print(json.dumps(ib))
        break

if not found:
    print(f'ERROR:Клиент {email} не найден')
" 2>/dev/null)

    FIRST_LINE=$(echo "$RESULT" | head -1)

    if [[ "$FIRST_LINE" == ERROR:* ]]; then
        err "${FIRST_LINE#ERROR:}"
    fi

    IB_ID="${FIRST_LINE#FOUND:}"
    IB_JSON=$(echo "$RESULT" | tail -n +2)

    UPDATE_RESP=$(api POST "/panel/api/inbounds/update/${IB_ID}" "$IB_JSON")

    if echo "$UPDATE_RESP" | grep -q '"success":true'; then
        log "Лимит устройств для ${client_email} установлен: ${max_devices}"
        info "limitIp = ${max_devices} (макс. одновременных IP/устройств)"
    else
        err "Ошибка: ${UPDATE_RESP}"
    fi

    api_cleanup
    exit 0
}

# ===================== ПАРСИНГ АРГУМЕНТОВ =====================

case "${1:-}" in
    --encrypt)  encrypt_credentials ;;
    --devices)  monitor_devices ;;
    --limit)    set_device_limit "$2" "$3" ;;
    --help|-h)
        echo "Использование:"
        echo "  bash setup-panel.sh --encrypt            Зашифровать и сохранить креды"
        echo "  bash setup-panel.sh                      Настроить панель"
        echo "  bash setup-panel.sh --devices            Мониторинг девайсов/IP/трафика"
        echo "  bash setup-panel.sh --limit <email> <N>  Ограничить устройства (N штук)"
        echo ""
        echo "Примеры:"
        echo "  bash setup-panel.sh --limit main-user 3  Макс. 3 устройства"
        echo "  bash setup-panel.sh --limit main-user 0  Без ограничений"
        exit 0
        ;;
esac

# ===================== ОСНОВНАЯ НАСТРОЙКА =====================

# VLESS+Reality параметры
VLESS_PORT=443
DEST="yandex.ru:443"
SNI="yandex.ru"
FINGERPRINT="chrome"

decrypt_credentials
api_login

# 1. Получаем настройки
log "Получаю текущие настройки..."
SETTINGS_RESP=$(api POST "/panel/setting/all")
if ! echo "$SETTINGS_RESP" | grep -q '"success":true'; then
    err "Не удалось получить настройки: ${SETTINGS_RESP}"
fi

CURRENT=$(echo "$SETTINGS_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success'):
    print(json.dumps(data['obj']))
else:
    print('{}')
" 2>/dev/null || echo "{}")

# 2. Обновляем настройки
log "Обновляю настройки..."
UPDATED_SETTINGS=$(echo "$CURRENT" | python3 -c "
import sys, json

settings = json.load(sys.stdin)

# Подписки
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
    warn "Ошибка: ${UPDATE_RESP}"
fi

# 3. Ключи X25519
log "Генерирую ключи X25519..."
KEYS_RESP=$(api GET "/panel/api/server/getNewX25519Cert")
PRIV_KEY=$(echo "$KEYS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['obj']['privateKey'])" 2>/dev/null)
PUB_KEY=$(echo "$KEYS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['obj']['publicKey'])" 2>/dev/null)
[ -z "$PRIV_KEY" ] && err "Не удалось сгенерировать ключи"

# 4. UUID
UUID_RESP=$(api GET "/panel/api/server/getNewUUID")
CLIENT_UUID=$(echo "$UUID_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['obj'])" 2>/dev/null)
[ -z "$CLIENT_UUID" ] && CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)

# 5. Short ID
SHORT_ID=$(openssl rand -hex 8)
SUB_ID=$(openssl rand -hex 8)

# 6. Создаём VLESS+Reality
log "Создаю VLESS+Reality на порту ${VLESS_PORT}..."
INBOUND_JSON=$(python3 -c "
import json
inbound = {
    'up': 0, 'down': 0, 'total': 0,
    'remark': 'VLESS-Reality-${SNI}',
    'enable': True, 'expiryTime': 0, 'listen': '',
    'port': ${VLESS_PORT}, 'protocol': 'vless',
    'settings': json.dumps({
        'clients': [{
            'id': '${CLIENT_UUID}',
            'flow': 'xtls-rprx-vision',
            'email': 'main-user',
            'limitIp': 0, 'totalGB': 0, 'expiryTime': 0,
            'enable': True, 'tgId': '',
            'subId': '${SUB_ID}', 'comment': 'Main user'
        }],
        'decryption': 'none', 'fallbacks': []
    }),
    'streamSettings': json.dumps({
        'network': 'tcp', 'security': 'reality',
        'externalProxy': [],
        'realitySettings': {
            'show': False, 'xver': 0,
            'dest': '${DEST}',
            'serverNames': ['${SNI}'],
            'privateKey': '${PRIV_KEY}',
            'minClient': '', 'maxClient': '', 'maxTimediff': 0,
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
        'metadataOnly': False, 'routeOnly': False
    }),
    'allocate': json.dumps({
        'strategy': 'always', 'refresh': 5, 'concurrency': 3
    })
}
print(json.dumps(inbound))
")

ADD_RESP=$(api POST "/panel/api/inbounds/add" "$INBOUND_JSON")
if echo "$ADD_RESP" | grep -q '"success":true'; then
    log "VLESS+Reality создан!"
else
    warn "Ошибка: ${ADD_RESP}"
    warn "Порт ${VLESS_PORT} может быть занят."
fi

# 7. Итог
SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me || curl -s4 --connect-timeout 5 api.ipify.org || echo "UNKNOWN")

echo ""
log "============================================"
log "  НАСТРОЙКА ЗАВЕРШЕНА!"
log "============================================"
echo ""
info "  Панель:     https://${SERVER_IP}:${PANEL_PORT}${PANEL_BASE}/"
echo ""
log "  VLESS+Reality:"
info "    Порт:        ${VLESS_PORT}"
info "    UUID:        ${CLIENT_UUID}"
info "    Public Key:  ${PUB_KEY}"
info "    Short ID:    ${SHORT_ID}"
info "    SNI:         ${SNI}"
info "    Fingerprint: ${FINGERPRINT}"
info "    Flow:        xtls-rprx-vision"
echo ""
log "  Подписки:"
info "    https://${SERVER_IP}:2096/sub/${SUB_ID}"
info "    https://${SERVER_IP}:2096/json/${SUB_ID}"
echo ""
warn "  Мониторинг девайсов:  bash setup-panel.sh --devices"
echo ""
log "============================================"

api_cleanup
