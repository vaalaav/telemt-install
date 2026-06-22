# Установка telemt proxy на VPS + примочки.

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

## Сценарии установки

При запуске установщика первым шагом выбирается сценарий:

### 1. Стандартная установка
MTProxy на нескольких портах с маскировкой под чужие SNI (готовые пресеты или ваши собственные). Доступны все опции: фаервол, тюнинг сети, VLESS upstream, свой домен в ссылке клиента.

### 2. Свой сайт
Поднимает реальный сайт через nginx + Let's Encrypt, MTProxy + опции: фаервол, тюнинг сети, VLESS upstream. Сертификат обновляется автоматически.

---

## mytelemtinfo — управление после установки

```bash
sudo mytelemtinfo
```

## Режимы запуска install.sh

При повторном запуске на уже установленной системе (или если найден telemt установленный другим способом) скрипт предлагает выбор:

- **Установка поверх** — оставляет существующие конфиги
- **Чистая установка** — полная очистка + новая установка
- **Только очистка** — удалить всё без новой установки
- **Только установить VLESS туннель** — поставить xray + VLESS upstream поверх существующего telemt (своего или чужого), автоматически прицепить ко всем найденным `/etc/telemt/telemt*.toml` или вывести инструкцию для ручной интеграции

Флаги командной строки:

```bash
sudo bash install.sh --update       # обновить только бинарник telemt
sudo bash install.sh --clean        # чистая установка без интерактивного выбора режима
sudo bash install.sh --purge        # только полная очистка
sudo bash install.sh --vless-only   # установить только VLESS туннель
```

---

## Источники

- Основной гайд: https://assyoucandy.github.io/telemt-server-guide/
- Keepalive: https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
- nft tune: https://h1de0x.github.io/telemt-tune/
- telemt releases: https://github.com/telemt/telemt/releases
- xray-core: https://github.com/XTLS/Xray-core
