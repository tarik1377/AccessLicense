#!/bin/bash

#=================================================================
# AccessLicense Monitor — мониторинг девайсов и управление лимитами
#
# Использование:
#   bash setup-panel.sh              Мониторинг (онлайн, IP, девайсы, трафик)
#   bash setup-panel.sh --limit 5    Ограничить все клиенты до 5 устройств
#=================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# Тот же зашифрованный blob что и в deploy.sh
_ENCRYPTED_CREDS="U2FsdGVkX19TtWfu7yLluyWHeNr3txR3iPhCmMIqGoEjyoEO1ZVvpYvDn/baglKzBku9OenS0aL4p1oYjaplfkPb/44sLasAHdkzVK7PM9cOHS1Q+PazGPAlf2ZCJj3V2/L6ZEW5KElVouL0jX2O8aqNRTiS1JbQ1LQUD6N0MvIq938L+t5iLfqkJeDo4FXazI7t6JwqFOadxg8wmFzcKLGK1lpfSktlWgB6yaVSHRTBe/bw2jvYSgZ7lOgzVOEuRnh5KKVcBFU/ZU/yyNg1ubSJ1Tn+W40EYzo2aTgy/9nzeCS7f71vpPfNAdQmPICu"

echo ""
read -rsp "Мастер-пароль: " MASTER_PASS
echo ""

_D=$(echo "$_ENCRYPTED_CREDS" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
    -d -salt -pass "pass:${MASTER_PASS}" -base64 -A 2>/dev/null) \
    || err "Неверный мастер-пароль!"

PANEL_USER=$(echo "$_D" | python3 -c "import sys,json; print(json.load(sys.stdin)['user'])")
PANEL_PASS=$(echo "$_D" | python3 -c "import sys,json; print(json.load(sys.stdin)['pass'])")
PANEL_PORT=$(echo "$_D" | python3 -c "import sys,json; print(json.load(sys.stdin)['panel_port'])")
WEB_BASE=$(echo "$_D" | python3 -c "import sys,json; print(json.load(sys.stdin)['web_base'])")
unset MASTER_PASS _D _ENCRYPTED_CREDS

BASE_URL="https://127.0.0.1:${PANEL_PORT}${WEB_BASE}"
COOKIES=$(mktemp)

# Логин
LOGIN_RESP=$(curl -sk -c "$COOKIES" -X POST "${BASE_URL}/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${PANEL_USER}&password=${PANEL_PASS}" 2>/dev/null)
echo "$LOGIN_RESP" | grep -q '"success":true' || err "Ошибка логина"
log "Залогинился"

api() {
    local method="$1" endpoint="$2" data="$3"
    local args=(-sk -b "$COOKIES" -c "$COOKIES" -H "Content-Type: application/json")
    [ "$method" = "POST" ] && [ -n "$data" ] && args+=(-X POST -d "$data")
    [ "$method" = "POST" ] && [ -z "$data" ] && args+=(-X POST)
    curl "${args[@]}" "${BASE_URL}${endpoint}" 2>/dev/null
}

# ===================== ЛИМИТ УСТРОЙСТВ =====================
if [ "${1:-}" = "--limit" ]; then
    MAX_DEV="${2:-}"
    [ -z "$MAX_DEV" ] && err "Укажи число: --limit <N>"

    LIST_RESP=$(api GET "/panel/api/inbounds/list")
    echo "$LIST_RESP" | python3 -c "
import sys, json

data = json.load(sys.stdin)
if not data.get('success'):
    print('ERROR')
    sys.exit()

limit = int('${MAX_DEV}')
results = []
for ib in data['obj']:
    settings = json.loads(ib.get('settings', '{}'))
    changed = False
    for cl in settings.get('clients', []):
        if cl.get('limitIp') != limit:
            cl['limitIp'] = limit
            changed = True
    if changed:
        ib['settings'] = json.dumps(settings)
        results.append((ib['id'], ib.get('remark',''), json.dumps(ib)))

for ib_id, remark, ib_json in results:
    print(f'{ib_id}|{remark}|{ib_json}')
" 2>/dev/null | while IFS='|' read -r IB_ID REMARK IB_JSON; do
        UPDATE_RESP=$(api POST "/panel/api/inbounds/update/${IB_ID}" "$IB_JSON")
        if echo "$UPDATE_RESP" | grep -q '"success":true'; then
            log "${REMARK}: лимит → ${MAX_DEV} устройств"
        else
            warn "${REMARK}: ошибка обновления"
        fi
    done

    log "Готово! Лимит устройств: ${MAX_DEV}"
    rm -f "$COOKIES"
    exit 0
fi

# ===================== МОНИТОРИНГ =====================
echo ""
log "============================================"
log "  МОНИТОРИНГ"
log "============================================"

# Онлайн
echo ""
log "Онлайн сейчас:"
ONLINE_RESP=$(api POST "/panel/api/inbounds/onlines")
echo "$ONLINE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success') and data.get('obj'):
    for email in data['obj']:
        print(f'  * {email}')
    print(f'\n  Всего: {len(data[\"obj\"])}')
else:
    print('  (никого)')
" 2>/dev/null

# Inbound'ы + клиенты + трафик
echo ""
log "Inbound'ы и клиенты:"
LIST_RESP=$(api GET "/panel/api/inbounds/list")
EMAILS=$(echo "$LIST_RESP" | python3 -c "
import sys, json

data = json.load(sys.stdin)
if not data.get('success') or not data.get('obj'):
    sys.exit()

emails = []
for ib in data['obj']:
    remark = ib.get('remark', 'N/A')
    port = ib.get('port', '?')
    proto = ib.get('protocol', '?')
    on = 'ON' if ib.get('enable') else 'OFF'
    up = ib.get('up', 0) / (1024**3)
    down = ib.get('down', 0) / (1024**3)

    print(f'\n  === {remark} ({proto}:{port}) [{on}] ===')
    print(f'  Upload: {up:.2f} GB | Download: {down:.2f} GB')

    settings = json.loads(ib.get('settings', '{}'))
    clients = settings.get('clients', [])
    stats = {cs['email']: cs for cs in ib.get('clientStats', []) if cs.get('email')}

    for cl in clients:
        email = cl.get('email', '?')
        on_cl = 'ON' if cl.get('enable', True) else 'OFF'
        limit = cl.get('limitIp', 0)
        sub = cl.get('subId', '')
        s = stats.get(email, {})
        cu = s.get('up', 0) / (1024**3)
        cd = s.get('down', 0) / (1024**3)

        print(f'    {email} [{on_cl}]  up:{cu:.2f}GB  down:{cd:.2f}GB  devices_limit:{limit}  sub:{sub}')
        emails.append(email)

# Output emails for device check
import os
with open('/tmp/_xui_emails.txt', 'w') as f:
    f.write('\n'.join(set(emails)))
" 2>/dev/null)

# Девайсы и IP по каждому клиенту
echo ""
log "IP и девайсы:"
if [ -f /tmp/_xui_emails.txt ]; then
    while read -r EMAIL; do
        [ -z "$EMAIL" ] && continue
        info "  ${EMAIL}:"

        IPS=$(api POST "/panel/api/inbounds/clientIps/${EMAIL}")
        echo "$IPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success') and data.get('obj'):
    obj = data['obj']
    if isinstance(obj, str) and obj.strip() and obj.strip() != 'null':
        ips = [ip.strip() for ip in obj.split(',') if ip.strip()]
        for ip in ips:
            print(f'      IP: {ip}')
        print(f'      ({len(ips)} IP всего)')
    elif isinstance(obj, (list, dict)) and obj:
        items = obj if isinstance(obj, list) else list(obj.keys())
        for item in items:
            print(f'      IP: {item}')
        print(f'      ({len(items)} IP всего)')
    else:
        print('      (нет IP)')
else:
    print('      (нет IP)')
" 2>/dev/null

        DEVS=$(api POST "/panel/api/inbounds/clientDevices/${EMAIL}")
        echo "$DEVS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data.get('success') and data.get('obj'):
    d = data['obj']
    if isinstance(d, list) and d:
        for dev in d:
            print(f'      Device: {dev}')
        print(f'      ({len(d)} девайсов)')
    elif isinstance(d, dict) and d:
        for k,v in d.items():
            print(f'      Device: {k} = {v}')
    else:
        print('      (нет девайсов)')
else:
    print('      (нет девайсов)')
" 2>/dev/null
    done < /tmp/_xui_emails.txt
    rm -f /tmp/_xui_emails.txt
fi

echo ""
log "============================================"
info "  Ограничить устройства:  bash setup-panel.sh --limit 3"
log "============================================"

rm -f "$COOKIES"
