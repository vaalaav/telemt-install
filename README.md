# telemt-install

Скрипт автоматической установки **[telemt](https://github.com/telemt/telemt)** — Telegram MTProxy на Rust — на чистый Ubuntu VPS.

Основан на гайде: [assyoucandy.github.io/telemt-server-guide](https://assyoucandy.github.io/telemt-server-guide/)

---

## Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh)
```

> Требуется root. Поддерживаются Ubuntu 20.04 / 22.04 / 24.04.

---

## Что делает скрипт

- **Выбор компонентов** — выбираешь какие инстансы ставить (1, 2, 3 или все)
- **Подтверждение каждого шага** — на каждом этапе можно подтвердить, пропустить или полностью прервать (`q`)
- **3 инстанса** с разными портами и маскировочными доменами:

| Инстанс | Порт | Домен (SNI)          | Маскируется под                |
|---------|------|----------------------|--------------------------------|
| 1       | 443  | `www.cloudflare.com` | Обычный HTTPS / CDN            |
| 2       | 5223 | `www.apple.com`      | Apple Push Notification (APNs) |
| 3       | 8530 | `www.microsoft.com`  | Windows Update (WSUS)          |

- **Настройка UFW** с опциональным rate-limit (защита от активного зондирования DPI / РКН)
- **systemd-сервисы** с автозапуском и перезапуском при падении
- **Вывод готовых ссылок** `tg://proxy?...` в конце установки

---

## Шаги установки

```
Шаг 0 — Выбор компонентов и SSH-порта
Шаг 1 — Обновление системы, зависимости, пользователь telemt
Шаг 2 — Скачивание бинарника telemt (последний релиз с GitHub)
Шаг 3 — Генерация секретов (openssl rand -hex 16)
Шаг 4 — Создание конфигов /etc/telemt/telemtN.toml
Шаг 5 — Создание systemd-сервисов
Шаг 6 — Настройка UFW (открытие портов)
Шаг 7 — Rate-limit правила в /etc/ufw/before.rules (xt_recent)
Шаг 8 — Запуск сервисов и проверка статуса
Шаг 9 — Вывод готовых ссылок для клиентов Telegram
```

---

## Обновление telemt

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh) --update
```

---

## Управление после установки

```bash
# Статус
systemctl status telemt1 telemt2 telemt3

# Логи
journalctl -u telemt1 -f

# Получить ссылки для клиентов
curl -s http://127.0.0.1:9091/v1/users | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])"
curl -s http://127.0.0.1:9092/v1/users | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])"
curl -s http://127.0.0.1:9093/v1/users | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])"

# Статистика подключений
curl -s http://127.0.0.1:9091/v1/stats/summary | python3 -m json.tool

# Рестарт
systemctl restart telemt1 telemt2 telemt3
```

---

## Требования

- Ubuntu 20.04 / 22.04 / 24.04
- Права root
- Архитектура x86_64
- Открытые порты 443, 5223, 8530 (или любые выбранные)

---

## Источники

- Гайд: https://assyoucandy.github.io/telemt-server-guide/
- telemt releases: https://github.com/telemt/telemt/releases
