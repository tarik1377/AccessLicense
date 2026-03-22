# План: Anti-Detection + Максимальная скорость + Цепочки

## Итоги исследования (4 агента на Opus)

### Что уже есть в коде:
- Fragment + Noise (sub/default.json, config.json)
- Vision testseed рандомизация (crypto.getRandomValues + prime jitter)
- SpiderX 45+ реалистичных путей
- Reality hardening (rejectUnknownSni, maxTimediff=5000)
- WARP полный API (регистрация, конфиг, лицензия)
- xHTTP transport с xmux и padding obfuscation
- ML-DSA-65 пост-квантовая верификация
- MUX (но отключается при Vision flow!)

### Критические bottleneck-и скорости:
1. **bufferSize=4 KB** — ГЛАВНЫЙ ТОРМОЗ! Надо 0 (без лимита)
2. **connIdle рассинхрон** — сервер 120, клиент 300. Сервер убивает раньше
3. **Noise на сервере** — 2 источника ~18 KB/s на соединение. Лишний overhead
4. **Fragment interval 10-15ms** — 50-150ms latency на handshake. Надо 5-10ms
5. **Fragment length 50-100** — слишком узкий. Надо 100-200 (меньше фрагментов)

### Ключевое ограничение:
**MUX и Vision (flow) несовместимы** — Vision = zero-copy (splice), MUX = userspace processing.
Это значит: при VLESS+Reality+Vision+TCP мы НЕ можем включить MUX.
Но: xHTTP имеет встроенный xmux, который работает ВМЕСТО MUX.

### Два профиля использования:

**Профиль SPEED (TCP+Vision) — максимальная скорость:**
```
VLESS + Reality + Vision + TCP
  - Zero-copy (splice) — 0.5-2% overhead
  - Fragment на handshake — 0% потеря данных
  - Noise минимальный — 1% overhead
  - connIdle=300, keepalive=30
  - bufferSize=0 (без лимита!)
```

**Профиль STEALTH (xHTTP) — максимальная скрытность:**
```
VLESS + Reality + xHTTP (без Vision)
  - xmux: 16-32 потока (имитация HTTP/2)
  - Padding obfuscation (tokenish)
  - Каждый chunk = HTTP POST/GET
  - 5-15% overhead, но НЕОТЛИЧИМ от обычного веба
  - Для случаев когда TCP детектируют
```

---

## Фаза 1: Скоростные фиксы (0% потеря скорости)

### 1.1 bufferSize 4 → 0
**Файл:** `web/service/config.json`
- `"bufferSize": 4` → `"bufferSize": 0`
- Эффект: убирает искусственное ограничение буфера, throughput может вырасти в разы

### 1.2 connIdle синхронизация
**Файлы:** `web/service/config.json`, `sub/default.json`
- Сервер: `connIdle: 120` → `300`
- Клиент: оставить `300`
- handshake: оставить `4` (2 мало для высоко-latency)
- downlinkOnly клиент: `1` → `5` (не рвать крупные загрузки)

### 1.3 Fragment оптимизация
**Файлы:** `sub/default.json`, `web/service/config.json`
- length: `"50-100"` → `"100-200"` (крупнее = меньше фрагментов = быстрее)
- interval: `"10-15"` → `"5-10"` (быстрее handshake)
- Итого: ~22-30ms вместо 50-150ms на handshake

### 1.4 Noise оптимизация (меньше overhead)
**Файл:** `web/service/config.json`
- Убрать 2-й noise source на сервере (лишний ~18 KB/s)
- 1 source: `"packet": "50-150", "delay": "50-150"` → ~750 B/s overhead

**Файл:** `sub/default.json`
- Клиент: `"packet": "10-30"` → `"50-100"`, `"delay": "10-16"` → `"30-80"`

---

## Фаза 2: Anti-Detection (0-1% потеря скорости)

### 2.1 Vision testseed — уже усилено ✓
- crypto.getRandomValues(), диапазоны 200-2400, prime jitter

### 2.2 SpiderX — уже усилено ✓
- 45+ путей, timestamps, session IDs

### 2.3 ML-DSA-65 рекомендация
- В гайде (x-ui.sh меню 28) добавить шаг: "Get New mldsa65 Seed" при создании Reality inbound
- Пост-квантовая защита — бесплатно, 0% overhead

### 2.4 Fingerprint ротация
**Файл:** `sub/subService.go`
- Вместо фиксированного `fp=chrome` — случайный выбор из: chrome, firefox, safari, edge
- Каждая подписка получает случайный fingerprint
- 0% overhead, усложняет корреляцию

---

## Фаза 3: WARP Chain (опция в меню, не по дефолту)

### 3.1 WARP как опция
- НЕ включать по дефолту (10-20% потеря скорости + 10-50ms latency)
- Добавить в x-ui.sh меню "Setup WARP Chain" (автоматическая регистрация + конфиг)
- Routing rule: определённые домены → WARP (не весь трафик)

### 3.2 Когда включать WARP:
- IP сервера заблокирован
- Нужен "чистый" Cloudflare IP
- Обход geo-restrictions
- Максимальная анонимность (IP сервера скрыт от назначений)

---

## Фаза 4: xHTTP как запасной транспорт

### 4.1 xHTTP + Reality (без Vision)
- Для случаев когда TCP+Reality детектируется
- xmux заменяет MUX (16-32 потока)
- Padding obfuscation (tokenish, 100-1000 байт)
- 5-15% overhead, но полная скрытность

### 4.2 xHTTP defaults
```
path: /api/v1/data
mode: auto
xPaddingBytes: 100-1000
xPaddingObfsMode: true
xPaddingMethod: tokenish
sessionPlacement: cookie
sessionKey: session_id
xmux.maxConcurrency: 16-32
xmux.hMaxReusableSecs: 1800-3000
```

---

## Оптимальная цепочка (итог)

### По дефолту (SPEED — 0-1% потеря):
```
Клиент (V2rayN / Streisand)
  │
  ├─ Fragment: TLS hello → 100-200 байт, interval 5-10ms
  ├─ Noise: 50-100 байт, delay 30-80ms (минимальный)
  ├─ uTLS: случайный (chrome/firefox/safari/edge)
  │
  ▼
[VLESS + Reality + Vision + TCP] ──── порт 443
  │   dest: www.microsoft.com:443
  │   SNI: www.microsoft.com
  │   SpiderX: реалистичные MS/CDN пути
  │   ML-DSA-65: пост-квантовая верификация
  │   bufferSize: 0 (без лимита!)
  │   connIdle: 300s
  │
  ▼
Интернет

RU сайты → Direct (split tunnel)
```

### При блокировке TCP (STEALTH — 5-15% потеря):
```
Переключить транспорт TCP → xHTTP в панели
  │
  ├─ xmux: 16-32 потока (как HTTP/2)
  ├─ Padding: tokenish obfuscation
  ├─ Каждый chunk = HTTP POST
  │
  ▼
[VLESS + Reality + xHTTP] ──── порт 443
```

### При блокировке IP (+ WARP):
```
Включить WARP Chain в меню x-ui
  │
  ▼
[Сервер] → [WARP WireGuard] → [Cloudflare CDN] → Интернет
```

## Что видит DPI

| DPI видит | Реальность | Вердикт |
|---|---|---|
| TLS 1.3 к microsoft.com:443 | VLESS+Reality | "Обычный Microsoft трафик" |
| Chrome/Firefox fingerprint | uTLS (ротация) | "Обычный браузер" |
| Соединения живут 300 сек | connIdle=300 | "Нормальный браузинг" |
| Фрагменты 100-200 байт | Fragment | "MTU issues" |
| Нет plaintext DNS | DoH 1.1.1.1 | "Современный браузер" |
| RU сайты напрямую | Split tunnel | "Пользователь в РФ" |
| PQ параметры | ML-DSA-65 | "Защищённое соединение" |

## Файлы для изменения (Фаза 1)

1. `web/service/config.json` — bufferSize, connIdle, noise, fragment
2. `sub/default.json` — fragment, noise, policy, downlinkOnly
3. `sub/subService.go` — fingerprint ротация
4. `x-ui.sh` — обновить гайд (ML-DSA-65, xHTTP как backup)
