# telemt-install

Автоустановка **[telemt](https://github.com/telemt/telemt)** — Telegram MTProxy на Rust — на Ubuntu VPS, с интерактивным менеджером `mytelemtinfo`.

---

## Установка

Рекомендуемый способ (надёжно работает всегда):

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh
chmod +x install.sh
sudo bash install.sh
```

Однострочный вариант (может не сработать с первого раза из-за CDN-кэша — тогда используйте способ выше):

```bash
sudo bash -c "curl -fsSL 'https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh?v=$(date +%s)' | bash"
```

> Требуется root. Ubuntu 20.04 / 22.04 / 24.04, x86_64.

После установки управление — командой `sudo mytelemtinfo`.

---

## Опции установки

В диалоге можно включить или пропустить любой компонент:

- **Инстансы telemt** — 3 пресета (cloudflare:443 / apple:5223 / microsoft:8530) или свой SNI и порт
- **UFW + rate-limit** — фаервол с защитой от DPI-зондирования
- **TCP Keepalive** — фикс залипания iOS-клиентов после фона
- **BBR + fq qdisc** — congestion control для нестабильных сетей
- **nft SYN limiter** — per-client ограничение SYN на каждый порт
- **Тюнинг таймаутов** — для проблемных сетей (по умолчанию выключено)
- **Свой домен в ссылке** — вместо IP в `tg://proxy?server=`
- **VLESS Reality upstream** — туннелирует трафик telemt → Telegram DC через ваш VLESS-сервер (например 3x-ui). Просто вставьте `vless://` ссылку при установке.

После финального подтверждения установка идёт автоматически. В конце — таблица статуса и готовые ссылки для клиентов.

---

## mytelemtinfo — управление после установки

```bash
sudo mytelemtinfo
```

7 разделов:

1. **Управление прокси** — старт/стоп/рестарт, добавление и удаление инстансов (до 10), ссылки клиентам, логи, полное удаление
2. **Сетевой тюнинг** — Keepalive + BBR
3. **nft SYN Limiter** — настройка параметров и счётчики дропов
4. **Таймауты telemt**
5. **UFW / Rate-limit**
6. **Свой домен в ссылках** — с проверкой DNS
7. **VLESS Reality upstream** — изменить ссылку, прицепить/отцепить от telemt, тест IP

---

## Режимы запуска install.sh

При повторном запуске на уже установленной системе скрипт предлагает выбор:

- **Установка поверх** — оставляет существующие конфиги
- **Чистая установка** — полная очистка + новая установка
- **Только очистка** — удалить всё без новой установки

Флаги командной строки:

```bash
sudo bash install.sh --update    # обновить только бинарник telemt
sudo bash install.sh --clean     # чистая установка без интерактивного выбора режима
sudo bash install.sh --purge     # только полная очистка
```

---

## Источники

- Основной гайд: https://assyoucandy.github.io/telemt-server-guide/
- Keepalive: https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
- nft tune: https://h1de0x.github.io/telemt-tune/
- telemt releases: https://github.com/telemt/telemt/releases
