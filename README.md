<div align="center">

# telemt-install

**Автоустановщик telemt для Ubuntu**

[![OS](https://img.shields.io/badge/Ubuntu-20.04+-E95420?logo=ubuntu&logoColor=white)](#)
[![Shell](https://img.shields.io/badge/Bash-5.0+-4EAA25?logo=gnubash&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-MIT-blue)](#)

Разворачивает Telegram MTProxy на VPS в одну команду.\
Полная автоматизация — от бинарника до готовых ссылок.

🇷🇺 [Русский](#-русский) &nbsp;|&nbsp; 🇬🇧 [English](#-english)

</div>

---

## 🇷🇺 Русский

### ⚡ Быстрый старт

```bash
git clone https://github.com/vaalaav/telemt-install.git
cd telemt-install && chmod +x install.sh
sudo ./install.sh
```

> После подтверждения установка идёт полностью автоматически.\
> В конце — таблица статуса и готовые клиентские ссылки.

---

### 🧩 Возможности

| | Функция | Описание |
|:--:|---|---|
| 🔀 | **Мультиинстанс** | До 10 параллельных прокси с индивидуальными параметрами |
| 🛡️ | **VLESS Reality** | Интеграция xray-core — одиночные ссылки, подписки, балансировка |
| 📊 | **Web-панель** | telemt_panel — управление через браузер с авторизацией |
| 🔍 | **Защита от DPI** | Rate-limit через xt_recent, nftables SYN-лимитер, TSPU-режим |
| 🧬 | **MEKO-фиксы** | DPI-оптимизация на уровне параметров прокси и ядра |
| ⚙️ | **Тюнинг ядра** | BBR, TCP Keepalive, настройка таймаутов |
| 🧱 | **Файрвол** | Автонастройка UFW с синхронизацией при добавлении/удалении инстансов |
| 🔄 | **Жизненный цикл** | systemd-сервисы, обновление бинарника, чистая переустановка, полное удаление |
| 🏷️ | **Свой домен** | Кастомный домен в клиентских ссылках с проверкой DNS |

---

### 🖥️ mytelemtinfo — интерактивный менеджер

```bash
sudo mytelemtinfo
```

TUI-панель с 9 разделами:

1. **Управление прокси** — старт, стоп, рестарт, добавление и удаление инстансов, ссылки, логи, полное удаление
2. **Сетевой тюнинг** — Keepalive, BBR
3. **nft SYN Limiter** — параметры лимитера, счётчики
4. **Таймауты** — настройка таймаутов telemt
5. **UFW / Rate-limit** — управление файрволом
6. **Свой домен** — привязка домена к ссылкам
7. **VLESS Reality** — смена ссылки, привязка/отвязка от инстансов, тест IP
8. **Web-панель** — установка, удаление и управление telemt_panel
9. **MEKO-фиксы** — DPI-оптимизация

---

### 🔧 Режимы запуска

```bash
sudo ./install.sh              # Интерактивная установка
sudo ./install.sh --update     # Обновить бинарник telemt
sudo ./install.sh --clean      # Очистка + новая установка
sudo ./install.sh --purge      # Полное удаление всех компонентов
```

При повторном запуске без флагов — выбор: установка поверх, чистая установка или только очистка.

---

## 🇬🇧 English

### ⚡ Quick Start

```bash
git clone https://github.com/vaalaav/telemt-install.git
cd telemt-install && chmod +x install.sh
sudo ./install.sh
```

> After confirmation the installation runs fully automatically.\
> Finishes with a status table and ready-to-share client links.

---

### 🧩 Features

| | Feature | Description |
|:--:|---|---|
| 🔀 | **Multi-instance** | Up to 10 parallel proxies with individual settings |
| 🛡️ | **VLESS Reality** | xray-core integration — single links, subscriptions, load balancing |
| 📊 | **Web Panel** | telemt_panel — browser-based management with authentication |
| 🔍 | **DPI Protection** | Rate-limiting via xt_recent, nftables SYN limiter, TSPU mode |
| 🧬 | **MEKO Tweaks** | DPI optimization at proxy and kernel level |
| ⚙️ | **Kernel Tuning** | BBR, TCP Keepalive, timeout configuration |
| 🧱 | **Firewall** | Automatic UFW setup synced with instance changes |
| 🔄 | **Lifecycle** | systemd services, binary updates, clean reinstall, full removal |
| 🏷️ | **Custom Domain** | Custom domain in client links with DNS validation |

---

### 🖥️ mytelemtinfo — Interactive Manager

```bash
sudo mytelemtinfo
```

TUI panel with 9 sections:

1. **Proxy management** — start, stop, restart, add and remove instances, links, logs, full removal
2. **Network tuning** — Keepalive, BBR
3. **nft SYN Limiter** — limiter settings, counters
4. **Timeouts** — telemt timeout configuration
5. **UFW / Rate-limit** — firewall management
6. **Custom domain** — bind domain to client links
7. **VLESS Reality** — change link, bind/unbind to instances, IP test
8. **Web Panel** — install, remove and manage telemt_panel
9. **MEKO Tweaks** — DPI optimization

---

### 🔧 Run Modes

```bash
sudo ./install.sh              # Interactive installation
sudo ./install.sh --update     # Update telemt binary
sudo ./install.sh --clean      # Clean wipe + fresh install
sudo ./install.sh --purge      # Full removal of all components
```

On re-run without flags — choose: install over existing, clean install, or removal only.

---

<div align="center">

### 📚 Источники / References

[telemt server guide](https://assyoucandy.github.io/telemt-server-guide/) · [keepalive guide](https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html) · [nft tune](https://h1de0x.github.io/telemt-tune/) · [telemt releases](https://github.com/telemt/telemt/releases)· [MEKO fixes](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO)

Часть кода написана с помощью Claude (Anthropic)

</div>
