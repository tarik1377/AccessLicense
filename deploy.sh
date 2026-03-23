#!/bin/bash

#=================================================================
# AccessLicense Deploy — полная автоматическая установка
# Одна команда, один пароль — всё настроится само:
#   bash deploy.sh
#   bash deploy.sh --domain tech-blog.ru
#
# Креды зашифрованы AES-256-CBC. Вводишь мастер-пароль → готово.
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

# ===================== ПАРСИНГ АРГУМЕНТОВ =====================
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)     CUSTOM_DOMAIN="$2"; shift 2 ;;
        --node-name)  CUSTOM_NODE_NAME="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ===================== МАСТЕР-ПАРОЛЬ → РАСШИФРОВКА =====================
# Все креды зашифрованы AES-256-CBC + PBKDF2 (100k итераций)
# В гите лежит только зашифрованный blob — plaintext нигде не хранится
_ENCRYPTED_CREDS="U2FsdGVkX19TtWfu7yLluyWHeNr3txR3iPhCmMIqGoEjyoEO1ZVvpYvDn/baglKzBku9OenS0aL4p1oYjaplfkPb/44sLasAHdkzVK7PM9cOHS1Q+PazGPAlf2ZCJj3V2/L6ZEW5KElVouL0jX2O8aqNRTiS1JbQ1LQUD6N0MvIq938L+t5iLfqkJeDo4FXazI7t6JwqFOadxg8wmFzcKLGK1lpfSktlWgB6yaVSHRTBe/bw2jvYSgZ7lOgzVOEuRnh5KKVcBFU/ZU/yyNg1ubSJ1Tn+W40EYzo2aTgy/9nzeCS7f71vpPfNAdQmPICu"

echo ""
log "AccessLicense Deploy"
echo ""
read -rsp "  Мастер-пароль: " MASTER_PASS
echo ""

_DECRYPTED=$(echo "$_ENCRYPTED_CREDS" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
    -d -salt -pass "pass:${MASTER_PASS}" -base64 -A 2>/dev/null) \
    || err "Неверный мастер-пароль!"

# Парсим JSON с кредами
PANEL_USER=$(echo "$_DECRYPTED" | python3 -c "import sys,json; print(json.load(sys.stdin)['user'])")
PANEL_PASS=$(echo "$_DECRYPTED" | python3 -c "import sys,json; print(json.load(sys.stdin)['pass'])")
PANEL_PORT=$(echo "$_DECRYPTED" | python3 -c "import sys,json; print(json.load(sys.stdin)['panel_port'])")
PANEL_PATH=$(echo "$_DECRYPTED" | python3 -c "import sys,json; print(json.load(sys.stdin)['panel_path'])")
SUB_PORT=$(echo "$_DECRYPTED" | python3 -c "import sys,json; print(json.load(sys.stdin)['sub_port'])")
SUB_PATH=$(echo "$_DECRYPTED" | python3 -c "import sys,json; print(json.load(sys.stdin)['sub_path'])")
SUB_JSON_PATH=$(echo "$_DECRYPTED" | python3 -c "import sys,json; print(json.load(sys.stdin)['sub_json_path'])")
WEB_BASE=$(echo "$_DECRYPTED" | python3 -c "import sys,json; print(json.load(sys.stdin)['web_base'])")

# Очищаем пароль из памяти
unset MASTER_PASS _DECRYPTED _ENCRYPTED_CREDS

log "Креды расшифрованы"

# ===================== КОНФИГУРАЦИЯ =====================
XUI_FOLDER="/usr/local/x-ui"
DB_PATH="/etc/x-ui/x-ui.db"
GITHUB_REPO="tarik1377/AccessLicense"
NODE_NAME=${CUSTOM_NODE_NAME:-"node-$(hostname -s)"}
DOMAIN=${CUSTOM_DOMAIN:-""}

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

# 3. Настраиваем панель через x-ui setting + БД
log "Настраиваю панель..."
systemctl stop x-ui 2>/dev/null || true
sleep 1

# Логин/пароль/порт/путь — через CLI
${XUI_FOLDER}/x-ui setting -username "${PANEL_USER}" -password "${PANEL_PASS}" -resetTwoFactor false >/dev/null 2>&1
${XUI_FOLDER}/x-ui setting -port "${PANEL_PORT}" >/dev/null 2>&1
${XUI_FOLDER}/x-ui setting -webBasePath "${WEB_BASE}" >/dev/null 2>&1
log "x-ui setting: логин/пароль/порт/путь — установлены"

# Подписки и расширенные настройки — через БД (CLI не поддерживает)
if [ ! -f "${DB_PATH}" ]; then
    FOUND_DB=$(find /etc/x-ui -name "*.db" -type f 2>/dev/null | head -1)
    [ -n "${FOUND_DB}" ] && DB_PATH="${FOUND_DB}" || err "БД не создалась!"
fi

sqlite3 "${DB_PATH}" << SQLEOF
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

-- Xray шаблон: оптимизирован для VLESS+Reality + обход белых списков
INSERT OR REPLACE INTO settings (id, key, value) VALUES
  ((SELECT id FROM settings WHERE key='xrayTemplateConfig'), 'xrayTemplateConfig', '{
  "log": {"loglevel":"warning","access":"/var/log/x-ui/access.log","error":"/var/log/x-ui/error.log"},
  "api": {"services":["HandlerService","LoggerService","StatsService"],"tag":"api"},
  "stats": {},
  "policy": {"levels":{"0":{"handshake":4,"connIdle":300,"uplinkOnly":1,"downlinkOnly":1,"statsUserUplink":true,"statsUserDownlink":true,"bufferSize":0}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true,"statsOutboundUplink":true,"statsOutboundDownlink":true}},
  "inbounds": [{"listen":"127.0.0.1","port":62789,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"},"tag":"api","sniffing":null}],
  "outbounds": [{"protocol":"freedom","settings":{"domainStrategy":"AsIs"},"tag":"direct"},{"protocol":"blackhole","settings":{},"tag":"blocked"}],
  "routing": {"domainStrategy":"AsIs","rules":[{"inboundTag":["api"],"outboundTag":"api","type":"field"},{"ip":["geoip:private"],"outboundTag":"blocked","type":"field"},{"domain":["geosite:category-ads-all"],"outboundTag":"blocked","type":"field"}]}
}');
SQLEOF

log "Панель настроена (x-ui setting + БД)"

# 5. Nginx — реальный сайт-прикрытие (статика, без proxy_pass)
log "Генерирую сайт-прикрытие и настраиваю nginx..."
if command -v nginx &>/dev/null; then
    mkdir -p /var/www/cover-site
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    # --- index.html: бизнес-лендинг "CloudVantage Solutions" ---
    cat > /var/www/cover-site/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="CloudVantage Solutions — enterprise cloud infrastructure, managed services, and DevOps consulting. Scalable, secure, reliable.">
    <meta name="keywords" content="cloud solutions, managed hosting, DevOps, infrastructure, cloud migration, enterprise IT">
    <meta name="author" content="CloudVantage Solutions">
    <meta name="robots" content="index, follow">
    <title>CloudVantage Solutions — Enterprise Cloud Infrastructure</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>☁</text></svg>">
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Oxygen,Ubuntu,sans-serif;color:#1a1a2e;line-height:1.6;background:#fff}
        .container{max-width:1100px;margin:0 auto;padding:0 24px}
        /* Nav */
        nav{background:#fff;border-bottom:1px solid #e8e8e8;padding:16px 0;position:sticky;top:0;z-index:100}
        nav .container{display:flex;justify-content:space-between;align-items:center}
        .logo{font-size:1.4rem;font-weight:700;color:#0f4c81;text-decoration:none}
        .logo span{color:#2d9cdb}
        nav ul{list-style:none;display:flex;gap:28px}
        nav a{text-decoration:none;color:#444;font-size:.95rem;transition:color .2s}
        nav a:hover{color:#0f4c81}
        /* Hero */
        .hero{padding:80px 0 60px;text-align:center;background:linear-gradient(135deg,#f0f7ff 0%,#e8f4f8 100%)}
        .hero h1{font-size:2.6rem;color:#0f4c81;margin-bottom:16px;font-weight:800}
        .hero p{font-size:1.15rem;color:#555;max-width:620px;margin:0 auto 32px}
        .btn{display:inline-block;padding:14px 36px;background:#0f4c81;color:#fff;text-decoration:none;border-radius:6px;font-weight:600;font-size:1rem;transition:background .2s}
        .btn:hover{background:#0d3d6b}
        .btn-outline{background:transparent;border:2px solid #0f4c81;color:#0f4c81}
        .btn-outline:hover{background:#0f4c81;color:#fff}
        /* Services */
        .services{padding:70px 0;background:#fff}
        .services h2{text-align:center;font-size:2rem;color:#0f4c81;margin-bottom:12px}
        .services .subtitle{text-align:center;color:#666;margin-bottom:48px;font-size:1.05rem}
        .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:28px}
        .card{padding:32px 28px;border:1px solid #e8e8e8;border-radius:10px;transition:box-shadow .25s}
        .card:hover{box-shadow:0 8px 30px rgba(15,76,129,.1)}
        .card .icon{font-size:2rem;margin-bottom:14px}
        .card h3{font-size:1.2rem;color:#0f4c81;margin-bottom:10px}
        .card p{color:#555;font-size:.95rem}
        /* About */
        .about{padding:70px 0;background:#f8fbff}
        .about-inner{display:grid;grid-template-columns:1fr 1fr;gap:48px;align-items:center}
        .about h2{font-size:2rem;color:#0f4c81;margin-bottom:16px}
        .about p{color:#555;margin-bottom:14px;font-size:1rem}
        .stats{display:flex;gap:36px;margin-top:24px}
        .stat-item .num{font-size:2rem;font-weight:800;color:#0f4c81}
        .stat-item .label{font-size:.85rem;color:#888}
        /* Contact */
        .contact{padding:70px 0;background:#fff}
        .contact h2{text-align:center;font-size:2rem;color:#0f4c81;margin-bottom:12px}
        .contact .subtitle{text-align:center;color:#666;margin-bottom:40px}
        .contact-grid{display:grid;grid-template-columns:1fr 1fr;gap:40px}
        .contact-info div{margin-bottom:20px}
        .contact-info h4{color:#0f4c81;margin-bottom:4px}
        .contact-info p{color:#555;font-size:.95rem}
        form input,form textarea{width:100%;padding:12px 16px;border:1px solid #ddd;border-radius:6px;font-size:.95rem;font-family:inherit;margin-bottom:14px}
        form textarea{height:120px;resize:vertical}
        form button{width:100%;padding:14px;background:#0f4c81;color:#fff;border:none;border-radius:6px;font-size:1rem;font-weight:600;cursor:pointer;transition:background .2s}
        form button:hover{background:#0d3d6b}
        /* Footer */
        footer{background:#0f4c81;color:#c8ddf0;padding:36px 0;text-align:center;font-size:.9rem}
        footer a{color:#8bbee8;text-decoration:none}
        @media(max-width:768px){
            .hero h1{font-size:1.8rem}
            .about-inner,.contact-grid{grid-template-columns:1fr}
            nav ul{gap:16px}
            .stats{flex-wrap:wrap;gap:20px}
        }
    </style>
</head>
<body>

<nav>
    <div class="container">
        <a href="/" class="logo">Cloud<span>Vantage</span></a>
        <ul>
            <li><a href="#services">Services</a></li>
            <li><a href="#about">About</a></li>
            <li><a href="#contact">Contact</a></li>
        </ul>
    </div>
</nav>

<section class="hero">
    <div class="container">
        <h1>Enterprise Cloud Infrastructure<br>Built for Scale</h1>
        <p>We help businesses migrate, optimize, and manage their cloud infrastructure with zero downtime and maximum performance.</p>
        <a href="#contact" class="btn">Get Started</a>
        <a href="#services" class="btn btn-outline" style="margin-left:12px">Our Services</a>
    </div>
</section>

<section class="services" id="services">
    <div class="container">
        <h2>Our Services</h2>
        <p class="subtitle">End-to-end cloud solutions tailored to your business needs</p>
        <div class="grid">
            <div class="card">
                <div class="icon">&#9729;</div>
                <h3>Cloud Migration</h3>
                <p>Seamless migration from on-premise to cloud with automated tooling, data integrity checks, and rollback strategies.</p>
            </div>
            <div class="card">
                <div class="icon">&#9881;</div>
                <h3>Managed Infrastructure</h3>
                <p>24/7 monitoring, patching, and incident response. We keep your systems running so you can focus on your product.</p>
            </div>
            <div class="card">
                <div class="icon">&#128274;</div>
                <h3>Security &amp; Compliance</h3>
                <p>SOC 2, ISO 27001, and GDPR-ready infrastructure. Vulnerability scanning, WAF, and encrypted data at rest.</p>
            </div>
            <div class="card">
                <div class="icon">&#128200;</div>
                <h3>DevOps Consulting</h3>
                <p>CI/CD pipelines, container orchestration, infrastructure as code. Accelerate your delivery cycles by 10x.</p>
            </div>
            <div class="card">
                <div class="icon">&#9889;</div>
                <h3>Performance Optimization</h3>
                <p>Reduce latency, optimize costs, and improve throughput. Our engineers analyze and tune every layer of your stack.</p>
            </div>
            <div class="card">
                <div class="icon">&#128218;</div>
                <h3>Disaster Recovery</h3>
                <p>Multi-region failover, automated backups, and tested recovery procedures. RPO under 5 minutes, RTO under 15.</p>
            </div>
        </div>
    </div>
</section>

<section class="about" id="about">
    <div class="container">
        <div class="about-inner">
            <div>
                <h2>Why CloudVantage?</h2>
                <p>Founded in 2019, CloudVantage Solutions has helped over 200 companies modernize their infrastructure. Our team of certified cloud architects brings deep expertise across AWS, Azure, and GCP.</p>
                <p>We believe infrastructure should be invisible — reliable, fast, and secure without constant attention. That is exactly what we deliver.</p>
                <div class="stats">
                    <div class="stat-item">
                        <div class="num">200+</div>
                        <div class="label">Clients Served</div>
                    </div>
                    <div class="stat-item">
                        <div class="num">99.97%</div>
                        <div class="label">Uptime SLA</div>
                    </div>
                    <div class="stat-item">
                        <div class="num">40+</div>
                        <div class="label">Engineers</div>
                    </div>
                </div>
            </div>
            <div style="background:#e0eef9;border-radius:12px;height:320px;display:flex;align-items:center;justify-content:center;color:#0f4c81;font-size:1.1rem;font-weight:600">
                Trusted by Fortune 500
            </div>
        </div>
    </div>
</section>

<section class="contact" id="contact">
    <div class="container">
        <h2>Get in Touch</h2>
        <p class="subtitle">Ready to transform your infrastructure? Let us know how we can help.</p>
        <div class="contact-grid">
            <div class="contact-info">
                <div>
                    <h4>Email</h4>
                    <p>hello@cloudvantage.io</p>
                </div>
                <div>
                    <h4>Phone</h4>
                    <p>+1 (415) 555-0192</p>
                </div>
                <div>
                    <h4>Office</h4>
                    <p>548 Market St, Suite 300<br>San Francisco, CA 94104</p>
                </div>
                <div>
                    <h4>Hours</h4>
                    <p>Monday — Friday, 9:00 AM — 6:00 PM PST<br>24/7 emergency support for managed clients</p>
                </div>
            </div>
            <form onsubmit="return false;">
                <input type="text" placeholder="Your Name" required>
                <input type="email" placeholder="Email Address" required>
                <input type="text" placeholder="Company">
                <textarea placeholder="Tell us about your project..."></textarea>
                <button type="submit">Send Message</button>
            </form>
        </div>
    </div>
</section>

<footer>
    <div class="container">
        <p>&copy; 2024 CloudVantage Solutions, Inc. All rights reserved. | <a href="#">Privacy Policy</a> | <a href="#">Terms of Service</a></p>
    </div>
</footer>

</body>
</html>
HTMLEOF

    # --- robots.txt ---
    cat > /var/www/cover-site/robots.txt << 'ROBOTSEOF'
User-agent: *
Allow: /
Sitemap: /sitemap.xml
ROBOTSEOF

    # --- sitemap.xml ---
    cat > /var/www/cover-site/sitemap.xml << 'SITEMAPEOF'
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>http://localhost/</loc>
    <lastmod>2024-10-15</lastmod>
    <changefreq>monthly</changefreq>
    <priority>1.0</priority>
  </url>
</urlset>
SITEMAPEOF

    # --- sitemap.xml: подставляем домен если передан ---
    if [ -n "$DOMAIN" ]; then
        sed -i "s|http://localhost/|https://${DOMAIN}/|g" /var/www/cover-site/sitemap.xml
    fi

    # --- nginx config: статический сайт вместо proxy_pass ---
    NGINX_SERVER_NAME="_"
    if [ -n "$DOMAIN" ]; then
        NGINX_SERVER_NAME="$DOMAIN"
    fi

    cat > /etc/nginx/sites-available/camouflage << NGXEOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${NGINX_SERVER_NAME};

    root /var/www/cover-site;
    index index.html;

    # Реальный статический сайт
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Кэширование статики
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Блокируем сканеры и утечки конфигов
    location ~* \.(env|git|svn|htaccess|htpasswd|bak|old|orig|save|conf|cfg|ini|log|sql|db|sh|py|yml|yaml|toml|json)$ {
        return 404;
    }

    # Блокируем типичные пути сканеров
    location ~* /(\.git|\.svn|\.env|wp-admin|wp-login|phpinfo|phpmyadmin|admin|cgi-bin) {
        return 404;
    }
}
NGXEOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/camouflage /etc/nginx/sites-enabled/
    nginx -t >/dev/null 2>&1 && systemctl restart nginx
    log "Nginx: порт 80 → статический сайт-прикрытие (CloudVantage)"

    # --- Let's Encrypt: автоматический сертификат если передан домен ---
    if [ -n "$DOMAIN" ]; then
        log "Получаю SSL-сертификат Let's Encrypt для ${DOMAIN}..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y certbot python3-certbot-nginx >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y certbot python3-certbot-nginx >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y certbot python3-certbot-nginx >/dev/null 2>&1
        fi
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "admin@${DOMAIN}" \
            && log "SSL-сертификат получен для ${DOMAIN}" \
            || warn "Не удалось получить SSL-сертификат. Проверь DNS A-запись для ${DOMAIN} → ${SERVER_IP}"
    fi
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

# 9. Запускаем панель
log "Запускаю AccessLicense..."
systemctl restart x-ui
sleep 3

if ! systemctl is-active --quiet x-ui; then
    err "Панель не запустилась! Проверь: journalctl -u x-ui -n 50"
fi

# 10. Создаём VLESS+Reality автоматически через API
log "Создаю VLESS+Reality inbound автоматически..."

PANEL_BASE_URL="https://127.0.0.1:${PANEL_PORT}${WEB_BASE}"
COOKIES_FILE=$(mktemp)

# Логинимся в API
LOGIN_RESP=$(curl -sk -c "$COOKIES_FILE" -X POST "${PANEL_BASE_URL}/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${PANEL_USER}&password=${PANEL_PASS}" 2>/dev/null)

if echo "$LOGIN_RESP" | grep -q '"success":true'; then
    log "API: залогинился"

    _api() {
        local method="$1" endpoint="$2" data="$3"
        local args=(-sk -b "$COOKIES_FILE" -c "$COOKIES_FILE" -H "Content-Type: application/json")
        [ "$method" = "POST" ] && [ -n "$data" ] && args+=(-X POST -d "$data")
        [ "$method" = "POST" ] && [ -z "$data" ] && args+=(-X POST)
        curl "${args[@]}" "${PANEL_BASE_URL}${endpoint}" 2>/dev/null
    }

    # Генерируем ключи
    KEYS_RESP=$(_api GET "/panel/api/server/getNewX25519Cert")
    PRIV_KEY=$(echo "$KEYS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['obj']['privateKey'])" 2>/dev/null)
    PUB_KEY=$(echo "$KEYS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['obj']['publicKey'])" 2>/dev/null)

    UUID_RESP=$(_api GET "/panel/api/server/getNewUUID")
    CLIENT_UUID=$(echo "$UUID_RESP" | python3 -c "
import sys,json
obj=json.load(sys.stdin)['obj']
print(obj['uuid'] if isinstance(obj,dict) else obj)
" 2>/dev/null)
    [ -z "$CLIENT_UUID" ] && CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)

    SHORT_ID=$(openssl rand -hex 8)
    SUB_ID=$(openssl rand -hex 8)

    VLESS_PORT=443
    # SNI — домены из глобальных белых списков, которые НИКОГДА не блокируют
    DEST="www.microsoft.com:443"
    SNI="www.microsoft.com"
    FP="chrome"
    # Дополнительные SNI для fallback (все из белых списков любого ISP)
    SNI_LIST="www.microsoft.com,www.google.com,dl.google.com,www.apple.com,gateway.icloud.com,cdn.mozilla.net"

    # Генерируем несколько shortIds для ротации
    SHORT_ID2=$(openssl rand -hex 4)
    SHORT_ID3=$(openssl rand -hex 2)
    SHORT_ID4=$(openssl rand -hex 8)

    # Создаём inbound
    INBOUND_JSON=$(python3 -c "
import json
sni_list = '${SNI_LIST}'.split(',')
ib = {
    'up':0,'down':0,'total':0,
    'remark':'VLESS-Reality-${SNI}','enable':True,'expiryTime':0,'listen':'',
    'port':${VLESS_PORT},'protocol':'vless',
    'settings':json.dumps({
        'clients':[{'id':'${CLIENT_UUID}','flow':'xtls-rprx-vision','email':'main-user',
            'limitIp':3,'totalGB':0,'expiryTime':0,'enable':True,'tgId':'',
            'subId':'${SUB_ID}','comment':'Main'}],
        'decryption':'none','fallbacks':[]
    }),
    'streamSettings':json.dumps({
        'network':'tcp','security':'reality','externalProxy':[],
        'realitySettings':{'show':False,'xver':0,'dest':'${DEST}',
            'serverNames':sni_list,'privateKey':'${PRIV_KEY}',
            'minClient':'','maxClient':'','maxTimediff':0,
            'shortIds':['${SHORT_ID}','${SHORT_ID2}','${SHORT_ID3}','${SHORT_ID4}',''],
            'settings':{'publicKey':'${PUB_KEY}','fingerprint':'${FP}','serverName':''}},
        'tcpSettings':{'acceptProxyProtocol':False,'header':{'type':'none'}}
    }),
    'sniffing':json.dumps({'enabled':True,'destOverride':['http','tls','quic','fakedns'],'metadataOnly':False,'routeOnly':False}),
    'allocate':json.dumps({'strategy':'always','refresh':5,'concurrency':3})
}
print(json.dumps(ib))
")

    ADD_RESP=$(_api POST "/panel/api/inbounds/add" "$INBOUND_JSON")
    if echo "$ADD_RESP" | grep -q '"success":true'; then
        log "VLESS+Reality создан на порту ${VLESS_PORT}!"
    else
        warn "Ошибка создания inbound (порт ${VLESS_PORT} занят?): $(echo "$ADD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('msg',''))" 2>/dev/null)"
    fi

    rm -f "$COOKIES_FILE"
else
    warn "Не удалось залогиниться в API — VLESS+Reality нужно создать вручную через панель"
    PRIV_KEY="(не сгенерирован)"
    PUB_KEY="(не сгенерирован)"
    CLIENT_UUID="(не сгенерирован)"
    SHORT_ID="(не сгенерирован)"
    SUB_ID="(не сгенерирован)"
    VLESS_PORT=443
    SNI="www.microsoft.com"
    FP="chrome"
fi

# 11. Итог
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  PLATFORM="amd64" ;;
    aarch64) PLATFORM="arm64" ;;
    armv7l)  PLATFORM="armv7" ;;
    *)       PLATFORM="$ARCH" ;;
esac

XRAY_VER=$(${XUI_FOLDER}/bin/xray-linux-${PLATFORM} -version 2>/dev/null | head -1 | awk '{print $2}' || echo "latest")

if [ -n "$DOMAIN" ]; then
    DISPLAY_HOST="${DOMAIN}"
    PANEL_PROTO="https"
else
    DISPLAY_HOST="${SERVER_IP}"
    PANEL_PROTO="https"
fi

# Генерируем VLESS ссылку (совместима с V2RayTun, v2rayNG, Hiddify, Streisand)
VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:${VLESS_PORT}?type=tcp&security=reality&pbk=${PUB_KEY}&fp=${FP}&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#AccessLicense-${NODE_NAME}"

echo ""
log "============================================"
log "  ВСЁ ГОТОВО! ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ"
log "============================================"
echo ""
info "  Server:    ${SERVER_IP}"
info "  Node:      ${NODE_NAME}"
info "  Xray:      ${XRAY_VER}"
echo ""
log "  Панель:    ${PANEL_PROTO}://${DISPLAY_HOST}:${PANEL_PORT}${PANEL_PATH}"
log "  Логин:     ${PANEL_USER}"
log "  Пароль:    (зашифрован, расшифрован при запуске)"
echo ""
log "  VLESS+Reality (создан автоматически):"
info "    Порт:        ${VLESS_PORT}"
info "    UUID:        ${CLIENT_UUID}"
info "    Public Key:  ${PUB_KEY}"
info "    Short ID:    ${SHORT_ID}"
info "    SNI:         ${SNI}"
info "    ServerNames: www.microsoft.com, www.google.com, dl.google.com, www.apple.com"
info "    Fingerprint: ${FP}"
info "    Flow:        xtls-rprx-vision"
info "    Лимит:       3 устройства"
echo ""
log "  VLESS ссылка (скопируй в V2RayTun / v2rayNG / Hiddify):"
echo -e "  ${CYAN}${VLESS_LINK}${NC}"
echo ""
log "  Подписки:"
info "    ${PANEL_PROTO}://${DISPLAY_HOST}:${SUB_PORT}${SUB_PATH}${SUB_ID}"
info "    ${PANEL_PROTO}://${DISPLAY_HOST}:${SUB_PORT}${SUB_JSON_PATH}${SUB_ID}"
echo ""
log "═══════════════════════════════════════════════════════════"
log "  ОБХОД БЕЛЫХ СПИСКОВ — НАСТРОЙКА В КЛИЕНТЕ V2RayTun:"
log "═══════════════════════════════════════════════════════════"
info "  1. Добавь профиль по ссылке выше"
info "  2. В настройках профиля включи Fragment:"
info "       packets: tlshello"
info "       length:  10-30"
info "       interval: 10-20"
info "  3. Если не подключается — смени SNI на один из:"
info "       www.google.com / dl.google.com / www.apple.com"
info "  4. Включи MUX (Multiplex) если доступно"
info "  5. Попробуй DNS: https://1.1.1.1/dns-query"
log "═══════════════════════════════════════════════════════════"
echo ""
log "  Nginx:     порт 80 → сайт-прикрытие (CloudVantage)"
log "  Мониторинг:  x-ui          (меню управления)"
log "============================================"
