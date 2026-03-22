#!/bin/bash

#=================================================================
# AccessLicense Deploy — быстрая установка из GitHub Releases
# Без Go, без сборки — скачивает готовый бинарник за секунды
# + настройка панели, nginx, firewall, sysctl, VLESS+Reality
# Использование:
#   bash deploy.sh
#   DOMAIN=tech-blog.ru PANEL_USER=admin bash deploy.sh
#   bash deploy.sh --domain tech-blog.ru --user admin --pass MyS3cret
#=================================================================

set -e

# ===================== ПАРСИНГ АРГУМЕНТОВ =====================
# Параметры можно передать через ENV или аргументы командной строки.
# Аргументы имеют приоритет над ENV, ENV — над дефолтами.
# Примеры:
#   DOMAIN=tech-blog.ru PANEL_USER=admin bash deploy.sh
#   bash deploy.sh --domain tech-blog.ru --user admin

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)     CUSTOM_DOMAIN="$2"; shift 2 ;;
        --user)       CUSTOM_USER="$2"; shift 2 ;;
        --pass)       CUSTOM_PASS="$2"; shift 2 ;;
        --panel-port) CUSTOM_PANEL_PORT="$2"; shift 2 ;;
        --sub-port)   CUSTOM_SUB_PORT="$2"; shift 2 ;;
        --node-name)  CUSTOM_NODE_NAME="$2"; shift 2 ;;
        *) shift ;;
    esac
done
# ==============================================================

# ===================== КОНФИГУРАЦИЯ =====================
# Приоритет: аргумент (--flag) > ENV переменная > дефолт
PANEL_PORT=${CUSTOM_PANEL_PORT:-${PANEL_PORT_ENV:-9443}}
SUB_PORT=${CUSTOM_SUB_PORT:-${SUB_PORT_ENV:-9444}}
PANEL_USER=${CUSTOM_USER:-${PANEL_USER_ENV:-"admin"}}
PANEL_PASS=${CUSTOM_PASS:-${PANEL_PASS_ENV:-$(openssl rand -base64 16)}}
PANEL_PATH="/secretpanel/"
SUB_PATH="/feed/"
SUB_JSON_PATH="/config/"
XUI_FOLDER="/usr/local/x-ui"
DB_PATH="/etc/x-ui/x-ui.db"
GITHUB_REPO="tarik1377/AccessLicense"
NODE_NAME=${CUSTOM_NODE_NAME:-"node-$(hostname -s)"}
DOMAIN=${CUSTOM_DOMAIN:-""}
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

    # Определяем адрес для вывода (домен или IP)
    if [ -n "$DOMAIN" ]; then
        DISPLAY_HOST="${DOMAIN}"
        PANEL_PROTO="https"
    else
        DISPLAY_HOST="${SERVER_IP}"
        PANEL_PROTO="http"
    fi

    echo ""
    log "============================================"
    log "  ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ (СОХРАНИ!)"
    log "============================================"
    echo ""
    info "  Server:    ${SERVER_IP}"
    info "  Node:      ${NODE_NAME}"
    if [ -n "$DOMAIN" ]; then
    info "  Domain:    ${DOMAIN}"
    fi
    info "  Xray:      ${XRAY_VER_ACTUAL}"
    info "  Arch:      ${PLATFORM}"
    echo ""
    log "  Панель:    ${PANEL_PROTO}://${DISPLAY_HOST}:${PANEL_PORT}${PANEL_PATH}"
    log "  Логин:     ${PANEL_USER}"
    log "  Пароль:    ${PANEL_PASS}"
    warn "  ↑ СОХРАНИ ПАРОЛЬ! Если он сгенерирован — повторно его не получить."
    echo ""
    log "  Подписки:"
    log "    Links:   ${PANEL_PROTO}://${DISPLAY_HOST}:${SUB_PORT}${SUB_PATH}<subId>"
    log "    JSON:    ${PANEL_PROTO}://${DISPLAY_HOST}:${SUB_PORT}${SUB_JSON_PATH}<subId>"
    echo ""
    log "  Nginx:     порт 80 → статический сайт-прикрытие (CloudVantage)"
    if [ -n "$DOMAIN" ]; then
    log "  SSL:       Let's Encrypt (auto-renew)"
    fi
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
