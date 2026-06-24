<div align="center">

# telemt-install

**Модульный автоустановщик telemt для Ubuntu**

[![OS](https://img.shields.io/badge/Ubuntu-20.04+-E95420?logo=ubuntu&logoColor=white)](#)
[![Shell](https://img.shields.io/badge/Bash-5.0+-4EAA25?logo=gnubash&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-MIT-blue)](#)

Разворачивает Telegram MTProxy на VPS в одну команду.\
Полная автоматизация — от бинарника до TLS-сертификата.

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
| 🛡️ | **VLESS Reality** | Интеграция xray-core — одиночные ссылки, подписки 3x-ui, балансировка, авто-обновление |
| 🌐 | **Свой сайт** | Nginx + Let's Encrypt — полноценный фронтенд с автоматическим TLS |
| 🔍 | **Защита от DPI** | Rate-limit через xt_recent, nftables SYN-лимитер, поддержка TSPU-режима |
| ⚙️ | **Тюнинг ядра** | BBR, TCP Keepalive, настройка таймаутов |
| 🧱 | **Файрвол** | Автонастройка UFW с синхронизацией при добавлении/удалении инстансов |
| 🔄 | **Жизненный цикл** | systemd-сервисы, обновление бинарника, чистая переустановка, полное удаление |
| 🏷️ | **Свой домен** | Кастомный домен в клиентских ссылках с проверкой DNS |

---

### 🖥️ mytelemtinfo — интерактивный менеджер

```bash
sudo mytelemtinfo
```

TUI-панель для управления всеми аспектами после установки:

- Управление инстансами — старт, стоп, рестарт, добавление, удаление, ссылки, логи
- Настройка сети — Keepalive, BBR, nft SYN-лимитер, таймауты
- Безопасность — UFW, rate-limit, TSPU
- VLESS Reality — смена ссылки, привязка/отвязка от инстансов, тест IP
- Сайт — установка, удаление, управление Nginx и сертификатами

---

### 🔧 Режимы запуска

```bash
sudo ./install.sh              # Интерактивная установка
sudo ./install.sh --update     # Обновить бинарник telemt
sudo ./install.sh --purge      # Полное удаление всех компонентов
```

При повторном запуске — выбор: установка поверх, чистая установка или только очистка.

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
| 🛡️ | **VLESS Reality** | xray-core integration — single links, 3x-ui subscriptions, load balancing, auto-refresh |
| 🌐 | **Own Website** | Nginx + Let's Encrypt — full frontend with automatic TLS |
| 🔍 | **DPI Protection** | Rate-limiting via xt_recent, nftables SYN limiter, TSPU mode support |
| ⚙️ | **Kernel Tuning** | BBR, TCP Keepalive, timeout configuration |
| 🧱 | **Firewall** | Automatic UFW setup synced with instance changes |
| 🔄 | **Lifecycle** | systemd services, binary updates, clean reinstall, full removal |
| 🏷️ | **Custom Domain** | Custom domain in client links with DNS validation |

---

### 🖥️ mytelemtinfo — Interactive Manager

```bash
sudo mytelemtinfo
```

TUI panel for post-install management:

- Instance control — start, stop, restart, add, remove, links, logs
- Network tuning — Keepalive, BBR, nft SYN limiter, timeouts
- Security — UFW, rate-limit, TSPU
- VLESS Reality — change link, bind/unbind to instances, IP test
- Website — install, remove, manage Nginx and certificates

---

### 🔧 Run Modes

```bash
sudo ./install.sh              # Interactive installation
sudo ./install.sh --update     # Update telemt binary
sudo ./install.sh --purge      # Full removal of all components
```

On re-run — choose: install over existing, clean install, or removal only.

---

<div align="center">

### 📚 Источники / References

[telemt server guide](https://assyoucandy.github.io/telemt-server-guide/) · [keepalive guide](https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html) · [nft tune](https://h1de0x.github.io/telemt-tune/) · [telemt releases](https://github.com/telemt/telemt/releases)· [telemt-panel](https://github.com/amirotin/telemt_panel)

Часть кода написана с помощью Claude (Anthropic)

</div>
