#!/usr/bin/env bash
# =============================================================================
#  telemt — автоустановка на Ubuntu VPS
#  Источник гайда:   https://assyoucandy.github.io/telemt-server-guide/
#  Keepalive:        https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
#  nft SYN limiter:  https://h1de0x.github.io/telemt-tune/
#  Repo:             https://github.com/vaalaav/telemt-install
# =============================================================================

set -uo pipefail

# Если stdin не подключён к терминалу (например при запуске через bash <(curl ...)
# или curl ... | bash), перенаправляем stdin от /dev/tty. Без этого
# интерактивные `read` сразу получают EOF и скрипт идёт по веткам пустого ввода.
if [[ ! -t 0 ]] && [[ -t 1 ]] && [[ -e /dev/tty ]]; then
    exec </dev/tty
fi

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

# ─── Хелпер: публичный IP сервера (с кэшем) ────────────────────────────────
_OUR_PUB_IP_CACHE=""
get_public_ip_cached() {
    if [[ -z "$_OUR_PUB_IP_CACHE" ]]; then
        _OUR_PUB_IP_CACHE=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null) || true
        [[ -z "$_OUR_PUB_IP_CACHE" ]] && _OUR_PUB_IP_CACHE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
        [[ -z "$_OUR_PUB_IP_CACHE" ]] && _OUR_PUB_IP_CACHE=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$_OUR_PUB_IP_CACHE"
}

# ─── Хелпер: проверка vless-ссылки на петлю (vless server != наш IP) ────────
check_vless_not_self() {
    local link="$1"
    local vless_host vless_ip our_ip
    vless_host=$(VL="$link" python3 -c "import os,urllib.parse as up;print(up.urlparse(os.environ['VL']).hostname)" 2>/dev/null)
    [[ -z "$vless_host" ]] && return 0
    vless_ip=$(getent hosts "$vless_host" 2>/dev/null | awk '{print $1}' | head -1)
    our_ip=$(get_public_ip_cached)
    if [[ -n "$vless_ip" && -n "$our_ip" && "$vless_ip" == "$our_ip" ]]; then
        err "VLESS-сервер (${vless_host} → ${vless_ip}) совпадает с этим сервером!"
        err "Это создаст петлю. Нужен VLESS на ДРУГОМ сервере."
        return 1
    fi
    return 0
}

# ─── Хелпер: проверка что порт 80 свободен (для certbot ACME) ──────────────
check_port_80_free() {
    if ! ss -tlnp 2>/dev/null | grep -qE ':80\s'; then
        return 0
    fi
    local listener; listener=$(ss -tlnp 2>/dev/null | grep -E ':80\s' | grep -oE 'users:\(\("[^"]+' | head -1 | cut -d'"' -f2)
    if [[ "$listener" == "nginx" ]]; then
        return 0  # nginx уже запущен — это нормально
    fi
    err "Порт 80 занят процессом: ${listener:-unknown}"
    err "certbot ACME challenge не сможет работать. Освободите порт 80."
    return 1
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
# ─── Выбор сценария: Стандарт / Свой сайт ──────────────────────────────────
select_scenario() {
    INSTALL_SCENARIO="standard"  # стандарт по умолчанию

    echo ""
    echo -e "  ${BOLD}${CYAN}Что устанавливать?${RESET}"
    echo ""
    echo -e "  ${BOLD}1.${RESET} ${BOLD}Стандартная установка${RESET}"
    echo -e "      MTProxy на нескольких портах (443/5223/8530) с маскировкой под SNI."
    echo -e "      ${DIM}UFW, keepalive, BBR, nft, VLESS upstream, свой домен в ссылке.${RESET}"
    echo ""
    echo -e "  ${BOLD}2.${RESET} ${BOLD}Свой сайт${RESET} ${DIM}(домен с заглушкой + MTProxy на 443)${RESET}"
    echo -e "      Поднимает реальный сайт через nginx + Let's Encrypt на порту 8443,"
    echo -e "      MTProxy слушает 443. В ссылке клиента — домен сайта."
    echo ""
    local ch
    while true; do
        read -rp "$(echo -e "  ${YELLOW}?${RESET} Сценарий [1/2]: ")" ch
        case "$ch" in
            1|"") INSTALL_SCENARIO="standard"; ok "Сценарий: Стандартная установка"; break ;;
            2)    INSTALL_SCENARIO="site";     ok "Сценарий: Свой сайт";              break ;;
            0|q)  echo -e "${YELLOW}Отменено.${RESET}"; exit 0 ;;
            *)    warn "Введите 1, 2 или 0" ;;
        esac
    done
    echo ""
}

# ─── Запрос параметров сайта (для сценария site) ────────────────────────────
ask_site_details() {
    SITE_DOMAIN=""
    SITE_EMAIL=""
    SITE_TEMPLATE_URL="https://github.com/vaalaav/Market-Terminal-Template"
    SITE_PORT="8443"   # фиксированный порт для сайта

    echo ""
    hdr "Настройка сайта-заглушки"
    echo ""
    echo -e "  Сайт будет на ${BOLD}${SITE_PORT}${RESET} порту, MTProxy остаётся на ${BOLD}443${RESET}."
    echo -e "  ${DIM}Требование: A-запись домен → IP этого сервера должна быть настроена.${RESET}"
    echo ""

    # 1) Домен с проверкой DNS
    local server_ip resolved_ip
    server_ip=$(get_public_ip)
    [[ -n "$server_ip" ]] && info "IP этого сервера: ${BOLD}${server_ip}${RESET}"
    echo ""

    while true; do
        read -rp "  Домен для сайта (например site.example.com): " SITE_DOMAIN
        if [[ -z "$SITE_DOMAIN" ]]; then
            warn "Домен обязателен"; continue
        fi
        if [[ "$SITE_DOMAIN" != *.* ]]; then
            warn "Введите корректное FQDN (с точкой), например proxy.example.com"; continue
        fi

        # Проверка A-записи
        info "Проверка DNS (резолв $SITE_DOMAIN)..."
        resolved_ip=$(getent hosts "$SITE_DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
        if [[ -z "$resolved_ip" ]]; then
            err "Домен не резолвится. Настройте A-запись и подождите пока DNS обновится."
            read -rp "  Попробовать ещё раз? [Y/n]: " r
            [[ "${r,,}" =~ ^(n|no)$ ]] && { err "Установка прервана"; exit 1; }
            continue
        fi
        if [[ -n "$server_ip" && "$resolved_ip" != "$server_ip" ]]; then
            err "DNS-несовпадение: $SITE_DOMAIN → $resolved_ip, IP сервера → $server_ip"
            warn "certbot не сможет выпустить сертификат — установка прервана"
            read -rp "  Попробовать другой домен? [Y/n]: " r
            [[ "${r,,}" =~ ^(n|no)$ ]] && { err "Установка прервана"; exit 1; }
            continue
        fi
        ok "DNS корректен: $SITE_DOMAIN → $resolved_ip"
        break
    done

    # 2) Email для Let's Encrypt
    echo ""
    while true; do
        read -rp "  Email для Let's Encrypt (для уведомлений об истечении): " SITE_EMAIL
        if [[ "$SITE_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
            ok "Email: $SITE_EMAIL"
            break
        fi
        warn "Введите корректный email (например you@example.com)"
    done

    # 3) Шаблон сайта
    echo ""
    echo -e "  ${BOLD}Шаблон сайта:${RESET}"
    echo -e "  ${GREEN}1${RESET} — ${BOLD}vaalaav/Market-Terminal-Template${RESET} ${DIM}(по умолчанию)${RESET}"
    echo -e "  ${GREEN}2${RESET} — другой GitHub-репозиторий"
    local tch
    while true; do
        read -rp "  Выбор [1/2]: " tch
        case "$tch" in
            1|"") SITE_TEMPLATE_URL="https://github.com/vaalaav/Market-Terminal-Template"; break ;;
            2)
                while true; do
                    read -rp "  URL GitHub-репозитория: " SITE_TEMPLATE_URL
                    if [[ "$SITE_TEMPLATE_URL" =~ ^https://github\.com/[^/]+/[^/]+/?$ ]]; then
                        break
                    fi
                    warn "Формат: https://github.com/user/repo"
                done
                break
                ;;
            *) warn "1 или 2" ;;
        esac
    done
    ok "Шаблон: $SITE_TEMPLATE_URL"

    # Фиксируем параметры инстанса telemt для сценария site:
    # один инстанс на 443, домен совпадает с реальным сайтом
    INSTANCES=(1)
    CUSTOM_PORTS[1]=443
    CUSTOM_DOMAINS[1]="$SITE_DOMAIN"
    CUSTOM_APIS[1]=9091
    info "Сценарий site: создаётся 1 инстанс telemt на порту 443 с tls_domain=$SITE_DOMAIN"
}

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
    # В сценарии 'site' инстансы уже зафиксированы в ask_site_details (1 шт. на 443)
    if [[ "${INSTALL_SCENARIO:-standard}" == "site" ]]; then
        echo ""
        info "Сценарий 'Свой сайт': инстанс telemt автоматически создаётся на порту 443"
        info "с tls_domain=${SITE_DOMAIN} (для совпадения с доменом сайта)"
    else
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
    fi   # конец else блока для INSTALL_SCENARIO != site

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

    # --- client_mss = "tspu" — обход ТСПУ (специфично для РФ) ---
    echo ""
    echo -e "  ${BOLD}Обход ТСПУ (client_mss = \"tspu\")${RESET}"
    echo -e "  Адаптирует MSS под фильтрацию ТСПУ (Технические Средства Противодействия Угрозам)."
    echo -e "  ${DIM}Нужно если сервер в РФ или провайдер фильтрует MTProxy через MSS.${RESET}"
    echo -e "  ${DIM}Если сервер вне РФ и нет проблем с подключением — можно отключить.${RESET}"
    USE_TSPU=true
    read -rp "$(echo -e "${YELLOW}?${RESET} Включить client_mss=\"tspu\"? [Y/n]: ")" ans
    [[ "${ans,,}" =~ ^(n|no|н|нет)$ ]] && USE_TSPU=false

    # --- Свой домен вместо IP в ссылке для клиента ---
    if [[ "${INSTALL_SCENARIO:-standard}" == "site" ]]; then
        # В сценарии site домен берётся из SITE_DOMAIN автоматически
        USE_CUSTOM_DOMAIN=true
        CUSTOM_LINK_DOMAIN="${SITE_DOMAIN:-}"
        mkdir -p /etc/telemt
        if [[ -n "$CUSTOM_LINK_DOMAIN" ]]; then
            echo "$CUSTOM_LINK_DOMAIN" > /etc/telemt/.custom_domain
            chmod 644 /etc/telemt/.custom_domain
            info "В ссылках клиентов будет домен сайта: ${BOLD}${CUSTOM_LINK_DOMAIN}${RESET}"
        fi
    else
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
    fi

    # --- VLESS Reality upstream для Telegram DC ---
    echo ""
    echo -e "  ${BOLD}VLESS Reality upstream${RESET} ${DIM}(туннель через ваш 3x-ui сервер)${RESET}"
    echo -e "  Заворачивает трафик ${BOLD}telemt → Telegram DC${RESET} через VLESS Reality."
    echo -e "  Клиенты подключаются к серверу ${BOLD}напрямую${RESET}, дальше идёт через VLESS."
    echo -e "  ${DIM}Реализация: xray-core поднимает локальный SOCKS5 на 127.0.0.1:40000,${RESET}"
    echo -e "  ${DIM}telemt идёт через него как [[upstreams]].${RESET}"
    DO_VLESS=false
    VLESS_LINK=""
    VLESS_TYPE=""           # "single" — одна vless ссылка / "subscription" — URL подписки 3x-ui
    VLESS_STRATEGY="leastPing"  # для подписок: leastPing | random | roundRobin
    VLESS_AUTO_REFRESH=true     # для подписок: автообновление раз в 6 часов
    read -rp "$(echo -e "${YELLOW}?${RESET} Использовать VLESS Reality upstream? [y/N]: ")" ans
    if [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]; then
        echo ""
        echo -e "  ${BOLD}Тип подключения:${RESET}"
        echo -e "  ${GREEN}1${RESET} — одна ${BOLD}vless://${RESET} ссылка (один сервер)"
        echo -e "  ${GREEN}2${RESET} — ${BOLD}подписка${RESET} 3x-ui (https://..., несколько серверов с балансировкой)"
        local link_type
        while true; do
            read -rp "$(echo -e "  ${YELLOW}?${RESET} Тип [1/2]: ")" link_type
            [[ "$link_type" == "1" || "$link_type" == "2" ]] && break
            warn "Введите 1 или 2"
        done

        if [[ "$link_type" == "1" ]]; then
            VLESS_TYPE="single"
            echo ""
            echo -e "  ${DIM}Вставьте полную vless:// ссылку:${RESET}"
            echo -e "  ${DIM}vless://uuid@server:443?security=reality&pbk=...&sni=...${RESET}"
            while true; do
                read -rp "  vless:// ссылка: " VLESS_LINK
                if [[ "$VLESS_LINK" == vless://*@*:*\?* ]] && [[ "$VLESS_LINK" == *security=reality* ]] \
                   && [[ "$VLESS_LINK" == *pbk=* ]] && [[ "$VLESS_LINK" == *sni=* ]]; then
                    if VL="$VLESS_LINK" python3 -c "import os,urllib.parse as up,sys;p=up.urlparse(os.environ['VL']);q=up.parse_qs(p.query);sys.exit(0 if (p.username and p.hostname and p.port and 'pbk' in q and 'sni' in q) else 1)" 2>/dev/null; then
                        # Защита от петли
                        if ! check_vless_not_self "$VLESS_LINK"; then
                            VLESS_LINK=""
                            read -rp "  Попробовать другую ссылку? [Y/n]: " retry
                            [[ "${retry,,}" =~ ^(n|no)$ ]] && { DO_VLESS=false; break; }
                            continue
                        fi
                        DO_VLESS=true
                        ok "VLESS ссылка принята (Reality)"
                        break
                    else
                        warn "Не удалось разобрать ссылку"
                    fi
                else
                    warn "Формат: vless://uuid@server:port?security=reality&pbk=...&sni=..."
                fi
                read -rp "  Попробовать ещё раз? [Y/n]: " retry
                if [[ "${retry,,}" =~ ^(n|no)$ ]]; then
                    DO_VLESS=false
                    VLESS_LINK=""
                    break
                fi
            done
        else
            VLESS_TYPE="subscription"
            echo ""
            echo -e "  ${DIM}Подписка 3x-ui — обычно HTTPS-URL вида:${RESET}"
            echo -e "  ${DIM}https://your-server:2096/path/subscription_id${RESET}"
            echo -e "  ${DIM}3x-ui отдаёт base64-кодированный список vless:// ссылок.${RESET}"
            while true; do
                read -rp "  URL подписки: " VLESS_LINK
                if [[ "$VLESS_LINK" =~ ^https?:// ]]; then
                    # Пробуем скачать и распарсить
                    info "Получение и парсинг подписки..."
                    local parse_out
                    parse_out=$(SUB_URL="$VLESS_LINK" python3 << 'PYTEST'
import os, sys, urllib.request, base64, ssl, urllib.parse as up
url = os.environ['SUB_URL']
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    req = urllib.request.Request(url, headers={'User-Agent': 'v2rayN/6.0'})
    with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
        data = r.read().decode('utf-8', errors='ignore').strip()
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
decoded = data
try:
    pad = '=' * (-len(data) % 4)
    decoded = base64.b64decode(data + pad).decode('utf-8', errors='ignore')
except Exception:
    pass
nodes = [ln.strip() for ln in decoded.split('\n') if ln.strip().startswith('vless://') and 'security=reality' in ln]
if not nodes:
    print("ERROR: VLESS Reality узлы не найдены в подписке", file=sys.stderr)
    sys.exit(2)
# Первая строка — кол-во узлов. Дальше — host:port каждого
print(len(nodes))
for n in nodes:
    p = up.urlparse(n)
    print(f"{p.hostname}:{p.port or 443}")
PYTEST
)
                    local nodes_count; nodes_count=$(echo "$parse_out" | head -1)
                    if [[ -n "$nodes_count" && "$nodes_count" =~ ^[0-9]+$ ]]; then
                        # Проверяем каждый узел на петлю
                        local our_ip; our_ip=$(get_public_ip_cached)
                        local loop_host=""
                        if [[ -n "$our_ip" ]]; then
                            while IFS= read -r hostline; do
                                [[ -z "$hostline" ]] && continue
                                local h="${hostline%:*}"
                                local hip; hip=$(getent hosts "$h" 2>/dev/null | awk '{print $1}' | head -1)
                                if [[ -n "$hip" && "$hip" == "$our_ip" ]]; then
                                    loop_host="$hostline"; break
                                fi
                            done < <(echo "$parse_out" | tail -n +2)
                        fi
                        if [[ -n "$loop_host" ]]; then
                            err "В подписке найден узел ${loop_host} с IP этого сервера — петля!"
                            err "Уберите этот узел из 3x-ui и попробуйте снова."
                            read -rp "  Попробовать другой URL? [Y/n]: " retry
                            if [[ "${retry,,}" =~ ^(n|no)$ ]]; then
                                DO_VLESS=false; VLESS_LINK=""; VLESS_TYPE=""
                                break
                            fi
                            continue
                        fi
                        DO_VLESS=true
                        ok "Подписка работает: найдено ${BOLD}${nodes_count}${RESET} VLESS Reality узлов"
                        break
                    else
                        warn "Не удалось извлечь узлы из подписки. Проверь URL и что 3x-ui отдаёт base64-формат"
                    fi
                else
                    warn "URL должен начинаться с http:// или https://"
                fi
                read -rp "  Попробовать ещё раз? [Y/n]: " retry
                if [[ "${retry,,}" =~ ^(n|no)$ ]]; then
                    DO_VLESS=false
                    VLESS_LINK=""
                    VLESS_TYPE=""
                    break
                fi
            done

            if [[ "$DO_VLESS" == true ]]; then
                # Стратегия балансировки
                echo ""
                echo -e "  ${BOLD}Стратегия балансировки между узлами:${RESET}"
                echo -e "  ${GREEN}1${RESET} — ${BOLD}leastPing${RESET} — автоматически выбирает самый быстрый ${DIM}(рекомендуется)${RESET}"
                echo -e "  ${GREEN}2${RESET} — ${BOLD}roundRobin${RESET} — по очереди по всем"
                echo -e "  ${GREEN}3${RESET} — ${BOLD}random${RESET} — случайно для каждого соединения"
                while true; do
                    read -rp "$(echo -e "  ${YELLOW}?${RESET} Стратегия [1/2/3]: ")" str
                    case "$str" in
                        1|"") VLESS_STRATEGY="leastPing"; break ;;
                        2)    VLESS_STRATEGY="roundRobin"; break ;;
                        3)    VLESS_STRATEGY="random"; break ;;
                        *)    warn "Введите 1, 2 или 3" ;;
                    esac
                done
                ok "Стратегия: $VLESS_STRATEGY"

                # Автообновление подписки
                echo ""
                read -rp "$(echo -e "  ${YELLOW}?${RESET} Авто-обновление подписки каждые 6 часов? [Y/n]: ")" auto
                if [[ "${auto,,}" =~ ^(n|no)$ ]]; then
                    VLESS_AUTO_REFRESH=false
                fi
                ok "Авто-обновление: $VLESS_AUTO_REFRESH"
            fi
        fi
    fi

    # --- Web-панель telemt_panel ---
    echo ""
    echo -e "  ${BOLD}Web-панель управления (telemt_panel)${RESET}"
    echo -e "  Мониторинг, управление пользователями, обновления — через браузер."
    echo -e "  ${DIM}Панель слушает порт ${PANEL_PORT:-8080}, подключается к API первого инстанса.${RESET}"
    DO_PANEL=false
    PANEL_ADMIN_PASS=""
    read -rp "$(echo -e "${YELLOW}?${RESET} Установить web-панель? [y/N]: ")" ans
    if [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]; then
        DO_PANEL=true
        read -rp "$(echo -e "  ${YELLOW}?${RESET} Логин администратора [${PANEL_ADMIN_USER:-admin}]: ")" inp_user
        [[ -n "$inp_user" ]] && PANEL_ADMIN_USER="$inp_user"
        while true; do
            read -rsp "$(echo -e "  ${YELLOW}?${RESET} Пароль администратора: ")" PANEL_ADMIN_PASS
            echo
            if [[ -n "$PANEL_ADMIN_PASS" ]]; then break; fi
            warn "Пароль не может быть пустым"
        done
        ok "Панель: логин=${BOLD}${PANEL_ADMIN_USER}${RESET}, порт=${BOLD}${PANEL_PORT:-8080}${RESET}"
    fi
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
        # client_mss = "tspu" — комментируем если отключено
        local tspu_line='client_mss = "tspu"'
        [[ "${USE_TSPU:-true}" == false ]] && tspu_line='#client_mss = "tspu"   # отключено: обход ТСПУ (РФ-фильтрация)'
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
${tspu_line}

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

        # Опциональный upstream через VLESS Reality SOCKS5 на 127.0.0.1:40000
        if [[ "${DO_VLESS:-false}" == true ]]; then
            cat >> "/etc/telemt/telemt${n}.toml" << TOMLVLESS

[[upstreams]]
type = "socks5"
address = "127.0.0.1:40000"
weight = 1
enabled = true
TOMLVLESS
            info "Добавлен upstream через VLESS Reality (SOCKS5 127.0.0.1:40000)"
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

    # В сценарии site открываем 80 (ACME) и SITE_PORT (сайт)
    if [[ "${INSTALL_SCENARIO:-standard}" == "site" ]]; then
        ufw allow 80/tcp
        ok "Порт 80 открыт (Let's Encrypt ACME)"
        ufw allow "${SITE_PORT:-8443}/tcp"
        ok "Порт ${SITE_PORT:-8443} открыт (сайт-заглушка)"
    fi

    # Web-панель
    if [[ "${DO_PANEL:-false}" == true ]]; then
        ufw allow "${PANEL_PORT:-8080}/tcp"
        ok "Порт ${PANEL_PORT:-8080} открыт (web-панель)"
    fi

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


# ─── ШАГ: Установка VLESS Reality upstream ──────────────────────────────────
# Поддерживает: одну vless:// ссылку ИЛИ подписку 3x-ui (https://...) с балансировкой
step_vless() {
    [[ "${DO_VLESS:-false}" != true ]] && return 0
    hdr "Установка VLESS Reality (xray-core)"

    echo ""
    if [[ "$VLESS_TYPE" == "subscription" ]]; then
        info "Тип: подписка 3x-ui (балансировка по стратегии $VLESS_STRATEGY)"
    else
        info "Тип: одна VLESS Reality ссылка"
    fi
    info "Архитектура: xray → SOCKS5 127.0.0.1:40000 → VLESS → Telegram DC."
    echo ""
    confirm "Установить?" skip || return 0

    # 1) Скачиваем xray-core бинарник
    if [[ ! -f /usr/local/bin/xray ]]; then
        info "Скачивание xray-core..."
        local arch xray_arch xray_version xray_url
        arch=$(uname -m)
        case "$arch" in
            x86_64) xray_arch="64" ;;
            aarch64|arm64) xray_arch="arm64-v8a" ;;
            armv7l) xray_arch="arm32-v7a" ;;
            *) xray_arch="64" ;;
        esac
        xray_version=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep tag_name | cut -d '"' -f 4)
        if [[ -z "$xray_version" ]]; then
            err "Не удалось определить версию xray-core"
            DO_VLESS=false
            return 0
        fi
        xray_url="https://github.com/XTLS/Xray-core/releases/download/${xray_version}/Xray-linux-${xray_arch}.zip"
        info "Версия: ${BOLD}${xray_version}${RESET} (${xray_arch})"

        wait_apt
        apt-get install -y unzip curl >/dev/null 2>&1
        cd /tmp
        if ! curl -fsSL --max-time 120 -o /tmp/xray.zip "$xray_url"; then
            err "Не удалось скачать xray-core"
            DO_VLESS=false
            cd - >/dev/null 2>&1 || true
            return 0
        fi
        unzip -o -q /tmp/xray.zip -d /tmp/xray-extract >/dev/null
        mv /tmp/xray-extract/xray /usr/local/bin/xray
        chmod +x /usr/local/bin/xray
        rm -rf /tmp/xray.zip /tmp/xray-extract
        ok "xray-core $(/usr/local/bin/xray version 2>&1 | head -1 | awk '{print $2}') установлен"
    else
        ok "xray-core уже установлен"
    fi

    # 2) Создаём пользователя xray для запуска сервиса
    if ! id xray &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --no-create-home --user-group xray 2>/dev/null \
        || useradd --system --shell /usr/sbin/nologin --no-create-home xray 2>/dev/null || true
        ok "Создан системный пользователь xray"
    fi

    # 3) Готовим директорию + сохраняем ссылку/URL
    mkdir -p /etc/telemt-vless
    echo "$VLESS_LINK" > /etc/telemt-vless/link.txt
    echo "$VLESS_TYPE" > /etc/telemt-vless/type.txt
    if [[ "$VLESS_TYPE" == "subscription" ]]; then
        echo "$VLESS_STRATEGY" > /etc/telemt-vless/strategy.txt
    fi

    # 4) Устанавливаем helper-скрипт для генерации конфига xray
    info "Установка генератора конфига..."
    install_xray_config_generator
    ok "Генератор установлен: /usr/local/sbin/telemt-vless-refresh"

    # 5) Первичная генерация конфига
    info "Генерация конфига xray..."
    if ! /usr/local/sbin/telemt-vless-refresh; then
        err "Не удалось сгенерировать конфиг"
        DO_VLESS=false
        return 0
    fi

    # 6) Валидация
    if /usr/local/bin/xray -test -config /etc/telemt-vless/config.json 2>&1 | grep -q "Configuration OK"; then
        ok "Конфиг xray валиден"
    else
        warn "xray -test не прошёл, но продолжаем"
    fi

    # 7) systemd-сервис
    cat > /etc/systemd/system/telemt-vless.service << 'SVC'
[Unit]
Description=xray-core VLESS Reality client (telemt SOCKS5 upstream)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -config /etc/telemt-vless/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/telemt-vless

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable --now telemt-vless 2>&1 | grep -v "Created symlink" || true
    sleep 3

    # 8) Авто-обновление подписки (только для типа subscription)
    if [[ "$VLESS_TYPE" == "subscription" && "$VLESS_AUTO_REFRESH" == true ]]; then
        info "Настройка автообновления подписки (каждые 6 часов)..."
        install_xray_refresh_timer
        ok "Авто-обновление включено: telemt-vless-refresh.timer"
    fi

    # 9) Проверка статуса
    if systemctl is-active --quiet telemt-vless; then
        ok "Сервис telemt-vless запущен"
    else
        err "telemt-vless не запустился"
        warn "Логи: journalctl -u telemt-vless -n 30"
        DO_VLESS=false
        return 0
    fi

    if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:40000"; then
        ok "SOCKS5 слушает на 127.0.0.1:40000"
    else
        warn "Порт 40000 не слушается"
    fi

    # 10) Тест: какой IP виден через VLESS
    info "Тест: какой IP виден через VLESS-туннель?"
    local direct_ip vless_ip
    direct_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    vless_ip=$(curl -s --max-time 10 --socks5 127.0.0.1:40000 https://api.ipify.org 2>/dev/null)
    [[ -n "$direct_ip" ]] && info "Прямой IP сервера: ${BOLD}${direct_ip}${RESET}"
    if [[ -n "$vless_ip" ]]; then
        ok "Через VLESS виден IP: ${BOLD}${vless_ip}${RESET}"
        if [[ "$direct_ip" == "$vless_ip" ]]; then
            warn "IP одинаковые — туннель может не работать"
        fi
    else
        warn "Тест не прошёл — проверьте позже: journalctl -u telemt-vless -n 50"
    fi
}

# ─── Установка генератора конфига xray ──────────────────────────────────────
# Создаёт /usr/local/sbin/telemt-vless-refresh — самостоятельный скрипт,
# который читает /etc/telemt-vless/link.txt и type.txt, генерит config.json,
# проверяет валидность и перезагружает сервис.
install_xray_config_generator() {
    cat > /usr/local/sbin/telemt-vless-refresh << 'GENEOF'
#!/usr/bin/env bash
# telemt-vless-refresh — генератор конфига xray из vless:// ссылки или 3x-ui подписки
set -uo pipefail

LINK_FILE="/etc/telemt-vless/link.txt"
TYPE_FILE="/etc/telemt-vless/type.txt"
STRATEGY_FILE="/etc/telemt-vless/strategy.txt"
CONFIG_FILE="/etc/telemt-vless/config.json"
NODES_FILE="/etc/telemt-vless/nodes.txt"  # последний скачанный список (для diff)

[[ ! -f "$LINK_FILE" ]] && { echo "ERROR: $LINK_FILE не существует"; exit 1; }
[[ ! -f "$TYPE_FILE" ]] && echo "single" > "$TYPE_FILE"
LINK=$(cat "$LINK_FILE")
TYPE=$(cat "$TYPE_FILE")
STRATEGY=$(cat "$STRATEGY_FILE" 2>/dev/null || echo "leastPing")

LINK="$LINK" TYPE="$TYPE" STRATEGY="$STRATEGY" CONFIG_FILE="$CONFIG_FILE" NODES_FILE="$NODES_FILE" python3 << 'PYGEN'
import os, json, sys, urllib.request, urllib.parse as up, base64, ssl

link = os.environ["LINK"].strip()
typ = os.environ["TYPE"].strip()
strategy = os.environ["STRATEGY"].strip() or "leastPing"
cfg_path = os.environ["CONFIG_FILE"]
nodes_path = os.environ["NODES_FILE"]

def parse_vless(url):
    p = up.urlparse(url)
    q = {k: v[0] for k, v in up.parse_qs(p.query).items()}
    if not (p.username and p.hostname and p.port and "pbk" in q and "sni" in q):
        return None
    name = up.unquote(p.fragment) if p.fragment else f"{p.hostname}:{p.port}"
    return {
        "name": name,
        "host": p.hostname, "port": p.port or 443,
        "uuid": p.username,
        "flow": q.get("flow", ""),
        "network": q.get("type", "tcp"),
        "fp": q.get("fp", "chrome"),
        "sni": q.get("sni", ""),
        "pbk": q.get("pbk", ""),
        "sid": q.get("sid", ""),
        "spx": q.get("spx", "/"),
    }

# Собираем список узлов
nodes = []
if typ == "subscription":
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        req = urllib.request.Request(link, headers={"User-Agent": "v2rayN/6.0"})
        with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
            data = r.read().decode("utf-8", errors="ignore").strip()
    except Exception as e:
        print(f"ERROR: подписка недоступна: {e}", file=sys.stderr)
        sys.exit(2)
    decoded = data
    try:
        pad = "=" * (-len(data) % 4)
        decoded = base64.b64decode(data + pad).decode("utf-8", errors="ignore")
    except Exception:
        pass
    for ln in decoded.split("\n"):
        ln = ln.strip()
        if not ln.startswith("vless://") or "security=reality" not in ln:
            continue
        n = parse_vless(ln)
        if n:
            nodes.append(n)
    if not nodes:
        print("ERROR: VLESS Reality узлы не найдены", file=sys.stderr)
        sys.exit(3)
else:
    n = parse_vless(link)
    if not n:
        print("ERROR: не удалось распарсить ссылку", file=sys.stderr)
        sys.exit(4)
    nodes.append(n)

def make_outbound(idx, n):
    out = {
        "tag": f"node-{idx}",
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": n["host"], "port": n["port"],
                "users": [{"id": n["uuid"], "encryption": "none"}]
            }]
        },
        "streamSettings": {
            "network": n["network"],
            "security": "reality",
            "realitySettings": {
                "show": False,
                "fingerprint": n["fp"] or "chrome",
                "serverName": n["sni"],
                "publicKey": n["pbk"],
                "shortId": n["sid"],
                "spiderX": n["spx"]
            }
        }
    }
    if n["flow"]:
        out["settings"]["vnext"][0]["users"][0]["flow"] = n["flow"]
    return out

cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "tag": "socks-in",
        "listen": "127.0.0.1",
        "port": 40000,
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": True, "ip": "127.0.0.1"},
        "sniffing": {"enabled": False}
    }],
    "outbounds": [make_outbound(i+1, n) for i, n in enumerate(nodes)] + [{"tag": "direct", "protocol": "freedom"}],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": []
    }
}

if len(nodes) > 1:
    # Балансер на все node-* outbound'ы
    cfg["routing"]["balancers"] = [{
        "tag": "balancer-vless",
        "selector": ["node-"],
        "strategy": {"type": strategy if strategy != "leastPing" else "leastPing"}
    }]
    cfg["routing"]["rules"].append({
        "type": "field",
        "inboundTag": ["socks-in"],
        "balancerTag": "balancer-vless"
    })
    # Для leastPing нужен observatory
    if strategy == "leastPing":
        cfg["observatory"] = {
            "subjectSelector": ["node-"],
            "probeUrl": "https://www.google.com/gen_204",
            "probeInterval": "300s"
        }
else:
    cfg["routing"]["rules"].append({
        "type": "field",
        "inboundTag": ["socks-in"],
        "outboundTag": "node-1"
    })

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)

# Сохраняем список узлов для diff
with open(nodes_path, "w") as f:
    for n in nodes:
        f.write(f"{n['name']}\t{n['host']}:{n['port']}\n")

if len(nodes) > 1:
    print(f"OK: {len(nodes)} узлов, стратегия={strategy}", file=sys.stderr)
else:
    print(f"OK: 1 узел (балансировка не активна)", file=sys.stderr)
PYGEN
GEN_RC=$?
[[ $GEN_RC -ne 0 ]] && exit $GEN_RC

# Применяем права (xray должен читать)
if ! id xray &>/dev/null; then
    useradd --system --shell /usr/sbin/nologin --no-create-home --user-group xray 2>/dev/null     || useradd --system --shell /usr/sbin/nologin --no-create-home xray 2>/dev/null || true
fi
chown -R xray:xray /etc/telemt-vless 2>/dev/null || chown -R root:root /etc/telemt-vless
chmod 750 /etc/telemt-vless
chmod 640 "$CONFIG_FILE" "$LINK_FILE" 2>/dev/null || true
chmod 644 "$TYPE_FILE" "$STRATEGY_FILE" "$NODES_FILE" 2>/dev/null || true

# Валидация и рестарт
if ! /usr/local/bin/xray -test -config "$CONFIG_FILE" 2>&1 | grep -q "Configuration OK"; then
    echo "WARN: xray -test не прошёл"
fi

# Если сервис уже запущен — рестартим
if systemctl is-active --quiet telemt-vless 2>/dev/null; then
    systemctl restart telemt-vless
fi

echo "OK: конфиг обновлён" >&2
exit 0
GENEOF
    chmod +x /usr/local/sbin/telemt-vless-refresh
}

# ─── Установка systemd timer для авто-обновления подписки ───────────────────
install_xray_refresh_timer() {
    cat > /etc/systemd/system/telemt-vless-refresh.service << 'RUNIT'
[Unit]
Description=Refresh telemt VLESS subscription from 3x-ui
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/telemt-vless-refresh
RUNIT

    cat > /etc/systemd/system/telemt-vless-refresh.timer << 'TUNIT'
[Unit]
Description=Refresh VLESS subscription every 6 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
TUNIT
    systemctl daemon-reload
    systemctl enable --now telemt-vless-refresh.timer 2>&1 | grep -v "Created symlink" || true
}

# ═════════════════════════════════════════════════════════════════════════════
# Сайт-заглушка (для сценария INSTALL_SCENARIO=site)
# ═════════════════════════════════════════════════════════════════════════════

# Шаг: установка nginx, certbot, git
step_install_site_deps() {
    hdr "Сайт: установка nginx + certbot + git"
    confirm "Установить?" skip || return 0

    wait_apt
    if ! apt-get install -y nginx certbot python3-certbot-nginx git curl 2>&1 | tail -3; then
        err "Не удалось установить зависимости — пропуск сайта"
        return 1
    fi
    ok "nginx + certbot + git установлены"
    systemctl enable --now nginx 2>&1 | grep -v "Created symlink" || true
    ok "nginx запущен"
}

# Шаг: клонирование шаблона из GitHub
step_clone_site_template() {
    hdr "Сайт: клонирование шаблона"
    info "Шаблон: ${BOLD}${SITE_TEMPLATE_URL}${RESET}"
    confirm "Клонировать в /var/www/telemt-site?" skip || return 0

    # Чистим старое если есть
    if [[ -d /var/www/telemt-site ]]; then
        warn "Старая директория /var/www/telemt-site существует — будет заменена"
        rm -rf /var/www/telemt-site
    fi
    mkdir -p /var/www

    if ! git clone --depth 1 "$SITE_TEMPLATE_URL" /var/www/telemt-site 2>&1; then
        err "Не удалось клонировать шаблон"
        # Резерв: ставим простую страницу-заглушку
        mkdir -p /var/www/telemt-site
        cat > /var/www/telemt-site/index.html << 'HTMLFB'
<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Сайт в разработке</title>
<style>body{font-family:sans-serif;text-align:center;padding:3em;background:#f4f4f4;color:#333}</style>
</head><body><h1>Сайт в разработке</h1><p>Coming soon.</p></body></html>
HTMLFB
        warn "Создана резервная заглушка"
    else
        ok "Шаблон склонирован: $(ls /var/www/telemt-site | head -5 | tr '\\n' ' ')..."
    fi

    chown -R www-data:www-data /var/www/telemt-site
    chmod -R o+rX /var/www/telemt-site
}

# Шаг: настройка nginx (HTTP для ACME + HTTPS-сайт на 8443)
step_setup_nginx() {
    hdr "Сайт: настройка nginx (HTTP для ACME + HTTPS на ${SITE_PORT})"
    confirm "Создать конфиг nginx?" skip || return 0

    # Проверяем что порт 80 не занят чужим процессом (нужен для ACME challenge)
    if ! check_port_80_free; then
        warn "Установка сайта прервана. Сценарий 'Свой сайт' не может продолжаться без 80 порта."
        warn "После освобождения порта 80 запустите: sudo mytelemtinfo → 8 → 1 (установить сайт)"
        SITE_SETUP_FAILED=true
        return 1
    fi

    mkdir -p /var/www/letsencrypt

    # HTTP-блок (для certbot ACME challenge); основной HTTPS-блок создадим ПОСЛЕ certbot
    cat > /etc/nginx/sites-available/telemt-site.conf << NGINX
# Сайт-заглушка telemt-install
# HTTP-блок — только для Let's Encrypt ACME challenge

server {
    listen 80;
    listen [::]:80;
    server_name ${SITE_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
    }
    location / {
        return 444;   # тихо обрываем любые другие запросы по HTTP
    }
}
NGINX

    # Включаем
    ln -sf /etc/nginx/sites-available/telemt-site.conf /etc/nginx/sites-enabled/telemt-site.conf

    # Убираем default site чтобы не было конфликта
    rm -f /etc/nginx/sites-enabled/default

    if ! nginx -t 2>&1 | tail -3; then
        err "nginx -t не прошёл"
        return 1
    fi
    systemctl reload nginx
    ok "nginx настроен (HTTP-блок для ACME)"
}

# Шаг: получение сертификата Let's Encrypt через webroot
step_get_certbot_cert() {
    hdr "Сайт: получение сертификата Let's Encrypt"
    confirm "Запустить certbot?" skip || return 0

    if [[ -z "${SITE_DOMAIN:-}" || -z "${SITE_EMAIL:-}" ]]; then
        err "Не заданы SITE_DOMAIN или SITE_EMAIL"
        return 1
    fi

    info "Запрос сертификата для $SITE_DOMAIN..."
    if ! certbot certonly --webroot -w /var/www/letsencrypt \
        -d "$SITE_DOMAIN" --email "$SITE_EMAIL" \
        --agree-tos --non-interactive --no-eff-email 2>&1 | tail -10; then
        err "certbot не смог выпустить сертификат для $SITE_DOMAIN"
        warn "Возможные причины:"
        warn "  1) DNS A-запись $SITE_DOMAIN ещё не пропагировалась"
        warn "  2) Порт 80 заблокирован UFW/iptables или другим хостом по дороге"
        warn "  3) Достигнут rate-limit Let's Encrypt (5 неудач за час)"
        echo ""
        warn "Откатываем nginx-конфиг сайта (HTTP-блок останется для повторной попытки)..."
        # Не удаляем nginx-конфиг полностью — он нужен для повторной попытки
        # Но помечаем что установка сайта провалилась
        SITE_SETUP_FAILED=true
        return 1
    fi

    ok "Сертификат получен: /etc/letsencrypt/live/$SITE_DOMAIN/"

    # Теперь добавляем HTTPS-блок на $SITE_PORT
    cat > /etc/nginx/sites-available/telemt-site.conf << NGINX
# Сайт-заглушка telemt-install
server {
    listen 80;
    listen [::]:80;
    server_name ${SITE_DOMAIN};
    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
    }
    location / { return 444; }
}

server {
    listen ${SITE_PORT} ssl http2;
    listen [::]:${SITE_PORT} ssl http2;
    server_name ${SITE_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/telemt-site;
    index index.html index.htm;

    server_tokens off;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX

    if ! nginx -t 2>&1 | tail -3; then
        err "nginx -t (с HTTPS) не прошёл"
        SITE_SETUP_FAILED=true
        return 1
    fi
    systemctl restart nginx
    ok "nginx переключён на HTTPS на порту ${SITE_PORT}"

    # Deploy-hook: после renewal сертификата перезагружаем nginx,
    # чтобы он подхватил новые ssl-файлы в памяти
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/bin/sh
# Авто-reload nginx после обновления сертификата certbot
systemctl reload nginx 2>/dev/null || true
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    ok "Deploy-hook установлен (nginx будет reload'иться после каждого renewal)"

    # Автообновление сертификата — certbot ставит свой timer, проверим что он активен
    if systemctl list-unit-files 2>/dev/null | grep -q "certbot.timer"; then
        systemctl enable --now certbot.timer 2>&1 | grep -v "Created symlink" || true
        ok "Автообновление сертификата: certbot.timer активен"
    fi
}

# Шаг: проверка работоспособности сайта + telemt + связки
step_site_health_check() {
    hdr "Сайт: проверка работоспособности"

    if [[ "${SITE_SETUP_FAILED:-false}" == true ]]; then
        echo ""
        err "${BOLD}Установка сайта НЕ завершилась успешно${RESET}"
        warn "Что работает: telemt на 443 (по обычным MTProxy ссылкам)"
        warn "Что НЕ работает: сайт-заглушка на ${SITE_DOMAIN:-?}:${SITE_PORT:-8443}"
        echo ""
        info "Чтобы попробовать установить сайт повторно после устранения проблемы:"
        info "  sudo mytelemtinfo → 8. Сайт-заглушка → 1. Установить"
        echo ""
        return 0  # не падаем, чтобы остальной pipeline продолжился (mytelemtinfo, summary)
    fi

    local issues=0

    # 1. nginx active
    if systemctl is-active --quiet nginx; then
        ok "nginx: active"
    else
        err "nginx: НЕ active"
        issues=$((issues+1))
    fi

    # 2. Сертификат существует и валиден
    local cert="/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem"
    if [[ -f "$cert" ]]; then
        local exp_date
        exp_date=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        ok "Сертификат: действителен до ${BOLD}${exp_date}${RESET}"
    else
        err "Сертификат не найден: $cert"
        issues=$((issues+1))
    fi

    # 3. HTTPS на 8443 отвечает 200
    sleep 2  # дать nginx время на reload
    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 \
        "https://${SITE_DOMAIN}:${SITE_PORT}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" || "$http_code" == "30"* ]]; then
        ok "Сайт отвечает: https://${SITE_DOMAIN}:${SITE_PORT}/ → ${http_code}"
    else
        warn "Сайт ответил кодом: ${http_code} (ожидался 200)"
        issues=$((issues+1))
    fi

    # 4. tls_domain в telemt-конфиге совпадает с SITE_DOMAIN
    if [[ -f /etc/telemt/telemt1.toml ]]; then
        if grep -q "tls_domain = \"${SITE_DOMAIN}\"" /etc/telemt/telemt1.toml; then
            ok "tls_domain в telemt совпадает с доменом сайта"
        else
            warn "tls_domain в /etc/telemt/telemt1.toml не равен ${SITE_DOMAIN}"
            issues=$((issues+1))
        fi
    fi

    echo ""
    if [[ $issues -eq 0 ]]; then
        ok "${BOLD}Сайт-заглушка работает корректно${RESET}"
    else
        warn "${BOLD}Найдено проблем: ${issues}${RESET}"
    fi
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
# ─── ШАГ: Web-панель telemt_panel ────────────────────────────────────────────
PANEL_REPO="amirotin/telemt_panel"
PANEL_BIN="/usr/local/bin/telemt-panel"
PANEL_CFG_DIR="/etc/telemt-panel"
PANEL_CFG="${PANEL_CFG_DIR}/config.toml"
PANEL_DATA="/var/lib/telemt-panel"
PANEL_SVC="telemt-panel"
PANEL_USER="telemt-panel"
PANEL_PORT="${PANEL_PORT:-8080}"
PANEL_ADMIN_USER="${PANEL_ADMIN_USER:-admin}"

step_panel() {
    [[ "${DO_PANEL:-false}" != true ]] && return 0
    hdr "Шаг — Установка web-панели (telemt_panel)"

    # Архитектура
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="x86_64"  ;;
        aarch64) arch="aarch64" ;;
        *)       err "Архитектура $arch не поддерживается панелью"; return 1 ;;
    esac

    # Системный пользователь
    if ! id "$PANEL_USER" &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --home /nonexistent "$PANEL_USER"
        ok "Создан пользователь ${PANEL_USER}"
    fi
    if getent group telemt &>/dev/null; then
        usermod -aG telemt "$PANEL_USER" 2>/dev/null || true
    fi

    # Директории
    mkdir -p "$PANEL_CFG_DIR" "$PANEL_DATA/staging"
    chown "${PANEL_USER}:${PANEL_USER}" "$PANEL_CFG_DIR" "$PANEL_DATA" "$PANEL_DATA/staging"

    # Скачивание бинарника
    info "Определение последней версии панели..."
    local tag
    tag=$(curl -fsSL "https://api.github.com/repos/${PANEL_REPO}/releases/latest" \
        | jq -r '.tag_name') || { err "Не удалось получить версию панели"; return 1; }
    [[ -z "$tag" || "$tag" == "null" ]] && { err "Пустой tag_name"; return 1; }
    info "Версия: $tag"

    local tarball="telemt-panel-${arch}-linux-gnu.tar.gz"
    local url="https://github.com/${PANEL_REPO}/releases/download/${tag}/${tarball}"
    local tmp_dir; tmp_dir=$(mktemp -d)

    info "Скачивание ${tarball}..."
    if curl -fSL "$url" -o "${tmp_dir}/${tarball}"; then
        tar -xzf "${tmp_dir}/${tarball}" -C "$tmp_dir"
        install -m 0755 "${tmp_dir}/telemt-panel-${arch}-linux" "$PANEL_BIN"
        rm -rf "$tmp_dir"
        ok "Бинарник: ${PANEL_BIN} (${tag})"
    else
        rm -rf "$tmp_dir"
        err "Ошибка загрузки панели"; return 1
    fi

    # Конфиг
    if [[ ! -f "$PANEL_CFG" ]]; then
        local api_port
        api_port=$(instance_api "${INSTANCES[0]}")

        local jwt_secret pass_hash
        jwt_secret=$(openssl rand -hex 32)
        pass_hash=$(printf '%s\n' "$PANEL_ADMIN_PASS" | "$PANEL_BIN" hash-password) \
            || { err "Не удалось сгенерировать хеш пароля"; return 1; }

        cat > "$PANEL_CFG" <<TOML
listen = "0.0.0.0:${PANEL_PORT}"
data_dir = "${PANEL_DATA}"

[telemt]
url = "http://127.0.0.1:${api_port}"
binary_path = "/bin/telemt"
service_name = "telemt${INSTANCES[0]}"

[panel]
binary_path = "${PANEL_BIN}"
service_name = "${PANEL_SVC}"

[auth]
username = "${PANEL_ADMIN_USER}"
password_hash = "${pass_hash}"
jwt_secret = "${jwt_secret}"
session_ttl = "24h"
TOML
        chown "${PANEL_USER}:${PANEL_USER}" "$PANEL_CFG"
        chmod 600 "$PANEL_CFG"
        ok "Конфиг: ${PANEL_CFG}"
    else
        info "Конфиг панели уже существует — пропуск"
    fi

    # Sudoers drop-in
    local sudoers="/etc/sudoers.d/${PANEL_SVC}"
    local cp_bin mv_bin chmod_bin rm_bin systemctl_bin
    cp_bin=$(command -v cp); mv_bin=$(command -v mv)
    chmod_bin=$(command -v chmod); rm_bin=$(command -v rm)
    systemctl_bin=$(command -v systemctl)

    cat > "$sudoers" <<EOF
${PANEL_USER} ALL=(root) NOPASSWD: ${cp_bin} -f ${PANEL_BIN} ${PANEL_DATA}/staging/telemt-panel.bak
${PANEL_USER} ALL=(root) NOPASSWD: ${cp_bin} -f ${PANEL_DATA}/staging/telemt-panel ${PANEL_BIN}.tmp
${PANEL_USER} ALL=(root) NOPASSWD: ${chmod_bin} 0755 ${PANEL_BIN}.tmp
${PANEL_USER} ALL=(root) NOPASSWD: ${mv_bin} -f ${PANEL_BIN}.tmp ${PANEL_BIN}
${PANEL_USER} ALL=(root) NOPASSWD: ${rm_bin} -f ${PANEL_BIN}.tmp
${PANEL_USER} ALL=(root) NOPASSWD: ${systemctl_bin} restart ${PANEL_SVC}
${PANEL_USER} ALL=(root) NOPASSWD: ${systemctl_bin} restart telemt*
${PANEL_USER} ALL=(root) NOPASSWD: ${systemctl_bin} start ${PANEL_SVC}
EOF
    chmod 0440 "$sudoers"
    ok "Sudoers: ${sudoers}"

    # Systemd unit
    cat > "/etc/systemd/system/${PANEL_SVC}.service" <<SVC
[Unit]
Description=Telemt Panel
After=network.target

[Service]
Type=simple
User=${PANEL_USER}
ExecStart=${PANEL_BIN} --config ${PANEL_CFG}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${PANEL_CFG_DIR} ${PANEL_DATA}

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable "${PANEL_SVC}"
    ok "Systemd-сервис ${PANEL_SVC} создан"

    local pub_ip; pub_ip=$(get_public_ip_cached)
    info "Панель будет доступна: http://${pub_ip}:${PANEL_PORT}"
}

panel_start() {
    [[ "${DO_PANEL:-false}" != true ]] && return 0
    systemctl start "${PANEL_SVC}" 2>/dev/null || true
    local st; st=$(systemctl is-active "${PANEL_SVC}" 2>/dev/null)
    if [[ "$st" == "active" ]]; then
        ok "telemt-panel: ${GREEN}active${RESET} (порт ${PANEL_PORT})"
    else
        warn "telemt-panel: $st"
    fi
}

panel_remove() {
    if [[ -f "/etc/systemd/system/${PANEL_SVC:-telemt-panel}.service" ]] || id "${PANEL_USER:-telemt-panel}" &>/dev/null; then
        info "Удаление web-панели..."
        systemctl stop "${PANEL_SVC:-telemt-panel}" 2>/dev/null || true
        systemctl disable "${PANEL_SVC:-telemt-panel}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${PANEL_SVC:-telemt-panel}.service"
        rm -f "/etc/sudoers.d/${PANEL_SVC:-telemt-panel}"
        rm -f "${PANEL_BIN:-/usr/local/bin/telemt-panel}"
        rm -rf "${PANEL_CFG_DIR:-/etc/telemt-panel}" "${PANEL_DATA:-/var/lib/telemt-panel}"
        userdel "${PANEL_USER:-telemt-panel}" 2>/dev/null || true
        systemctl daemon-reload
        ok "Web-панель удалена"
    fi
}

step_start() {
    hdr "Шаг 10 — Запуск сервисов"
    confirm "Запустить и включить telemt в автозагрузку?" skip || return 0

    # Убиваем старые процессы если остались от предыдущей установки
    if pgrep -x telemt >/dev/null 2>&1; then
        warn "Обнаружены старые процессы telemt — завершаю..."
        pkill -x telemt 2>/dev/null; sleep 1
        pkill -9 -x telemt 2>/dev/null || true
    fi

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

    # Запуск web-панели если была выбрана
    panel_start
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

    # ── Блок про сайт-заглушку (только для сценария site) ──
    if [[ "${INSTALL_SCENARIO:-standard}" == "site" && -n "${SITE_DOMAIN:-}" ]]; then
        echo ""
        echo -e "  ${BOLD}Сайт-заглушка:${RESET}"
        local site_status; site_status=$(systemctl is-active nginx 2>/dev/null)
        local site_st_disp
        case "$site_status" in
            active)   site_st_disp="${GREEN}▶ active${RESET}" ;;
            *)        site_st_disp="${RED}■ ${site_status}${RESET}" ;;
        esac
        echo -e "  nginx:    ${site_st_disp}"
        echo -e "  URL:      ${CYAN}https://${SITE_DOMAIN}:${SITE_PORT:-8443}/${RESET}"
        local cert="/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem"
        if [[ -f "$cert" ]]; then
            local exp; exp=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
            echo -e "  Сертификат: ${GREEN}валиден до ${exp}${RESET}"
        fi
        echo -e "  Шаблон:   ${DIM}${SITE_TEMPLATE_URL}${RESET}"
    fi

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
    [[ "${USE_TSPU:-true}" == true ]] && echo -e "  ${GREEN}✓${RESET} client_mss=\"tspu\" ${DIM}— обход ТСПУ${RESET}"
    [[ "${USE_TSPU:-true}" == false ]] && echo -e "  ${YELLOW}○${RESET} client_mss=\"tspu\" ${DIM}— отключён (закомментирован)${RESET}"
    [[ "${DO_VLESS:-false}"    == true ]] && echo -e "  ${GREEN}✓${RESET} VLESS Reality upstream (telemt → SOCKS5 → 3x-ui → Telegram DC)"
    if [[ "${DO_PANEL:-false}" == true ]]; then
        local panel_st; panel_st=$(systemctl is-active "${PANEL_SVC:-telemt-panel}" 2>/dev/null)
        local pub_ip_panel; pub_ip_panel=$(get_public_ip_cached)
        echo -e "  ${GREEN}✓${RESET} Web-панель: http://${pub_ip_panel}:${PANEL_PORT:-8080}  (${panel_st})"
    fi

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
    echo -e "  • Web-панель telemt_panel (сервис, бинарник, конфиг, пользователь)"
    echo -e "  • VLESS Reality: xray-core конфиги (бинарник /usr/local/bin/xray не трогается)"
    echo -e "  • WARP компоненты ${DIM}(legacy)${RESET}: wg-quick@warp, microsocks-мост, wgcf"
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

    # ── 3b) Удаляем web-панель ──
    panel_remove

    # ── 4) Удаляем VLESS Reality (xray-core) ──
    if [[ -f /etc/telemt-vless/config.json ]] || systemctl list-unit-files 2>/dev/null | grep -q "telemt-vless" || id xray &>/dev/null; then
        info "Удаление VLESS Reality..."
        systemctl stop telemt-vless 2>/dev/null || true
        systemctl disable telemt-vless 2>/dev/null || true
        # Refresh timer и сервис
        systemctl stop telemt-vless-refresh.timer 2>/dev/null || true
        systemctl disable telemt-vless-refresh.timer 2>/dev/null || true
        systemctl stop telemt-vless-refresh.service 2>/dev/null || true
        rm -f /etc/systemd/system/telemt-vless.service
        rm -f /etc/systemd/system/telemt-vless-refresh.service
        rm -f /etc/systemd/system/telemt-vless-refresh.timer
        rm -f /usr/local/sbin/telemt-vless-refresh
        rm -rf /etc/telemt-vless
        # Удаляем пользователя xray если он остался без процессов
        if id xray &>/dev/null && ! pgrep -u xray &>/dev/null; then
            userdel xray 2>/dev/null || true
        fi
        systemctl daemon-reload 2>/dev/null || true
        # xray бинарник не трогаем — он мог стоять и до нас (от других сервисов)
        ok "VLESS Reality компоненты удалены"
        if [[ -f /usr/local/bin/xray ]]; then
            info "Бинарник /usr/local/bin/xray не тронут (может использоваться другими сервисами)"
            info "Чтобы удалить вручную: rm -f /usr/local/bin/xray"
        fi
    fi

    # ── 4с) Удаляем сайт-заглушку (nginx config, шаблон, серт) ──
    if [[ -f /etc/nginx/sites-enabled/telemt-site.conf ]] || [[ -d /var/www/telemt-site ]]; then
        info "Удаление сайта-заглушки..."
        rm -f /etc/nginx/sites-enabled/telemt-site.conf
        rm -f /etc/nginx/sites-available/telemt-site.conf
        rm -rf /var/www/telemt-site
        rm -rf /var/www/letsencrypt
        # Reload nginx если он установлен
        if command -v nginx &>/dev/null && systemctl is-active --quiet nginx; then
            nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        fi
        # Сертификат — спросим у пользователя
        # Извлекаем домен из бэкапа если он есть
        local saved_dom=""
        [[ -f /etc/telemt/.custom_domain ]] && saved_dom=$(cat /etc/telemt/.custom_domain)
        if [[ -n "$saved_dom" && -d "/etc/letsencrypt/live/$saved_dom" ]]; then
            warn "Найден сертификат Let's Encrypt для $saved_dom"
            read -rp "  Удалить сертификат тоже? [y/N]: " ans
            if [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]; then
                certbot delete --cert-name "$saved_dom" --non-interactive 2>&1 | tail -2 || true
                ok "Сертификат удалён"
            else
                info "Сертификат оставлен в /etc/letsencrypt/live/$saved_dom"
            fi
        fi
        ok "Сайт-заглушка удалена"
    fi

    # ── 4b) WARP — на случай если был установлен в прошлых версиях скрипта ──
    if [[ -f /etc/wireguard/warp.conf ]] || systemctl list-unit-files 2>/dev/null | grep -q "wg-quick@warp\|telemt-warp-socks"; then
        info "Удаление WARP (legacy)..."
        # Старый микрососкс-мост (для совместимости с предыдущими версиями)
        systemctl stop telemt-warp-socks 2>/dev/null || true
        systemctl disable telemt-warp-socks 2>/dev/null || true
        rm -f /etc/systemd/system/telemt-warp-socks.service

        # Основное: WireGuard интерфейс
        systemctl stop wg-quick@warp 2>/dev/null || true
        systemctl disable wg-quick@warp 2>/dev/null || true
        rm -f /etc/wireguard/warp.conf /etc/wireguard/wgcf-account.toml /etc/wireguard/wgcf-profile.conf
        rm -f /usr/local/bin/wgcf

        # Чистим policy routing на случай если что-то осталось в памяти ядра
        while ip rule 2>/dev/null | grep -q "lookup 200"; do
            ip rule del lookup 200 2>/dev/null || break
        done
        ip route flush table 200 2>/dev/null || true

        # Старый cloudflare-warp если был
        if command -v warp-cli &>/dev/null; then
            warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
            systemctl disable --now warp-svc 2>/dev/null || true
            apt-get purge -y cloudflare-warp 2>&1 | tail -2 || true
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        fi
        ok "WARP legacy компоненты удалены"
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
        for port in 443 5223 8530 8080; do
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
    echo -e "  ${DIM}• telemt-panel: $(command -v telemt-panel &>/dev/null && echo 'ещё есть' || echo 'удалён')${RESET}"
    echo -e "  ${DIM}• VLESS (telemt-vless): $(systemctl is-active --quiet telemt-vless 2>/dev/null && echo 'активен' || echo 'нет')${RESET}"
    echo -e "  ${DIM}• warp интерфейс ${DIM}(legacy)${RESET}: $(wg show warp &>/dev/null && echo 'активен' || echo 'нет')${RESET}"
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

# ─── Режим --vless-only: установить только VLESS туннель ────────────────────
# Используется когда telemt уже работает (поставлен нашим скриптом или другим способом)
# и нужно добавить только xray VLESS Reality upstream поверх него.
do_vless_only_install() {
    check_root
    print_banner
    hdr "Установка VLESS Reality поверх существующего telemt"

    echo ""
    info "Этот режим установит только xray + VLESS туннель."
    info "telemt НЕ устанавливается и НЕ изменяется (только опционально"
    info "добавляется upstream-секция в его конфиги, если найдены)."
    echo ""

    # Детектим telemt
    local telemt_bin=""
    for p in /bin/telemt /usr/local/bin/telemt /usr/bin/telemt; do
        [[ -x "$p" ]] && telemt_bin="$p" && break
    done

    if [[ -n "$telemt_bin" ]]; then
        ok "Обнаружен telemt: ${BOLD}${telemt_bin}${RESET}"
        local tv; tv=$("$telemt_bin" --version 2>&1 | head -1)
        info "Версия: ${tv}"
    else
        warn "telemt не найден в /bin /usr/local/bin /usr/bin"
        warn "xray будет установлен, но без активного потребителя SOCKS5"
        echo ""
        read -rp "  Всё равно продолжить? [y/N]: " ans
        [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && { info "Отменено"; exit 0; }
    fi

    # Запрос ссылки/подписки — переиспользуем select_components, но только VLESS-часть
    echo ""
    DO_VLESS=true
    VLESS_LINK=""
    VLESS_TYPE=""
    VLESS_STRATEGY="leastPing"
    VLESS_AUTO_REFRESH=true

    echo -e "  ${BOLD}Тип подключения:${RESET}"
    echo -e "  ${GREEN}1${RESET} — одна ${BOLD}vless://${RESET} ссылка ${DIM}(vless://uuid@server:port?...)${RESET}"
    echo -e "  ${GREEN}2${RESET} — ${BOLD}подписка${RESET} 3x-ui ${DIM}(https://server:port/path/sub-id)${RESET}"
    echo ""
    local link_type
    while true; do
        read -rp "  Тип [1/2]: " link_type
        [[ "$link_type" == "1" || "$link_type" == "2" ]] && break
        warn "Введите 1 или 2"
    done

    if [[ "$link_type" == "1" ]]; then
        VLESS_TYPE="single"
        while true; do
            read -rp "  vless:// ссылка: " VLESS_LINK
            if [[ "$VLESS_LINK" == vless://*@*:*\?* ]] && [[ "$VLESS_LINK" == *security=reality* ]] \
               && [[ "$VLESS_LINK" == *pbk=* ]] && [[ "$VLESS_LINK" == *sni=* ]]; then
                if VL="$VLESS_LINK" python3 -c "import os,urllib.parse as up,sys;p=up.urlparse(os.environ['VL']);q=up.parse_qs(p.query);sys.exit(0 if (p.username and p.hostname and p.port and 'pbk' in q and 'sni' in q) else 1)" 2>/dev/null; then
                    if ! check_vless_not_self "$VLESS_LINK"; then
                        read -rp "  Попробовать другую ссылку? [Y/n]: " retry
                        [[ "${retry,,}" =~ ^(n|no)$ ]] && { info "Отменено"; exit 0; }
                        continue
                    fi
                    ok "VLESS ссылка принята"
                    break
                fi
            fi
            warn "Неверный формат ссылки"
            read -rp "  Попробовать ещё раз? [Y/n]: " retry
            [[ "${retry,,}" =~ ^(n|no)$ ]] && { info "Отменено"; exit 0; }
        done
    else
        VLESS_TYPE="subscription"
        while true; do
            read -rp "  URL подписки: " VLESS_LINK
            if [[ "$VLESS_LINK" =~ ^https?:// ]]; then
                info "Получение и парсинг подписки..."
                local parse_out
                parse_out=$(SUB_URL="$VLESS_LINK" python3 << 'PYTEST'
import os, sys, urllib.request, base64, ssl, urllib.parse as up
url = os.environ["SUB_URL"]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    req = urllib.request.Request(url, headers={"User-Agent": "v2rayN/6.0"})
    with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
        data = r.read().decode("utf-8", errors="ignore").strip()
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
decoded = data
try:
    pad = "=" * (-len(data) % 4)
    decoded = base64.b64decode(data + pad).decode("utf-8", errors="ignore")
except Exception: pass
nodes = [ln.strip() for ln in decoded.split("\n") if ln.strip().startswith("vless://") and "security=reality" in ln]
if not nodes:
    print("ERROR: VLESS Reality узлы не найдены", file=sys.stderr); sys.exit(2)
print(len(nodes))
for n in nodes:
    p = up.urlparse(n)
    print(f"{p.hostname}:{p.port or 443}")
PYTEST
)
                local nodes_count; nodes_count=$(echo "$parse_out" | head -1)
                if [[ -n "$nodes_count" && "$nodes_count" =~ ^[0-9]+$ ]]; then
                    # Проверка узлов на петлю
                    local our_ip; our_ip=$(get_public_ip_cached)
                    local loop_host=""
                    if [[ -n "$our_ip" ]]; then
                        while IFS= read -r hostline; do
                            [[ -z "$hostline" ]] && continue
                            local h="${hostline%:*}"
                            local hip; hip=$(getent hosts "$h" 2>/dev/null | awk '{print $1}' | head -1)
                            if [[ -n "$hip" && "$hip" == "$our_ip" ]]; then
                                loop_host="$hostline"; break
                            fi
                        done < <(echo "$parse_out" | tail -n +2)
                    fi
                    if [[ -n "$loop_host" ]]; then
                        err "В подписке узел ${loop_host} с IP этого сервера — петля!"
                        read -rp "  Попробовать другой URL? [Y/n]: " retry
                        [[ "${retry,,}" =~ ^(n|no)$ ]] && { info "Отменено"; exit 0; }
                        continue
                    fi
                    ok "Подписка работает: найдено ${BOLD}${nodes_count}${RESET} узлов"
                    break
                fi
                warn "Не удалось извлечь узлы из подписки"
            else
                warn "URL должен начинаться с http:// или https://"
            fi
            read -rp "  Попробовать ещё раз? [Y/n]: " retry
            [[ "${retry,,}" =~ ^(n|no)$ ]] && { info "Отменено"; exit 0; }
        done

        echo ""
        echo -e "  ${BOLD}Стратегия балансировки:${RESET}"
        echo -e "  ${GREEN}1${RESET} — leastPing (рекомендуется)"
        echo -e "  ${GREEN}2${RESET} — roundRobin"
        echo -e "  ${GREEN}3${RESET} — random"
        while true; do
            read -rp "  Стратегия [1/2/3]: " s
            case "$s" in
                1|"") VLESS_STRATEGY="leastPing"; break ;;
                2)    VLESS_STRATEGY="roundRobin"; break ;;
                3)    VLESS_STRATEGY="random"; break ;;
                *)    warn "1, 2 или 3" ;;
            esac
        done

        echo ""
        read -rp "  Автообновление подписки каждые 6 часов? [Y/n]: " auto
        [[ "${auto,,}" =~ ^(n|no)$ ]] && VLESS_AUTO_REFRESH=false
    fi

    # Запускаем step_warp-style установку
    echo ""
    info "Установка xray-core и настройка туннеля..."
    AUTO_CONFIRM=true   # пропускаем confirm в step_vless
    step_vless

    # Поиск telemt-конфигов чтобы прицепить upstream
    echo ""
    info "Поиск telemt-конфигов для интеграции..."
    local found_configs=()
    if [[ -d /etc/telemt ]]; then
        for f in /etc/telemt/telemt*.toml; do
            [[ -f "$f" ]] && found_configs+=("$f")
        done
    fi

    if [[ ${#found_configs[@]} -gt 0 ]]; then
        ok "Найдено telemt-конфигов: ${#found_configs[@]}"
        for f in "${found_configs[@]}"; do
            echo -e "    ${DIM}- ${f}${RESET}"
        done
        echo ""
        read -rp "  Прицепить VLESS upstream ко всем конфигам и перезапустить telemt? [Y/n]: " att
        if [[ ! "${att,,}" =~ ^(n|no)$ ]]; then
            local attached=0
            for f in "${found_configs[@]}"; do
                if grep -q "127.0.0.1:40000" "$f" 2>/dev/null; then
                    info "Уже прицеплен: $(basename "$f")"
                    continue
                fi
                python3 - "$f" << 'PYU'
import sys, re
path = sys.argv[1]
content = open(path).read()
content = re.sub(r'\n*\[\[upstreams\]\][^\[]*', '\n', content, flags=re.DOTALL)
content = re.sub(r'\n{3,}', '\n\n', content)
if not content.endswith('\n'): content += '\n'
content += '\n[[upstreams]]\ntype = "socks5"\naddress = "127.0.0.1:40000"\nweight = 1\nenabled = true\n'
open(path, 'w').write(content)
PYU
                attached=$((attached + 1))
            done
            ok "Прицеплено к ${attached} конфигам"

            # Рестарт telemt: пробуем стандартные имена сервисов
            info "Перезапуск инстансов telemt..."
            local restarted=0
            for n in 1 2 3 4 5 6 7 8 9 10; do
                if systemctl is-enabled "telemt${n}" &>/dev/null; then
                    systemctl restart "telemt${n}" 2>/dev/null && restarted=$((restarted + 1))
                fi
            done
            # Также пробуем общий сервис telemt
            if systemctl is-enabled telemt &>/dev/null && [[ "$restarted" -eq 0 ]]; then
                systemctl restart telemt 2>/dev/null && restarted=1
            fi
            if [[ "$restarted" -gt 0 ]]; then
                ok "Перезапущено сервисов: ${restarted}"
            else
                warn "Не нашёл активных telemt-сервисов. Перезапусти telemt вручную:"
                warn "  systemctl restart telemt    # или telemt1 telemt2 ..."
            fi
        fi
    else
        warn "Конфиги telemt в /etc/telemt/ не найдены."
        echo ""
        echo -e "  ${BOLD}Чтобы прицепить VLESS к вашему telemt вручную, добавьте в TOML-конфиг:${RESET}"
        echo ""
        echo -e "  ${CYAN}[[upstreams]]${RESET}"
        echo -e "  ${CYAN}type = \"socks5\"${RESET}"
        echo -e "  ${CYAN}address = \"127.0.0.1:40000\"${RESET}"
        echo -e "  ${CYAN}weight = 1${RESET}"
        echo -e "  ${CYAN}enabled = true${RESET}"
        echo ""
        info "После этого перезапустите telemt: ${BOLD}systemctl restart <ваш telemt service>${RESET}"
    fi

    # Финал
    echo ""
    hdr "Готово"
    echo ""
    ok "xray-core установлен и активен"
    [[ "$VLESS_TYPE" == "subscription" && "$VLESS_AUTO_REFRESH" == true ]] && \
        ok "Авто-обновление подписки: каждые 6 часов"
    echo ""
    info "Управление через ${BOLD}mytelemtinfo${RESET} → 7. VLESS Reality upstream"
    info "(если mytelemtinfo не установлен — запустите install.sh обычным образом)"
    echo ""
    info "Тест туннеля:"
    echo -e "  ${DIM}curl --socks5 127.0.0.1:40000 https://api.ipify.org${RESET}"
    echo ""
    exit 0
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    # Перенаправляем stdin на /dev/tty — это нужно когда скрипт запускается через
    # `curl ... | bash` или `bash <(curl ...)`. Без этого read получает данные из
    # пайпа curl'а вместо терминала, и интерактивный ввод не работает.
    if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
        exec < /dev/tty
    fi

    check_root
    print_banner

    # Флаги командной строки
    [[ "${1:-}" == "--update" ]] && do_update
    [[ "${1:-}" == "--purge"  ]] && do_purge_only
    [[ "${1:-}" == "--vless-only" ]] && do_vless_only_install

    echo -e "  Установка ${BOLD}telemt${RESET} — Telegram MTProxy на Rust."
    echo ""

    # Определяем что уже установлено
    local existing_install=false
    local telemt_exists=false
    if [[ -f /bin/telemt ]] || [[ -d /etc/telemt ]] || [[ -f /usr/local/bin/mytelemtinfo ]]; then
        existing_install=true
    fi
    # Проверяем, есть ли вообще telemt на сервере (мог быть установлен не нашим скриптом)
    if command -v telemt &>/dev/null || [[ -x /bin/telemt ]] || [[ -x /usr/local/bin/telemt ]] || [[ -x /usr/bin/telemt ]]; then
        telemt_exists=true
    fi

    # Меню режимов показываем если: есть существующая установка ИЛИ есть telemt от другого
    # установщика ИЛИ передан --clean
    if [[ "$existing_install" == true || "$telemt_exists" == true || "${1:-}" == "--clean" ]]; then
        if [[ "$existing_install" == true ]]; then
            warn "Обнаружена существующая установка telemt-install."
        elif [[ "$telemt_exists" == true ]]; then
            info "Обнаружен telemt установленный другим способом (не нашим скриптом)."
        fi
        echo ""
        echo -e "  ${BOLD}Выберите режим:${RESET}"
        echo -e "  ${BOLD}1.${RESET} Установка поверх ${DIM}(обычная, существующие конфиги сохраняются)${RESET}"
        echo -e "  ${BOLD}2.${RESET} ${YELLOW}Чистая установка${RESET} ${DIM}(полная очистка + новая установка)${RESET}"
        echo -e "  ${BOLD}3.${RESET} ${RED}Только очистка${RESET} ${DIM}(удалить всё без новой установки)${RESET}"
        echo -e "  ${BOLD}${CYAN}4.${RESET} ${CYAN}Только установить VLESS туннель${RESET} ${DIM}(xray поверх существующего telemt)${RESET}"
        echo -e "  ${BOLD}0.${RESET} Отмена"
        echo ""
        local mode
        if [[ "${1:-}" == "--clean" ]]; then
            mode=2
            info "Режим --clean: чистая установка"
        else
            read -rp "  Режим [1/2/3/4/0]: " mode
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
            4) do_vless_only_install ;;
            0|q|"") echo -e "${YELLOW}Отменено.${RESET}"; exit 0 ;;
            *) err "Неверный пункт"; exit 1 ;;
        esac
    fi

    echo -e "  На каждом шаге: ${GREEN}y${RESET} (выполнить), Enter/n (пропустить), ${RED}q${RESET} (выход)."
    echo ""

    # Выбор сценария установки (Стандартная / Свой сайт)
    select_scenario

    confirm "Начать установку?" exit

    detect_ssh_port

    # Сайт-заглушка — запрос параметров ДО select_components,
    # потому что select_components читает SITE_DOMAIN
    if [[ "${INSTALL_SCENARIO:-standard}" == "site" ]]; then
        ask_site_details
    fi

    select_components

    echo ""
    echo -e "${BOLD}Итоговый план:${RESET}"
    echo -e "  Сценарий:        ${INSTALL_SCENARIO:-standard}"
    if [[ "${INSTALL_SCENARIO:-standard}" == "site" ]]; then
        echo -e "  Сайт:            ${SITE_DOMAIN:-?} на порту ${SITE_PORT:-8443}"
        echo -e "  Email Let's Encrypt: ${SITE_EMAIL:-?}"
        echo -e "  Шаблон сайта:    ${SITE_TEMPLATE_URL:-?}"
    fi
    echo -e "  Инстансы:        ${INSTANCES[*]}"
    echo -e "  UFW:             $DO_UFW | rate-limit: $DO_RATELIMIT"
    echo -e "  Keepalive:       ${DO_KEEPALIVE:-false}"
    echo -e "  BBR + fq:        ${DO_BBR:-false}"
    echo -e "  nft limiter:     ${DO_NFT:-false}"
    echo -e "  Таймауты:        ${DO_TIMEOUTS:-false}"
    if [[ "${INSTALL_SCENARIO:-standard}" != "site" ]]; then
        echo -e "  Свой домен:      ${USE_CUSTOM_DOMAIN:-false}${USE_CUSTOM_DOMAIN:+ (${CUSTOM_LINK_DOMAIN})}"
    fi
    echo -e "  client_mss=tspu: ${USE_TSPU:-true}"
    echo -e "  VLESS Reality:   ${DO_VLESS:-false}"
    echo -e "  Web-панель:      ${DO_PANEL:-false}"
    echo ""
    confirm "Всё верно — поехали?" exit

    # С этого момента все шаги выполняются автоматически без подтверждений
    AUTO_CONFIRM=true
    echo ""
    info "Установка пошла. Подтверждения больше не требуются."

    step_prepare
    step_install_binary
    step_vless
    step_gen_secrets
    step_configs
    step_systemd
    step_ufw
    step_ratelimit
    step_keepalive
    step_nft_limiter
    # Сайт-заглушка (только в сценарии site)
    if [[ "${INSTALL_SCENARIO:-standard}" == "site" ]]; then
        SITE_SETUP_FAILED=false
        step_install_site_deps || SITE_SETUP_FAILED=true
        if [[ "$SITE_SETUP_FAILED" != true ]]; then
            step_clone_site_template || SITE_SETUP_FAILED=true
        fi
        if [[ "$SITE_SETUP_FAILED" != true ]]; then
            step_setup_nginx || SITE_SETUP_FAILED=true
        fi
        if [[ "$SITE_SETUP_FAILED" != true ]]; then
            step_get_certbot_cert || SITE_SETUP_FAILED=true
        fi
        # health_check всегда вызываем — он сам поймёт нужно ли отчитываться об ошибке
        step_site_health_check
    fi
    step_install_mytelemtinfo
    step_panel
    step_start
    print_summary
}

main "$@"
