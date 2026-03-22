#!/bin/bash

#=================================================================
# AccessLicense Harden — дополнительная безопасность и anti-detection
# SSH hardening, anti-fingerprinting, firewall, DNS leak protection
# Интерактивный: спрашивает подтверждение перед каждым шагом
# Идемпотентный: можно запускать повторно без проблем
# Использование: sudo bash harden.sh
#=================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

SSHD_CONFIG="/etc/ssh/sshd_config"
SYSCTL_HARDEN="/etc/sysctl.d/98-harden-antidetect.conf"
CHANGES=()

# Проверка root
[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash harden.sh"

# ─────────────────────────────────────────────────────────
# Утилита: задать вопрос да/нет
# ─────────────────────────────────────────────────────────
confirm() {
    local prompt="$1"
    local reply
    echo ""
    echo -en "${CYAN}[?]${NC} ${prompt} [y/N]: "
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ─────────────────────────────────────────────────────────
# Утилита: безопасно задать параметр в sshd_config
# Идемпотентно: заменяет существующую строку или добавляет
# ─────────────────────────────────────────────────────────
sshd_set() {
    local key="$1"
    local value="$2"
    if grep -qE "^\s*#?\s*${key}\s+" "$SSHD_CONFIG" 2>/dev/null; then
        sed -i "s|^\s*#\?\s*${key}\s\+.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

log "============================================"
log "  AccessLicense Harden & Anti-Detection"
log "============================================"
warn "Этот скрипт изменяет конфигурацию системы."
warn "Перед каждым шагом будет запрошено подтверждение."
warn "УБЕДИСЬ, что у тебя есть SSH-ключ или консольный доступ!"

# =============================================================
# 1. SSH HARDENING
# =============================================================
if confirm "Шаг 1/4: SSH Hardening (смена порта, отключение root-пароля, MaxAuthTries 3)?"; then
    log "SSH Hardening..."

    if [ ! -f "$SSHD_CONFIG" ]; then
        err "Файл ${SSHD_CONFIG} не найден!"
    fi

    # Бэкап
    cp -n "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.harden" 2>/dev/null || true

    # 1a. Случайный порт SSH (10000-60000)
    # Если порт уже был сменён ранее — показываем текущий, не меняем
    CURRENT_SSH_PORT=$(grep -E "^\s*Port\s+" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1)
    CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"

    if [ "$CURRENT_SSH_PORT" -ge 10000 ] && [ "$CURRENT_SSH_PORT" -le 60000 ]; then
        info "SSH порт уже сменён ранее: ${CURRENT_SSH_PORT} (не меняю)"
        NEW_SSH_PORT="$CURRENT_SSH_PORT"
    else
        NEW_SSH_PORT=$(shuf -i 10000-60000 -n 1)
        sshd_set "Port" "$NEW_SSH_PORT"
        CHANGES+=("SSH порт: ${CURRENT_SSH_PORT} → ${NEW_SSH_PORT}")
        log "SSH порт: ${CURRENT_SSH_PORT} → ${NEW_SSH_PORT}"
    fi

    # 1b. Отключить root login по паролю (ключи остаются)
    sshd_set "PermitRootLogin" "prohibit-password"
    CHANGES+=("PermitRootLogin → prohibit-password")
    log "PermitRootLogin → prohibit-password (только ключи)"

    # 1c. Отключить пустые пароли
    sshd_set "PermitEmptyPasswords" "no"
    CHANGES+=("PermitEmptyPasswords → no")
    log "PermitEmptyPasswords → no"

    # 1d. MaxAuthTries 3
    sshd_set "MaxAuthTries" "3"
    CHANGES+=("MaxAuthTries → 3")
    log "MaxAuthTries → 3"

    # Валидация и перезапуск sshd
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        log "SSHD перезагружен"
    else
        warn "sshd -t обнаружил ошибку! Откатываю конфиг..."
        cp "${SSHD_CONFIG}.bak.harden" "$SSHD_CONFIG"
        err "SSH конфиг невалиден — откат выполнен. Проверь вручную."
    fi

    # Обновить UFW если используется
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${NEW_SSH_PORT}/tcp" comment "SSH harden" >/dev/null 2>&1
        info "UFW: разрешён порт ${NEW_SSH_PORT}/tcp"
        # Не удаляем 22 сразу — пусть оператор убедится что новый порт работает
        warn "Порт 22 НЕ удалён из UFW — удали вручную после проверки: ufw delete allow 22/tcp"
    fi

    echo ""
    warn "╔══════════════════════════════════════════════════╗"
    warn "║  НОВЫЙ SSH ПОРТ: ${NEW_SSH_PORT}                          ║"
    warn "║  Подключайся: ssh -p ${NEW_SSH_PORT} user@host             ║"
    warn "║  НЕ ЗАКРЫВАЙ текущую сессию до проверки!        ║"
    warn "╚══════════════════════════════════════════════════╝"
else
    info "SSH Hardening — пропущен"
fi

# =============================================================
# 2. ANTI-FINGERPRINTING
# =============================================================
if confirm "Шаг 2/4: Anti-fingerprinting (nginx headers, ICMP timestamps)?"; then
    log "Anti-fingerprinting..."

    # 2a. Nginx: server_tokens off
    if command -v nginx &>/dev/null; then
        NGINX_CONF="/etc/nginx/nginx.conf"
        if [ -f "$NGINX_CONF" ]; then
            # Бэкап
            cp -n "$NGINX_CONF" "${NGINX_CONF}.bak.harden" 2>/dev/null || true

            # server_tokens off — идемпотентно
            if grep -qE "^\s*server_tokens\s+off;" "$NGINX_CONF"; then
                info "server_tokens off уже установлен"
            else
                # Заменяем существующий server_tokens или добавляем в http блок
                if grep -qE "^\s*#?\s*server_tokens" "$NGINX_CONF"; then
                    sed -i 's|^\s*#\?\s*server_tokens.*|    server_tokens off;|' "$NGINX_CONF"
                else
                    sed -i '/http\s*{/a\    server_tokens off;' "$NGINX_CONF"
                fi
                CHANGES+=("Nginx: server_tokens off")
                log "Nginx: server_tokens off"
            fi

            # 2b. Случайный server header через more_set_headers (если модуль есть)
            if nginx -V 2>&1 | grep -q "headers-more"; then
                RANDOM_SERVER="Microsoft-IIS/10.0"
                if grep -qE "^\s*more_set_headers\s+.*[Ss]erver" "$NGINX_CONF"; then
                    info "more_set_headers Server уже установлен"
                else
                    sed -i '/http\s*{/a\    more_set_headers "Server: '"${RANDOM_SERVER}"'";' "$NGINX_CONF"
                    CHANGES+=("Nginx: Server header → ${RANDOM_SERVER}")
                    log "Nginx: Server header → ${RANDOM_SERVER}"
                fi
            else
                info "Модуль headers-more не найден — пропускаю подмену Server header"
            fi

            # Проверяем и перезагружаем
            if nginx -t 2>/dev/null; then
                systemctl reload nginx 2>/dev/null || true
                log "Nginx перезагружен"
            else
                warn "nginx -t обнаружил ошибку! Откатываю..."
                cp "${NGINX_CONF}.bak.harden" "$NGINX_CONF"
                warn "Nginx конфиг откачен. Проверь вручную."
            fi
        else
            warn "Файл ${NGINX_CONF} не найден"
        fi
    else
        info "Nginx не установлен — пропускаю"
    fi

    # 2c. Отключить ICMP timestamp reply
    if grep -qE "^\s*net\.ipv4\.icmp_echo_ignore_all" "$SYSCTL_HARDEN" 2>/dev/null; then
        info "ICMP sysctl уже настроен в ${SYSCTL_HARDEN}"
    else
        mkdir -p "$(dirname "$SYSCTL_HARDEN")"
        cat >> "$SYSCTL_HARDEN" << 'EOF'
# === Anti-fingerprinting: ICMP ===
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_timestamps = 1
EOF
        sysctl -p "$SYSCTL_HARDEN" >/dev/null 2>&1 || true
        CHANGES+=("ICMP: timestamps отключены, broadcast echo отключен")
        log "ICMP timestamps и broadcast echo отключены"
    fi
else
    info "Anti-fingerprinting — пропущен"
fi

# =============================================================
# 3. ДОПОЛНИТЕЛЬНЫЙ FIREWALL
# =============================================================
if confirm "Шаг 3/4: Дополнительный firewall (SSH rate limit, drop invalid, SYN flood)?"; then
    log "Настраиваю дополнительный firewall..."

    # 3a. UFW rate limiting на SSH
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        # Определяем текущий SSH порт
        ACTIVE_SSH_PORT=$(grep -E "^\s*Port\s+" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1)
        ACTIVE_SSH_PORT="${ACTIVE_SSH_PORT:-22}"

        # ufw limit — идемпотентно (ufw не дублирует одинаковые правила limit)
        ufw limit "${ACTIVE_SSH_PORT}/tcp" comment "SSH rate limit" >/dev/null 2>&1 || true
        CHANGES+=("UFW: rate limit на SSH порт ${ACTIVE_SSH_PORT}")
        log "UFW: rate limit на SSH порт ${ACTIVE_SSH_PORT}"
    else
        info "UFW не активен — пропускаю rate limit"
    fi

    # 3b. Drop invalid packets через iptables
    # Идемпотентно: проверяем наличие правила перед добавлением
    if command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null; then
            iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
            CHANGES+=("iptables: DROP INVALID packets")
            log "iptables: DROP INVALID packets"
        else
            info "iptables INVALID DROP уже установлен"
        fi

        # 3c. SYN flood protection
        if ! iptables -C INPUT -p tcp --syn -m limit --limit 60/s --limit-burst 20 -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -p tcp --syn -m limit --limit 60/s --limit-burst 20 -j ACCEPT
            CHANGES+=("iptables: SYN flood protection (60/s burst 20)")
            log "iptables: SYN flood protection (60/s, burst 20)"
        else
            info "iptables SYN flood protection уже установлена"
        fi

        # Сохраняем правила если iptables-persistent есть
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1 || true
            log "iptables правила сохранены (netfilter-persistent)"
        elif [ -f /etc/iptables/rules.v4 ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            log "iptables правила сохранены в /etc/iptables/rules.v4"
        else
            warn "iptables-persistent не установлен — правила будут потеряны после reboot"
            warn "Установи: apt install iptables-persistent"
        fi
    else
        warn "iptables не найден"
    fi

    # Дополнительные sysctl для защиты от SYN flood
    if ! grep -q "net.ipv4.tcp_syncookies" "$SYSCTL_HARDEN" 2>/dev/null; then
        cat >> "$SYSCTL_HARDEN" << 'EOF'

# === SYN flood protection ===
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
EOF
        sysctl -p "$SYSCTL_HARDEN" >/dev/null 2>&1 || true
        CHANGES+=("sysctl: SYN cookies + synack_retries=2")
        log "sysctl: SYN cookies включены"
    else
        info "SYN flood sysctl уже настроен"
    fi
else
    info "Дополнительный firewall — пропущен"
fi

# =============================================================
# 4. DNS LEAK PROTECTION (DoT через systemd-resolved)
# =============================================================
if confirm "Шаг 4/4: DNS leak protection (systemd-resolved с DoT на 1.1.1.1 и 8.8.8.8)?"; then
    log "Настраиваю DNS over TLS..."

    # Установить systemd-resolved если нет
    if ! command -v resolvectl &>/dev/null && ! systemctl list-unit-files | grep -q "systemd-resolved"; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq systemd-resolved >/dev/null 2>&1 || true
        fi
    fi

    RESOLVED_CONF="/etc/systemd/resolved.conf"
    if [ -f "$RESOLVED_CONF" ]; then
        # Бэкап
        cp -n "$RESOLVED_CONF" "${RESOLVED_CONF}.bak.harden" 2>/dev/null || true

        cat > "$RESOLVED_CONF" << 'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
FallbackDNS=1.0.0.1#cloudflare-dns.com 8.8.4.4#dns.google
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
CacheFromLocalhost=no
EOF

        # Активируем systemd-resolved
        systemctl enable systemd-resolved >/dev/null 2>&1 || true
        systemctl restart systemd-resolved 2>/dev/null || true

        # Привязываем resolv.conf к systemd-resolved
        if [ ! -L /etc/resolv.conf ] || [ "$(readlink -f /etc/resolv.conf)" != "/run/systemd/resolve/stub-resolv.conf" ]; then
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
        fi

        CHANGES+=("DNS: DoT через systemd-resolved (1.1.1.1 + 8.8.8.8)")
        log "DNS over TLS: 1.1.1.1 (Cloudflare) + 8.8.8.8 (Google)"

        # Проверка
        if resolvectl status 2>/dev/null | grep -qi "over-tls\|DNS-over-TLS"; then
            log "DoT активен (resolvectl подтверждает)"
        else
            info "systemd-resolved запущен, проверь: resolvectl status"
        fi
    else
        warn "${RESOLVED_CONF} не найден — systemd-resolved недоступен на этой системе"
    fi
else
    info "DNS leak protection — пропущен"
fi

# =============================================================
# ИТОГ
# =============================================================
echo ""
log "============================================"
log "  HARDENING ЗАВЕРШЁН"
log "============================================"
echo ""

if [ ${#CHANGES[@]} -eq 0 ]; then
    info "Ничего не было изменено (всё пропущено или уже применено)"
else
    log "Применённые изменения:"
    for change in "${CHANGES[@]}"; do
        echo -e "  ${GREEN}✓${NC} ${change}"
    done
fi

echo ""

# Показать текущий SSH порт для памятки
FINAL_SSH_PORT=$(grep -E "^\s*Port\s+" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1)
FINAL_SSH_PORT="${FINAL_SSH_PORT:-22}"

if [ "$FINAL_SSH_PORT" != "22" ]; then
    warn "╔══════════════════════════════════════════════════╗"
    warn "║  SSH ПОРТ: ${FINAL_SSH_PORT}                                  ║"
    warn "║  ssh -p ${FINAL_SSH_PORT} user@host                          ║"
    warn "╚══════════════════════════════════════════════════╝"
fi

echo ""
log "Рекомендации:"
info "  1. Проверь SSH доступ в НОВОЙ сессии перед закрытием текущей"
info "  2. Убедись что SSH-ключ добавлен: ssh-copy-id -p ${FINAL_SSH_PORT} user@host"
info "  3. Проверь DNS: resolvectl status"
info "  4. Проверь firewall: ufw status && iptables -L -n"
info "  5. Повторный запуск скрипта безопасен (идемпотентный)"
echo ""
log "============================================"
