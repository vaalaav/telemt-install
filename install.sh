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
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ─── Глобальные настройки инстансов (заполняются в select_components) ─────────
declare -A CUSTOM_PORTS=([1]=443 [2]=5223 [3]=8530 [4]=0)
declare -A CUSTOM_DOMAINS=([1]="www.cloudflare.com" [2]="www.apple.com" [3]="www.microsoft.com" [4]="")

ok()   { echo -e "${GREEN}✓${RESET} $*"; }
info() { echo -e "${CYAN}→${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "${RED}✗ ОШИБКА:${RESET} $*" >&2; }
hdr()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}";
         echo -e " ${BOLD}$*${RESET}";
         echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

# ─── Подтверждение шага ───────────────────────────────────────────────────────
# Глобальный флаг: после "поехали?" все шаги выполняются без подтверждения
AUTO_CONFIRM=false

confirm() {
    local msg="${1:-Продолжить?}"
    local mode="${2:-skip}"   # skip | exit

    # В авто-режиме сразу возвращаем «да» (но не для финального exit-вопроса)
    if [[ "$AUTO_CONFIRM" == true && "$mode" == "skip" ]]; then
        return 0
    fi

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
    echo -e "  ${GREEN}4${RESET} — ${BOLD}свой инстанс${RESET} | ${DIM}задаются вручную SNI и порт${RESET}"
    echo ""
    echo -e "  Введите номера через пробел или ${BOLD}all${RESET} (1 2 3, без 4):"
    while true; do
        read -rp "$(echo -e "${YELLOW}?${RESET} Инстансы [all]: ")" sel
        sel="${sel:-all}"
        if [[ "$sel" == "all" ]]; then INSTANCES=(1 2 3); break; fi
        INSTANCES=(); valid=true
        for n in $sel; do
            [[ "$n" =~ ^[1-4]$ ]] && INSTANCES+=("$n") || { warn "Неверный номер: $n (допустимо 1-4)"; valid=false; break; }
        done
        [[ "$valid" == true && ${#INSTANCES[@]} -gt 0 ]] && break
    done

    # Если выбран кастомный инстанс — спрашиваем SNI и порт
    if [[ " ${INSTANCES[*]} " =~ " 4 " ]]; then
        echo ""
        echo -e "  ${BOLD}Настройка кастомного инстанса (№4)${RESET}"
        echo -e "  ${DIM}Популярные SNI: www.google.com, www.amazon.com, www.youtube.com,${RESET}"
        echo -e "  ${DIM}                www.netflix.com, www.github.com, www.discord.com${RESET}"
        echo ""

        # Порт
        while true; do
            read -rp "$(echo -e "  ${YELLOW}?${RESET} Порт (1-65535): ")" inp_port
            if [[ "$inp_port" =~ ^[0-9]+$ ]] && (( inp_port >= 1 && inp_port <= 65535 )); then
                # Проверяем что не совпадает со стандартными
                local dup=false
                for other in "${INSTANCES[@]}"; do
                    [[ "$other" != "4" && "${CUSTOM_PORTS[$other]}" == "$inp_port" ]] && dup=true && break
                done
                if [[ "$dup" == true ]]; then
                    warn "Порт $inp_port уже используется другим выбранным инстансом"
                else
                    CUSTOM_PORTS[4]="$inp_port"; break
                fi
            else
                warn "Порт должен быть числом от 1 до 65535"
            fi
        done

        # SNI домен
        while true; do
            read -rp "$(echo -e "  ${YELLOW}?${RESET} SNI домен (например www.google.com): ")" inp_domain
            if [[ -n "$inp_domain" && "$inp_domain" == *.* ]]; then
                CUSTOM_DOMAINS[4]="$inp_domain"; break
            else
                warn "Введите корректный домен (с точкой, например www.google.com)"
            fi
        done

        ok "Инстанс 4 (свой): порт=${BOLD}${CUSTOM_PORTS[4]}${RESET}  SNI=${CYAN}${CUSTOM_DOMAINS[4]}${RESET}"
    fi
    ok "Инстансы: ${INSTANCES[*]}"

    # --- UFW ---
    echo ""
    DO_UFW=true; DO_RATELIMIT=true
    read -rp "$(echo -e "${YELLOW}?${RESET} Настроить UFW (фаервол)? [Y/n]: ")" ans
    [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_UFW=false && DO_RATELIMIT=false

    if [[ "$DO_UFW" == true ]]; then
        read -rp "$(echo -e "${YELLOW}?${RESET} Добавить UFW rate-limit (xt_recent, anti-DPI)? [Y/n]: ")" ans
        [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_RATELIMIT=false
    fi

    # --- Сетевой тюнинг: TCP Keepalive + BBR ---
    echo ""
    echo -e "  ${BOLD}Сетевой тюнинг ядра${RESET}"
    echo ""
    echo -e "  ${BOLD}TCP Keepalive${RESET} — ускоряет отлов мёртвых мобильных соединений (фикс iOS-фона)."
    echo -e "  Прописывает sysctl: keepalive_time=60 / intvl=15 / probes=3"
    echo -e "  ${DIM}Когда iPhone усыпляет Telegram, сокет рвётся \"грязно\". Без keepalive сервер${RESET}"
    echo -e "  ${DIM}держит мёртвый коннект часами и при возврате клиент залипает.${RESET}"
    DO_KEEPALIVE=true
    read -rp "$(echo -e "${YELLOW}?${RESET} Настроить TCP keepalive? [Y/n]: ")" ans
    [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_KEEPALIVE=false

    echo ""
    echo -e "  ${BOLD}BBR + fq qdisc${RESET} — congestion control от Google."
    echo -e "  Улучшает скорость и латентность на нестабильных/мобильных каналах."
    echo -e "  ${DIM}Безопасно: если BBR недоступен (старое ядро) — пропустится автоматически.${RESET}"
    DO_BBR=true
    read -rp "$(echo -e "${YELLOW}?${RESET} Включить BBR + fq? [Y/n]: ")" ans
    [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && DO_BBR=false

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

    # --- Свой домен вместо IP в ссылке для клиента ---
    echo ""
    echo -e "  ${BOLD}Свой домен в ссылке для клиента${RESET}"
    echo -e "  Вместо ${BOLD}server=РЕАЛЬНЫЙ_IP${RESET} в tg://proxy?... будет ${BOLD}server=твой.домен${RESET}"
    echo -e "  ${DIM}Требование: A-запись твой.домен → IP этого сервера должна быть настроена в DNS.${RESET}"
    echo -e "  ${DIM}Это чистая косметика — Telegram-клиент сам резолвит домен в IP перед коннектом.${RESET}"
    USE_CUSTOM_DOMAIN=false
    CUSTOM_LINK_DOMAIN=""
    read -rp "$(echo -e "${YELLOW}?${RESET} Использовать свой домен? [y/N]: ")" ans
    if [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]; then
        while true; do
            read -rp "$(echo -e "  ${YELLOW}→${RESET} Введите домен (например proxy.example.com): ")" inp_dom
            if [[ -n "$inp_dom" && "$inp_dom" == *.* ]]; then
                CUSTOM_LINK_DOMAIN="$inp_dom"
                USE_CUSTOM_DOMAIN=true
                # Проверяем что домен резолвится в IP этого сервера
                local resolved_ip server_ip
                resolved_ip=$(getent hosts "$inp_dom" 2>/dev/null | awk '{print $1}' | head -1)
                server_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null \
                            || ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
                if [[ -n "$resolved_ip" && -n "$server_ip" ]]; then
                    if [[ "$resolved_ip" == "$server_ip" ]]; then
                        ok "Домен резолвится в IP сервера ($server_ip) — всё верно"
                    else
                        warn "Внимание: домен резолвится в $resolved_ip, а IP сервера — $server_ip"
                        warn "Возможно DNS ещё не обновился или A-запись указывает на другой хост"
                        read -rp "  Продолжить с этим доменом? [Y/n]: " conf
                        [[ "${conf,,}" =~ ^(n|no)$ ]] && { USE_CUSTOM_DOMAIN=false; CUSTOM_LINK_DOMAIN=""; continue; }
                    fi
                else
                    warn "Не удалось проверить DNS — домен будет использован как есть"
                fi
                break
            else
                warn "Введите корректный домен (например proxy.example.com)"
            fi
        done
        ok "В ссылках для клиентов будет: ${BOLD}${CUSTOM_LINK_DOMAIN}${RESET}"
        # Сохраняем в файл состояния для mytelemtinfo
        mkdir -p /etc/telemt
        echo "$CUSTOM_LINK_DOMAIN" > /etc/telemt/.custom_domain
        chmod 644 /etc/telemt/.custom_domain
    fi

    # --- WARP для трафика к Telegram DC ---
    echo ""
    echo -e "  ${BOLD}WARP для трафика к Telegram DC${RESET} ${DIM}(native WireGuard + SOCKS5 bridge)${RESET}"
    echo -e "  Заворачивает трафик ${BOLD}telemt → Telegram DC${RESET} через Cloudflare WARP."
    echo -e "  Клиенты подключаются к серверу ${BOLD}напрямую${RESET}, дальше идёт через WARP."
    echo -e "  ${DIM}Помогает если Telegram DC блокируется на исходящем (например с некоторых хостеров).${RESET}"
    echo -e "  ${DIM}Реализация: wgcf создаёт WireGuard-интерфейс 'warp' (Table=off),${RESET}"
    echo -e "  ${DIM}microsocks поднимает SOCKS5 на 127.0.0.1:40000 через этот интерфейс.${RESET}"
    echo -e "  ${DIM}НЕ использует громоздкий cloudflare-warp пакет (77 MB).${RESET}"
    DO_WARP=false
    read -rp "$(echo -e "${YELLOW}?${RESET} Завернуть Telegram-трафик в WARP? [y/N]: ")" ans
    [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]] && DO_WARP=true
}

# ─── Вспомогательные функции инстансов ───────────────────────────────────────
# Читают из CUSTOM_PORTS / CUSTOM_DOMAINS, заполненных в select_components()
instance_port()   { echo "${CUSTOM_PORTS[$1]}"; }
instance_domain() { echo "${CUSTOM_DOMAINS[$1]}"; }
instance_api()    { local -A m=([1]=9091 [2]=9092 [3]=9093 [4]=9094); echo "${m[$1]}"; }

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

    # Определяем публичный IP для tg:// ссылок (без него telemt вернёт 0.0.0.0)
    info "Определение публичного IP сервера..."
    PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null) || true
    [[ -z "${PUBLIC_IP:-}" ]] && PUBLIC_IP=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null) || true
    [[ -z "${PUBLIC_IP:-}" ]] && PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    [[ -z "${PUBLIC_IP:-}" ]] && PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

    if [[ -z "${PUBLIC_IP:-}" ]]; then
        read -rp "$(echo -e "${YELLOW}?${RESET} Не удалось определить IP. Введите вручную: ")" PUBLIC_IP
    else
        info "Публичный IP: ${BOLD}${PUBLIC_IP}${RESET}"
        read -rp "$(echo -e "${YELLOW}?${RESET} Подтвердите или введите свой [${PUBLIC_IP}]: ")" inp
        PUBLIC_IP="${inp:-$PUBLIC_IP}"
    fi
    ok "IP для tg://ссылок: $PUBLIC_IP"
    echo ""

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
        local tg_line=""
        [[ "${DO_TIMEOUTS:-false}" == true ]] && tg_line="tg_connect = ${TM_TG:-10}"
        cat > "/etc/telemt/telemt${n}.toml" << TOML
[general]
fast_mode = true
use_middle_proxy = false
${tg_line}

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${PUBLIC_IP}"

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

        # Опциональная секция [timeouts] (tg_connect уже в [general] выше)
        if [[ "${DO_TIMEOUTS:-false}" == true ]]; then
            cat >> "/etc/telemt/telemt${n}.toml" << TOMLTIME

[timeouts]
client_handshake = ${TM_HS:-15}
client_keepalive = ${TM_KA:-60}
TOMLTIME
            info "Добавлена секция [timeouts]: tg_connect=${TM_TG} handshake=${TM_HS} keepalive=${TM_KA}"
        fi

        # Опциональный upstream через WARP (SOCKS5 на 127.0.0.1:40000)
        if [[ "${DO_WARP:-false}" == true ]]; then
            cat >> "/etc/telemt/telemt${n}.toml" << TOMLWARP

[[upstreams]]
type = "socks5"
address = "127.0.0.1:40000"
weight = 1
enabled = true
TOMLWARP
            info "Добавлен upstream через WARP (SOCKS5 127.0.0.1:40000)"
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

# ─── ШАГ 8: Сетевой тюнинг (Keepalive + BBR) ─────────────────────────────────
step_keepalive() {
    # Пропускаем шаг полностью если ни keepalive, ни BBR не выбраны
    [[ "${DO_KEEPALIVE:-false}" != true && "${DO_BBR:-false}" != true ]] && return 0
    hdr "Шаг 8 — Сетевой тюнинг ядра"

    echo ""
    # Проверяем BBR доступен ли вообще
    local bbr_available=false
    if [[ "${DO_BBR:-false}" == true ]]; then
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            bbr_available=true
        else
            # Пробуем загрузить модуль
            modprobe tcp_bbr 2>/dev/null || true
            if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
                bbr_available=true
                ok "Модуль tcp_bbr загружен"
            else
                warn "BBR недоступен в этом ядре — пропуск BBR-настроек"
                DO_BBR=false
            fi
        fi
    fi

    # Формируем конфиг
    local sysctl_file="/etc/sysctl.d/99-telemt-net.conf"
    {
        echo "# telemt — сетевой тюнинг ядра"
        echo ""
        if [[ "${DO_KEEPALIVE:-false}" == true ]]; then
            echo "# --- TCP keepalive: быстро реапим мёртвые коннекты (фикс iOS-фона) ---"
            echo "net.ipv4.tcp_keepalive_time = 60"
            echo "net.ipv4.tcp_keepalive_intvl = 15"
            echo "net.ipv4.tcp_keepalive_probes = 3"
            echo ""
        fi
        if [[ "${DO_BBR:-false}" == true ]]; then
            echo "# --- BBR + fq: лучше латентность и throughput на плохих сетях ---"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
    } > "$sysctl_file"

    # Удаляем старый файл если был (миграция со старого имени)
    [[ -f /etc/sysctl.d/99-tg-keepalive.conf ]] && rm -f /etc/sysctl.d/99-tg-keepalive.conf

    sysctl --system > /dev/null 2>&1
    ok "Применён $sysctl_file"

    # Проверка
    echo ""
    if [[ "${DO_KEEPALIVE:-false}" == true ]]; then
        local t i p
        t=$(sysctl -n net.ipv4.tcp_keepalive_time)
        i=$(sysctl -n net.ipv4.tcp_keepalive_intvl)
        p=$(sysctl -n net.ipv4.tcp_keepalive_probes)
        echo -e "  Keepalive: time=${BOLD}$t${RESET} intvl=${BOLD}$i${RESET} probes=${BOLD}$p${RESET}"
        if [[ "$t" == "60" && "$i" == "15" && "$p" == "3" ]]; then
            ok "Keepalive — фикс iOS-фона активен (мёртвый коннект рвётся за ~105с)"
        else
            warn "Значения keepalive не совпадают с ожидаемыми"
        fi
    fi
    if [[ "${DO_BBR:-false}" == true ]]; then
        local cc qdisc
        cc=$(sysctl -n net.ipv4.tcp_congestion_control)
        qdisc=$(sysctl -n net.core.default_qdisc)
        echo -e "  BBR: congestion=${BOLD}$cc${RESET} qdisc=${BOLD}$qdisc${RESET}"
        if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
            ok "BBR + fq qdisc активны"
        else
            warn "BBR/fq не применились — проверь sysctl вручную"
        fi
    fi
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


# ─── ШАГ: Установка Cloudflare WARP ──────────────────────────────────────────
step_warp() {
    [[ "${DO_WARP:-false}" != true ]] && return 0
    hdr "Установка WARP (native WireGuard + SOCKS5-мост)"

    echo ""
    info "Архитектура: wgcf создаёт WireGuard-интерфейс 'warp' (Table=off — не перехватывает весь трафик)."
    info "microsocks поднимает SOCKS5 на 127.0.0.1:40000 с привязкой к интерфейсу warp."
    info "telemt идёт в SOCKS5 → microsocks → WARP-туннель → Telegram DC."
    echo ""
    confirm "Установить?" skip || return 0

    # ── 1) WireGuard + зависимости ────────────────────────────────────────────
    info "Установка WireGuard и microsocks..."
    wait_apt
    if ! apt-get install -y wireguard microsocks curl 2>&1; then
        err "Не удалось установить wireguard/microsocks — пропуск WARP"
        DO_WARP=false
        return 0
    fi
    ok "wireguard + microsocks установлены"

    # ── 2) wgcf — Go-бинарник, регистрация free WARP аккаунта ─────────────────
    if ! command -v wgcf &>/dev/null; then
        info "Скачивание wgcf..."
        local arch wgcf_arch wgcf_version wgcf_url

        arch=$(uname -m)
        case "$arch" in
            x86_64) wgcf_arch="amd64" ;;
            aarch64|arm64) wgcf_arch="arm64" ;;
            armv7l) wgcf_arch="armv7" ;;
            *) wgcf_arch="amd64" ;;
        esac

        wgcf_version=$(curl -s --max-time 10 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" \
                       | grep tag_name | cut -d '"' -f 4)
        if [[ -z "$wgcf_version" ]]; then
            err "Не удалось определить последнюю версию wgcf — пропуск WARP"
            DO_WARP=false
            return 0
        fi

        wgcf_url="https://github.com/ViRb3/wgcf/releases/download/${wgcf_version}/wgcf_${wgcf_version#v}_linux_${wgcf_arch}"
        info "Версия wgcf: ${BOLD}${wgcf_version}${RESET} (${wgcf_arch})"

        if ! curl -fsSL --max-time 60 -o /usr/local/bin/wgcf "$wgcf_url"; then
            err "Не удалось скачать wgcf — пропуск WARP"
            DO_WARP=false
            return 0
        fi
        chmod +x /usr/local/bin/wgcf
        ok "wgcf установлен"
    else
        ok "wgcf уже установлен"
    fi

    # ── 3) Регистрация WARP-аккаунта ─────────────────────────────────────────
    info "Регистрация free WARP-аккаунта..."
    mkdir -p /etc/wireguard
    cd /etc/wireguard

    if [[ ! -f /etc/wireguard/wgcf-account.toml ]]; then
        # Бэкап DNS на время регистрации (если /etc/resolv.conf битый)
        local restore_dns=false
        if ! getent hosts api.cloudflareclient.com &>/dev/null; then
            cp /etc/resolv.conf /etc/resolv.conf.warp-backup 2>/dev/null || true
            printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
            restore_dns=true
        fi

        # yes для авто-подтверждения TOS
        if ! timeout 60 bash -c 'yes | wgcf register' >/dev/null 2>&1; then
            # Иногда первый раз падает на 500 от Cloudflare — пробуем ещё раз
            sleep 3
            yes | wgcf register >/dev/null 2>&1 || true
        fi

        # Восстановить DNS
        if [[ "$restore_dns" == true && -f /etc/resolv.conf.warp-backup ]]; then
            cp /etc/resolv.conf.warp-backup /etc/resolv.conf
            rm -f /etc/resolv.conf.warp-backup
        fi

        if [[ ! -f /etc/wireguard/wgcf-account.toml ]]; then
            err "Регистрация wgcf не удалась — пропуск WARP"
            err "Можно попробовать позже через mytelemtinfo → 7"
            DO_WARP=false
            cd - >/dev/null 2>&1 || true
            return 0
        fi
        ok "WARP-аккаунт зарегистрирован"
    else
        ok "WARP-аккаунт уже зарегистрирован"
    fi

    # ── 4) Генерация конфига WireGuard ───────────────────────────────────────
    info "Генерация WireGuard-профиля..."
    if ! wgcf generate >/dev/null 2>&1; then
        err "Не удалось сгенерировать wgcf-profile.conf"
        DO_WARP=false
        cd - >/dev/null 2>&1 || true
        return 0
    fi

    # ── 5) Правка конфига: критично! ─────────────────────────────────────────
    # - Убираем DNS (мы не хотим чтобы WARP-интерфейс заменял системный DNS)
    # - Table = off — НЕ создаём маршрутов автоматически (не перехватываем весь трафик)
    # - PersistentKeepalive для держания соединения
    # - Убираем IPv6 если он отключён
    local conf=/etc/wireguard/wgcf-profile.conf
    sed -i '/^DNS =/d' "$conf"
    grep -q "Table = off" "$conf" || sed -i '/^MTU =/a Table = off' "$conf"
    grep -q "PersistentKeepalive" "$conf" || sed -i '/^Endpoint =/a PersistentKeepalive = 25' "$conf"

    # IPv6 — если на сервере выключен, убираем из конфига чтобы не было ошибки
    if ! sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q ' = 0'; then
        sed -i 's/,\s*[0-9a-fA-F:]\+\/128//' "$conf"
        sed -i '/Address = [0-9a-fA-F:]\+\/128/d' "$conf"
        info "IPv6 отключён в системе — убран из WARP-конфига"
    fi

    # Перемещаем в стандартное место для wg-quick
    mv "$conf" /etc/wireguard/warp.conf
    chmod 600 /etc/wireguard/warp.conf
    ok "Конфиг сохранён: /etc/wireguard/warp.conf"

    # ── 6) Запуск интерфейса warp ────────────────────────────────────────────
    info "Поднятие интерфейса warp..."
    if ! systemctl enable --now wg-quick@warp 2>&1 | grep -v "Created symlink"; then
        # Иногда нужна вторая попытка
        sleep 2
        systemctl start wg-quick@warp 2>/dev/null || true
    fi
    sleep 3

    if ! wg show warp &>/dev/null; then
        err "Интерфейс warp не поднялся"
        warn "Логи: journalctl -u wg-quick@warp -n 30"
        DO_WARP=false
        cd - >/dev/null 2>&1 || true
        return 0
    fi

    # Проверка handshake (до 10 секунд)
    local handshake=""
    for i in {1..10}; do
        handshake=$(wg show warp | grep "latest handshake" | awk -F': ' '{print $2}')
        [[ "$handshake" == *"second"* || "$handshake" == *"minute"* ]] && break
        sleep 1
    done
    if [[ -n "$handshake" && "$handshake" != "0 seconds ago" ]]; then
        ok "WARP handshake: ${handshake}"
    else
        warn "Handshake не получен за 10с (но интерфейс может ожить позже)"
    fi

    # ── 7) microsocks bridge: SOCKS5 на 127.0.0.1:40000 через warp ───────────
    info "Запуск SOCKS5-моста (microsocks через warp интерфейс)..."

    # Получаем IP интерфейса warp (что-то типа 172.16.0.2)
    local warp_ip
    warp_ip=$(ip -4 -o addr show warp 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [[ -z "$warp_ip" ]]; then
        err "Не удалось определить IP интерфейса warp"
        DO_WARP=false
        cd - >/dev/null 2>&1 || true
        return 0
    fi
    info "IP интерфейса warp: ${BOLD}${warp_ip}${RESET}"

    # Создаём systemd-сервис для microsocks
    # Используем -b 127.0.0.1 (listen) + -i $warp_ip (outbound через warp)
    cat > /etc/systemd/system/telemt-warp-socks.service << UNIT
[Unit]
Description=microsocks SOCKS5 bridge to WARP (for telemt upstream)
After=network-online.target wg-quick@warp.service
Wants=network-online.target
Requires=wg-quick@warp.service

[Service]
Type=simple
ExecStart=/usr/bin/microsocks -i 127.0.0.1 -p 40000 -b ${warp_ip}
Restart=on-failure
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now telemt-warp-socks.service 2>&1 | grep -v "Created symlink" || true
    sleep 2

    if systemctl is-active --quiet telemt-warp-socks; then
        ok "SOCKS5-мост запущен (127.0.0.1:40000 → warp → Telegram)"
    else
        warn "telemt-warp-socks не запустился"
        warn "Логи: journalctl -u telemt-warp-socks -n 20"
    fi

    # ── 8) Проверка ──────────────────────────────────────────────────────────
    info "Тест: какой IP виден через WARP-мост?"
    local direct_ip warp_visible_ip
    direct_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    warp_visible_ip=$(curl -s --max-time 10 --socks5 127.0.0.1:40000 https://api.ipify.org 2>/dev/null)
    if [[ -n "$direct_ip" ]]; then
        info "Прямой IP сервера: ${BOLD}${direct_ip}${RESET}"
    fi
    if [[ -n "$warp_visible_ip" ]]; then
        ok "Через WARP виден IP: ${BOLD}${warp_visible_ip}${RESET} (Cloudflare)"
        if [[ "$direct_ip" == "$warp_visible_ip" ]]; then
            warn "Странно — оба IP одинаковые. Возможно WARP не работает"
        fi
    else
        warn "Тест через SOCKS5 не прошёл — проверьте позже:"
        warn "  curl --socks5 127.0.0.1:40000 https://api.ipify.org"
    fi

    cd - >/dev/null 2>&1 || true
}


# ─── ШАГ: Установка mytelemtinfo ─────────────────────────────────────────────
step_install_mytelemtinfo() {
    hdr "Установка команды mytelemtinfo"
    info "Скачивание менеджера /usr/local/bin/mytelemtinfo"
    confirm "Установить?" skip || return 0

    curl -fsSL "https://raw.githubusercontent.com/vaalaav/telemt-install/main/mytelemtinfo.sh?v=$(date +%s)" \
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

    # Определяем публичный IP сервера для подмены 0.0.0.0 в ссылках
    local pub_ip
    pub_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null) || true
    [[ -z "$pub_ip" ]] && pub_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    [[ -z "$pub_ip" ]] && pub_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    for n in "${INSTANCES[@]}"; do
        local api port domain
        api=$(instance_api "$n"); port=$(instance_port "$n"); domain=$(instance_domain "$n")
        echo -e "  ${BOLD}Инстанс $n${RESET} (порт $port / $domain):"
        local link
        link=$(curl -s --max-time 5 "http://127.0.0.1:${api}/v1/users" 2>/dev/null \
               | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])" 2>/dev/null \
               || true)
        # Подменяем 0.0.0.0 на реальный публичный IP
        [[ -n "$link" && -n "$pub_ip" ]] && link="${link/server=0.0.0.0/server=${pub_ip}}"
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

    # Определяем публичный IP для ссылок
    local pub_ip
    pub_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null) || true
    [[ -z "$pub_ip" ]] && pub_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    [[ -z "$pub_ip" ]] && pub_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    # ── Таблица статуса инстансов ──
    echo -e "  ${BOLD}Статус инстансов:${RESET}"
    echo -e "  ${CYAN}┌──────┬───────┬────────────────────────┬───────────┐${RESET}"
    echo -e "  ${CYAN}│${RESET} ${BOLD}# ${RESET}   ${CYAN}│${RESET} ${BOLD}Порт${RESET}  ${CYAN}│${RESET} ${BOLD}SNI домен${RESET}              ${CYAN}│${RESET} ${BOLD}Статус${RESET}    ${CYAN}│${RESET}"
    echo -e "  ${CYAN}├──────┼───────┼────────────────────────┼───────────┤${RESET}"
    for n in "${INSTANCES[@]}"; do
        local port domain status status_disp
        port=$(instance_port "$n")
        domain=$(instance_domain "$n")
        status=$(systemctl is-active "telemt${n}" 2>/dev/null)
        case "$status" in
            active)   status_disp="${GREEN}▶ active${RESET}  " ;;
            inactive) status_disp="${RED}■ inactive${RESET}" ;;
            *)        status_disp="${YELLOW}? $status${RESET}" ;;
        esac
        printf "  ${CYAN}│${RESET} %-4s ${CYAN}│${RESET} %-5s ${CYAN}│${RESET} %-22s ${CYAN}│${RESET} %b ${CYAN}│${RESET}\n" \
               "$n" "$port" "$domain" "$status_disp"
    done
    echo -e "  ${CYAN}└──────┴───────┴────────────────────────┴───────────┘${RESET}"

    echo ""

    # ── Ссылки для клиентов ──
    echo -e "  ${BOLD}Ссылки для подключения клиентов Telegram:${RESET}"
    echo ""
    for n in "${INSTANCES[@]}"; do
        local api port domain link
        api=$(instance_api "$n"); port=$(instance_port "$n"); domain=$(instance_domain "$n")
        link=$(curl -s --max-time 5 "http://127.0.0.1:${api}/v1/users" 2>/dev/null \
               | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])" 2>/dev/null \
               || true)
        # Подмена 0.0.0.0 на реальный IP или на свой домен
        if [[ -n "$link" ]]; then
            if [[ "${USE_CUSTOM_DOMAIN:-false}" == true && -n "${CUSTOM_LINK_DOMAIN:-}" ]]; then
                link="${link/server=0.0.0.0/server=${CUSTOM_LINK_DOMAIN}}"
                [[ -n "$pub_ip" ]] && link="${link/server=${pub_ip}/server=${CUSTOM_LINK_DOMAIN}}"
            elif [[ -n "$pub_ip" ]]; then
                link="${link/server=0.0.0.0/server=${pub_ip}}"
            fi
        fi

        echo -e "  ${BOLD}Инстанс ${n}${RESET} — порт ${BOLD}${port}${RESET} | ${CYAN}${domain}${RESET}"
        if [[ -n "$link" ]]; then
            echo -e "  ${GREEN}${link}${RESET}"
        else
            warn "API ещё не ответил. Подожди минуту и выполни:"
            echo -e "    ${DIM}curl -s http://127.0.0.1:${api}/v1/users | python3 -c \"import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])\"${RESET}"
        fi
        echo ""
    done

    # ── Установленные компоненты ──
    echo -e "  ${BOLD}Установлено:${RESET}"
    [[ "$DO_UFW"               == true ]] && echo -e "  ${GREEN}✓${RESET} UFW фаервол"
    [[ "$DO_RATELIMIT"         == true ]] && echo -e "  ${GREEN}✓${RESET} UFW rate-limit (xt_recent)"
    [[ "${DO_KEEPALIVE:-false}" == true ]] && echo -e "  ${GREEN}✓${RESET} TCP keepalive (time=60 intvl=15 probes=3)  ${DIM}— фикс iOS-фона${RESET}"
    [[ "${DO_BBR:-false}"       == true ]] && echo -e "  ${GREEN}✓${RESET} BBR + fq qdisc                            ${DIM}— скорость на плохих сетях${RESET}"
    [[ "${DO_NFT:-false}"      == true ]] && echo -e "  ${GREEN}✓${RESET} nft SYN limiter (${NFT_RATE} burst ${NFT_BURST})"
    [[ "${DO_TIMEOUTS:-false}" == true ]] && echo -e "  ${GREEN}✓${RESET} [timeouts]: tg_connect=${TM_TG} handshake=${TM_HS} keepalive=${TM_KA}"
    [[ "${USE_CUSTOM_DOMAIN:-false}" == true ]] && echo -e "  ${GREEN}✓${RESET} Свой домен в ссылках: ${BOLD}${CUSTOM_LINK_DOMAIN}${RESET}"
    [[ "${DO_WARP:-false}"     == true ]] && echo -e "  ${GREEN}✓${RESET} Cloudflare WARP upstream (трафик к Telegram DC через WARP)"

    echo ""
    echo -e "  ${BOLD}Управление:${RESET} ${CYAN}sudo mytelemtinfo${RESET}"
    echo -e "  ${BOLD}Обновление:${RESET} ${DIM}bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh) --update${RESET}"
    echo ""
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

# ─── Полная очистка системы от всех компонентов установщика ─────────────────
# Используется в режиме --purge (только очистка) и в режиме --clean (очистка + установка)
do_purge_all() {
    hdr "Полная очистка системы от компонентов telemt-install"

    echo ""
    echo -e "  ${YELLOW}Будут удалены:${RESET}"
    echo -e "  • Все инстансы telemt (сервисы, конфиги, бинарник, пользователь)"
    echo -e "  • mytelemtinfo команда"
    echo -e "  • WARP компоненты: интерфейс wg-quick@warp, microsocks-мост, wgcf"
    echo -e "  • nft SYN limiter (сервис и правила)"
    echo -e "  • TCP keepalive + BBR sysctl (откат к дефолтам ядра)"
    echo -e "  • UFW правила портов и rate-limit (xt_recent)"
    echo -e "  • Сохранённый кастомный домен"
    echo ""
    echo -e "  ${DIM}НЕ удаляются: системные пакеты (wireguard, microsocks, jq, ufw)${RESET}"
    echo -e "  ${DIM}Это сохраняет их для других сервисов которые могут их использовать.${RESET}"
    echo ""
    confirm "Подтвердить полную очистку?" exit || return 1

    # ── 1) Останавливаем все инстансы telemt ──
    info "Остановка инстансов telemt..."
    for n in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -f "/etc/systemd/system/telemt${n}.service" ]]; then
            systemctl stop    "telemt${n}" 2>/dev/null || true
            systemctl disable "telemt${n}" 2>/dev/null || true
            rm -f "/etc/systemd/system/telemt${n}.service"
        fi
    done
    ok "telemt-инстансы остановлены"

    # ── 2) Удаляем конфиги и бинарник telemt ──
    info "Удаление файлов telemt..."
    rm -rf /etc/telemt /opt/telemt
    rm -f  /bin/telemt
    userdel telemt 2>/dev/null || true
    ok "Файлы telemt удалены"

    # ── 3) Удаляем mytelemtinfo ──
    if [[ -f /usr/local/bin/mytelemtinfo ]]; then
        rm -f /usr/local/bin/mytelemtinfo
        ok "mytelemtinfo удалён"
    fi

    # ── 4) Удаляем WARP (native WireGuard + microsocks) ──
    if [[ -f /etc/wireguard/warp.conf ]] || systemctl list-unit-files 2>/dev/null | grep -q "wg-quick@warp\|telemt-warp-socks"; then
        info "Удаление WARP..."
        systemctl stop telemt-warp-socks 2>/dev/null || true
        systemctl disable telemt-warp-socks 2>/dev/null || true
        rm -f /etc/systemd/system/telemt-warp-socks.service

        systemctl stop wg-quick@warp 2>/dev/null || true
        systemctl disable wg-quick@warp 2>/dev/null || true
        rm -f /etc/wireguard/warp.conf /etc/wireguard/wgcf-account.toml /etc/wireguard/wgcf-profile.conf
        rm -f /usr/local/bin/wgcf

        # Старый cloudflare-warp если был
        if command -v warp-cli &>/dev/null; then
            warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
            systemctl disable --now warp-svc 2>/dev/null || true
            apt-get purge -y cloudflare-warp 2>&1 | tail -2 || true
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        fi
        ok "WARP компоненты удалены"
    fi

    # ── 5) nft SYN limiter ──
    if [[ -f /etc/systemd/system/telemt-nft-limit.service ]] || nft list table inet telemt_limit &>/dev/null; then
        info "Удаление nft SYN limiter..."
        systemctl stop    telemt-nft-limit.service 2>/dev/null || true
        systemctl disable telemt-nft-limit.service 2>/dev/null || true
        rm -f /etc/systemd/system/telemt-nft-limit.service
        rm -f /usr/local/sbin/telemt-nft-limit.sh
        nft delete table inet telemt_limit 2>/dev/null || true
        ok "nft limiter удалён"
    fi

    # ── 6) TCP keepalive + BBR sysctl ──
    if [[ -f /etc/sysctl.d/99-telemt-net.conf || -f /etc/sysctl.d/99-tg-keepalive.conf ]]; then
        info "Откат TCP keepalive и BBR..."
        rm -f /etc/sysctl.d/99-telemt-net.conf /etc/sysctl.d/99-tg-keepalive.conf
        sysctl -w net.ipv4.tcp_keepalive_time=7200  >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_keepalive_intvl=75   >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_keepalive_probes=9   >/dev/null 2>&1 || true
        sysctl -w net.core.default_qdisc=fq_codel   >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
        sysctl --system >/dev/null 2>&1 || true
        ok "Keepalive + BBR откачены к дефолтам"
    fi

    # ── 7) UFW: rate-limit и порты ──
    if grep -q "MTProto rate-limit" /etc/ufw/before.rules 2>/dev/null; then
        info "Удаление UFW rate-limit правил..."
        python3 << 'PYEOF'
path = "/etc/ufw/before.rules"
lines = open(path).readlines()
out, skip = [], False
for l in lines:
    if "MTProto rate-limit" in l and "конец" not in l: skip = True
    if not skip: out.append(l)
    if "конец MTProto rate-limit" in l: skip = False
open(path,"w").writelines(out)
PYEOF
        rm -f /etc/modules-load.d/xt_recent.conf
        ufw reload >/dev/null 2>&1 || true
        ok "UFW rate-limit убран"
    fi

    # Порты telemt (стандартные + кастомные из конфигов если бы они ещё были)
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Закрытие UFW портов telemt..."
        for port in 443 5223 8530; do
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
        done
        ok "UFW порты закрыты"
    fi

    # ── 8) Бэкапы и временные файлы ──
    rm -f /etc/ufw/before.rules.bak.* 2>/dev/null || true
    rm -f /etc/telemt/.custom_domain 2>/dev/null || true

    echo ""
    ok "${BOLD}Очистка завершена.${RESET}"
    echo ""
    info "Состояние системы после очистки:"
    echo -e "  ${DIM}• telemt: $(command -v /bin/telemt &>/dev/null && echo 'ещё есть' || echo 'удалён')${RESET}"
    echo -e "  ${DIM}• mytelemtinfo: $(command -v mytelemtinfo &>/dev/null && echo 'ещё есть' || echo 'удалён')${RESET}"
    echo -e "  ${DIM}• warp интерфейс: $(wg show warp &>/dev/null && echo 'активен' || echo 'нет')${RESET}"
    echo -e "  ${DIM}• nft telemt_limit: $(nft list table inet telemt_limit &>/dev/null && echo 'активна' || echo 'нет')${RESET}"
    echo ""
    return 0
}

# ─── Режим --purge (только очистка, без установки) ──────────────────────────
do_purge_only() {
    check_root
    print_banner
    echo -e "  ${BOLD}${RED}РЕЖИМ ПОЛНОЙ ОЧИСТКИ${RESET}"
    echo -e "  ${DIM}Будут удалены все компоненты telemt-install без последующей установки.${RESET}"
    echo ""
    if do_purge_all; then
        echo -e "  Чтобы установить заново позже:"
        echo -e "  ${CYAN}sudo bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh)${RESET}"
        echo ""
    fi
    exit 0
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    check_root
    print_banner

    # Флаги командной строки
    [[ "${1:-}" == "--update" ]] && do_update
    [[ "${1:-}" == "--purge"  ]] && do_purge_only

    echo -e "  Установка ${BOLD}telemt${RESET} — Telegram MTProxy на Rust."
    echo ""

    # Определяем что уже установлено
    local existing_install=false
    if [[ -f /bin/telemt ]] || [[ -d /etc/telemt ]] || [[ -f /usr/local/bin/mytelemtinfo ]]; then
        existing_install=true
    fi

    # Если что-то уже установлено или передан флаг --clean — предлагаем меню режимов
    if [[ "$existing_install" == true || "${1:-}" == "--clean" ]]; then
        if [[ "$existing_install" == true ]]; then
            warn "Обнаружена существующая установка telemt-install."
            echo ""
        fi
        echo -e "  ${BOLD}Выберите режим:${RESET}"
        echo -e "  ${BOLD}1.${RESET} Установка поверх ${DIM}(обычная, существующие конфиги сохраняются)${RESET}"
        echo -e "  ${BOLD}2.${RESET} ${YELLOW}Чистая установка${RESET} ${DIM}(полная очистка + новая установка)${RESET}"
        echo -e "  ${BOLD}3.${RESET} ${RED}Только очистка${RESET} ${DIM}(удалить всё без новой установки)${RESET}"
        echo -e "  ${BOLD}0.${RESET} Отмена"
        echo ""
        local mode
        # Если передан --clean — сразу режим 2
        if [[ "${1:-}" == "--clean" ]]; then
            mode=2
            info "Режим --clean: чистая установка"
        else
            read -rp "  Режим [1/2/3/0]: " mode
        fi
        case "$mode" in
            1) info "Режим: установка поверх существующей" ;;
            2)
                info "Режим: чистая установка (сначала очистка)"
                if ! do_purge_all; then
                    echo -e "${RED}Очистка отменена.${RESET}"
                    exit 1
                fi
                echo ""
                info "Очистка завершена. Переходим к установке..."
                sleep 2
                ;;
            3) do_purge_only ;;
            0|q|"") echo -e "${YELLOW}Отменено.${RESET}"; exit 0 ;;
            *) err "Неверный пункт"; exit 1 ;;
        esac
    fi

    echo -e "  На каждом шаге: ${GREEN}y${RESET} (выполнить), Enter/n (пропустить), ${RED}q${RESET} (выход)."
    echo ""
    confirm "Начать установку?" exit

    detect_ssh_port
    select_components

    echo ""
    echo -e "${BOLD}Итоговый план:${RESET}"
    echo -e "  Инстансы:        ${INSTANCES[*]}"
    echo -e "  UFW:             $DO_UFW | rate-limit: $DO_RATELIMIT"
    echo -e "  Keepalive:       ${DO_KEEPALIVE:-false}"
    echo -e "  BBR + fq:        ${DO_BBR:-false}"
    echo -e "  nft limiter:     ${DO_NFT:-false}"
    echo -e "  Таймауты:        ${DO_TIMEOUTS:-false}"
    echo -e "  Свой домен:      ${USE_CUSTOM_DOMAIN:-false}${USE_CUSTOM_DOMAIN:+ (${CUSTOM_LINK_DOMAIN})}"
    echo -e "  WARP upstream:   ${DO_WARP:-false}"
    echo ""
    confirm "Всё верно — поехали?" exit

    # С этого момента все шаги выполняются автоматически без подтверждений
    AUTO_CONFIRM=true
    echo ""
    info "Установка пошла. Подтверждения больше не требуются."

    step_prepare
    step_install_binary
    step_warp
    step_gen_secrets
    step_configs
    step_systemd
    step_ufw
    step_ratelimit
    step_keepalive
    step_nft_limiter
    step_install_mytelemtinfo
    step_start
    print_summary
}

main "$@"
