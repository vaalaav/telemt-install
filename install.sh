#!/usr/bin/env bash
# =============================================================================
#  telemt — автоустановка на Ubuntu VPS
#  Источник: https://assyoucandy.github.io/telemt-server-guide/
#  Repo:     https://github.com/vaalaav/telemt-install
# =============================================================================

set -euo pipefail

# ─── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $*"; }
info() { echo -e "${CYAN}→${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "${RED}✗ ОШИБКА:${RESET} $*" >&2; }
hdr()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
         echo -e " ${BOLD}$*${RESET}"; \
         echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

# ─── Подтверждение шага ───────────────────────────────────────────────────────
# Возвращает 0 (продолжить) или 1 (пропустить/выйти)
confirm() {
    local msg="${1:-Продолжить?}"
    local skip_ok="${2:-skip}"   # skip | exit
    echo ""
    while true; do
        if [[ "$skip_ok" == "exit" ]]; then
            read -rp "$(echo -e "${YELLOW}?${RESET} $msg [y/N/q]: ")" ans
        else
            read -rp "$(echo -e "${YELLOW}?${RESET} $msg [y/N/s=пропустить]: ")" ans
        fi
        case "${ans,,}" in
            y|yes|д|да) return 0 ;;
            q|quit|exit|в|выход)
                echo -e "${RED}Прерывание установки. Выход.${RESET}"; exit 1 ;;
            *)  if [[ "$skip_ok" == "exit" ]]; then
                    echo -e "${YELLOW}Пропуск шага.${RESET}"; return 1
                else
                    echo -e "${YELLOW}Пропуск шага.${RESET}"; return 1
                fi ;;
        esac
    done
}

# ─── Проверка root ────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Скрипт должен запускаться от root (или через sudo)"
        exit 1
    fi
}

# ─── Баннер ───────────────────────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat << 'BANNER'
  ████████╗███████╗██╗     ███████╗███╗   ███╗████████╗
     ██╔══╝██╔════╝██║     ██╔════╝████╗ ████║╚══██╔══╝
     ██║   █████╗  ██║     █████╗  ██╔████╔██║   ██║
     ██║   ██╔══╝  ██║     ██╔══╝  ██║╚██╔╝██║   ██║
     ██║   ███████╗███████╗███████╗██║ ╚═╝ ██║   ██║
     ╚═╝   ╚══════╝╚══════╝╚══════╝╚═╝     ╚═╝   ╚═╝
BANNER
    echo -e "${RESET}"
    echo -e "  Telegram MTProxy (Rust) — автоустановка на Ubuntu"
    echo -e "  ${CYAN}https://github.com/vaalaav/telemt-install${RESET}"
    echo ""
}

# ─── Выбор SSH-порта ──────────────────────────────────────────────────────────
detect_ssh_port() {
    SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/{print $4}' | grep -oE '[0-9]+$' | head -1)
    SSH_PORT="${SSH_PORT:-22}"
    info "Определён SSH-порт: ${BOLD}$SSH_PORT${RESET}"
    read -rp "$(echo -e "${YELLOW}?${RESET} Введите SSH-порт [${SSH_PORT}]: ")" inp
    SSH_PORT="${inp:-$SSH_PORT}"
    ok "SSH-порт: $SSH_PORT"
}

# ─── Выбор компонентов ────────────────────────────────────────────────────────
select_components() {
    hdr "Шаг 0 — Выбор компонентов"
    echo ""
    echo -e "  ${BOLD}Доступные инстансы:${RESET}"
    echo -e "  ${GREEN}1${RESET} — порт ${BOLD}443${RESET}   | домен ${CYAN}www.cloudflare.com${RESET}  (обычный HTTPS/CDN)"
    echo -e "  ${GREEN}2${RESET} — порт ${BOLD}5223${RESET}  | домен ${CYAN}www.apple.com${RESET}       (Apple Push, Anti-DPI)"
    echo -e "  ${GREEN}3${RESET} — порт ${BOLD}8530${RESET}  | домен ${CYAN}www.microsoft.com${RESET}   (Windows Update)"
    echo ""
    echo -e "  Введите номера через пробел (например: ${BOLD}1 2 3${RESET}) или ${BOLD}all${RESET} для всех."

    while true; do
        read -rp "$(echo -e "${YELLOW}?${RESET} Выберите инстансы [all]: ")" sel
        sel="${sel:-all}"
        if [[ "$sel" == "all" ]]; then
            INSTANCES=(1 2 3); break
        fi
        INSTANCES=()
        valid=true
        for n in $sel; do
            if [[ "$n" =~ ^[1-3]$ ]]; then
                INSTANCES+=("$n")
            else
                warn "Неверный номер: $n. Допустимо 1, 2 или 3."; valid=false; break
            fi
        done
        [[ "$valid" == true && ${#INSTANCES[@]} -gt 0 ]] && break
    done

    ok "Будут установлены инстансы: ${INSTANCES[*]}"

    # ── Дополнительные компоненты
    echo ""
    echo -e "  ${BOLD}Дополнительные компоненты:${RESET}"
    DO_UFW=true
    DO_RATELIMIT=true
    read -rp "$(echo -e "${YELLOW}?${RESET} Настроить UFW (фаервол)? [Y/n]: ")" ans
    [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_UFW=false && DO_RATELIMIT=false

    if [[ "$DO_UFW" == true ]]; then
        read -rp "$(echo -e "${YELLOW}?${RESET} Добавить rate-limit против зондирования DPI? [Y/n]: ")" ans
        [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_RATELIMIT=false
    fi
}

# ─── Порты и домены по номеру инстанса ───────────────────────────────────────
instance_port()   { local -A m=([1]=443 [2]=5223 [3]=8530);   echo "${m[$1]}"; }
instance_domain() { local -A m=([1]="www.cloudflare.com" [2]="www.apple.com" [3]="www.microsoft.com"); echo "${m[$1]}"; }
instance_api()    { local -A m=([1]=9091 [2]=9092 [3]=9093);  echo "${m[$1]}"; }

# ─── ШАГ 1: Подготовка системы ───────────────────────────────────────────────
step_prepare() {
    hdr "Шаг 1 — Подготовка системы"
    info "Обновление пакетов и установка зависимостей: wget tar jq ufw python3 iptables"
    confirm "Выполнить?" skip || return 0

    apt-get update -qq
    apt-get install -y wget tar jq ufw python3 iptables > /dev/null
    ok "Зависимости установлены"

    info "Создание пользователя 'telemt' и директорий /opt/telemt /etc/telemt"
    id telemt &>/dev/null || useradd -r -s /usr/sbin/nologin -d /opt/telemt telemt
    mkdir -p /opt/telemt /etc/telemt
    chown -R telemt:telemt /opt/telemt /etc/telemt
    ok "Пользователь и директории готовы"
}

# ─── ШАГ 2: Установка бинарника ──────────────────────────────────────────────
step_install_binary() {
    hdr "Шаг 2 — Установка бинарника telemt"
    info "Скачивание последнего релиза с GitHub..."
    confirm "Выполнить?" skip || return 0

    cd /tmp
    wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz" | tar -xz
    mv /tmp/telemt /bin/telemt
    chmod +x /bin/telemt

    VER=$(/bin/telemt --version 2>&1 || true)
    ok "Установлен: ${BOLD}$VER${RESET}"
}

# ─── ШАГ 3: Генерация секретов ────────────────────────────────────────────────
step_gen_secrets() {
    hdr "Шаг 3 — Генерация секретов"
    info "Генерация 32-hex секретов для каждого инстанса"
    confirm "Выполнить (или введите свои позже)?" skip || return 0

    declare -gA SECRETS
    for n in "${INSTANCES[@]}"; do
        SECRETS[$n]=$(openssl rand -hex 16)
        ok "Инстанс $n — секрет: ${BOLD}${SECRETS[$n]}${RESET}"
    done
}

# ─── ШАГ 4: Конфиги ──────────────────────────────────────────────────────────
step_configs() {
    hdr "Шаг 4 — Создание конфигов /etc/telemt/telemtN.toml"

    for n in "${INSTANCES[@]}"; do
        local port domain api secret
        port=$(instance_port "$n")
        domain=$(instance_domain "$n")
        api=$(instance_api "$n")
        secret="${SECRETS[$n]:-}"

        if [[ -z "$secret" ]]; then
            read -rp "$(echo -e "${YELLOW}?${RESET} Введите секрет для инстанса $n (32 hex): ")" secret
        fi

        info "Конфиг инстанса $n: порт=$port, домен=$domain, api=$api"
        confirm "Создать /etc/telemt/telemt${n}.toml?" skip || continue

        cat > "/etc/telemt/telemt${n}.toml" << TOML
[general]
fast_mode = true
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[network]
ipv4 = true
ipv6 = false
prefer = 4

[server]
port = ${port}
listen_addr_ipv4 = "0.0.0.0"
client_mss = "tspu"

[server.api]
enabled = true
listen = "127.0.0.1:${api}"
whitelist = ["127.0.0.1/32"]

[censorship]
tls_domain = "${domain}"
mask = true
mask_port = 443
tls_emulation = true
unknown_sni_action = "reject_handshake"
fake_cert_len = 2048

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
user${n} = "${secret}"
TOML

        ok "Создан /etc/telemt/telemt${n}.toml"
        SECRETS[$n]="$secret"
    done

    chown -R telemt:telemt /etc/telemt
}

# ─── ШАГ 5: systemd-сервисы ──────────────────────────────────────────────────
step_systemd() {
    hdr "Шаг 5 — Создание systemd-сервисов"

    declare -A DESCS=([1]="443 cloudflare" [2]="5223 apple" [3]="8530 microsoft")

    for n in "${INSTANCES[@]}"; do
        info "Сервис telemt${n}.service (${DESCS[$n]})"
        confirm "Создать?" skip || continue

        cat > "/etc/systemd/system/telemt${n}.service" << SERVICE
[Unit]
Description=Telemt Proxy ${n} (${DESCS[$n]})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/bin/telemt /etc/telemt/telemt${n}.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SERVICE
        ok "Создан telemt${n}.service"
    done

    systemctl daemon-reload
    ok "daemon-reload выполнен"
}

# ─── ШАГ 6: UFW ──────────────────────────────────────────────────────────────
step_ufw() {
    [[ "$DO_UFW" != true ]] && return 0
    hdr "Шаг 6 — Настройка UFW"

    warn "SSH-порт ${BOLD}${SSH_PORT}${RESET} будет открыт — убедитесь что это верно!"
    confirm "Продолжить настройку UFW?" skip || return 0

    ufw allow "${SSH_PORT}/tcp"
    ok "SSH порт $SSH_PORT открыт"

    for n in "${INSTANCES[@]}"; do
        local port; port=$(instance_port "$n")
        ufw allow "${port}/tcp"
        ok "Порт $port открыт"
    done

    ufw --force enable
    ok "UFW включён"
    ufw status
}

# ─── ШАГ 7: Rate-limit ────────────────────────────────────────────────────────
step_ratelimit() {
    [[ "$DO_RATELIMIT" != true ]] && return 0
    hdr "Шаг 7 — Rate-limit (анти-зондирование DPI)"

    info "Загрузка модуля xt_recent"
    confirm "Выполнить?" skip || return 0

    modprobe xt_recent 2>/dev/null || { warn "Модуль xt_recent недоступен — пропуск rate-limit"; return 0; }
    echo xt_recent > /etc/modules-load.d/xt_recent.conf

    if ! lsmod | grep -q xt_recent; then
        warn "xt_recent не загружен — пропуск rate-limit"
        return 0
    fi
    ok "Модуль xt_recent загружен"

    local bak="/etc/ufw/before.rules.bak.$(date +%s)"
    cp /etc/ufw/before.rules "$bak"
    ok "Бэкап: $bak"

    # Собираем список портов для Python
    local port_list=""
    for n in "${INSTANCES[@]}"; do
        port_list+="$(instance_port "$n"),"
    done
    port_list="${port_list%,}"

    # Вставка правил через Python
    python3 - "$port_list" << 'PYEOF'
import sys
PORTS = [int(p) for p in sys.argv[1].split(",")]
path = "/etc/ufw/before.rules"
lines = open(path).readlines()
if any("MTProto rate-limit" in l for l in lines):
    print("Правила уже существуют — пропуск"); raise SystemExit(0)
idx = None
for i, l in enumerate(lines):
    if "ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" in l:
        idx = i + 1; break
if idx is None:
    print("ОШИБКА: точка вставки не найдена"); raise SystemExit(1)
block = ["\n# === MTProto rate-limit (1 SYN/сек на IP per-port) ===\n"]
for p in PORTS:
    block.append(f"-A ufw-before-input -p tcp --dport {p} --syn -m recent --name mtp{p} --rcheck --seconds 1 -j DROP\n")
    block.append(f"-A ufw-before-input -p tcp --dport {p} --syn -m recent --name mtp{p} --set -j ACCEPT\n")
block.append("# === конец MTProto rate-limit ===\n")
lines[idx:idx] = block
open(path, "w").writelines(lines)
print(f"Вставлено {len(block)} строк после строки {idx}")
PYEOF

    ufw reload
    ok "UFW перезагружен с rate-limit правилами"
    iptables -L ufw-before-input -n 2>/dev/null | grep recent || \
        warn "iptables rate-limit не виден (возможно nftables — это нормально)"
}

# ─── ШАГ 8: Запуск и проверка ────────────────────────────────────────────────
step_start() {
    hdr "Шаг 8 — Запуск сервисов"
    confirm "Запустить и включить telemt в автозагрузку?" skip || return 0

    local units=()
    for n in "${INSTANCES[@]}"; do units+=("telemt${n}"); done

    systemctl enable "${units[@]}"
    systemctl start  "${units[@]}"
    sleep 3

    echo ""
    for n in "${INSTANCES[@]}"; do
        local status; status=$(systemctl is-active "telemt${n}" 2>&1)
        if [[ "$status" == "active" ]]; then
            ok "telemt${n}: ${GREEN}active${RESET}"
        else
            err "telemt${n}: $status"
        fi
    done

    echo ""
    info "Открытые порты:"
    ss -tlnp | grep -E ":(443|5223|8530)" || warn "Порты пока не видны"
}

# ─── ШАГ 9: Ссылки для клиентов ──────────────────────────────────────────────
step_links() {
    hdr "Шаг 9 — Ссылки для клиентов Telegram"

    # Ждём пока telemt подтянет TLS-сертификаты
    info "Ожидание инициализации (до 10 сек)..."
    sleep 5

    echo ""
    for n in "${INSTANCES[@]}"; do
        local api; api=$(instance_api "$n")
        local port; port=$(instance_port "$n")
        local domain; domain=$(instance_domain "$n")
        echo -e "  ${BOLD}Инстанс $n${RESET} (порт $port / $domain):"
        local link
        link=$(curl -s --max-time 5 "http://127.0.0.1:${api}/v1/users" 2>/dev/null \
               | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])" 2>/dev/null \
               || true)
        if [[ -n "$link" ]]; then
            echo -e "  ${GREEN}${link}${RESET}"
        else
            warn "API ещё не ответил. Повтори позже:"
            echo -e "  curl -s http://127.0.0.1:${api}/v1/users | python3 -c \"import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])\""
        fi
        echo ""
    done
}

# ─── Итоговое резюме ──────────────────────────────────────────────────────────
print_summary() {
    hdr "Установка завершена"
    echo ""
    echo -e "  ${BOLD}Секреты инстансов:${RESET}"
    for n in "${INSTANCES[@]}"; do
        local port domain
        port=$(instance_port "$n")
        domain=$(instance_domain "$n")
        echo -e "  Инстанс $n | порт ${BOLD}$port${RESET} | ${CYAN}$domain${RESET}"
        echo -e "    Секрет: ${BOLD}${SECRETS[$n]:-[не сохранён]}${RESET}"
    done
    echo ""
    echo -e "  ${BOLD}Полезные команды:${RESET}"
    echo -e "  systemctl status telemt1 telemt2 telemt3"
    echo -e "  journalctl -u telemt1 -f"
    for n in "${INSTANCES[@]}"; do
        local api; api=$(instance_api "$n")
        echo -e "  curl -s http://127.0.0.1:${api}/v1/users | python3 -c \"import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])\""
    done
    echo ""
    echo -e "  ${BOLD}Обновление telemt:${RESET}"
    echo -e "  bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh) --update"
    echo ""
}

# ─── Режим обновления ─────────────────────────────────────────────────────────
do_update() {
    hdr "Обновление telemt"
    confirm "Скачать и установить новую версию?" exit || exit 0
    cd /tmp
    wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz" | tar -xz
    systemctl stop telemt1 telemt2 telemt3 2>/dev/null || true
    mv /tmp/telemt /bin/telemt && chmod +x /bin/telemt
    systemctl start telemt1 telemt2 telemt3 2>/dev/null || true
    ok "Обновлено: $(/bin/telemt --version 2>&1)"
    exit 0
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    check_root
    print_banner

    # Флаг обновления
    [[ "${1:-}" == "--update" ]] && do_update

    echo -e "  Этот скрипт установит ${BOLD}telemt${RESET} (Telegram MTProxy на Rust)."
    echo -e "  На каждом шаге можно подтвердить, пропустить или отменить установку."
    echo -e "  Для полного прерывания введите ${RED}q${RESET} на любом вопросе."
    echo ""
    confirm "Начать установку?" exit

    detect_ssh_port
    select_components

    echo ""
    echo -e "${BOLD}Итоговый план:${RESET}"
    echo -e "  Инстансы:  ${INSTANCES[*]}"
    echo -e "  UFW:       $DO_UFW"
    echo -e "  Rate-limit: $DO_RATELIMIT"
    echo -e "  SSH-порт:  $SSH_PORT"
    echo ""
    confirm "Всё верно — поехали?" exit

    step_prepare
    step_install_binary
    step_gen_secrets
    step_configs
    step_systemd
    step_ufw
    step_ratelimit
    step_start
    step_links
    print_summary
}

main "$@"
