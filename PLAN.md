# План: Anti-Detection + Скорость + Цепочки

## Проблема: Connection Patterns (ВЫСОКИЙ РИСК)

DPI видит:
- Один IP, много долгоживущих TCP-соединений (5+ минут) — не похоже на браузер
- Браузер открывает 2-6 параллельных HTTP/2 соединений на 30-120 секунд и закрывает
- VPN держит 1 соединение часами с постоянным потоком данных
- Нет мультиплексирования — каждый запрос = новая TCP-сессия

## Решение: 5 уровней защиты

### Уровень 1: MUX — имитация HTTP/2 браузера
**Файлы:** `sub/subJsonService.go`, `sub/default.json`

Что делаем:
- mux concurrency: 8 (уже есть) — 8 потоков в 1 TLS = как HTTP/2
- НО: нужно добавить ротацию соединений — закрывать через 60-120 сек и открывать новые
- xHTTP transport вместо TCP — трафик выглядит как реальные HTTP запросы

Конкретно:
1. `sub/default.json` — добавить mux config в proxy outbound
2. `sub/subJsonService.go` — убедиться что mux включается для VLESS+Vision (сейчас отключается при flow!)
3. Policy `connIdle: 60` вместо 120-300 — короче сессии = больше похоже на браузер

### Уровень 2: Fragment + Noise с реалистичными распределениями
**Файлы:** `sub/default.json`, `web/service/config.json`

Что делаем:
- Fragment length: `30-300` вместо `50-100` (шире = менее предсказуемо)
- Noise packet: `50-1300` вместо `10-30` (имитация реальных TLS records, 1300≈MTU)
- Noise delay: `5-50` вместо `10-16` (шире диапазон — сложнее ML)
- На сервере: noise `50-1400` (полный MSS range)

### Уровень 3: WARP Chain по умолчанию
**Файлы:** `web/service/config.json`, `deploy.sh`

Что делаем:
- Добавить WireGuard (WARP) outbound в серверный шаблон
- Routing: весь не-RU трафик → WARP → интернет
- Сервер перестаёт быть конечной точкой — DPI видит только WG трафик к Cloudflare
- deploy.sh: автоматическая регистрация WARP при установке

### Уровень 4: xHTTP transport (SplitHTTP) как альтернатива TCP
**Файлы:** `sub/subService.go`, панель UI

xHTTP = трафик выглядит как обычные HTTP POST/GET запросы
- Каждый chunk данных = отдельный HTTP запрос
- xmux: maxConcurrency 16-32, hMaxReusableSecs 1800-3000
- Padding с obfuscation
- Уже поддерживается в коде! Нужно только сделать рекомендуемым

### Уровень 5: Ротация соединений и connection reuse patterns
**Файлы:** `sub/default.json`, `web/service/xray.go`

Что делаем:
- Policy connIdle: 60 (закрывать idle через 60 сек как браузер)
- tcpKeepAliveIdle: 30 (вместо 100 — браузеры шлют keepalive чаще)
- Добавить connection lifetime limit через policy

## Порядок реализации

### Фаза 1: Быстрые wins (default.json + config.json)
1. [x] Fragment/noise расширить диапазоны
2. [ ] Mux добавить в default.json для proxy outbound
3. [ ] Policy connIdle уменьшить до 60
4. [ ] Noise на сервере расширить до 50-1400

### Фаза 2: WARP Chain
5. [ ] WARP outbound в config.json шаблон
6. [ ] Routing rule: не-RU → warp outbound
7. [ ] deploy.sh: автоматическая регистрация WARP
8. [ ] x-ui.sh: пункт меню "Setup WARP Chain"

### Фаза 3: Рекомендация xHTTP
9. [ ] В гайде Reality рекомендовать xHTTP вместо TCP
10. [ ] xHTTP defaults оптимизировать (xmux параметры)
11. [ ] Subscription links с xHTTP параметрами

### Фаза 4: Финальный hardening
12. [ ] Ротация uTLS fingerprint между соединениями (subService.go)
13. [ ] SpiderX path — привязка к dest (microsoft paths для microsoft dest)
14. [ ] Testseed wider ranges уже сделано ✓

## Оптимальная цепочка (итог)

```
Клиент (V2rayN/Streisand)
  │
  ├─ MUX: 8 потоков в 1 TLS (как HTTP/2 браузер)
  ├─ Fragment: TLS hello → 30-300 байт (ломает DPI сигнатуры)
  ├─ Noise: 50-1300 байт (имитация реальных TLS records)
  ├─ uTLS: chrome (ротация)
  │
  ▼
[VLESS + Reality + Vision] ──── порт 443
  │   dest: www.microsoft.com
  │   SNI: www.microsoft.com
  │   SpiderX: /en-us/windows/... (реалистичные MS пути)
  │   connIdle: 60s (как браузер)
  │
  ▼
[WARP outbound] ──── WireGuard → Cloudflare CDN
  │   IP сервера скрыт от назначения
  │   Трафик = обычный CDN
  │
  ▼
Интернет (google.com, youtube.com, etc.)

Российские сайты → Direct (split tunnel, без VPN)
```

## Что видит DPI на каждом уровне

| DPI видит | Что это на самом деле | Вердикт DPI |
|---|---|---|
| TLS 1.3 к www.microsoft.com:443 | VLESS+Reality | "Легитимный Microsoft трафик" |
| Chrome TLS fingerprint | uTLS имитация | "Обычный браузер" |
| 2-8 параллельных потоков | MUX внутри 1 TLS | "HTTP/2 мультиплексирование" |
| Соединения живут 60 сек | connIdle=60 | "Обычный браузинг" |
| Фрагменты 30-300 байт | Fragment | "MTU issues / packet loss" |
| Нет DNS запросов в plaintext | DoH через 1.1.1.1 | "Современный браузер" |
| RU сайты идут напрямую | Split tunnel | "Пользователь в РФ, всё ок" |
