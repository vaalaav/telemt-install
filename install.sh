#!/usr/bin/env bash
# =============================================================================
#  telemt — автоустановка на Ubuntu VPS
#  Источник гайда:   https://assyoucandy.github.io/telemt-server-guide/
#  Keepalive:        https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
#  nft SYN limiter:  https://h1de0x.github.io/telemt-tune/
#  Repo:             https://github.com/vaalaav/telemt-install
# =============================================================================

set -uo pipefail

# ─── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── Глобальные настройки инстансов (заполняются в select_components) ─────────
declare -A CUSTOM_PORTS=([1]=443  [2]=5223 [3]=8530)
declare -A CUSTOM_DOMAINS=([1]="www.cloudflare.com" [2]="www.apple.com" [3]="www.microsoft.com")

ok()   { echo -e "${GREEN}✓${RESET} $*"; }
info() { echo -e "${CYAN}→${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "${RED}✗ ОШИБКА:${RESET} $*" >&2; }
hdr()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}";
         echo -e " ${BOLD}$*${RESET}";
         echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

# ─── Подтверждение шага ───────────────────────────────────────────────────────
confirm() {
    local msg="${1:-Продолжить?}"
    local mode="${2:-skip}"   # skip | exit
    echo ""
    while true; do
        if [[ "$mode" == "exit" ]]; then
            read -rp "$(echo -e "${YELLOW}?${RESET} $msg [y/N/q=выход]: ")" ans
        else
            read -rp "$(echo -e "${YELLOW}?${RESET} $msg [y/N/s=пропустить/q=выход]: ")" ans
        fi
        case "${ans,,}" in
            y|yes|д|да) return 0 ;;
            q|quit|в|выход) echo -e "${RED}Прерывание. Выход.${RESET}"; exit 1 ;;
            *) echo -e "${YELLOW}Пропуск шага.${RESET}"; return 1 ;;
        esac
    done
}


# ─── Ожидание освобождения apt lock ──────────────────────────────────────────
wait_apt() {
    local locks=("/var/lib/apt/lists/lock" "/var/lib/dpkg/lock" "/var/lib/dpkg/lock-frontend")
    local waited=0
    while fuser "${locks[@]}" >/dev/null 2>&1; do
        if [[ $waited -eq 0 ]]; then
            warn "apt занят другим процессом (автообновления?) — ожидаем..."
        fi
        printf "\r  ${CYAN}→${RESET} Ждём apt... ${waited}с"
        sleep 3; waited=$((waited + 3))
        if [[ $waited -ge 120 ]]; then
            echo ""
            warn "apt не освобождается 2 минуты. Снимаем lock принудительно..."
            local pid
            pid=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | awk '{print $1}') || true
            [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null || true
            rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock \
                  /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null || true
            break
        fi
    done
    [[ $waited -gt 0 ]] && echo "" && ok "apt освободился (ждали ${waited}с)"
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

# ─── Определение SSH-порта ────────────────────────────────────────────────────
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

    # --- Инстансы ---
    echo ""
    echo -e "  ${BOLD}Инстансы telemt:${RESET}"
    echo -e "  ${GREEN}1${RESET} — порт ${BOLD}443${RESET}   | ${CYAN}www.cloudflare.com${RESET}  (HTTPS/CDN)"
    echo -e "  ${GREEN}2${RESET} — порт ${BOLD}5223${RESET}  | ${CYAN}www.apple.com${RESET}       (Apple Push / Anti-DPI)"
    echo -e "  ${GREEN}3${RESET} — порт ${BOLD}8530${RESET}  | ${CYAN}www.microsoft.com${RESET}   (Windows Update)"
    echo ""
    echo -e "  Введите номера через пробел или ${BOLD}all${RESET}:"
    while true; do
        read -rp "$(echo -e "${YELLOW}?${RESET} Инстансы [all]: ")" sel
        sel="${sel:-all}"
        if [[ "$sel" == "all" ]]; then INSTANCES=(1 2 3); break; fi
        INSTANCES=(); valid=true
        for n in $sel; do
            [[ "$n" =~ ^[1-3]$ ]] && INSTANCES+=("$n") || { warn "Неверный номер: $n"; valid=false; break; }
        done
        [[ "$valid" == true && ${#INSTANCES[@]} -gt 0 ]] && break
    done
    ok "Инстансы: ${INSTANCES[*]}"

    # --- Кастомизация SNI и портов ---
    echo ""
    echo -e "  ${BOLD}Настройка SNI и портов${RESET}"
    echo -e "  Для каждого инстанса можно оставить дефолт или задать свои значения."
    echo -e "  ${DIM}Популярные SNI для маскировки: www.cloudflare.com, www.apple.com,${RESET}"
    echo -e "  ${DIM}www.microsoft.com, www.google.com, www.amazon.com, www.youtube.com${RESET}"
    echo ""

    for n in "${INSTANCES[@]}"; do
        local def_port def_domain
        def_port="${CUSTOM_PORTS[$n]}"
        def_domain="${CUSTOM_DOMAINS[$n]}"
        echo -e "  ${BOLD}Инстанс $n${RESET} — дефолт: порт ${BOLD}${def_port}${RESET}, SNI ${CYAN}${def_domain}${RESET}"
        read -rp "$(echo -e "  ${YELLOW}?${RESET} Изменить? [y/N]: ")" cust
        if [[ "${cust,,}" =~ ^(y|yes|д|да)$ ]]; then
            # Порт
            while true; do
                read -rp "$(echo -e "    ${YELLOW}→${RESET} Порт [${def_port}]: ")" inp_port
                inp_port="${inp_port:-$def_port}"
                if [[ "$inp_port" =~ ^[0-9]+$ ]] && (( inp_port >= 1 && inp_port <= 65535 )); then
                    # Проверяем дублирование
                    local dup=false
                    for other in "${INSTANCES[@]}"; do
                        [[ "$other" != "$n" && "${CUSTOM_PORTS[$other]}" == "$inp_port" ]] && dup=true && break
                    done
                    if [[ "$dup" == true ]]; then
                        warn "Порт $inp_port уже занят другим инстансом"
                    else
                        CUSTOM_PORTS[$n]="$inp_port"; break
                    fi
                else
                    warn "Порт должен быть числом от 1 до 65535"
                fi
            done
            # SNI домен
            while true; do
                read -rp "$(echo -e "    ${YELLOW}→${RESET} SNI домен [${def_domain}]: ")" inp_domain
                inp_domain="${inp_domain:-$def_domain}"
                # Базовая валидация — не пустой, содержит точку
                if [[ -n "$inp_domain" && "$inp_domain" == *.* ]]; then
                    CUSTOM_DOMAINS[$n]="$inp_domain"; break
                else
                    warn "Введите корректный домен (например: www.google.com)"
                fi
            done
            ok "Инстанс $n: порт=${BOLD}${CUSTOM_PORTS[$n]}${RESET} SNI=${CYAN}${CUSTOM_DOMAINS[$n]}${RESET}"
        fi
        echo ""
    done

    # --- UFW ---
    echo ""
    DO_UFW=true; DO_RATELIMIT=true
    read -rp "$(echo -e "${YELLOW}?${RESET} Настроить UFW (фаервол)? [Y/n]: ")" ans
    [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_UFW=false && DO_RATELIMIT=false

    if [[ "$DO_UFW" == true ]]; then
        read -rp "$(echo -e "${YELLOW}?${RESET} Добавить UFW rate-limit (xt_recent, anti-DPI)? [Y/n]: ")" ans
        [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_RATELIMIT=false
    fi

    # --- TCP Keepalive ---
    echo ""
    echo -e "  ${BOLD}TCP Keepalive${RESET} — ускоряет отлов мёртвых мобильных соединений:"
    echo -e "  Прописывает sysctl: keepalive_time=60 / intvl=15 / probes=3"
    echo -e "  Мёртвый коннект рвётся за ~105с вместо ~2 часов по дефолту."
    DO_KEEPALIVE=true
    read -rp "$(echo -e "${YELLOW}?${RESET} Настроить TCP keepalive? [Y/n]: ")" ans
    [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_KEEPALIVE=false

    # --- nft SYN Limiter ---
    echo ""
    echo -e "  ${BOLD}nft inbound SYN limiter${RESET} — per-client ограничение входящих SYN:"
    echo -e "  Лечит зависания при подключении у некоторых провайдеров."
    echo -e "  Требует nftables (ставится автоматически)."
    DO_NFT=false
    read -rp "$(echo -e "${YELLOW}?${RESET} Установить nft SYN limiter? [y/N]: ")" ans
    [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]] && DO_NFT=true

    if [[ "$DO_NFT" == true ]]; then
        echo ""
        echo -e "  Параметры лимитера (Enter = оставить дефолт):"
        read -rp "$(echo -e "${YELLOW}?${RESET} RATE (rate over X) [1/second]: ")" NFT_RATE
        NFT_RATE="${NFT_RATE:-1/second}"
        read -rp "$(echo -e "${YELLOW}?${RESET} BURST [1]: ")" NFT_BURST
        NFT_BURST="${NFT_BURST:-1}"
        read -rp "$(echo -e "${YELLOW}?${RESET} METER_TIMEOUT [60s]: ")" NFT_TIMEOUT
        NFT_TIMEOUT="${NFT_TIMEOUT:-60s}"
        ok "nft limiter: rate over $NFT_RATE burst $NFT_BURST timeout $NFT_TIMEOUT"
    fi

    # --- Тюнинг таймаутов telemt ---
    echo ""
    echo -e "  ${BOLD}Тюнинг [timeouts] в конфиге telemt${RESET}:"
    echo -e "  Опциональная секция для проблемных сетей (медленный мобайл, нестабильный NAT)."
    echo -e "  ${YELLOW}По умолчанию НЕ добавляется${RESET} — telemt хорошо работает на дефолтах."
    DO_TIMEOUTS=false
    read -rp "$(echo -e "${YELLOW}?${RESET} Добавить секцию [timeouts] в конфиги? [y/N]: ")" ans
    [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]] && DO_TIMEOUTS=true

    if [[ "$DO_TIMEOUTS" == true ]]; then
        echo ""
        echo -e "  Значения [timeouts] (Enter = дефолт):"
        read -rp "$(echo -e "${YELLOW}?${RESET} tg_connect (сек) [10, для проблемных сетей 30]: ")" TM_TG
        TM_TG="${TM_TG:-10}"
        read -rp "$(echo -e "${YELLOW}?${RESET} client_handshake (сек) [15, для медленных клиентов 120]: ")" TM_HS
        TM_HS="${TM_HS:-15}"
        read -rp "$(echo -e "${YELLOW}?${RESET} client_keepalive (сек) [60, для нестабильных NAT 90]: ")" TM_KA
        TM_KA="${TM_KA:-60}"
        ok "Таймауты: tg_connect=$TM_TG client_handshake=$TM_HS client_keepalive=$TM_KA"
    fi
}

# ─── Вспомогательные функции инстансов ───────────────────────────────────────
# Читают из CUSTOM_PORTS / CUSTOM_DOMAINS, заполненных в select_components()
instance_port()   { echo "${CUSTOM_PORTS[$1]}"; }
instance_domain() { echo "${CUSTOM_DOMAINS[$1]}"; }
instance_api()    { local -A m=([1]=9091 [2]=9092  [3]=9093); echo "${m[$1]}"; }

# ─── ШАГ 1: Подготовка системы ───────────────────────────────────────────────
step_prepare() {
    hdr "Шаг 1 — Подготовка системы"
    info "Обновление пакетов и зависимости: wget tar jq ufw python3 iptables"
    confirm "Выполнить?" skip || return 0

    wait_apt
    info "apt-get update..."
    if ! apt-get update -qq 2>&1; then
        warn "apt update вернул ошибку, продолжаем..."
    fi
    info "Установка пакетов..."
    if ! apt-get install -y wget tar jq ufw python3 iptables 2>&1; then
        err "Не удалось установить зависимости"
        err "Попробуйте вручную: apt-get install -y wget tar jq ufw python3 iptables"
        read -rp "  Продолжить скрипт несмотря на ошибку? [y/N]: " ans
        [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && exit 1
    fi
    ok "Зависимости установлены"

    info "Создание пользователя telemt и директорий"
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
    info "Скачивание telemt..."
    if ! wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz" | tar -xz; then
        err "Не удалось скачать telemt"
        err "Проверьте интернет-соединение или скачайте вручную:"
        err "https://github.com/telemt/telemt/releases/latest"
        read -rp "  Продолжить? [y/N]: " ans
        [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && exit 1
        return 0
    fi
    if [[ ! -f /tmp/telemt ]]; then
        err "Файл /tmp/telemt не найден после распаковки"
        read -rp "  Продолжить? [y/N]: " ans
        [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && exit 1
        return 0
    fi
    mv /tmp/telemt /bin/telemt
    chmod +x /bin/telemt
    ok "Установлен: ${BOLD}$(/bin/telemt --version 2>&1)${RESET}"
}

# ─── ШАГ 3: Генерация секретов ───────────────────────────────────────────────
step_gen_secrets() {
    hdr "Шаг 3 — Генерация секретов"
    confirm "Сгенерировать секреты автоматически?" skip || return 0

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
        port=$(instance_port "$n"); domain=$(instance_domain "$n"); api=$(instance_api "$n")
        secret="${SECRETS[$n]:-}"

        if [[ -z "$secret" ]]; then
            read -rp "$(echo -e "${YELLOW}?${RESET} Введите секрет для инстанса $n (32 hex): ")" secret
        fi

        info "Инстанс $n: порт=$port домен=$domain api=$api"
        confirm "Создать /etc/telemt/telemt${n}.toml?" skip || continue

        # Базовый конфиг
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

        # Опциональная секция [timeouts]
        if [[ "${DO_TIMEOUTS:-false}" == true ]]; then
            cat >> "/etc/telemt/telemt${n}.toml" << TOMLTIME

[general]
tg_connect = ${TM_TG:-10}

[timeouts]
client_handshake = ${TM_HS:-15}
client_keepalive = ${TM_KA:-60}
TOMLTIME
            info "Добавлена секция [timeouts]: tg_connect=${TM_TG} handshake=${TM_HS} keepalive=${TM_KA}"
        fi

        ok "Создан /etc/telemt/telemt${n}.toml"
        SECRETS[$n]="$secret"
    done

    chown -R telemt:telemt /etc/telemt
}

# ─── ШАГ 5: systemd-сервисы ──────────────────────────────────────────────────
step_systemd() {
    hdr "Шаг 5 — Создание systemd-сервисов"
    for n in "${INSTANCES[@]}"; do
        local svc_desc; svc_desc="${CUSTOM_PORTS[$n]} $(echo "${CUSTOM_DOMAINS[$n]}" | cut -d. -f2)"
        info "Сервис telemt${n}.service (${svc_desc})"
        confirm "Создать?" skip || continue

        cat > "/etc/systemd/system/telemt${n}.service" << SERVICE
[Unit]
Description=Telemt Proxy ${n} (port ${CUSTOM_PORTS[$n]} / ${CUSTOM_DOMAINS[$n]})
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

    if ufw --force enable; then
        ok "UFW включён"
    else
        warn "ufw enable вернул ошибку, проверьте статус: ufw status"
    fi
    ufw status
}

# ─── ШАГ 7: UFW rate-limit (xt_recent) ───────────────────────────────────────
step_ratelimit() {
    [[ "$DO_RATELIMIT" != true ]] && return 0
    hdr "Шаг 7 — UFW rate-limit (anti-DPI зондирование)"

    confirm "Настроить rate-limit через xt_recent?" skip || return 0

    modprobe xt_recent 2>/dev/null || { warn "Модуль xt_recent недоступен — пропуск"; return 0; }
    echo xt_recent > /etc/modules-load.d/xt_recent.conf

    if ! lsmod | grep -q xt_recent; then
        warn "xt_recent не загружен — пропуск"
        return 0
    fi
    ok "Модуль xt_recent загружен"

    cp /etc/ufw/before.rules "/etc/ufw/before.rules.bak.$(date +%s)"
    ok "Бэкап before.rules создан"

    # Собираем список портов
    local port_list=""
    for n in "${INSTANCES[@]}"; do port_list+="$(instance_port "$n"),"; done
    port_list="${port_list%,}"

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
print(f"Вставлено {len(block)} строк")
PYEOF

    ufw reload
    ok "UFW перезагружен с rate-limit"
    iptables -L ufw-before-input -n 2>/dev/null | grep recent || \
        warn "iptables не показывает (возможно nftables — это нормально)"
}

# ─── ШАГ 8: TCP Keepalive (sysctl) ───────────────────────────────────────────
step_keepalive() {
    [[ "${DO_KEEPALIVE:-false}" != true ]] && return 0
    hdr "Шаг 8 — TCP Keepalive (sysctl)"

    echo ""
    echo -e "  Будет создан ${BOLD}/etc/sysctl.d/99-tg-keepalive.conf${RESET}:"
    echo -e "  tcp_keepalive_time  = ${BOLD}60${RESET}   (первая проба через 60с тишины)"
    echo -e "  tcp_keepalive_intvl = ${BOLD}15${RESET}   (повтор каждые 15с)"
    echo -e "  tcp_keepalive_probes= ${BOLD}3${RESET}    (3 без ответа → RST)"
    echo -e "  Мёртвый коннект рвётся за ~${BOLD}105с${RESET} вместо ~7200с по умолчанию."
    echo ""

    confirm "Применить?" skip || return 0

    cat > /etc/sysctl.d/99-tg-keepalive.conf << 'SYSCTL'
# telemt — агрессивный keepalive для отлова мёртвых мобильных соединений
# после 60с тишины — первая keepalive-проба
net.ipv4.tcp_keepalive_time = 60
# повтор пробы каждые 15с
net.ipv4.tcp_keepalive_intvl = 15
# 3 неотвеченных пробы → RST
net.ipv4.tcp_keepalive_probes = 3
SYSCTL

    sysctl --system > /dev/null
    ok "sysctl применён"

    # Проверка
    local t i p
    t=$(sysctl -n net.ipv4.tcp_keepalive_time)
    i=$(sysctl -n net.ipv4.tcp_keepalive_intvl)
    p=$(sysctl -n net.ipv4.tcp_keepalive_probes)
    echo -e "  Проверка ядра: time=${BOLD}$t${RESET} intvl=${BOLD}$i${RESET} probes=${BOLD}$p${RESET}"

    if [[ "$t" == "60" && "$i" == "15" && "$p" == "3" ]]; then
        ok "Keepalive настроен корректно"
    else
        warn "Значения не совпадают с ожидаемыми — проверь вручную"
    fi

    # Проверка активных соединений (если уже есть трафик)
    echo ""
    read -rp "$(echo -e "${YELLOW}?${RESET} Запустить диагностику keepalive на текущих соединениях? [y/N]: ")" ans
    if [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]; then
        python3 << 'PYEOF'
import subprocess, re, glob
from collections import Counter

ports = set()
for f in glob.glob("/etc/telemt/*.toml"):
    for line in open(f):
        m = re.match(r'\s*port\s*=\s*(\d+)', line)
        if m: ports.add(m.group(1))

out = subprocess.run(["ss","-tinoH","state","established"], capture_output=True, text=True).stdout
records, buf = [], ""
for ln in out.split("\n"):
    if not ln.strip(): continue
    if ln[0].isspace(): buf += " " + ln.strip()
    else:
        if buf: records.append(buf)
        buf = ln.strip()
if buf: records.append(buf)

timers, total = Counter(), 0
for r in records:
    f = r.split()
    local = f[2] if len(f) > 2 else ""
    if not any(local.endswith(":"+p) for p in ports): continue
    total += 1
    m = re.search(r'timer:\((\w+)', r)
    timers[m.group(1) if m else "—"] += 1

W = 44
print("╭" + "─"*W + "╮")
print("│ " + "KEEPALIVE CHECK".ljust(W-1) + "│")
print("├" + "─"*W + "┤")
print("│ " + f"Порты telemt:  {', '.join(sorted(ports)) or '—'}".ljust(W-1) + "│")
print("│ " + f"Соединений:    {total}".ljust(W-1) + "│")
print("├" + "─"*W + "┤")
if total == 0:
    print("│ " + "Нет активных соединений (норма при первом запуске)".ljust(W-1) + "│")
else:
    for name, cnt in timers.most_common():
        bar = "█" * min(cnt, 20)
        print("│ " + f"{name:<12} {cnt:>4}  {bar}".ljust(W-1) + "│")
print("╰" + "─"*W + "╯")
PYEOF
    fi

    # Откат
    echo ""
    info "Для отката: rm /etc/sysctl.d/99-tg-keepalive.conf && sysctl -w net.ipv4.tcp_keepalive_time=7200 net.ipv4.tcp_keepalive_intvl=75 net.ipv4.tcp_keepalive_probes=9 && sysctl --system"
}

# ─── ШАГ 9: nft inbound SYN per-client limiter ───────────────────────────────
step_nft_limiter() {
    [[ "${DO_NFT:-false}" != true ]] && return 0
    hdr "Шаг 9 — nft inbound SYN per-client limiter"

    echo ""
    echo -e "  Создаёт per-client ограничение входящих SYN для каждого порта telemt."
    echo -e "  Параметры: rate over ${BOLD}${NFT_RATE}${RESET} burst ${BOLD}${NFT_BURST}${RESET} timeout ${BOLD}${NFT_TIMEOUT}${RESET}"
    echo -e "  Метод: hook ${BOLD}input${RESET} (non-Docker инсталляция)"
    echo -e "  После перезагрузки: systemd-сервис ${BOLD}telemt-nft-limit.service${RESET} восстанавливает правила."
    echo ""

    confirm "Установить nft SYN limiter?" skip || return 0

    # Устанавливаем nftables если нужно
    if ! command -v nft &>/dev/null; then
        info "Установка nftables..."
        wait_apt
        if ! apt-get install -y nftables 2>&1; then
            err "Не удалось установить nftables — пропуск nft limiter"
            return 0
        fi
        ok "nftables установлен"
    else
        ok "nftables уже установлен: $(nft --version 2>&1 | head -1)"
    fi

    # Определяем публичный IP сервера
    local SERVER_IP
    SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
             || ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' \
             || hostname -I | awk '{print $1}')
    info "IP сервера: ${BOLD}$SERVER_IP${RESET}"
    read -rp "$(echo -e "${YELLOW}?${RESET} Подтвердите IP сервера [${SERVER_IP}]: ")" inp
    SERVER_IP="${inp:-$SERVER_IP}"
    ok "Будет использован IP: $SERVER_IP"

    # Создаём постоянный скрипт
    cat > /usr/local/sbin/telemt-nft-limit.sh << NFTSCRIPT
#!/bin/bash
# telemt nft inbound SYN per-client limiter
# Адаптировано для non-Docker: hook input
# Источник: https://h1de0x.github.io/telemt-tune/

set -eu

TABLE="telemt_limit"
SERVER_IP="${SERVER_IP}"
RATE="${NFT_RATE}"
BURST="${NFT_BURST}"
METER_TIMEOUT="${NFT_TIMEOUT}"

# Удаляем старую таблицу
nft delete table inet "\$TABLE" 2>/dev/null || true

# Создаём таблицу и цепочку input (non-Docker)
nft add table inet "\$TABLE"
nft "add chain inet \$TABLE input { type filter hook input priority 0; policy accept; }"

# Добавляем правила per-port per-client
NFTSCRIPT

    # Добавляем правила для каждого порта
    for n in "${INSTANCES[@]}"; do
        local port; port=$(instance_port "$n")
        cat >> /usr/local/sbin/telemt-nft-limit.sh << NFTRULE
nft "add rule inet \$TABLE input ip daddr \$SERVER_IP tcp dport ${port} tcp flags & (syn | ack) == syn meter telemt_in_syn_p${port} { ip saddr timeout \$METER_TIMEOUT limit rate over \$RATE burst \$BURST packets } counter drop comment \"telemt_syn_p${port}\""
echo "Правило применено: порт ${port}"
NFTRULE
    done

    cat >> /usr/local/sbin/telemt-nft-limit.sh << 'NFTEND'
echo "=== Применённые правила ==="
nft list chain inet telemt_limit input
NFTEND

    chmod +x /usr/local/sbin/telemt-nft-limit.sh
    ok "Скрипт создан: /usr/local/sbin/telemt-nft-limit.sh"

    # Применяем правила сейчас
    info "Применение nft-правил..."
    /usr/local/sbin/telemt-nft-limit.sh
    ok "nft-правила применены"

    # Создаём systemd-сервис для автозапуска
    cat > /etc/systemd/system/telemt-nft-limit.service << 'SERVICE'
[Unit]
Description=Telemt nft inbound SYN per-client limiter
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/telemt-nft-limit.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable telemt-nft-limit.service
    ok "Сервис telemt-nft-limit.service включён в автозапуск"

    # Проверка
    echo ""
    info "Проверка счётчиков:"
    nft list chain inet telemt_limit input 2>/dev/null | grep -E "counter|dport" || true
    echo ""
    info "Текущие дропы:"
    nft list chain inet telemt_limit input 2>/dev/null | grep "packets" || warn "Правил нет — проверь вывод выше"
}


# ─── ШАГ: Установка mytelemtinfo ─────────────────────────────────────────────
step_install_mytelemtinfo() {
    hdr "Установка команды mytelemtinfo"
    info "Скачивание менеджера /usr/local/bin/mytelemtinfo"
    confirm "Установить?" skip || return 0

    curl -fsSL "https://raw.githubusercontent.com/vaalaav/telemt-install/main/mytelemtinfo.sh" \
        -o /usr/local/bin/mytelemtinfo
    chmod +x /usr/local/bin/mytelemtinfo
    ok "Установлено: mytelemtinfo"
    info "Запуск: ${BOLD}mytelemtinfo${RESET} или ${BOLD}sudo mytelemtinfo${RESET}"
}

# ─── ШАГ 10: Запуск сервисов ──────────────────────────────────────────────────
step_start() {
    hdr "Шаг 10 — Запуск сервисов"
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

# ─── ШАГ 11: Ссылки для клиентов ─────────────────────────────────────────────
step_links() {
    hdr "Шаг 11 — Ссылки для клиентов Telegram"
    info "Ожидание инициализации TLS-сертификатов..."
    sleep 5
    echo ""

    for n in "${INSTANCES[@]}"; do
        local api port domain
        api=$(instance_api "$n"); port=$(instance_port "$n"); domain=$(instance_domain "$n")
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
    echo -e "  ${BOLD}Инстансы:${RESET}"
    for n in "${INSTANCES[@]}"; do
        echo -e "  $n │ порт ${BOLD}$(instance_port "$n")${RESET} │ ${CYAN}$(instance_domain "$n")${RESET} │ секрет: ${BOLD}${SECRETS[$n]:-[не сохранён]}${RESET}"
    done

    echo ""
    echo -e "  ${BOLD}Установленные компоненты:${RESET}"
    [[ "$DO_UFW"          == true ]] && echo -e "  ${GREEN}✓${RESET} UFW фаервол"
    [[ "$DO_RATELIMIT"    == true ]] && echo -e "  ${GREEN}✓${RESET} UFW rate-limit (xt_recent)"
    [[ "${DO_KEEPALIVE:-false}" == true ]] && echo -e "  ${GREEN}✓${RESET} TCP keepalive sysctl (time=60 intvl=15 probes=3)"
    [[ "${DO_NFT:-false}" == true ]] && echo -e "  ${GREEN}✓${RESET} nft inbound SYN limiter (${NFT_RATE} burst ${NFT_BURST})"
    [[ "${DO_TIMEOUTS:-false}" == true ]] && echo -e "  ${GREEN}✓${RESET} [timeouts]: tg_connect=${TM_TG} handshake=${TM_HS} keepalive=${TM_KA}"

    echo ""
    echo -e "  ${BOLD}Получить ссылки повторно:${RESET}"
    for n in "${INSTANCES[@]}"; do
        local api; api=$(instance_api "$n")
        echo -e "  curl -s http://127.0.0.1:${api}/v1/users | python3 -c \"import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])\""
    done

    echo ""
    echo -e "  ${BOLD}Управление:${RESET}"
    echo -e "  systemctl status telemt1 telemt2 telemt3"
    echo -e "  journalctl -u telemt1 -f"
    [[ "${DO_NFT:-false}" == true ]] && echo -e "  nft list chain inet telemt_limit input   # счётчики SYN"
    [[ "${DO_KEEPALIVE:-false}" == true ]] && echo -e "  sysctl net.ipv4.tcp_keepalive_time       # проверка keepalive"

    echo ""
    echo -e "  ${BOLD}Менеджер:${RESET}"
  echo -e "  ${CYAN}mytelemtinfo${RESET}  — интерактивное управление (прокси / keepalive / nft / таймауты)"
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

    [[ "${1:-}" == "--update" ]] && do_update

    echo -e "  Установка ${BOLD}telemt${RESET} — Telegram MTProxy на Rust."
    echo -e "  На каждом шаге: ${GREEN}y${RESET} (выполнить), Enter/n (пропустить), ${RED}q${RESET} (выход)."
    echo ""
    confirm "Начать установку?" exit

    detect_ssh_port
    select_components

    echo ""
    echo -e "${BOLD}Итоговый план:${RESET}"
    echo -e "  Инстансы:   ${INSTANCES[*]}"
    echo -e "  UFW:        $DO_UFW | rate-limit: $DO_RATELIMIT"
    echo -e "  Keepalive:  ${DO_KEEPALIVE:-false}"
    echo -e "  nft limiter:${DO_NFT:-false}"
    echo -e "  Таймауты:   ${DO_TIMEOUTS:-false}"
    echo ""
    confirm "Всё верно — поехали?" exit

    step_prepare
    step_install_binary
    step_gen_secrets
    step_configs
    step_systemd
    step_ufw
    step_ratelimit
    step_keepalive
    step_nft_limiter
    step_install_mytelemtinfo
    step_start
    step_links
    print_summary
}

main "$@"
