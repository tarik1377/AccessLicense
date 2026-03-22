#!/bin/bash

#=================================================================
# AccessLicense Multi-Node Manager
# Управление несколькими VPN-нодами с локальной машины через SSH
#
# Конфиг нод: ~/.accesslicense/nodes.conf
# Формат: name|host|port|user|domain
#
# Использование:
#   multi-node.sh list
#   multi-node.sh deploy node-01
#   multi-node.sh deploy-all
#   multi-node.sh status
#   multi-node.sh add-user user@mail.com node-01
#   multi-node.sh add-user-all user@mail.com
#   multi-node.sh gen-sub user@mail.com
#   multi-node.sh health
#   multi-node.sh backup
#   multi-node.sh update-all
#=================================================================

set -euo pipefail

# ===================== ЦВЕТА И ЛОГИРОВАНИЕ =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
errnx(){ echo -e "${RED}[x]${NC} $1"; }

# ===================== КОНФИГУРАЦИЯ =====================
NODES_DIR="$HOME/.accesslicense"
NODES_CONF="$NODES_DIR/nodes.conf"
BACKUP_DIR="$NODES_DIR/backups"
GITHUB_REPO="tarik1377/AccessLicense"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# ===================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====================

ensure_config() {
    if [[ ! -f "$NODES_CONF" ]]; then
        mkdir -p "$NODES_DIR"
        cat > "$NODES_CONF" << 'EOF'
# AccessLicense Multi-Node Config
# Формат: name|host|port|user|domain
# Пример:
# node-01|195.168.1.1|22|root|tech-blog.ru
# node-02|195.168.1.2|22|root|recipes-app.ru
# node-03|195.168.1.3|22|root|photo-port.ru
EOF
        warn "Создан конфиг: $NODES_CONF"
        warn "Добавь ноды в конфиг и запусти снова."
        exit 0
    fi
}

# Парсинг одной строки ноды — устанавливает переменные NODE_*
parse_node_line() {
    local line="$1"
    NODE_NAME=$(echo "$line" | cut -d'|' -f1)
    NODE_HOST=$(echo "$line" | cut -d'|' -f2)
    NODE_PORT=$(echo "$line" | cut -d'|' -f3)
    NODE_USER=$(echo "$line" | cut -d'|' -f4)
    NODE_DOMAIN=$(echo "$line" | cut -d'|' -f5)
}

# Получить строку ноды по имени
get_node() {
    local name="$1"
    local line
    line=$(grep -v '^#' "$NODES_CONF" | grep -v '^\s*$' | grep "^${name}|" | head -1)
    if [[ -z "$line" ]]; then
        err "Нода '${name}' не найдена в $NODES_CONF"
    fi
    echo "$line"
}

# Получить все ноды (массив строк)
get_all_nodes() {
    grep -v '^#' "$NODES_CONF" | grep -v '^\s*$' || true
}

# Количество нод
count_nodes() {
    get_all_nodes | wc -l | tr -d ' '
}

# SSH-команда на ноду
run_ssh() {
    local host="$1" port="$2" user="$3"
    shift 3
    ssh $SSH_OPTS -p "$port" "${user}@${host}" "$@"
}

# SSH с parse_node_line уже вызванным
node_ssh() {
    run_ssh "$NODE_HOST" "$NODE_PORT" "$NODE_USER" "$@"
}

# ===================== КОМАНДА: list =====================
cmd_list() {
    ensure_config
    local total
    total=$(count_nodes)

    echo ""
    log "============================================"
    log "  AccessLicense Nodes (${total} шт.)"
    log "============================================"
    echo ""
    printf "  ${BOLD}%-12s %-18s %-6s %-8s %-20s${NC}\n" "NAME" "HOST" "PORT" "USER" "DOMAIN"
    printf "  %-12s %-18s %-6s %-8s %-20s\n" "────────────" "──────────────────" "──────" "────────" "────────────────────"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_node_line "$line"
        printf "  %-12s %-18s %-6s %-8s %-20s\n" "$NODE_NAME" "$NODE_HOST" "$NODE_PORT" "$NODE_USER" "$NODE_DOMAIN"
    done <<< "$(get_all_nodes)"
    echo ""
}

# ===================== КОМАНДА: deploy =====================
cmd_deploy() {
    local name="$1"
    local line
    line=$(get_node "$name")
    parse_node_line "$line"

    log "Деплою AccessLicense на ${BOLD}${NODE_NAME}${NC} (${NODE_HOST})..."

    # Проверяем SSH-доступ
    if ! node_ssh "echo ok" &>/dev/null; then
        err "Не могу подключиться к ${NODE_NAME} (${NODE_USER}@${NODE_HOST}:${NODE_PORT})"
    fi
    log "SSH-соединение: OK"

    # Запускаем deploy.sh на удалённом сервере
    local deploy_cmd="bash <(curl -Ls 'https://raw.githubusercontent.com/${GITHUB_REPO}/main/deploy.sh') --domain ${NODE_DOMAIN} --node-name ${NODE_NAME}"
    log "Запускаю deploy.sh на ${NODE_NAME}..."
    node_ssh "$deploy_cmd"

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log "Деплой на ${BOLD}${NODE_NAME}${NC} завершён успешно"
    else
        errnx "Деплой на ${NODE_NAME} завершился с ошибкой (код: ${exit_code})"
    fi
}

cmd_deploy_all() {
    local total
    total=$(count_nodes)
    log "Деплою AccessLicense на все ${total} нод(ы)..."
    echo ""

    local ok=0 fail=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_node_line "$line"
        log "━━━ ${BOLD}${NODE_NAME}${NC} ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if cmd_deploy_single_quiet "$NODE_NAME" "$line"; then
            ((ok++))
        else
            ((fail++))
        fi
        echo ""
    done <<< "$(get_all_nodes)"

    log "============================================"
    log "  Результат: ${GREEN}${ok} OK${NC}, ${RED}${fail} FAIL${NC}"
    log "============================================"
}

# deploy без exit при ошибке
cmd_deploy_single_quiet() {
    local name="$1" line="$2"
    parse_node_line "$line"

    if ! node_ssh "echo ok" &>/dev/null; then
        errnx "Не могу подключиться к ${NODE_NAME} (${NODE_USER}@${NODE_HOST}:${NODE_PORT})"
        return 1
    fi
    log "SSH: OK"

    local deploy_cmd="bash <(curl -Ls 'https://raw.githubusercontent.com/${GITHUB_REPO}/main/deploy.sh') --domain ${NODE_DOMAIN} --node-name ${NODE_NAME}"
    if node_ssh "$deploy_cmd"; then
        log "${NODE_NAME}: деплой OK"
        return 0
    else
        errnx "${NODE_NAME}: деплой FAIL"
        return 1
    fi
}

# ===================== КОМАНДА: status =====================
cmd_status() {
    ensure_config
    echo ""
    log "============================================"
    log "  Статус всех нод"
    log "============================================"
    echo ""
    printf "  ${BOLD}%-12s %-18s %-10s %-10s %-10s${NC}\n" "NAME" "HOST" "SSH" "X-UI" "TLS"
    printf "  %-12s %-18s %-10s %-10s %-10s\n" "────────────" "──────────────────" "──────────" "──────────" "──────────"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_node_line "$line"

        local ssh_ok="--" xui_ok="--" tls_ok="--"

        # Проверка SSH
        if node_ssh "echo ok" &>/dev/null; then
            ssh_ok="${GREEN}OK${NC}"

            # Проверка x-ui
            if node_ssh "systemctl is-active --quiet x-ui" &>/dev/null; then
                xui_ok="${GREEN}running${NC}"
            else
                xui_ok="${RED}down${NC}"
            fi
        else
            ssh_ok="${RED}FAIL${NC}"
        fi

        # Проверка TLS (через curl к домену)
        if [[ -n "$NODE_DOMAIN" ]]; then
            if curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "https://${NODE_DOMAIN}" 2>/dev/null | grep -qE '^(200|301|302|403)$'; then
                tls_ok="${GREEN}OK${NC}"
            else
                tls_ok="${RED}FAIL${NC}"
            fi
        else
            tls_ok="${DIM}n/a${NC}"
        fi

        printf "  %-12s %-18s %-22b %-22b %-22b\n" "$NODE_NAME" "$NODE_HOST" "$ssh_ok" "$xui_ok" "$tls_ok"
    done <<< "$(get_all_nodes)"
    echo ""
}

# ===================== КОМАНДА: add-user =====================
cmd_add_user() {
    local email="$1"
    local name="$2"
    local line
    line=$(get_node "$name")
    parse_node_line "$line"

    local uuid
    uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")

    log "Добавляю пользователя ${BOLD}${email}${NC} на ${BOLD}${NODE_NAME}${NC}..."
    info "UUID: ${uuid}"

    # Добавляем клиента через x-ui API на сервере (через sqlite3)
    local add_cmd="
        DB_PATH=\$(find /etc/x-ui -name '*.db' -type f 2>/dev/null | head -1);
        if [ -z \"\$DB_PATH\" ]; then echo 'DB_NOT_FOUND'; exit 1; fi;
        INBOUND_ID=\$(sqlite3 \"\$DB_PATH\" \"SELECT id FROM inbounds WHERE protocol='vless' LIMIT 1;\");
        if [ -z \"\$INBOUND_ID\" ]; then echo 'NO_VLESS_INBOUND'; exit 1; fi;
        SETTINGS=\$(sqlite3 \"\$DB_PATH\" \"SELECT settings FROM inbounds WHERE id=\$INBOUND_ID;\");
        NEW_CLIENT='{\"id\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"${email}\",\"limitIp\":2,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"${email}\"}';
        UPDATED=\$(echo \"\$SETTINGS\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
new_client = json.loads('''\$NEW_CLIENT''')
data['clients'].append(new_client)
print(json.dumps(data))
\");
        sqlite3 \"\$DB_PATH\" \"UPDATE inbounds SET settings='\$UPDATED' WHERE id=\$INBOUND_ID;\";
        systemctl restart x-ui;
        echo 'USER_ADDED';
    "

    local result
    result=$(node_ssh "$add_cmd" 2>&1)

    if echo "$result" | grep -q "USER_ADDED"; then
        log "Пользователь ${email} добавлен на ${NODE_NAME}"
        info "UUID: ${uuid}"
        info "SubID: ${email}"
    elif echo "$result" | grep -q "NO_VLESS_INBOUND"; then
        errnx "На ${NODE_NAME} нет VLESS inbound. Сначала создай его в панели."
    elif echo "$result" | grep -q "DB_NOT_FOUND"; then
        errnx "БД x-ui не найдена на ${NODE_NAME}."
    else
        errnx "Ошибка при добавлении пользователя на ${NODE_NAME}: ${result}"
    fi

    echo "$uuid"
}

# ===================== КОМАНДА: add-user-all =====================
cmd_add_user_all() {
    local email="$1"

    # Единый UUID для всех нод
    local uuid
    uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")

    log "Добавляю пользователя ${BOLD}${email}${NC} на все ноды..."
    info "Единый UUID: ${uuid}"
    echo ""

    local ok=0 fail=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_node_line "$line"

        local add_cmd="
            DB_PATH=\$(find /etc/x-ui -name '*.db' -type f 2>/dev/null | head -1);
            if [ -z \"\$DB_PATH\" ]; then echo 'DB_NOT_FOUND'; exit 1; fi;
            INBOUND_ID=\$(sqlite3 \"\$DB_PATH\" \"SELECT id FROM inbounds WHERE protocol='vless' LIMIT 1;\");
            if [ -z \"\$INBOUND_ID\" ]; then echo 'NO_VLESS_INBOUND'; exit 1; fi;
            SETTINGS=\$(sqlite3 \"\$DB_PATH\" \"SELECT settings FROM inbounds WHERE id=\$INBOUND_ID;\");
            NEW_CLIENT='{\"id\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"${email}\",\"limitIp\":2,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"${email}\"}';
            UPDATED=\$(echo \"\$SETTINGS\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
new_client = json.loads('''\$NEW_CLIENT''')
data['clients'].append(new_client)
print(json.dumps(data))
\");
            sqlite3 \"\$DB_PATH\" \"UPDATE inbounds SET settings='\$UPDATED' WHERE id=\$INBOUND_ID;\";
            systemctl restart x-ui;
            echo 'USER_ADDED';
        "

        local result
        result=$(node_ssh "$add_cmd" 2>&1) || true

        if echo "$result" | grep -q "USER_ADDED"; then
            log "  ${NODE_NAME}: ${GREEN}OK${NC}"
            ((ok++))
        else
            errnx "  ${NODE_NAME}: FAIL — ${result}"
            ((fail++))
        fi
    done <<< "$(get_all_nodes)"

    echo ""
    log "============================================"
    log "  Результат: ${GREEN}${ok} OK${NC}, ${RED}${fail} FAIL${NC}"
    log "  UUID: ${uuid}"
    log "============================================"
}

# ===================== КОМАНДА: gen-sub =====================
cmd_gen_sub() {
    local email="$1"

    log "Генерирую подписку для ${BOLD}${email}${NC}..."
    echo ""

    local links=""
    local node_count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_node_line "$line"

        # Получаем UUID и параметры inbound с ноды
        local query_cmd="
            DB_PATH=\$(find /etc/x-ui -name '*.db' -type f 2>/dev/null | head -1);
            if [ -z \"\$DB_PATH\" ]; then echo 'DB_NOT_FOUND'; exit 1; fi;
            INBOUND_ID=\$(sqlite3 \"\$DB_PATH\" \"SELECT id FROM inbounds WHERE protocol='vless' LIMIT 1;\");
            if [ -z \"\$INBOUND_ID\" ]; then echo 'NO_VLESS_INBOUND'; exit 1; fi;
            SETTINGS=\$(sqlite3 \"\$DB_PATH\" \"SELECT settings FROM inbounds WHERE id=\$INBOUND_ID;\");
            STREAM=\$(sqlite3 \"\$DB_PATH\" \"SELECT stream_settings FROM inbounds WHERE id=\$INBOUND_ID;\");
            PORT=\$(sqlite3 \"\$DB_PATH\" \"SELECT port FROM inbounds WHERE id=\$INBOUND_ID;\");
            UUID=\$(echo \"\$SETTINGS\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
for c in data.get('clients', []):
    if c.get('email') == '${email}' or c.get('subId') == '${email}':
        print(c['id'])
        break
\" 2>/dev/null);
            if [ -z \"\$UUID\" ]; then echo 'USER_NOT_FOUND'; exit 1; fi;
            PBK=\$(echo \"\$STREAM\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
rs = data.get('realitySettings', {})
print(rs.get('settings', {}).get('publicKey', ''))
\" 2>/dev/null);
            FP=\$(echo \"\$STREAM\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
rs = data.get('realitySettings', {})
print(rs.get('settings', {}).get('fingerprint', 'chrome'))
\" 2>/dev/null);
            SNI=\$(echo \"\$STREAM\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
rs = data.get('realitySettings', {})
sn = rs.get('serverNames', [])
print(sn[0] if sn else 'www.microsoft.com')
\" 2>/dev/null);
            SID=\$(echo \"\$STREAM\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
rs = data.get('realitySettings', {})
sids = rs.get('shortIds', [])
print(sids[0] if sids else '')
\" 2>/dev/null);
            echo \"UUID=\$UUID|PORT=\$PORT|PBK=\$PBK|FP=\$FP|SNI=\$SNI|SID=\$SID\";
        "

        local result
        result=$(node_ssh "$query_cmd" 2>&1) || true

        if echo "$result" | grep -q "^UUID="; then
            local uuid port pbk fp sni sid
            uuid=$(echo "$result" | grep "^UUID=" | sed 's/.*UUID=\([^|]*\).*/\1/')
            port=$(echo "$result" | grep "^UUID=" | sed 's/.*PORT=\([^|]*\).*/\1/')
            pbk=$(echo "$result" | grep "^UUID=" | sed 's/.*PBK=\([^|]*\).*/\1/')
            fp=$(echo "$result" | grep "^UUID=" | sed 's/.*FP=\([^|]*\).*/\1/')
            sni=$(echo "$result" | grep "^UUID=" | sed 's/.*SNI=\([^|]*\).*/\1/')
            sid=$(echo "$result" | grep "^UUID=" | sed 's/.*SID=\([^|]*\).*/\1/')

            local domain_or_host="${NODE_DOMAIN:-$NODE_HOST}"
            local vless_link="vless://${uuid}@${domain_or_host}:${port}?type=tcp&security=reality&pbk=${pbk}&fp=${fp}&sni=${sni}&sid=${sid}&flow=xtls-rprx-vision#${NODE_NAME}"

            if [[ -n "$links" ]]; then
                links="${links}\n${vless_link}"
            else
                links="${vless_link}"
            fi
            ((node_count++))
            log "  ${NODE_NAME}: ${GREEN}OK${NC}"
        elif echo "$result" | grep -q "USER_NOT_FOUND"; then
            warn "  ${NODE_NAME}: пользователь ${email} не найден"
        else
            errnx "  ${NODE_NAME}: ошибка — ${result}"
        fi
    done <<< "$(get_all_nodes)"

    if [[ $node_count -eq 0 ]]; then
        err "Ни одна нода не вернула данные для ${email}"
    fi

    echo ""
    log "━━━ VLESS-ссылки (${node_count} нод) ━━━"
    echo -e "$links"
    echo ""

    # Base64-кодируем для подписки
    local sub_b64
    sub_b64=$(echo -e "$links" | base64 -w 0 2>/dev/null || echo -e "$links" | base64 | tr -d '\n')

    log "━━━ Base64-подписка ━━━"
    echo "$sub_b64"
    echo ""
    info "Эту строку можно использовать как URL подписки в клиентах (v2rayN, Hiddify, Streisand и т.д.)"
    info "Сохрани её на любой хостинг и укажи URL в клиенте."
    echo ""
}

# ===================== КОМАНДА: health =====================
cmd_health() {
    ensure_config
    echo ""
    log "============================================"
    log "  Health Check всех нод"
    log "============================================"
    echo ""
    printf "  ${BOLD}%-12s %-18s %-10s %-12s %-10s${NC}\n" "NAME" "HOST" "PING" "HTTPS" "LATENCY"
    printf "  %-12s %-18s %-10s %-12s %-10s\n" "────────────" "──────────────────" "──────────" "────────────" "──────────"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_node_line "$line"

        local ping_ok="--" https_ok="--" latency="--"

        # Ping
        if ping -c 1 -W 3 "$NODE_HOST" &>/dev/null; then
            ping_ok="${GREEN}OK${NC}"
        else
            ping_ok="${RED}FAIL${NC}"
        fi

        # HTTPS curl
        if [[ -n "$NODE_DOMAIN" ]]; then
            local curl_time
            curl_time=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{time_total}' "https://${NODE_DOMAIN}" 2>/dev/null || echo "0")
            if (( $(echo "$curl_time > 0" | bc -l 2>/dev/null || echo 0) )); then
                https_ok="${GREEN}OK${NC}"
                latency="${curl_time}s"
            else
                https_ok="${RED}FAIL${NC}"
            fi
        else
            https_ok="${DIM}n/a${NC}"
        fi

        printf "  %-12s %-18s %-22b %-24b %-10s\n" "$NODE_NAME" "$NODE_HOST" "$ping_ok" "$https_ok" "$latency"
    done <<< "$(get_all_nodes)"
    echo ""
}

# ===================== КОМАНДА: backup =====================
cmd_backup() {
    ensure_config
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/${timestamp}"
    mkdir -p "$backup_path"

    log "Бэкап БД со всех нод → ${backup_path}"
    echo ""

    local ok=0 fail=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_node_line "$line"

        local remote_db_cmd="find /etc/x-ui -name '*.db' -type f 2>/dev/null | head -1"
        local remote_db
        remote_db=$(node_ssh "$remote_db_cmd" 2>/dev/null) || true

        if [[ -z "$remote_db" ]]; then
            errnx "  ${NODE_NAME}: БД не найдена"
            ((fail++))
            continue
        fi

        local local_file="${backup_path}/${NODE_NAME}_x-ui.db"
        if scp $SSH_OPTS -P "$NODE_PORT" "${NODE_USER}@${NODE_HOST}:${remote_db}" "$local_file" &>/dev/null; then
            local size
            size=$(du -h "$local_file" 2>/dev/null | cut -f1)
            log "  ${NODE_NAME}: ${GREEN}OK${NC} (${size})"
            ((ok++))
        else
            errnx "  ${NODE_NAME}: FAIL (scp error)"
            ((fail++))
        fi
    done <<< "$(get_all_nodes)"

    echo ""
    log "============================================"
    log "  Бэкап: ${GREEN}${ok} OK${NC}, ${RED}${fail} FAIL${NC}"
    log "  Путь: ${backup_path}"
    log "============================================"
}

# ===================== КОМАНДА: update-all =====================
cmd_update_all() {
    ensure_config
    log "Обновляю AccessLicense на всех нодах..."
    echo ""

    local ok=0 fail=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        parse_node_line "$line"

        log "━━━ ${BOLD}${NODE_NAME}${NC} ━━━"

        if ! node_ssh "echo ok" &>/dev/null; then
            errnx "  ${NODE_NAME}: SSH FAIL"
            ((fail++))
            continue
        fi

        local update_cmd="bash <(curl -Ls 'https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh') && systemctl restart x-ui"
        if node_ssh "$update_cmd" 2>&1; then
            log "  ${NODE_NAME}: ${GREEN}OK${NC}"
            ((ok++))
        else
            errnx "  ${NODE_NAME}: FAIL"
            ((fail++))
        fi
        echo ""
    done <<< "$(get_all_nodes)"

    log "============================================"
    log "  Обновление: ${GREEN}${ok} OK${NC}, ${RED}${fail} FAIL${NC}"
    log "============================================"
}

# ===================== USAGE =====================
usage() {
    echo ""
    echo -e "${BOLD}AccessLicense Multi-Node Manager${NC}"
    echo ""
    echo -e "  ${CYAN}Использование:${NC}"
    echo "    $0 <command> [args]"
    echo ""
    echo -e "  ${CYAN}Команды:${NC}"
    echo "    list                      Показать все ноды"
    echo "    deploy <node-name>        Установить AccessLicense на ноду"
    echo "    deploy-all                Установить на ВСЕ ноды"
    echo "    status                    Статус всех нод (SSH, x-ui, TLS)"
    echo "    add-user <email> <node>   Добавить юзера на ноду"
    echo "    add-user-all <email>      Добавить юзера на ВСЕ ноды (один UUID)"
    echo "    gen-sub <email>           Сгенерировать подписку (все серверы)"
    echo "    health                    Health check (ping + HTTPS)"
    echo "    backup                    Бэкап БД со всех нод"
    echo "    update-all                Обновить AccessLicense на всех нодах"
    echo ""
    echo -e "  ${CYAN}Конфиг:${NC} ${NODES_CONF}"
    echo -e "  ${CYAN}Формат:${NC} name|host|port|user|domain"
    echo ""
}

# ===================== MAIN =====================
main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true

    case "$cmd" in
        list)
            cmd_list
            ;;
        deploy)
            [[ -z "${1:-}" ]] && err "Использование: $0 deploy <node-name>"
            ensure_config
            cmd_deploy "$1"
            ;;
        deploy-all)
            ensure_config
            cmd_deploy_all
            ;;
        status)
            cmd_status
            ;;
        add-user)
            [[ -z "${1:-}" || -z "${2:-}" ]] && err "Использование: $0 add-user <email> <node-name>"
            ensure_config
            cmd_add_user "$1" "$2"
            ;;
        add-user-all)
            [[ -z "${1:-}" ]] && err "Использование: $0 add-user-all <email>"
            ensure_config
            cmd_add_user_all "$1"
            ;;
        gen-sub)
            [[ -z "${1:-}" ]] && err "Использование: $0 gen-sub <email>"
            ensure_config
            cmd_gen_sub "$1"
            ;;
        health)
            cmd_health
            ;;
        backup)
            cmd_backup
            ;;
        update-all)
            cmd_update_all
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            usage
            [[ -n "$cmd" ]] && err "Неизвестная команда: ${cmd}"
            ;;
    esac
}

main "$@"
