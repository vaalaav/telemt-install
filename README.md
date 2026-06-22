# Установка telemt proxy на VPS + примочки

🇷🇺 [Русский](#-русский) | 🇬🇧 [English](#-english)

---

## 🇷🇺 Русский

### Что это

Модульный автоустановщик **telemt** для Ubuntu — разворачивает прокси-сервер на VPS в одну команду. Поддерживает несколько инстансов с индивидуальными портами и доменами, опциональный VLESS Reality, камуфляжный сайт с TLS и защиту от DPI-зондирования.

### Возможности

- **Мультиинстанс** — до 4 параллельных прокси (443, 5223, 8530…) с отдельными секретами
- **VLESS Reality** — интеграция с xray-core для дополнительного транспорта
- **Камуфляжный сайт** — Nginx + Certbot, автоматический TLS-сертификат
- **Защита от DPI** — rate-limit через xt_recent и nftables SYN-лимитер
- **Тюнинг ядра** — BBR, TCP Keepalive
- **Файрвол** — автонастройка UFW
- **systemd-сервисы** — автозапуск, обновление (`--update`) и полная очистка (`--purge`)

### Структура проекта

```
├── main.sh              # Оркестратор
├── config.env           # Переменные и настройки
├── utils/
│   └── helpers.sh       # Логирование, утилиты
└── lib/
    ├── 01_prepare.sh    # Подготовка системы
    ├── 02_binary.sh     # Скачивание бинарника
    ├── 03_vless.sh      # VLESS Reality
    ├── 04_configs.sh    # Генерация секретов и .toml
    ├── 05_network.sh    # UFW, rate-limit, keepalive
    ├── 06_site.sh       # Nginx + Certbot
    └── 07_lifecycle.sh  # systemd, update, purge
```

### Быстрый старт

```bash
# Запуск от root на чистой Ubuntu 20.04+
git clone https://github.com/vaalaav/telemt-install.git
cd telemt-install
chmod +x main.sh
sudo ./main.sh
```

### Управление

```bash
sudo ./main.sh --update   # Обновление бинарника и перезапуск
sudo ./main.sh --purge    # Полное удаление всех компонентов
journalctl -u telemt1 -f  # Просмотр логов инстанса
```

### Настройка

Отредактируйте `config.env` перед запуском:

| Параметр | Описание |
|---|---|
| `CUSTOM_PORTS` | Порты для каждого инстанса |
| `CUSTOM_DOMAINS` | Домены-маскировки |
| `DO_VLESS` | Включить VLESS Reality (`true`/`false`) |
| `DO_UFW` | Настроить файрвол (`true`/`false`) |
| `DO_RATELIMIT` | Защита от DPI-зондирования |
| `DO_NFT` | nftables SYN-лимитер |
| `INSTALL_SCENARIO` | `standard` или `site` (с Nginx) |

### Требования

- Ubuntu 20.04+
- Права root
- Свободный порт 443 (или другие из `CUSTOM_PORTS`)

---

## 🇬🇧 English

### What is this

A modular auto-installer for **telemt** on Ubuntu — deploys a proxy server on a VPS with a single command. Supports multiple instances with individual ports and domains, optional VLESS Reality, a camouflage website with TLS, and DPI probing protection.

### Features

- **Multi-instance** — up to 4 parallel proxies (443, 5223, 8530…) with separate secrets
- **VLESS Reality** — xray-core integration for an additional transport layer
- **Camouflage site** — Nginx + Certbot with automatic TLS certificates
- **DPI protection** — rate-limiting via xt_recent and nftables SYN limiter
- **Kernel tuning** — BBR, TCP Keepalive
- **Firewall** — automatic UFW configuration
- **systemd services** — auto-start, update (`--update`), and full removal (`--purge`)

### Project structure

```
├── main.sh              # Orchestrator
├── config.env           # Variables and settings
├── utils/
│   └── helpers.sh       # Logging, utilities
└── lib/
    ├── 01_prepare.sh    # System preparation
    ├── 02_binary.sh     # Binary download
    ├── 03_vless.sh      # VLESS Reality
    ├── 04_configs.sh    # Secret generation & .toml configs
    ├── 05_network.sh    # UFW, rate-limit, keepalive
    ├── 06_site.sh       # Nginx + Certbot
    └── 07_lifecycle.sh  # systemd, update, purge
```

### Quick start

```bash
# Run as root on a clean Ubuntu 20.04+
git clone https://github.com/vaalaav/telemt-install.git
cd telemt-install
chmod +x main.sh
sudo ./main.sh
```

### Management

```bash
sudo ./main.sh --update   # Update binary and restart
sudo ./main.sh --purge    # Complete removal of all components
journalctl -u telemt1 -f  # View instance logs
```

### Configuration

Edit `config.env` before running:

| Parameter | Description |
|---|---|
| `CUSTOM_PORTS` | Ports for each instance |
| `CUSTOM_DOMAINS` | Masquerade domains |
| `DO_VLESS` | Enable VLESS Reality (`true`/`false`) |
| `DO_UFW` | Configure firewall (`true`/`false`) |
| `DO_RATELIMIT` | DPI probing protection |
| `DO_NFT` | nftables SYN limiter |
| `INSTALL_SCENARIO` | `standard` or `site` (with Nginx) |

### Requirements

- Ubuntu 20.04+
- Root privileges
- Port 443 available (or others from `CUSTOM_PORTS`)
