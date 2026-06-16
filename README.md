# telemt-install

Скрипт автоматической установки **[telemt](https://github.com/telemt/telemt)** — Telegram MTProxy на Rust — на чистый Ubuntu VPS.

Источники:
- [Основной гайд](https://assyoucandy.github.io/telemt-server-guide/)
- [Keepalive гайд](https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html)
- [nft SYN limiter](https://h1de0x.github.io/telemt-tune/)

---

## Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh)
```

> Требуется root. Ubuntu 20.04 / 22.04 / 24.04, архитектура x86\_64.

---

## Обновление telemt

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh) --update
```

---

## Что делает скрипт

На каждом шаге можно **подтвердить** (`y`), **пропустить** (Enter / `n`) или полностью **прервать** (`q`).

### Компоненты на выбор

#### 3 инстанса telemt

| # | Порт | SNI домен            | Маскируется под                |
|---|------|----------------------|--------------------------------|
| 1 | 443  | `www.cloudflare.com` | Обычный HTTPS / CDN            |
| 2 | 5223 | `www.apple.com`      | Apple Push Notification (APNs) |
| 3 | 8530 | `www.microsoft.com`  | Windows Update (WSUS)          |

Можно выбрать любое подмножество: `1`, `2 3`, или `all`.

#### UFW фаервол + rate-limit (xt_recent)

Открывает нужные порты, включает фаервол, опционально добавляет правила `xt_recent` в `/etc/ufw/before.rules` — ограничение 1 SYN/сек на IP per-port. Защищает от активного зондирования DPI/РКН.

#### TCP Keepalive (sysctl)

Настраивает агрессивный keepalive через `/etc/sysctl.d/99-tg-keepalive.conf`:

```
tcp_keepalive_time  = 60    ← первая проба через 60с тишины (дефолт: 7200)
tcp_keepalive_intvl = 15    ← повтор каждые 15с
tcp_keepalive_probes = 3    ← 3 без ответа → RST
```

Мёртвый коннект рвётся за ~105с вместо ~2 часов. Лечит залипание мобильных клиентов после выхода из фона. telemt выставляет `SO_KEEPALIVE` на сокеты, поэтому достаточно подкрутить sysctl — ядро делает всё само.

Включает диагностику активных соединений (показывает таймеры keepalive на живых коннектах).

#### nft inbound SYN per-client limiter

Создаёт per-client ограничение входящих SYN для каждого порта telemt через nftables. Лечит зависания при подключении у некоторых провайдеров.

Адаптировано для **non-Docker** установки (`hook input` вместо `hook forward`). Раздельные meter-ы на каждый порт, чтобы переключение между инстансами в Telegram не триггерило лимит.

Настраиваемые параметры:

| Параметр        | Дефолт      | Когда менять                              |
|-----------------|-------------|-------------------------------------------|
| `RATE`          | `1/second`  | Увеличить если клиентам не хватает burst  |
| `BURST`         | `1`         | `3` — мягче для многих клиентов           |
| `METER_TIMEOUT` | `60s`       | `30s` быстрее / `120s` дольше помнит IP   |

Создаёт постоянный скрипт `/usr/local/sbin/telemt-nft-limit.sh` и systemd-сервис `telemt-nft-limit.service` для автовосстановления после перезагрузки.

#### Тюнинг [timeouts] telemt

Опциональная секция в конфигах telemt для проблемных сетей. По умолчанию **не устанавливается** — telemt работает хорошо на дефолтах:

| Параметр           | Дефолт | Для проблемных сетей |
|--------------------|--------|----------------------|
| `tg_connect`       | 10     | 30 (нестабильный DC) |
| `client_handshake` | 15     | 120 (медленный мобайл) |
| `client_keepalive` | 60     | 90 (нестабильный NAT)  |

---

## Шаги установки

```
Шаг 0  — Выбор компонентов, SSH-порта, параметров nft/keepalive/таймаутов
Шаг 1  — Зависимости, пользователь telemt, директории
Шаг 2  — Скачивание бинарника (последний релиз GitHub)
Шаг 3  — Генерация секретов (openssl rand -hex 16)
Шаг 4  — Создание конфигов /etc/telemt/telemtN.toml
Шаг 5  — Создание systemd-сервисов
Шаг 6  — UFW: открытие портов
Шаг 7  — UFW rate-limit (xt_recent, анти-DPI)
Шаг 8  — TCP keepalive sysctl + диагностика
Шаг 9  — nft SYN limiter: скрипт + systemd-сервис
Шаг 10 — Запуск сервисов + проверка статуса
Шаг 11 — Вывод готовых tg://proxy?... ссылок
```

---

## Управление после установки

```bash
# Статус
systemctl status telemt1 telemt2 telemt3

# Логи в реальном времени
journalctl -u telemt1 -f

# Ссылки для клиентов
curl -s http://127.0.0.1:9091/v1/users | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])"
curl -s http://127.0.0.1:9092/v1/users | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])"
curl -s http://127.0.0.1:9093/v1/users | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])"

# Статистика подключений
curl -s http://127.0.0.1:9091/v1/stats/summary | python3 -m json.tool

# Рестарт
systemctl restart telemt1 telemt2 telemt3

# nft: счётчики SYN лимитера
nft list chain inet telemt_limit input

# Keepalive: проверка значений ядра
sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes

# Откат keepalive к дефолтам
rm -f /etc/sysctl.d/99-tg-keepalive.conf
sysctl -w net.ipv4.tcp_keepalive_time=7200 net.ipv4.tcp_keepalive_intvl=75 net.ipv4.tcp_keepalive_probes=9
sysctl --system

# Отключить nft limiter
systemctl stop telemt-nft-limit.service
nft delete table inet telemt_limit 2>/dev/null
```

---

## Источники

- Основной гайд: https://assyoucandy.github.io/telemt-server-guide/
- Keepalive: https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
- nft SYN limiter: https://h1de0x.github.io/telemt-tune/
- telemt releases: https://github.com/telemt/telemt/releases
