# Установка telemt proxy на VPS + примочки

🇷🇺 [Русский](#-русский) | 🇬🇧 [English](#-english)

---

## 🇷🇺 Русский

### Что это

Модульный автоустановщик **telemt** для Ubuntu — разворачивает прокси-сервер на VPS в одну команду. Поддерживает несколько инстансов с индивидуальными портами и доменами, опциональный VLESS Reality, камуфляжный сайт с TLS и защиту от DPI-зондирования.

### Возможности

- **Мультиинстанс** — до 4 параллельных прокси с отдельными секретами
- **VLESS Reality** — интеграция с xray-core для дополнительного транспорта
- **Камуфляжный сайт** — Nginx + Certbot, автоматический TLS-сертификат
- **Защита от DPI** — rate-limit через xt_recent и nftables SYN-лимитер
- **Тюнинг ядра** — BBR, TCP Keepalive
- **Файрвол** — автонастройка UFW
- **systemd-сервисы** — автозапуск, обновление (`--update`) и полная очистка (`--purge`)

### Быстрый старт

```bash
# Запуск от root на чистой Ubuntu 20.04+
git clone https://github.com/vaalaav/telemt-install.git
cd telemt-install
chmod +x install.sh
sudo ./install.sh
```

### Интерактивный менеджер управления

```bash
sudo mytelemtinfo
```

### Управление

```bash
sudo ./main.sh --update   # Обновление бинарника и перезапуск
sudo ./main.sh --purge    # Полное удаление всех компонентов
journalctl -u telemt1 -f  # Просмотр логов инстанса
```

---

## 🇬🇧 English

# Installing telemt proxy on VPS + utilities

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


### Quick start

```bash
# Run as root on a clean Ubuntu 20.04+
git clone https://github.com/vaalaav/telemt-install.git
cd telemt-install
chmod +x install.sh
sudo ./install.sh
```

### Interactive Management Manager

```bash
sudo mytelemtinfo
```

### Management

```bash
sudo ./main.sh --update   # Update binary and restart
sudo ./main.sh --purge    # Complete removal of all components
journalctl -u telemt1 -f  # View instance logs
```
