# telemt-install

Автоустановка **[telemt](https://github.com/telemt/telemt)** — Telegram MTProxy на Rust — на чистый Ubuntu VPS, с интерактивным менеджером `mytelemtinfo` для дальнейшего управления.

Источники инструкций:
- [Основной гайд](https://assyoucandy.github.io/telemt-server-guide/)
- [Keepalive](https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html)
- [nft SYN limiter](https://h1de0x.github.io/telemt-tune/)

---

## Установка

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh)
```

> Требуется root. Поддержка: Ubuntu 20.04 / 22.04 / 24.04, архитектура x86_64.

После установки управление прокси и всеми компонентами — командой `sudo mytelemtinfo`.

---

## Как работает установка

Скрипт интерактивно спрашивает: SSH-порт, какие инстансы поднимать, и хочешь ли ставить дополнительные компоненты (UFW, keepalive, nft, таймауты). Затем показывает итоговый план и одно финальное «поехали?». **После этого установка идёт автоматически без промежуточных вопросов** — на экране только прогресс.

В конце выводится таблица статуса инстансов и готовые `tg://proxy?...` ссылки для клиентов с реальным публичным IP сервера.

---

## Инстансы

Три преднастроенных инстанса с разными портами и SNI-доменами для маскировки:

| # | Порт | SNI                  | Маскируется под                |
|---|------|----------------------|--------------------------------|
| 1 | 443  | `www.cloudflare.com` | Обычный HTTPS / CDN            |
| 2 | 5223 | `www.apple.com`      | Apple Push Notification (APNs) |
| 3 | 8530 | `www.microsoft.com`  | Windows Update (WSUS)          |

Можно выбрать любое подмножество (`1`, `2 3`, `all`) или добавить **свой** инстанс с произвольными SNI и портом (пункт 4 в выборе).

Уже после установки через `mytelemtinfo` можно добавлять и удалять инстансы — всего поддерживается до 10 параллельных.

---

## Опциональные компоненты

### UFW фаервол + rate-limit

Открывает порты выбранных инстансов, включает UFW. Опционально добавляет правила `xt_recent` в `/etc/ufw/before.rules` — 1 SYN/сек на IP per-port, защита от активного зондирования DPI. Раздельные списки на каждый порт чтобы переключение между инстансами в Telegram не триггерило лимит.

### TCP Keepalive

Прописывает `/etc/sysctl.d/99-tg-keepalive.conf` с агрессивными таймерами `time=60 / intvl=15 / probes=3`. Мёртвый коннект рвётся за ~105с вместо дефолтных ~2 часов — лечит залипание мобильных клиентов после выхода из фона. telemt сам выставляет `SO_KEEPALIVE` на сокеты, поэтому ядро делает всё остальное.

### nft inbound SYN per-client limiter

Per-client ограничение входящих SYN на каждый порт telemt через nftables. Лечит зависания подключения у некоторых провайдеров. Адаптировано для **non-Docker** (`hook input`). Создаёт `/usr/local/sbin/telemt-nft-limit.sh` и systemd-сервис `telemt-nft-limit.service` для автовосстановления после перезагрузки.

Параметры: `RATE=1/second`, `BURST=1`, `METER_TIMEOUT=60s` (настраиваемые в установщике и через mytelemtinfo).

### Тюнинг [timeouts]

Опциональная секция в конфигах telemt для проблемных сетей. По умолчанию **не добавляется** — telemt хорошо работает на дефолтах. Включается явно, с настройкой `tg_connect / client_handshake / client_keepalive`.

---

## mytelemtinfo — интерактивный менеджер

После установки доступна команда `sudo mytelemtinfo` — TUI-меню с подменю под каждый компонент. На главном экране показывается сводный статус всех компонентов.

### 1. Управление прокси

- Показать ссылки для клиентов (с реальным публичным IP)
- Перезапустить / остановить / запустить все инстансы
- Управление отдельным инстансом (статус, логи, конфиг, ссылка)
- **Добавить новый инстанс** — пресет (1/2/3 — cloudflare/apple/microsoft) или свой (сначала SNI, затем порт). Авто-синхронизация UFW и nft-правил.
- **Удалить отдельный инстанс** — снимает сервис, чистит конфиг, закрывает порт в UFW, пересоздаёт rate-limit и nft под оставшиеся порты.
- Обновить бинарник telemt (последний релиз с GitHub)
- Просмотр логов
- Удалить telemt полностью (с опциональным откатом UFW / keepalive / nft)

При удалении единственного инстанса меню сразу предлагает добавить новый, чтобы не вываливать пользователя из меню.

### 2. TCP Keepalive

- Применить рекомендуемые настройки (`60/15/3`)
- Изменить значения вручную
- Диагностика активных соединений — Python-скрипт читает таймеры через `ss` и показывает счётчики
- Откатить к дефолтам ядра (`7200/75/9`)

### 3. nft SYN Limiter

- Применить / перезапустить правила
- Изменить параметры (rate / burst / timeout) — перегенерирует правила под актуальные порты
- Показать счётчики дропов
- Временно отключить (без удаления скрипта)
- Удалить полностью

### 4. Таймауты telemt

- Установить / изменить `tg_connect / client_handshake / client_keepalive` для всех или отдельных инстансов
- Сбросить к дефолтам telemt (удаляет секцию `[timeouts]`)

### 5. UFW / Rate-limit

- Полный статус UFW
- Включить UFW
- Добавить / удалить rate-limit правила в `before.rules`

---

## Обновление

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh) --update
```

Обновляет только бинарник telemt без переустановки конфигов.

Чтобы обновить сам `mytelemtinfo`:
```bash
sudo curl -fsSL "https://raw.githubusercontent.com/vaalaav/telemt-install/main/mytelemtinfo.sh?v=$(date +%s)" -o /usr/local/bin/mytelemtinfo && sudo chmod +x /usr/local/bin/mytelemtinfo
```

---

## Структура установки

```
/bin/telemt                              — бинарник
/etc/telemt/telemt{N}.toml               — конфиги инстансов (N = 1..10)
/etc/systemd/system/telemt{N}.service    — systemd-сервисы
/opt/telemt/                             — рабочая директория, TLS-кэш
/usr/local/bin/mytelemtinfo              — интерактивный менеджер
/etc/sysctl.d/99-tg-keepalive.conf       — keepalive (если включён)
/usr/local/sbin/telemt-nft-limit.sh      — nft-лимитер (если включён)
/etc/systemd/system/telemt-nft-limit.service — автозапуск nft-лимитера
```

API-порты инстансов: `9091-9100` (только на 127.0.0.1).

---

## Управление через systemd

```bash
systemctl status telemt1 telemt2 telemt3
journalctl -u telemt1 -f
systemctl restart telemt1
```

---

## Полное удаление

Через mytelemtinfo: главное меню → 1 → 10. Скрипт остановит и удалит все сервисы, конфиги, бинарник, и опционально откатит UFW / keepalive / nft к системным дефолтам.
