#!/usr/bin/env bash
# =============================================================================
#  mytelemtinfo — интерактивный менеджер telemt
#  Repo: https://github.com/vaalaav/telemt-install
# =============================================================================

# Защита от запуска через process substitution или pipe
if [[ ! -t 0 ]] && [[ -t 1 ]] && [[ -e /dev/tty ]]; then
    exec </dev/tty
fi

# ─── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m';   YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m';  BOLD='\033[1m';      DIM='\033[2m'
MAGENTA='\033[0;35m'; RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
info() { echo -e "  ${CYAN}→${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "  ${RED}✗${RESET} $*"; }
pause(){ echo ""; read -rp "  Нажмите Enter для продолжения..." _; }

# ─── Хелперы инстансов ────────────────────────────────────────────────────────
declare -A INSTANCE_PORTS=([1]=443 [2]=5223 [3]=8530 [4]=0 [5]=0 [6]=0 [7]=0 [8]=0 [9]=0 [10]=0)
declare -A INSTANCE_DOMAINS=([1]="www.cloudflare.com" [2]="www.apple.com" [3]="www.microsoft.com" [4]="" [5]="" [6]="" [7]="" [8]="" [9]="" [10]="")
declare -A INSTANCE_APIS=([1]=9091 [2]=9092 [3]=9093 [4]=9094 [5]=9095 [6]=9096 [7]=9097 [8]=9098 [9]=9099 [10]=9100)
INSTANCES_ALL=(1 2 3 4 5 6 7 8 9 10)

# Перечитываем реальные значения порта/SNI из существующих конфигов
load_instance_config() {
    for n in "${INSTANCES_ALL[@]}"; do
        local f="/etc/telemt/telemt${n}.toml"
        [[ ! -f "$f" ]] && continue
        local p d
        p=$(grep -m1 '^\s*port\s*=' "$f" 2>/dev/null | grep -oE '[0-9]+')
        d=$(grep -m1 '^\s*tls_domain\s*=' "$f" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"')
        [[ -n "$p" ]] && INSTANCE_PORTS[$n]="$p"
        [[ -n "$d" ]] && INSTANCE_DOMAINS[$n]="$d"
    done
}

active_instances() {
    local result=()
    for n in "${INSTANCES_ALL[@]}"; do
        [[ -f "/etc/telemt/telemt${n}.toml" ]] && result+=("$n")
    done
    echo "${result[@]}"
}

# Найти первый свободный слот для нового инстанса (1-10)
next_free_slot() {
    for n in "${INSTANCES_ALL[@]}"; do
        [[ ! -f "/etc/telemt/telemt${n}.toml" ]] && echo "$n" && return
    done
    echo ""
}

# Вызываем загрузку при старте
load_instance_config

svc_status() {
    # возвращает "active" / "inactive" / "не установлен"
    local n=$1
    if [[ ! -f "/etc/systemd/system/telemt${n}.service" ]]; then
        echo "не установлен"
    else
        systemctl is-active "telemt${n}" 2>/dev/null || echo "inactive"
    fi
}

svc_status_color() {
    local st="$1"
    case "$st" in
        active)         echo -e "${GREEN}▶ active${RESET}" ;;
        inactive)       echo -e "${RED}■ inactive${RESET}" ;;
        "не установлен")echo -e "${DIM}— не установлен${RESET}" ;;
        *)              echo -e "${YELLOW}? $st${RESET}" ;;
    esac
}

# ─── Получить публичный IP сервера ───────────────────────────────────────────
get_public_ip() {
    local ip
    ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null) || true
    [[ -z "$ip" ]] && ip=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null) || true
    [[ -z "$ip" ]] && ip=$(curl -s --max-time 3 https://ipv4.icanhazip.com 2>/dev/null) || true
    [[ -z "$ip" ]] && ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

# ─── Получить ссылку из API ───────────────────────────────────────────────────
# Кэш публичного IP — определяется один раз за сессию
_PUBLIC_IP_CACHE=""
get_link() {
    local api=$1
    local link
    link=$(curl -s --max-time 3 "http://127.0.0.1:${api}/v1/users" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])" 2>/dev/null) \
      || link=""
    [[ -z "$link" ]] && return

    # Приоритет: сохранённый кастомный домен → реальный публичный IP
    local custom_dom
    custom_dom=$(get_custom_domain)
    if [[ -n "$custom_dom" ]]; then
        link="${link/server=0.0.0.0/server=${custom_dom}}"
        # Также подменяем если там IP (из предыдущей установки)
        [[ -z "$_PUBLIC_IP_CACHE" ]] && _PUBLIC_IP_CACHE=$(get_public_ip)
        [[ -n "$_PUBLIC_IP_CACHE" ]] && link="${link/server=${_PUBLIC_IP_CACHE}/server=${custom_dom}}"
    elif [[ "$link" == *"server=0.0.0.0"* ]]; then
        [[ -z "$_PUBLIC_IP_CACHE" ]] && _PUBLIC_IP_CACHE=$(get_public_ip)
        if [[ -n "$_PUBLIC_IP_CACHE" ]]; then
            link="${link/server=0.0.0.0/server=${_PUBLIC_IP_CACHE}}"
        fi
    fi
    echo "$link"
}

# ─── Заголовок ────────────────────────────────────────────────────────────────
draw_header() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║          mytelemtinfo — telemt manager           ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ─── Статус-строки для главного меню ─────────────────────────────────────────
status_proxy() {
    local insts; read -ra insts <<< "$(active_instances)"
    if [[ ${#insts[@]} -eq 0 ]]; then
        echo -e "${DIM}не установлен${RESET}"
        return
    fi
    local parts=()
    for n in "${insts[@]}"; do
        local st; st=$(svc_status "$n")
        local col; [[ "$st" == "active" ]] && col="$GREEN" || col="$RED"
        parts+=("${col}${n}:${INSTANCE_PORTS[$n]}${RESET}")
    done
    (IFS='  '; echo -e "${parts[*]}")
}

status_keepalive() {
    # Поддерживаем оба имени конфига (старый и новый)
    if [[ -f /etc/sysctl.d/99-telemt-net.conf ]] && grep -q tcp_keepalive_time /etc/sysctl.d/99-telemt-net.conf 2>/dev/null \
       || [[ -f /etc/sysctl.d/99-tg-keepalive.conf ]]; then
        local t i p
        t=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
        i=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
        p=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
        echo -e "${GREEN}включён${RESET}  time=${BOLD}${t}${RESET} intvl=${BOLD}${i}${RESET} probes=${BOLD}${p}${RESET}"
    else
        echo -e "${DIM}не настроен${RESET} (дефолты ядра)"
    fi
}

status_bbr() {
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
        echo -e "${GREEN}активен${RESET}  congestion=${BOLD}bbr${RESET} qdisc=${BOLD}fq${RESET}"
    elif [[ "$cc" == "bbr" ]]; then
        echo -e "${YELLOW}частично${RESET}  bbr есть, qdisc=${cc}"
    else
        echo -e "${DIM}не настроен${RESET}  (cc=${cc})"
    fi
}

status_nft() {
    if nft list table inet telemt_limit &>/dev/null; then
        local drops; drops=$(nft list chain inet telemt_limit input 2>/dev/null | grep -oE "packets [0-9]+" | awk '{s+=$2} END{print s+0}')
        echo -e "${GREEN}активен${RESET}  дропов SYN: ${BOLD}${drops}${RESET}"
    elif [[ -f /usr/local/sbin/telemt-nft-limit.sh ]]; then
        echo -e "${YELLOW}скрипт есть, таблица не активна${RESET}"
    else
        echo -e "${DIM}не установлен${RESET}"
    fi
}

status_timeouts() {
    local found=0
    for f in /etc/telemt/telemt*.toml; do
        [[ -f "$f" ]] && grep -q '\[timeouts\]' "$f" 2>/dev/null && found=1 && break
    done
    if [[ $found -eq 1 ]]; then
        local hs ka
        hs=$(grep -h 'client_handshake' /etc/telemt/telemt*.toml 2>/dev/null | head -1 | grep -oE '[0-9]+')
        ka=$(grep -h 'client_keepalive' /etc/telemt/telemt*.toml 2>/dev/null | head -1 | grep -oE '[0-9]+')
        echo -e "${GREEN}настроены${RESET}  handshake=${BOLD}${hs:-?}${RESET} keepalive=${BOLD}${ka:-?}${RESET}"
    else
        echo -e "${DIM}дефолты telemt${RESET}"
    fi
}

status_ufw() {
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        local rl; rl=$(grep -c "MTProto rate-limit" /etc/ufw/before.rules 2>/dev/null || echo 0)
        if [[ $rl -gt 0 ]]; then
            echo -e "${GREEN}активен${RESET} + rate-limit (xt_recent)"
        else
            echo -e "${GREEN}активен${RESET}  rate-limit ${DIM}выключен${RESET}"
        fi
    else
        echo -e "${YELLOW}выключен${RESET}"
    fi
}

# ─── Свой домен ──────────────────────────────────────────────────────────────
CUSTOM_DOMAIN_FILE="/etc/telemt/.custom_domain"

get_custom_domain() {
    [[ -f "$CUSTOM_DOMAIN_FILE" ]] && cat "$CUSTOM_DOMAIN_FILE" 2>/dev/null || echo ""
}

status_custom_domain() {
    local d; d=$(get_custom_domain)
    if [[ -n "$d" ]]; then
        echo -e "${GREEN}${d}${RESET}"
    else
        echo -e "${DIM}не задан${RESET} (используется IP)"
    fi
}

# ─── VLESS Reality (xray-core SOCKS5 upstream) ──────────────────────────────
VLESS_CONFIG_DIR="/etc/telemt-vless"

status_vless() {
    local service_up=false port_up=false has_upstream=false

    if systemctl is-active --quiet telemt-vless 2>/dev/null; then
        service_up=true
    fi
    if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:40000"; then
        port_up=true
    fi
    for f in /etc/telemt/telemt*.toml; do
        [[ -f "$f" ]] && grep -q "127.0.0.1:40000" "$f" 2>/dev/null && has_upstream=true && break
    done

    if [[ ! -d "$VLESS_CONFIG_DIR" ]] && [[ ! -f /usr/local/bin/xray ]]; then
        echo -e "${DIM}не установлен${RESET}"
        return
    fi

    if [[ "$service_up" == true && "$port_up" == true && "$has_upstream" == true ]]; then
        echo -e "${GREEN}активен${RESET} (xray + telemt прицеплен)"
    elif [[ "$service_up" == true && "$port_up" == true ]]; then
        echo -e "${YELLOW}работает, но не прицеплен к telemt${RESET}"
    elif [[ "$service_up" == true ]]; then
        echo -e "${YELLOW}сервис up, порт 40000 не слушается${RESET}"
    else
        echo -e "${DIM}установлен, не запущен${RESET}"
    fi
}

# ════════════════════════════════════════════════════════════════════════
#  ГЛАВНОЕ МЕНЮ
# ════════════════════════════════════════════════════════════════════════
main_menu() {
    while true; do
        draw_header

        echo -e "  ${BOLD}Состояние:${RESET}"
        echo -e "  Прокси:    $(status_proxy)"
        echo -e "  Keepalive: $(status_keepalive)"
        echo -e "  BBR:       $(status_bbr)"
        echo -e "  nft SYN:   $(status_nft)"
        echo -e "  Таймауты:  $(status_timeouts)"
        echo -e "  UFW:       $(status_ufw)"
        echo -e "  Свой домен: $(status_custom_domain)"
        echo -e "  VLESS:      $(status_vless)"
        echo ""
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo -e "  ${BOLD}1.${RESET} Управление прокси"
        echo -e "  ${BOLD}2.${RESET} Сетевой тюнинг (Keepalive + BBR)"
        echo -e "  ${BOLD}3.${RESET} nft SYN Limiter"
        echo -e "  ${BOLD}4.${RESET} Таймауты telemt"
        echo -e "  ${BOLD}5.${RESET} UFW / Rate-limit"
        echo -e "  ${BOLD}6.${RESET} Свой домен в ссылках"
        echo -e "  ${BOLD}7.${RESET} VLESS Reality upstream"
        echo -e "  ${BOLD}0.${RESET} Выход"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите пункт: " choice
        case "$choice" in
            1) menu_proxy ;;
            2) menu_keepalive ;;
            3) menu_nft ;;
            4) menu_timeouts ;;
            5) menu_ufw ;;
            6) menu_custom_domain ;;
            7) menu_vless ;;
            0|q) echo ""; exit 0 ;;
            *) warn "Неверный пункт" ; sleep 1 ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════════════════
#  1. УПРАВЛЕНИЕ ПРОКСИ
# ════════════════════════════════════════════════════════════════════════
menu_proxy() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Управление прокси${RESET}\n"

        local insts; read -ra insts <<< "$(active_instances)"
        if [[ ${#insts[@]} -eq 0 ]]; then
            warn "Инстансы telemt не обнаружены (/etc/telemt/*.toml отсутствуют)"
            echo ""
            # Проверяем что telemt вообще установлен
            if [[ ! -x /bin/telemt ]]; then
                err "Бинарник /bin/telemt не установлен — сначала запустите install.sh"
                pause; return
            fi
            echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
            echo -e "  ${GREEN}${BOLD}1.${RESET} ${GREEN}Добавить новый инстанс${RESET}"
            echo -e "  ${BOLD}0.${RESET} ← Назад"
            echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
            echo ""
            read -rp "  Выберите: " ch_empty
            case "$ch_empty" in
                1) proxy_add ;;
                0|b|"") return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
            continue
        fi

        # Таблица состояния
        echo -e "  ${BOLD}  #   Порт    Домен                    Статус${RESET}"
        echo -e "  ${CYAN}  ─────────────────────────────────────────────${RESET}"
        for n in "${insts[@]}"; do
            local st; st=$(svc_status "$n")
            printf "  ${BOLD}  %-2s${RESET}  %-6s  %-24s  %b\n" \
                "$n" "${INSTANCE_PORTS[$n]}" "${INSTANCE_DOMAINS[$n]}" "$(svc_status_color "$st")"
        done
        echo ""

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo -e "  ${BOLD}1.${RESET} Показать ссылки для клиентов"
        echo -e "  ${BOLD}2.${RESET} Перезапустить все инстансы"
        echo -e "  ${BOLD}3.${RESET} Остановить все инстансы"
        echo -e "  ${BOLD}4.${RESET} Запустить все инстансы"
        echo -e "  ${BOLD}5.${RESET} Управление отдельным инстансом"
        echo -e "  ${GREEN}${BOLD}6.${RESET} ${GREEN}Добавить новый инстанс${RESET}"
        echo -e "  ${YELLOW}${BOLD}7.${RESET} ${YELLOW}Удалить отдельный инстанс${RESET}"
        echo -e "  ${BOLD}8.${RESET} Обновить бинарник telemt"
        echo -e "  ${BOLD}9.${RESET} Просмотр логов"
        echo -e "  ${BOLD}10.${RESET} ${RED}Удалить telemt полностью${RESET}"
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch
        case "$ch" in
            1) proxy_show_links ;;
            2) proxy_restart_all ;;
            3) proxy_stop_all ;;
            4) proxy_start_all ;;
            5) proxy_single ;;
            6) proxy_add ;;
            7) proxy_remove_single ;;
            8) proxy_update ;;
            9) proxy_logs ;;
            10) proxy_remove ;;
            0|b) return ;;
            *) warn "Неверный пункт"; sleep 1 ;;
        esac
    done
}

proxy_show_links() {
    draw_header
    echo -e "  ${BOLD}Ссылки для клиентов Telegram${RESET}\n"

    # Проверяем что во всех конфигах прописан public_host (иначе ссылки будут с 0.0.0.0)
    local need_fix=()
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        if ! grep -q 'public_host' "$f" 2>/dev/null; then
            need_fix+=("$f")
        fi
    done

    if [[ ${#need_fix[@]} -gt 0 ]]; then
        warn "В ${#need_fix[@]} конфигах нет public_host — ссылки будут с IP 0.0.0.0"
        echo -e "  ${DIM}Файлы: ${need_fix[*]}${RESET}"
        echo ""
        read -rp "  Автоматически добавить public_host? [Y/n]: " ans
        if [[ ! "${ans,,}" =~ ^(n|no)$ ]]; then
            local pub_ip; pub_ip=$(get_public_ip)
            if [[ -z "$pub_ip" ]]; then
                read -rp "  Не удалось определить IP. Введите вручную: " pub_ip
            else
                info "Публичный IP: ${BOLD}${pub_ip}${RESET}"
                read -rp "  Подтвердить или ввести свой [${pub_ip}]: " inp
                pub_ip="${inp:-$pub_ip}"
            fi

            for f in "${need_fix[@]}"; do
                python3 - "$f" "$pub_ip" << 'PYEOF'
import sys, re
path, ip = sys.argv[1], sys.argv[2]
content = open(path).read()

# Удаляем существующую секцию [general.links] если есть (на всякий случай)
content = re.sub(r'\n*\[general\.links\][^\[]*', '\n', content, flags=re.DOTALL)

# Вставляем [general.links] сразу после [general.modes]
modes_match = re.search(r'(\[general\.modes\][^\[]*)', content, flags=re.DOTALL)
if modes_match:
    insert_after = modes_match.end()
    block = f'\n[general.links]\nshow = "*"\npublic_host = "{ip}"\n'
    content = content[:insert_after] + block + content[insert_after:]
else:
    # Вставляем в начало после [general]
    content = re.sub(r'(\[general\][^\[]*)', r'\1\n[general.links]\nshow = "*"\npublic_host = "' + ip + '"\n\n', content, count=1)

# Чистим тройные пустые строки
content = re.sub(r'\n{3,}', '\n\n', content)
open(path, 'w').write(content)
print(f"  {path}")
PYEOF
            done
            chown -R telemt:telemt /etc/telemt 2>/dev/null || true
            ok "public_host добавлен"

            # Перезапуск
            local insts; read -ra insts <<< "$(active_instances)"
            info "Перезапуск инстансов..."
            for n in "${insts[@]}"; do
                systemctl restart "telemt${n}" 2>/dev/null && ok "telemt${n}" || err "telemt${n} ошибка"
            done
            sleep 3
            echo ""
        fi
    fi

    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        local api="${INSTANCE_APIS[$n]}"
        echo -e "  ${BOLD}Инстанс $n${RESET} (порт ${INSTANCE_PORTS[$n]} / ${INSTANCE_DOMAINS[$n]}):"
        local link; link=$(get_link "$api")
        if [[ -n "$link" ]]; then
            echo -e "  ${GREEN}${link}${RESET}"
        else
            warn "API не ответил. telemt запущен? Попробуй через минуту."
            echo -e "  ${DIM}curl -s http://127.0.0.1:${api}/v1/users | python3 -c \"import sys,json; print(json.load(sys.stdin)['data'][0]['links']['tls'][0])\"${RESET}"
        fi
        echo ""
    done
    pause
}

proxy_restart_all() {
    draw_header
    echo -e "  ${BOLD}Перезапуск всех инстансов...${RESET}\n"
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        systemctl restart "telemt${n}" && ok "telemt${n} перезапущен" || err "telemt${n} — ошибка"
    done
    pause
}

proxy_stop_all() {
    draw_header
    echo -e "  ${BOLD}Остановка всех инстансов...${RESET}\n"
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        systemctl stop "telemt${n}" && ok "telemt${n} остановлен" || err "telemt${n} — ошибка"
    done
    pause
}

proxy_start_all() {
    draw_header
    echo -e "  ${BOLD}Запуск всех инстансов...${RESET}\n"
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        systemctl start "telemt${n}" && ok "telemt${n} запущен" || err "telemt${n} — ошибка"
    done
    pause
}

proxy_single() {
    draw_header
    echo -e "  ${BOLD}Управление отдельным инстансом${RESET}\n"
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        echo -e "  ${BOLD}$n${RESET} — порт ${INSTANCE_PORTS[$n]}  $(svc_status_color "$(svc_status "$n")")"
    done
    echo ""
    read -rp "  Номер инстанса ($(IFS=/; echo "${insts[*]}")): " n
    [[ ! "$n" =~ ^([1-9]|10)$ ]] && { warn "Неверный номер"; sleep 1; return; }
    [[ ! -f "/etc/telemt/telemt${n}.toml" ]] && { warn "Инстанс $n не установлен"; sleep 1; return; }

    while true; do
        draw_header
        local st; st=$(svc_status "$n")
        echo -e "  ${BOLD}Инстанс $n${RESET} — порт ${INSTANCE_PORTS[$n]} — ${INSTANCE_DOMAINS[$n]}"
        echo -e "  Статус: $(svc_status_color "$st")"
        echo ""
        echo -e "  ${BOLD}1.${RESET} Запустить      ${BOLD}2.${RESET} Остановить"
        echo -e "  ${BOLD}3.${RESET} Перезапустить  ${BOLD}4.${RESET} Показать ссылку"
        echo -e "  ${BOLD}5.${RESET} Логи           ${BOLD}6.${RESET} Просмотр конфига"
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo ""
        read -rp "  Выберите: " ch
        case "$ch" in
            1) systemctl start  "telemt${n}" && ok "Запущен" || err "Ошибка"; pause ;;
            2) systemctl stop   "telemt${n}" && ok "Остановлен" || err "Ошибка"; pause ;;
            3) systemctl restart "telemt${n}" && ok "Перезапущен" || err "Ошибка"; pause ;;
            4) draw_header; link=$(get_link "${INSTANCE_APIS[$n]}"); \
               [[ -n "$link" ]] && echo -e "\n  ${GREEN}$link${RESET}\n" || warn "API не ответил"; pause ;;
            5) draw_header; journalctl -u "telemt${n}" -n 40 --no-pager; pause ;;
            6) draw_header; echo ""; cat "/etc/telemt/telemt${n}.toml" 2>/dev/null || warn "Конфиг не найден"; pause ;;
            0|b) return ;;
        esac
    done
}

proxy_update() {
    draw_header
    echo -e "  ${BOLD}Обновление бинарника telemt${RESET}\n"
    local cur; cur=$(/bin/telemt --version 2>&1 || echo "неизвестна")
    info "Текущая версия: ${BOLD}$cur${RESET}"
    echo ""
    read -rp "  Скачать и установить новую версию? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return
    echo ""
    info "Скачивание..."
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do systemctl stop "telemt${n}" 2>/dev/null || true; done
    cd /tmp && wget -qO- \
        "https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz" \
        | tar -xz
    mv /tmp/telemt /bin/telemt && chmod +x /bin/telemt
    for n in "${insts[@]}"; do systemctl start "telemt${n}" 2>/dev/null || true; done
    ok "Обновлено: $(/bin/telemt --version 2>&1)"
    pause
}

proxy_logs() {
    draw_header
    echo -e "  ${BOLD}Просмотр логов${RESET}\n"
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        echo -e "  ${BOLD}$n${RESET}) telemt${n}  (порт ${INSTANCE_PORTS[$n]})"
    done
    echo -e "  ${BOLD}a${RESET}) Все инстансы"
    echo ""
    read -rp "  Выберите: " ch
    draw_header
    if [[ "$ch" == "a" ]]; then
        for n in "${insts[@]}"; do
            echo -e "\n${BOLD}${CYAN}── telemt${n} ──────────────────────────────${RESET}"
            journalctl -u "telemt${n}" -n 20 --no-pager
        done
    elif [[ "$ch" =~ ^([1-9]|10)$ ]] && [[ -f "/etc/systemd/system/telemt${ch}.service" ]]; then
        journalctl -u "telemt${ch}" -n 60 --no-pager
    else
        warn "Неверный выбор"
    fi
    pause
}

# ─── Синхронизация зависимостей при изменениях инстансов ─────────────────────

# UFW: добавить правило порта
ufw_add_port() {
    local port=$1
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 && ok "UFW: порт $port открыт" || warn "UFW: не удалось открыть $port"
    fi
}

# UFW: удалить правило порта
ufw_del_port() {
    local port=$1
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 && ok "UFW: порт $port закрыт" || true
    fi
}

# UFW rate-limit: перегенерировать правила в before.rules под актуальные порты
ufw_resync_ratelimit() {
    if ! grep -q "MTProto rate-limit" /etc/ufw/before.rules 2>/dev/null; then
        return 0  # rate-limit не установлен — нечего синхронизировать
    fi

    # Собираем актуальные порты из активных конфигов
    local ports=()
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        local p; p=$(grep -m1 '^\s*port\s*=' "$f" 2>/dev/null | grep -oE '[0-9]+')
        [[ -n "$p" ]] && ports+=("$p")
    done

    info "Пересинхронизация rate-limit (xt_recent) для портов: ${ports[*]:-(нет)}"
    cp /etc/ufw/before.rules "/etc/ufw/before.rules.bak.$(date +%s)"

    local port_list=""
    [[ ${#ports[@]} -gt 0 ]] && port_list=$(IFS=,; echo "${ports[*]}")

    python3 - "$port_list" << 'PYEOF'
import sys
ports = [int(p) for p in sys.argv[1].split(",") if p]
path = "/etc/ufw/before.rules"
lines = open(path).readlines()
# Удаляем старый блок
out, skip = [], False
for l in lines:
    if "MTProto rate-limit" in l and "конец" not in l: skip = True
    if not skip: out.append(l)
    if "конец MTProto rate-limit" in l: skip = False
# Если порты есть — вставляем новый блок
if ports:
    idx = None
    for i, l in enumerate(out):
        if "ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" in l:
            idx = i + 1; break
    if idx is not None:
        block = ["\n# === MTProto rate-limit (1 SYN/сек на IP per-port) ===\n"]
        for p in ports:
            block.append(f"-A ufw-before-input -p tcp --dport {p} --syn -m recent --name mtp{p} --rcheck --seconds 1 -j DROP\n")
            block.append(f"-A ufw-before-input -p tcp --dport {p} --syn -m recent --name mtp{p} --set -j ACCEPT\n")
        block.append("# === конец MTProto rate-limit ===\n")
        out[idx:idx] = block
open(path,"w").writelines(out)
print(f"  {len(ports)} портов в rate-limit")
PYEOF
    ufw reload >/dev/null 2>&1 && ok "UFW перезагружен" || warn "Ошибка ufw reload"
}

# nft SYN limiter: перегенерировать правила
nft_resync() {
    if [[ ! -f /usr/local/sbin/telemt-nft-limit.sh ]]; then
        return 0  # nft не установлен
    fi

    info "Пересинхронизация nft SYN limiter под актуальные порты..."

    # Получаем параметры из существующего скрипта
    local rate burst timeout ip
    rate=$(grep -oP '(?<=^RATE=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "1/second")
    burst=$(grep -oP '(?<=^BURST=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "1")
    timeout=$(grep -oP '(?<=^METER_TIMEOUT=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "60s")
    ip=$(grep -oP '(?<=^SERVER_IP=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null)

    if [[ -z "$ip" ]]; then
        ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
             || ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' \
             || hostname -I | awk '{print $1}')
    fi

    # Собираем актуальные порты
    local ports=()
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        local p; p=$(grep -m1 '^\s*port\s*=' "$f" 2>/dev/null | grep -oE '[0-9]+')
        [[ -n "$p" ]] && ports+=("$p")
    done

    # Перезаписываем скрипт telemt-nft-limit.sh
    {
        echo '#!/bin/bash'
        echo '# telemt nft inbound SYN per-client limiter (auto-regenerated)'
        echo 'set -eu'
        echo ''
        echo 'TABLE="telemt_limit"'
        echo "SERVER_IP=\"${ip}\""
        echo "RATE=\"${rate}\""
        echo "BURST=\"${burst}\""
        echo "METER_TIMEOUT=\"${timeout}\""
        echo ''
        echo 'nft delete table inet "$TABLE" 2>/dev/null || true'
        echo 'nft add table inet "$TABLE"'
        echo 'nft "add chain inet $TABLE input { type filter hook input priority 0; policy accept; }"'
        echo ''
        for p in "${ports[@]}"; do
            echo "nft \"add rule inet \$TABLE input ip daddr \$SERVER_IP tcp dport ${p} tcp flags & (syn | ack) == syn meter telemt_in_syn_p${p} { ip saddr timeout \$METER_TIMEOUT limit rate over \$RATE burst \$BURST packets } counter drop comment \\\"telemt_syn_p${p}\\\"\""
            echo "echo \"Правило применено: порт ${p}\""
        done
        echo ''
        echo 'echo "=== Применённые правила ==="'
        echo 'nft list chain inet telemt_limit input'
    } > /usr/local/sbin/telemt-nft-limit.sh
    chmod +x /usr/local/sbin/telemt-nft-limit.sh

    if [[ ${#ports[@]} -eq 0 ]]; then
        # Нет инстансов — просто очищаем таблицу
        nft delete table inet telemt_limit 2>/dev/null || true
        ok "nft: таблица удалена (нет инстансов)"
    else
        /usr/local/sbin/telemt-nft-limit.sh >/dev/null 2>&1 && \
            ok "nft: правила обновлены для портов ${ports[*]}" || \
            warn "Ошибка применения nft-правил"
    fi
}

# ─── Добавление нового инстанса ──────────────────────────────────────────────
proxy_add() {
    draw_header
    echo -e "  ${BOLD}Добавление нового инстанса telemt${RESET}\n"

    # Находим свободный слот
    local slot; slot=$(next_free_slot)
    if [[ -z "$slot" ]]; then
        err "Достигнут лимит в 10 инстансов. Сначала удалите ненужные."
        pause; return
    fi
    info "Будет создан инстанс ${BOLD}#${slot}${RESET}"
    echo ""

    # Собираем уже занятые порты
    local used_ports=()
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        local p; p=$(grep -m1 '^\s*port\s*=' "$f" 2>/dev/null | grep -oE '[0-9]+')
        [[ -n "$p" ]] && used_ports+=("$p")
    done

    echo -e "  ${DIM}Уже заняты порты: ${used_ports[*]:-(нет)}${RESET}"
    echo ""

    # ── Меню выбора пресета ──
    echo -e "  ${BOLD}Выберите тип инстанса:${RESET}"
    echo -e "  ${GREEN}1${RESET} — порт ${BOLD}443${RESET}   | ${CYAN}www.cloudflare.com${RESET}  (HTTPS/CDN)"
    echo -e "  ${GREEN}2${RESET} — порт ${BOLD}5223${RESET}  | ${CYAN}www.apple.com${RESET}       (Apple Push / Anti-DPI)"
    echo -e "  ${GREEN}3${RESET} — порт ${BOLD}8530${RESET}  | ${CYAN}www.microsoft.com${RESET}   (Windows Update)"
    echo -e "  ${GREEN}4${RESET} — ${BOLD}свой инстанс${RESET} (вручную SNI и порт)"
    echo -e "  ${BOLD}0${RESET} — отмена"
    echo ""

    local new_port new_sni
    local -A presets_port=([1]=443 [2]=5223 [3]=8530)
    local -A presets_sni=([1]="www.cloudflare.com" [2]="www.apple.com" [3]="www.microsoft.com")

    while true; do
        read -rp "  ? Тип инстанса [1/2/3/4/0]: " preset
        case "$preset" in
            1|2|3)
                new_port="${presets_port[$preset]}"
                new_sni="${presets_sni[$preset]}"
                # Проверяем что порт пресета не занят
                local dup=false
                for p in "${used_ports[@]}"; do [[ "$p" == "$new_port" ]] && dup=true && break; done
                if [[ "$dup" == true ]]; then
                    warn "Порт пресета ${new_port} уже занят. Выберите другой тип или используйте 'свой инстанс' (4)."
                    continue
                fi
                ok "Выбрано: порт=${BOLD}${new_port}${RESET}  SNI=${CYAN}${new_sni}${RESET}"
                break
                ;;
            4)
                echo ""
                echo -e "  ${DIM}Популярные SNI: www.cloudflare.com, www.apple.com, www.microsoft.com,${RESET}"
                echo -e "  ${DIM}                www.google.com, www.amazon.com, www.youtube.com${RESET}"
                # Сначала SNI
                while true; do
                    read -rp "  ? SNI домен: " new_sni
                    if [[ -n "$new_sni" && "$new_sni" == *.* ]]; then
                        break
                    else
                        warn "Введите корректный домен (например www.google.com)"
                    fi
                done
                # Затем порт
                while true; do
                    read -rp "  ? Порт (1-65535): " new_port
                    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
                        warn "Порт должен быть числом от 1 до 65535"; continue
                    fi
                    local dup=false
                    for p in "${used_ports[@]}"; do [[ "$p" == "$new_port" ]] && dup=true && break; done
                    if [[ "$dup" == true ]]; then
                        warn "Порт $new_port уже занят другим инстансом"
                    else
                        break
                    fi
                done
                break
                ;;
            0|q)
                info "Отменено"; pause; return ;;
            *)
                warn "Введите 1, 2, 3, 4 или 0" ;;
        esac
    done

    # Генерация секрета
    local new_secret; new_secret=$(openssl rand -hex 16)

    # Получаем настройки таймаутов из существующих конфигов (если включены)
    local has_timeouts=false tm_tg=10 tm_hs=15 tm_ka=60
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        if grep -q '\[timeouts\]' "$f" 2>/dev/null; then
            has_timeouts=true
            tm_tg=$(grep -m1 'tg_connect' "$f" 2>/dev/null | grep -oE '[0-9]+' || echo 10)
            tm_hs=$(grep -m1 'client_handshake' "$f" 2>/dev/null | grep -oE '[0-9]+' || echo 15)
            tm_ka=$(grep -m1 'client_keepalive' "$f" 2>/dev/null | grep -oE '[0-9]+' || echo 60)
            break
        fi
    done

    echo ""
    echo -e "  ${BOLD}Будет создан инстанс:${RESET}"
    echo -e "    Слот:    ${BOLD}${slot}${RESET}"
    echo -e "    Порт:    ${BOLD}${new_port}${RESET}"
    echo -e "    SNI:     ${CYAN}${new_sni}${RESET}"
    echo -e "    API:     127.0.0.1:${INSTANCE_APIS[$slot]}"
    echo -e "    Секрет:  ${BOLD}${new_secret}${RESET}"
    [[ "$has_timeouts" == true ]] && \
        echo -e "    Таймауты: tg_connect=$tm_tg handshake=$tm_hs keepalive=$tm_ka ${DIM}(скопированы)${RESET}"
    echo ""
    read -rp "  Подтвердить создание? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && { info "Отменено"; pause; return; }

    # Создаём конфиг
    local tg_line=""
    [[ "$has_timeouts" == true ]] && tg_line="tg_connect = ${tm_tg}"
    local pub_ip; pub_ip=$(get_public_ip)
    if [[ -z "$pub_ip" ]]; then
        warn "Не удалось определить публичный IP. Введите вручную."
        read -rp "  IP сервера: " pub_ip
    else
        info "Публичный IP сервера: ${BOLD}${pub_ip}${RESET}"
    fi

    cat > "/etc/telemt/telemt${slot}.toml" << TOML
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
public_host = "${pub_ip}"

[network]
ipv4 = true
ipv6 = false
prefer = 4

[server]
port = ${new_port}
listen_addr_ipv4 = "0.0.0.0"
client_mss = "tspu"

[server.api]
enabled = true
listen = "127.0.0.1:${INSTANCE_APIS[$slot]}"
whitelist = ["127.0.0.1/32"]

[censorship]
tls_domain = "${new_sni}"
mask = true
mask_port = 443
tls_emulation = true
unknown_sni_action = "reject_handshake"
fake_cert_len = 2048

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
user${slot} = "${new_secret}"
TOML

    if [[ "$has_timeouts" == true ]]; then
        cat >> "/etc/telemt/telemt${slot}.toml" << TOMLTIME

[timeouts]
client_handshake = ${tm_hs}
client_keepalive = ${tm_ka}
TOMLTIME
    fi

    chown -R telemt:telemt /etc/telemt 2>/dev/null || true
    ok "Конфиг /etc/telemt/telemt${slot}.toml создан"

    # Обновляем нашу копию данных
    INSTANCE_PORTS[$slot]="$new_port"
    INSTANCE_DOMAINS[$slot]="$new_sni"

    # Создаём systemd-сервис
    cat > "/etc/systemd/system/telemt${slot}.service" << SERVICE
[Unit]
Description=Telemt Proxy ${slot} (port ${new_port} / ${new_sni})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/bin/telemt /etc/telemt/telemt${slot}.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    ok "Сервис telemt${slot}.service создан"

    # Открываем порт в UFW
    ufw_add_port "$new_port"

    # Синхронизируем зависимости
    ufw_resync_ratelimit
    nft_resync

    # Запускаем
    systemctl enable "telemt${slot}" >/dev/null 2>&1
    if systemctl start "telemt${slot}" 2>/dev/null; then
        sleep 2
        local st; st=$(systemctl is-active "telemt${slot}")
        if [[ "$st" == "active" ]]; then
            ok "Инстанс telemt${slot} запущен"
        else
            err "Инстанс не запустился, статус: $st"
            warn "Проверьте: journalctl -u telemt${slot} -n 30"
        fi
    else
        err "systemctl start telemt${slot} вернул ошибку"
    fi

    # Показываем ссылку
    echo ""
    info "Получение ссылки для клиента..."
    sleep 3
    local link; link=$(get_link "${INSTANCE_APIS[$slot]}")
    if [[ -n "$link" ]]; then
        echo -e "  ${GREEN}${link}${RESET}"
    else
        warn "API ещё не ответил. Получите ссылку позже из главного меню."
    fi
    pause
}

# ─── Удаление отдельного инстанса ────────────────────────────────────────────
proxy_remove_single() {
    draw_header
    echo -e "  ${BOLD}${YELLOW}Удаление отдельного инстанса${RESET}\n"

    local insts; read -ra insts <<< "$(active_instances)"
    if [[ ${#insts[@]} -eq 0 ]]; then
        warn "Нет установленных инстансов"
        pause; return
    fi

    echo -e "  ${BOLD}Доступные инстансы:${RESET}"
    for n in "${insts[@]}"; do
        local st; st=$(svc_status "$n")
        printf "    ${BOLD}%-2s${RESET}  порт %-6s  %-24s  %b\n" \
            "$n" "${INSTANCE_PORTS[$n]}" "${INSTANCE_DOMAINS[$n]}" "$(svc_status_color "$st")"
    done
    echo ""
    read -rp "  Номер инстанса для удаления (или 'q' для отмены): " n
    [[ "$n" == "q" || -z "$n" ]] && return
    if ! [[ "$n" =~ ^([1-9]|10)$ ]] || [[ ! -f "/etc/telemt/telemt${n}.toml" ]]; then
        warn "Инстанс $n не существует"; pause; return
    fi

    local port="${INSTANCE_PORTS[$n]}"
    local domain="${INSTANCE_DOMAINS[$n]}"

    echo ""
    warn "Будет удалён инстанс ${BOLD}#${n}${RESET} — порт ${BOLD}${port}${RESET}, SNI ${CYAN}${domain}${RESET}"
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && { info "Отменено"; pause; return; }

    # Останавливаем и удаляем сервис
    systemctl stop    "telemt${n}" 2>/dev/null || true
    systemctl disable "telemt${n}" 2>/dev/null || true
    rm -f "/etc/systemd/system/telemt${n}.service"
    systemctl daemon-reload
    ok "Сервис telemt${n} удалён"

    # Удаляем конфиг
    rm -f "/etc/telemt/telemt${n}.toml"
    ok "Конфиг telemt${n}.toml удалён"

    # Сбрасываем в массивах
    INSTANCE_PORTS[$n]=0
    INSTANCE_DOMAINS[$n]=""

    # Спрашиваем закрыть ли порт в UFW
    if ufw status 2>/dev/null | grep -qE "${port}/tcp"; then
        read -rp "  Закрыть порт $port в UFW? [Y/n]: " ans_ufw
        [[ ! "${ans_ufw,,}" =~ ^(n|no)$ ]] && ufw_del_port "$port"
    fi

    # Синхронизируем зависимости
    ufw_resync_ratelimit
    nft_resync

    echo ""
    ok "Инстанс ${BOLD}#${n}${RESET} полностью удалён"
    local remaining; read -ra remaining <<< "$(active_instances)"
    info "Оставшиеся инстансы: ${remaining[*]:-(нет)}"
    pause
}

proxy_remove() {
    draw_header
    echo -e "  ${BOLD}${RED}Полное удаление telemt${RESET}\n"
    warn "Это остановит и удалит ВСЕ инстансы, конфиги и бинарник."
    warn "UFW-правила, keepalive и nft-правила — опционально (спрошу отдельно)."
    echo ""
    read -rp "  Введите 'УДАЛИТЬ' для подтверждения: " ans
    [[ "$ans" != "УДАЛИТЬ" ]] && { info "Отменено."; pause; return; }

    # Сервисы
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        systemctl stop    "telemt${n}" 2>/dev/null || true
        systemctl disable "telemt${n}" 2>/dev/null || true
        rm -f "/etc/systemd/system/telemt${n}.service"
        ok "telemt${n} удалён"
    done
    systemctl daemon-reload

    # Конфиги и бинарник
    rm -rf /etc/telemt /opt/telemt
    rm -f  /bin/telemt
    userdel telemt 2>/dev/null || true
    ok "Файлы telemt удалены"

    # nft-сервис
    if [[ -f /etc/systemd/system/telemt-nft-limit.service ]]; then
        echo ""
        read -rp "  Удалить также nft SYN limiter? [Y/n]: " ans2
        if [[ ! "${ans2,,}" =~ ^(n|no)$ ]]; then
            systemctl stop    telemt-nft-limit.service 2>/dev/null || true
            systemctl disable telemt-nft-limit.service 2>/dev/null || true
            rm -f /etc/systemd/system/telemt-nft-limit.service
            rm -f /usr/local/sbin/telemt-nft-limit.sh
            nft delete table inet telemt_limit 2>/dev/null || true
            ok "nft limiter удалён"
        fi
    fi

    # keepalive + BBR
    if [[ -f /etc/sysctl.d/99-telemt-net.conf || -f /etc/sysctl.d/99-tg-keepalive.conf ]]; then
        echo ""
        read -rp "  Откатить сетевой тюнинг (keepalive + BBR) к дефолтам? [Y/n]: " ans3
        if [[ ! "${ans3,,}" =~ ^(n|no)$ ]]; then
            rm -f /etc/sysctl.d/99-telemt-net.conf /etc/sysctl.d/99-tg-keepalive.conf
            sysctl -w net.ipv4.tcp_keepalive_time=7200 \
                      net.ipv4.tcp_keepalive_intvl=75  \
                      net.ipv4.tcp_keepalive_probes=9  \
                      net.core.default_qdisc=fq_codel  \
                      net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1 || true
            sysctl --system > /dev/null
            ok "Keepalive + BBR сброшены к системным дефолтам"
        fi
    fi

    # UFW
    echo ""
    read -rp "  Удалить UFW-правила портов telemt? [Y/n]: " ans4
    if [[ ! "${ans4,,}" =~ ^(n|no)$ ]]; then
        ufw delete allow 443/tcp  2>/dev/null || true
        ufw delete allow 5223/tcp 2>/dev/null || true
        ufw delete allow 8530/tcp 2>/dev/null || true
        # Убираем rate-limit из before.rules
        if grep -q "MTProto rate-limit" /etc/ufw/before.rules 2>/dev/null; then
            python3 << 'PYEOF'
path = "/etc/ufw/before.rules"
lines = open(path).readlines()
out, skip = [], False
for l in lines:
    if "MTProto rate-limit" in l and "===" in l and "конец" not in l: skip = True
    if not skip: out.append(l)
    if "конец MTProto rate-limit" in l: skip = False
open(path,"w").writelines(out)
print("  rate-limit убран из before.rules")
PYEOF
            ufw reload
        fi
        ok "UFW-правила telemt удалены"
    fi

    echo ""
    ok "${BOLD}Удаление завершено.${RESET}"
    echo ""
    info "Команда mytelemtinfo больше не нужна. Удалить её:"
    echo -e "  ${DIM}rm -f /usr/local/bin/mytelemtinfo${RESET}"
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  2. СЕТЕВОЙ ТЮНИНГ (Keepalive + BBR)
# ════════════════════════════════════════════════════════════════════════

# Запись объединённого sysctl-файла (атомарно, по флагам)
# Параметры: $1=keepalive_enabled $2=bbr_enabled $3=t $4=i $5=p
netconf_write() {
    local ka="$1" bbr="$2" t="${3:-60}" i="${4:-15}" p="${5:-3}"
    local file="/etc/sysctl.d/99-telemt-net.conf"

    # Если оба выключены — удаляем файл и откатываем значения к дефолтам ядра
    if [[ "$ka" != true && "$bbr" != true ]]; then
        rm -f "$file" /etc/sysctl.d/99-tg-keepalive.conf
        sysctl -w net.ipv4.tcp_keepalive_time=7200 \
                  net.ipv4.tcp_keepalive_intvl=75  \
                  net.ipv4.tcp_keepalive_probes=9 \
                  net.core.default_qdisc=fq_codel  \
                  net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1 || true
        sysctl --system > /dev/null 2>&1
        return 0
    fi

    {
        echo "# telemt — сетевой тюнинг ядра"
        echo ""
        if [[ "$ka" == true ]]; then
            echo "# --- TCP keepalive: фикс залипания iOS-клиентов после фона ---"
            echo "net.ipv4.tcp_keepalive_time = $t"
            echo "net.ipv4.tcp_keepalive_intvl = $i"
            echo "net.ipv4.tcp_keepalive_probes = $p"
            echo ""
        fi
        if [[ "$bbr" == true ]]; then
            echo "# --- BBR + fq qdisc ---"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
    } > "$file"

    # Если был старый файл — удаляем
    [[ -f /etc/sysctl.d/99-tg-keepalive.conf ]] && rm -f /etc/sysctl.d/99-tg-keepalive.conf
    sysctl --system > /dev/null 2>&1
}

# Прочитать текущее включено-ли что-то
netconf_keepalive_on() {
    grep -q "tcp_keepalive_time" /etc/sysctl.d/99-telemt-net.conf 2>/dev/null && return 0
    [[ -f /etc/sysctl.d/99-tg-keepalive.conf ]] && return 0
    return 1
}
netconf_bbr_on() {
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]
}

menu_keepalive() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Сетевой тюнинг ядра${RESET}\n"
        echo -e "  Keepalive: $(status_keepalive)"
        echo -e "  BBR + fq:  $(status_bbr)"
        echo ""

        local t i p cc qdisc bbr_avail
        t=$(sysctl -n net.ipv4.tcp_keepalive_time  2>/dev/null || echo "—")
        i=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "—")
        p=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "—")
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "—")
        qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "—")
        bbr_avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -o bbr || echo "")

        echo -e "  ${DIM}Текущие значения ядра:${RESET}"
        echo -e "  tcp_keepalive_time/intvl/probes = ${BOLD}${t}${RESET} / ${BOLD}${i}${RESET} / ${BOLD}${p}${RESET}"
        echo -e "  tcp_congestion_control           = ${BOLD}${cc}${RESET}"
        echo -e "  default_qdisc                    = ${BOLD}${qdisc}${RESET}"
        [[ -z "$bbr_avail" ]] && echo -e "  ${YELLOW}⚠ BBR недоступен в этом ядре${RESET}"
        echo ""

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo -e "  ${BOLD}── Keepalive (фикс iOS-фона) ──${RESET}"
        echo -e "  ${BOLD}1.${RESET} Применить рекомендуемые значения (60/15/3)"
        echo -e "  ${BOLD}2.${RESET} Изменить значения keepalive вручную"
        echo -e "  ${BOLD}3.${RESET} Диагностика keepalive на активных соединениях"
        echo -e "  ${BOLD}4.${RESET} ${YELLOW}Отключить keepalive${RESET} (откат к дефолтам)"
        echo ""
        echo -e "  ${BOLD}── BBR + fq qdisc ──${RESET}"
        echo -e "  ${BOLD}5.${RESET} Включить BBR + fq"
        echo -e "  ${BOLD}6.${RESET} ${YELLOW}Отключить BBR${RESET} (вернуть cubic + fq_codel)"
        echo ""
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch
        case "$ch" in
            1) keepalive_apply 60 15 3 ;;
            2) keepalive_custom ;;
            3) keepalive_diag ;;
            4) keepalive_off ;;
            5) bbr_on ;;
            6) bbr_off ;;
            0|b) return ;;
            *) warn "Неверный пункт"; sleep 1 ;;
        esac
    done
}

keepalive_apply() {
    local t=${1} i=${2} p=${3}
    draw_header
    echo -e "  ${BOLD}Применение настроек keepalive${RESET}\n"
    echo -e "  time=${BOLD}$t${RESET}  intvl=${BOLD}$i${RESET}  probes=${BOLD}$p${RESET}"
    echo -e "  Мёртвый коннект будет рваться за ~$((t + i * p))с"
    echo ""
    read -rp "  Применить? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && return

    # Сохраняем BBR-статус
    local bbr=false
    netconf_bbr_on && bbr=true

    netconf_write true "$bbr" "$t" "$i" "$p"
    ok "Применено: keepalive time=$t intvl=$i probes=$p"
    pause
}

keepalive_off() {
    draw_header
    echo -e "  ${BOLD}Отключение TCP keepalive${RESET}\n"
    warn "Значения вернутся к дефолтам ядра: time=7200 intvl=75 probes=9"
    echo ""
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    local bbr=false
    netconf_bbr_on && bbr=true

    # Если BBR был включён — оставляем только его в файле
    netconf_write false "$bbr"
    sysctl -w net.ipv4.tcp_keepalive_time=7200 \
              net.ipv4.tcp_keepalive_intvl=75  \
              net.ipv4.tcp_keepalive_probes=9 > /dev/null 2>&1
    ok "Keepalive отключён (дефолты ядра)"
    pause
}

bbr_on() {
    draw_header
    echo -e "  ${BOLD}Включение BBR + fq qdisc${RESET}\n"

    # Проверяем доступность BBR
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        info "Попытка загрузить модуль tcp_bbr..."
        modprobe tcp_bbr 2>/dev/null || true
        if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            err "BBR недоступен в этом ядре. Нужно обновить ядро (4.9+)."
            pause; return
        fi
        ok "Модуль tcp_bbr загружен"
    fi

    echo -e "  Будет установлено:"
    echo -e "    net.core.default_qdisc = ${BOLD}fq${RESET}"
    echo -e "    net.ipv4.tcp_congestion_control = ${BOLD}bbr${RESET}"
    echo ""
    read -rp "  Применить? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && return

    local ka=false
    netconf_keepalive_on && ka=true
    netconf_write "$ka" true

    # Текущие значения для отображения
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    qdisc=$(sysctl -n net.core.default_qdisc)
    ok "BBR включён: congestion=${BOLD}${cc}${RESET} qdisc=${BOLD}${qdisc}${RESET}"
    pause
}

bbr_off() {
    draw_header
    echo -e "  ${BOLD}Отключение BBR${RESET}\n"
    warn "Вернётся стандартный congestion control (cubic) и qdisc (fq_codel)"
    echo ""
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    local ka=false
    netconf_keepalive_on && ka=true
    netconf_write "$ka" false

    sysctl -w net.core.default_qdisc=fq_codel \
              net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
    ok "BBR отключён (cubic + fq_codel)"
    pause
}

keepalive_custom() {
    draw_header
    echo -e "  ${BOLD}Настройка TCP keepalive вручную${RESET}\n"
    echo -e "  ${DIM}Рекомендуется: time=60 intvl=15 probes=3${RESET}"
    echo -e "  ${DIM}Дефолты ядра:  time=7200 intvl=75 probes=9${RESET}\n"

    local cur_t cur_i cur_p
    cur_t=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo 60)
    cur_i=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo 15)
    cur_p=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo 3)

    read -rp "  tcp_keepalive_time   [${cur_t}]: " t;   t="${t:-$cur_t}"
    read -rp "  tcp_keepalive_intvl  [${cur_i}]: " i;   i="${i:-$cur_i}"
    read -rp "  tcp_keepalive_probes [${cur_p}]: " p;   p="${p:-$cur_p}"

    # Валидация
    if ! [[ "$t" =~ ^[0-9]+$ && "$i" =~ ^[0-9]+$ && "$p" =~ ^[0-9]+$ ]]; then
        err "Значения должны быть целыми числами"; pause; return
    fi
    keepalive_apply "$t" "$i" "$p"
}

keepalive_diag() {
    draw_header
    echo -e "  ${BOLD}Диагностика keepalive на активных соединениях${RESET}\n"
    python3 << 'PYEOF'
import subprocess, re, glob
from collections import Counter

ports = set()
for f in glob.glob("/etc/telemt/*.toml"):
    for line in open(f):
        m = re.match(r'\s*port\s*=\s*(\d+)', line)
        if m: ports.add(m.group(1))

out = subprocess.run(["ss","-tinoH","state","established"],
                     capture_output=True, text=True).stdout
records, buf = [], ""
for ln in out.split("\n"):
    if not ln.strip(): continue
    if ln[0].isspace(): buf += " " + ln.strip()
    else:
        if buf: records.append(buf)
        buf = ln.strip()
if buf: records.append(buf)

timers, countdowns, total = Counter(), Counter(), 0
for r in records:
    f = r.split()
    local = f[2] if len(f) > 2 else ""
    if not any(local.endswith(":"+p) for p in ports): continue
    total += 1
    m = re.search(r'timer:\((\w+)', r)
    timers[m.group(1) if m else "—"] += 1
    m2 = re.search(r'timer:\(keepalive,([^,)]+)', r)
    if m2: countdowns[m2.group(1)] += 1

W = 46
print("  ╭" + "─"*W + "╮")
print("  │ " + "KEEPALIVE CHECK".ljust(W-1) + "│")
print("  ├" + "─"*W + "┤")
print("  │ " + f"Порты telemt:    {', '.join(sorted(ports)) or '—'}".ljust(W-1) + "│")
print("  │ " + f"Соединений всего: {total}".ljust(W-1) + "│")
print("  ├" + "─"*W + "┤")
if total == 0:
    print("  │ " + "Нет активных соединений".ljust(W-1) + "│")
else:
    for name, cnt in timers.most_common():
        bar = "█" * min(cnt, 20)
        print("  │ " + f"  {name:<12} {cnt:>4}  {bar}".ljust(W-1) + "│")
    if countdowns:
        print("  ├" + "─"*W + "┤")
        print("  │ " + "Обратный отсчёт keepalive:".ljust(W-1) + "│")
        def secs(v):
            n = float(re.findall(r'[0-9.]+', v)[0])
            if 'ms' in v: return n/1000
            if 'min' in v: return n*60
            return n
        for val, cnt in sorted(countdowns.items(), key=lambda x: secs(x[0])):
            bar = "█" * min(cnt, 20)
            print("  │ " + f"  {val:<12} {cnt:>3}  {bar}".ljust(W-1) + "│")
print("  ╰" + "─"*W + "╯")
PYEOF
    pause
}

keepalive_reset() {
    # Алиас для совместимости — вызывает новую keepalive_off
    keepalive_off
}

# ════════════════════════════════════════════════════════════════════════
#  3. nft SYN LIMITER
# ════════════════════════════════════════════════════════════════════════
menu_nft() {
    while true; do
        draw_header
        echo -e "  ${BOLD}nft inbound SYN per-client Limiter${RESET}\n"
        echo -e "  Статус: $(status_nft)"
        echo ""

        if nft list table inet telemt_limit &>/dev/null; then
            echo -e "  ${DIM}Активные правила:${RESET}"
            nft list chain inet telemt_limit input 2>/dev/null \
              | grep -E "dport|counter" \
              | sed 's/^/    /'
            echo ""
        fi

        # Читаем текущие параметры из скрипта
        local cur_rate cur_burst cur_timeout
        cur_rate=$(grep -oP '(?<=RATE=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "1/second")
        cur_burst=$(grep -oP '(?<=BURST=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "1")
        cur_timeout=$(grep -oP '(?<=METER_TIMEOUT=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "60s")

        echo -e "  ${DIM}Параметры: rate=${BOLD}${cur_rate}${RESET}${DIM}  burst=${BOLD}${cur_burst}${RESET}${DIM}  timeout=${BOLD}${cur_timeout}${RESET}"
        echo ""

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        if [[ ! -f /usr/local/sbin/telemt-nft-limit.sh ]]; then
            echo -e "  ${BOLD}1.${RESET} Установить nft SYN limiter"
        else
            echo -e "  ${BOLD}1.${RESET} Применить / перезапустить правила"
            echo -e "  ${BOLD}2.${RESET} Изменить параметры (rate / burst / timeout)"
            echo -e "  ${BOLD}3.${RESET} Показать счётчики дропов"
            echo -e "  ${BOLD}4.${RESET} ${YELLOW}Временно отключить правила${RESET}"
            echo -e "  ${BOLD}5.${RESET} ${RED}Удалить nft limiter полностью${RESET}"
        fi
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch
        case "$ch" in
            1) if [[ -f /usr/local/sbin/telemt-nft-limit.sh ]]; then
                   nft_apply_rules
               else
                   nft_install
               fi ;;
            2) nft_change_params ;;
            3) nft_show_counters ;;
            4) nft_disable_temp ;;
            5) nft_remove ;;
            0|b) return ;;
            *) warn "Неверный пункт"; sleep 1 ;;
        esac
    done
}

nft_apply_rules() {
    draw_header
    echo -e "  ${BOLD}Применение nft-правил...${RESET}\n"
    if /usr/local/sbin/telemt-nft-limit.sh; then
        ok "Правила применены"
    else
        err "Ошибка применения правил"
    fi
    pause
}

nft_install() {
    draw_header
    echo -e "  ${BOLD}Установка nft SYN Limiter${RESET}\n"
    info "Запустите установщик для настройки nft limiter:"
    echo -e "  ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-install/main/install.sh)${RESET}"
    echo -e "\n  Или установите nftables и создайте скрипт вручную по гайду:"
    echo -e "  ${CYAN}https://h1de0x.github.io/telemt-tune/${RESET}"
    pause
}

nft_change_params() {
    draw_header
    echo -e "  ${BOLD}Изменение параметров nft SYN limiter${RESET}\n"

    local cur_rate cur_burst cur_timeout
    cur_rate=$(grep -oP '(?<=RATE=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "1/second")
    cur_burst=$(grep -oP '(?<=BURST=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "1")
    cur_timeout=$(grep -oP '(?<=METER_TIMEOUT=")[^"]+' /usr/local/sbin/telemt-nft-limit.sh 2>/dev/null || echo "60s")

    echo -e "  ${DIM}Варианты rate:    1/second (жёстко) | 2/second (мягче)${RESET}"
    echo -e "  ${DIM}Варианты burst:   1 (строго) | 3 (мягче для многих клиентов)${RESET}"
    echo -e "  ${DIM}Варианты timeout: 30s (быстрее) | 60s (дефолт) | 120s (дольше)${RESET}\n"

    read -rp "  RATE        [${cur_rate}]: " new_rate;    new_rate="${new_rate:-$cur_rate}"
    read -rp "  BURST       [${cur_burst}]: " new_burst;  new_burst="${new_burst:-$cur_burst}"
    read -rp "  TIMEOUT     [${cur_timeout}]: " new_timeout; new_timeout="${new_timeout:-$cur_timeout}"
    echo ""
    read -rp "  Применить и перезапустить? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && return

    # Обновляем скрипт
    sed -i "s|^RATE=.*|RATE=\"${new_rate}\"|" /usr/local/sbin/telemt-nft-limit.sh
    sed -i "s|^BURST=.*|BURST=\"${new_burst}\"|" /usr/local/sbin/telemt-nft-limit.sh
    sed -i "s|^METER_TIMEOUT=.*|METER_TIMEOUT=\"${new_timeout}\"|" /usr/local/sbin/telemt-nft-limit.sh
    ok "Параметры обновлены в скрипте"
    /usr/local/sbin/telemt-nft-limit.sh && ok "Правила применены" || err "Ошибка"
    pause
}

nft_show_counters() {
    draw_header
    echo -e "  ${BOLD}Счётчики nft SYN limiter${RESET}\n"
    if nft list table inet telemt_limit &>/dev/null; then
        nft list chain inet telemt_limit input 2>/dev/null | sed 's/^/  /'
    else
        warn "Таблица telemt_limit не активна"
    fi
    pause
}

nft_disable_temp() {
    draw_header
    echo -e "  ${BOLD}Временное отключение nft правил${RESET}\n"
    warn "Правила будут удалены из памяти. После перезагрузки systemd их восстановит."
    read -rp "  Отключить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return
    nft delete table inet telemt_limit 2>/dev/null && ok "Таблица удалена" || warn "Таблица не существовала"
    pause
}

nft_remove() {
    draw_header
    echo -e "  ${BOLD}${RED}Удаление nft limiter${RESET}\n"
    read -rp "  Удалить скрипт, сервис и правила? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    systemctl stop    telemt-nft-limit.service 2>/dev/null || true
    systemctl disable telemt-nft-limit.service 2>/dev/null || true
    rm -f /etc/systemd/system/telemt-nft-limit.service
    rm -f /usr/local/sbin/telemt-nft-limit.sh
    nft delete table inet telemt_limit 2>/dev/null || true
    systemctl daemon-reload
    ok "nft limiter удалён"
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  4. ТАЙМАУТЫ TELEMT
# ════════════════════════════════════════════════════════════════════════
menu_timeouts() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Таймауты telemt [timeouts]${RESET}\n"
        echo -e "  Статус: $(status_timeouts)\n"

        # Показываем текущие значения по инстансам
        local insts; read -ra insts <<< "$(active_instances)"
        if [[ ${#insts[@]} -gt 0 ]]; then
            echo -e "  ${DIM}Значения по конфигам:${RESET}"
            for n in "${insts[@]}"; do
                local f="/etc/telemt/telemt${n}.toml"
                if grep -q '\[timeouts\]' "$f" 2>/dev/null; then
                    local hs ka
                    hs=$(grep 'client_handshake' "$f" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "15")
                    ka=$(grep 'client_keepalive' "$f" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "60")
                    echo -e "  Инстанс ${BOLD}$n${RESET}: handshake=${BOLD}$hs${RESET}  keepalive=${BOLD}$ka${RESET}"
                else
                    echo -e "  Инстанс ${BOLD}$n${RESET}: ${DIM}дефолты telemt (handshake=15 keepalive=60)${RESET}"
                fi
            done
            echo ""
        fi

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo -e "  ${BOLD}1.${RESET} Установить / изменить значения"
        echo -e "  ${BOLD}2.${RESET} Сбросить к дефолтам (удалить секцию [timeouts])"
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch
        case "$ch" in
            1) timeouts_set ;;
            2) timeouts_reset ;;
            0|b) return ;;
            *) warn "Неверный пункт"; sleep 1 ;;
        esac
    done
}

timeouts_set() {
    draw_header
    echo -e "  ${BOLD}Настройка [timeouts]${RESET}\n"
    echo -e "  ${DIM}tg_connect      — таймаут подключения к Telegram DC (сек)${RESET}"
    echo -e "  ${DIM}client_handshake— ожидание хендшейка клиента (сек)${RESET}"
    echo -e "  ${DIM}client_keepalive— ожидание активности клиента (сек)${RESET}"
    echo -e "  ${DIM}Дефолты: tg_connect=10  handshake=15  keepalive=60${RESET}"
    echo -e "  ${DIM}Для проблемных сетей: tg_connect=30  handshake=120  keepalive=90${RESET}\n"

    read -rp "  tg_connect       [10]: " tg;  tg="${tg:-10}"
    read -rp "  client_handshake [15]: " hs;  hs="${hs:-15}"
    read -rp "  client_keepalive [60]: " ka;  ka="${ka:-60}"

    if ! [[ "$tg" =~ ^[0-9]+$ && "$hs" =~ ^[0-9]+$ && "$ka" =~ ^[0-9]+$ ]]; then
        err "Значения должны быть целыми числами"; pause; return
    fi

    echo ""
    read -rp "  Применить к каким инстансам? [all]: " sel
    local insts; read -ra insts <<< "$(active_instances)"
    local targets=()
    if [[ -z "$sel" || "$sel" == "all" ]]; then
        targets=("${insts[@]}")
    else
        for n in $sel; do [[ -f "/etc/telemt/telemt${n}.toml" ]] && targets+=("$n"); done
    fi

    for n in "${targets[@]}"; do
        local f="/etc/telemt/telemt${n}.toml"
        python3 - "$f" "$tg" "$hs" "$ka" << 'PYEOF'
import sys, re
path, tg, hs, ka = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
content = open(path).read()

# 1. Удаляем существующую секцию [timeouts] (всё до следующей секции или EOF)
content = re.sub(r'\n*\[timeouts\][^\[]*', '\n', content, flags=re.DOTALL)

# 2. Удаляем все существующие строки tg_connect везде
content = re.sub(r'^\s*tg_connect\s*=.*\n', '', content, flags=re.MULTILINE)

# 3. Удаляем "висячие" блоки [general] без содержимого (после удаления tg_connect)
# Если после [general] идёт сразу другая секция — пропускаем такую "пустую" [general]
# Но обычно в [general] остаются fast_mode, use_middle_proxy — поэтому просто добавим tg_connect туда

# 4. Вставляем tg_connect в существующий [general] (после use_middle_proxy)
if 'tg_connect' not in content:
    if 'use_middle_proxy' in content:
        content = re.sub(
            r'(use_middle_proxy\s*=\s*\w+)',
            r'\1\ntg_connect = ' + tg,
            content, count=1
        )
    elif '[general]' in content:
        # Вставка прямо после строки [general]
        content = re.sub(
            r'(\[general\]\n)',
            r'\1tg_connect = ' + tg + '\n',
            content, count=1
        )

# 5. Очищаем тройные пустые строки
content = re.sub(r'\n{3,}', '\n\n', content)
if not content.endswith('\n'): content += '\n'

# 6. Добавляем [timeouts] в конец
content += f'\n[timeouts]\nclient_handshake = {hs}\nclient_keepalive = {ka}\n'

open(path, 'w').write(content)
PYEOF
        ok "Инстанс $n обновлён"
    done

    echo ""
    read -rp "  Перезапустить инстансы для применения? [Y/n]: " ans
    if [[ ! "${ans,,}" =~ ^(n|no)$ ]]; then
        for n in "${targets[@]}"; do
            systemctl restart "telemt${n}" 2>/dev/null && ok "telemt${n} перезапущен" || err "Ошибка"
        done
    fi
    pause
}

timeouts_reset() {
    draw_header
    echo -e "  ${BOLD}Сброс [timeouts] к дефолтам${RESET}\n"
    warn "Секция [timeouts] будет удалена из конфигов (telemt будет использовать дефолты)."
    echo ""
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        local f="/etc/telemt/telemt${n}.toml"
        python3 - "$f" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
# Удаляем секцию [timeouts] целиком
content = re.sub(r'\n*\[timeouts\][^\[]*', '\n', content, flags=re.DOTALL)
# Удаляем строки tg_connect (откатывает к дефолту telemt = 10)
content = re.sub(r'^\s*tg_connect\s*=.*\n', '', content, flags=re.MULTILINE)
# Чистим тройные пустые строки
content = re.sub(r'\n{3,}', '\n\n', content)
if not content.endswith('\n'): content += '\n'
open(path, 'w').write(content)
PYEOF
        ok "Инстанс $n — [timeouts] и tg_connect удалены"
    done

    echo ""
    read -rp "  Перезапустить инстансы? [Y/n]: " ans2
    if [[ ! "${ans2,,}" =~ ^(n|no)$ ]]; then
        for n in "${insts[@]}"; do
            systemctl restart "telemt${n}" 2>/dev/null && ok "telemt${n} перезапущен" || err "Ошибка"
        done
    fi
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  5. UFW / RATE-LIMIT
# ════════════════════════════════════════════════════════════════════════
menu_ufw() {
    while true; do
        draw_header
        echo -e "  ${BOLD}UFW / Rate-limit${RESET}\n"
        echo -e "  Статус: $(status_ufw)\n"

        # Показываем правила портов telemt
        echo -e "  ${DIM}Правила UFW для портов telemt:${RESET}"
        ufw status 2>/dev/null | grep -E "443|5223|8530" | sed 's/^/    /' || echo "    (нет)"
        echo ""

        # Rate-limit
        local rl_count; rl_count=$(grep -c "mtp" /etc/ufw/before.rules 2>/dev/null || echo 0)
        echo -e "  ${DIM}rate-limit (xt_recent): ${BOLD}${rl_count}${RESET}${DIM} правил в before.rules${RESET}"
        echo ""

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo -e "  ${BOLD}1.${RESET} Показать полный статус UFW"
        echo -e "  ${BOLD}2.${RESET} Включить UFW (если выключен)"
        echo -e "  ${BOLD}3.${RESET} Добавить rate-limit (xt_recent) для портов"
        echo -e "  ${BOLD}4.${RESET} ${YELLOW}Удалить rate-limit из before.rules${RESET}"
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch
        case "$ch" in
            1) draw_header; ufw status verbose 2>/dev/null | sed 's/^/  /'; pause ;;
            2) draw_header
               read -rp "  Включить UFW (убедитесь что SSH-порт открыт)? [y/N]: " ans
               [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]] && ufw --force enable && ok "UFW включён" || info "Отменено"
               pause ;;
            3) ufw_add_ratelimit ;;
            4) ufw_remove_ratelimit ;;
            0|b) return ;;
            *) warn "Неверный пункт"; sleep 1 ;;
        esac
    done
}

ufw_add_ratelimit() {
    draw_header
    echo -e "  ${BOLD}Добавить rate-limit (xt_recent)${RESET}\n"

    if grep -q "MTProto rate-limit" /etc/ufw/before.rules 2>/dev/null; then
        warn "Rate-limit уже добавлен в before.rules"
        pause; return
    fi

    modprobe xt_recent 2>/dev/null || { err "Модуль xt_recent недоступен"; pause; return; }
    if ! lsmod | grep -q xt_recent; then err "xt_recent не загружен"; pause; return; fi
    echo xt_recent > /etc/modules-load.d/xt_recent.conf

    # Определяем порты из активных конфигов
    local ports=()
    for f in /etc/telemt/telemt*.toml; do
        local p; p=$(grep -m1 '^\s*port\s*=' "$f" 2>/dev/null | grep -oE '[0-9]+')
        [[ -n "$p" ]] && ports+=("$p")
    done

    if [[ ${#ports[@]} -eq 0 ]]; then
        warn "Порты telemt не найдены (конфиги отсутствуют)"
        pause; return
    fi

    info "Порты для rate-limit: ${ports[*]}"
    read -rp "  Продолжить? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && return

    cp /etc/ufw/before.rules "/etc/ufw/before.rules.bak.$(date +%s)"
    local port_list; port_list=$(IFS=,; echo "${ports[*]}")
    python3 - "$port_list" << 'PYEOF'
import sys
PORTS = [int(p) for p in sys.argv[1].split(",")]
path = "/etc/ufw/before.rules"
lines = open(path).readlines()
if any("MTProto rate-limit" in l for l in lines):
    print("Уже есть"); raise SystemExit(0)
idx = None
for i, l in enumerate(lines):
    if "ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" in l:
        idx = i + 1; break
if idx is None:
    print("Точка вставки не найдена"); raise SystemExit(1)
block = ["\n# === MTProto rate-limit (1 SYN/сек на IP per-port) ===\n"]
for p in PORTS:
    block.append(f"-A ufw-before-input -p tcp --dport {p} --syn -m recent --name mtp{p} --rcheck --seconds 1 -j DROP\n")
    block.append(f"-A ufw-before-input -p tcp --dport {p} --syn -m recent --name mtp{p} --set -j ACCEPT\n")
block.append("# === конец MTProto rate-limit ===\n")
lines[idx:idx] = block
open(path, "w").writelines(lines)
print(f"Вставлено {len(block)} строк")
PYEOF
    ufw reload && ok "UFW перезагружен с rate-limit" || err "Ошибка ufw reload"
    pause
}

ufw_remove_ratelimit() {
    draw_header
    echo -e "  ${BOLD}Удалить rate-limit из before.rules${RESET}\n"
    if ! grep -q "MTProto rate-limit" /etc/ufw/before.rules 2>/dev/null; then
        warn "Rate-limit не найден в before.rules"
        pause; return
    fi
    read -rp "  Удалить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    python3 << 'PYEOF'
path = "/etc/ufw/before.rules"
lines = open(path).readlines()
out, skip = [], False
for l in lines:
    if "MTProto rate-limit" in l and "===" in l and "конец" not in l: skip = True
    if not skip: out.append(l)
    if "конец MTProto rate-limit" in l: skip = False
open(path,"w").writelines(out)
print("  Правила удалены")
PYEOF
    ufw reload && ok "UFW перезагружен" || err "Ошибка"
    rm -f /etc/modules-load.d/xt_recent.conf
    ok "xt_recent убран из автозагрузки"
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  6. СВОЙ ДОМЕН В ССЫЛКАХ
# ════════════════════════════════════════════════════════════════════════
menu_custom_domain() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Свой домен в ссылках для клиентов${RESET}\n"
        local cur; cur=$(get_custom_domain)
        if [[ -n "$cur" ]]; then
            echo -e "  Текущий домен: ${BOLD}${GREEN}${cur}${RESET}"
            # Проверяем DNS
            local resolved server_ip
            resolved=$(getent hosts "$cur" 2>/dev/null | awk '{print $1}' | head -1)
            server_ip=$(get_public_ip)
            if [[ -n "$resolved" && -n "$server_ip" ]]; then
                if [[ "$resolved" == "$server_ip" ]]; then
                    ok "DNS резолвится корректно: ${cur} → ${resolved} (IP сервера)"
                else
                    warn "DNS не совпадает: ${cur} → ${resolved}, IP сервера: ${server_ip}"
                fi
            fi
        else
            echo -e "  Текущий: ${DIM}не задан${RESET} — в ссылках используется реальный IP сервера"
        fi
        echo ""

        # Превью одной ссылки
        local insts; read -ra insts <<< "$(active_instances)"
        if [[ ${#insts[@]} -gt 0 ]]; then
            local first="${insts[0]}"
            local link; link=$(get_link "${INSTANCE_APIS[$first]}")
            if [[ -n "$link" ]]; then
                echo -e "  ${DIM}Пример ссылки сейчас:${RESET}"
                echo -e "  ${GREEN}${link}${RESET}"
                echo ""
            fi
        fi

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo -e "  ${BOLD}1.${RESET} Установить / изменить домен"
        echo -e "  ${BOLD}2.${RESET} Проверить DNS"
        echo -e "  ${BOLD}3.${RESET} ${YELLOW}Удалить домен${RESET} (вернуть IP в ссылках)"
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch
        case "$ch" in
            1) custom_domain_set ;;
            2) custom_domain_check ;;
            3) custom_domain_remove ;;
            0|b) return ;;
            *) warn "Неверный пункт"; sleep 1 ;;
        esac
    done
}

custom_domain_set() {
    draw_header
    echo -e "  ${BOLD}Установка собственного домена${RESET}\n"
    echo -e "  Этот домен будет использоваться в tg://proxy ссылках вместо IP."
    echo -e "  ${DIM}Требование: A-запись домен → IP сервера должна быть настроена.${RESET}"
    echo -e "  ${DIM}Telegram-клиент сам делает DNS-резолв при подключении.${RESET}"
    echo ""

    local server_ip; server_ip=$(get_public_ip)
    [[ -n "$server_ip" ]] && info "IP вашего сервера: ${BOLD}${server_ip}${RESET}"
    echo ""

    local inp_dom
    while true; do
        read -rp "  Введите домен (или 'q' для отмены): " inp_dom
        [[ "$inp_dom" == "q" || -z "$inp_dom" ]] && { info "Отменено"; pause; return; }
        if [[ "$inp_dom" == *.* ]]; then
            break
        else
            warn "Введите корректный домен (например proxy.example.com)"
        fi
    done

    # DNS проверка
    local resolved
    resolved=$(getent hosts "$inp_dom" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -n "$resolved" && -n "$server_ip" ]]; then
        if [[ "$resolved" == "$server_ip" ]]; then
            ok "DNS проверка пройдена: ${inp_dom} → ${resolved}"
        else
            warn "DNS не совпадает: ${inp_dom} → ${resolved}, IP сервера: ${server_ip}"
            warn "Возможные причины: A-запись не настроена / TTL ещё держит старое / CDN перед сервером"
            read -rp "  Сохранить домен несмотря на это? [y/N]: " ans
            [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && { info "Отменено"; pause; return; }
        fi
    else
        warn "Не удалось проверить DNS (нет соединения или DNS не настроен)"
        read -rp "  Сохранить домен? [Y/n]: " ans
        [[ "${ans,,}" =~ ^(n|no)$ ]] && { info "Отменено"; pause; return; }
    fi

    # Сохраняем
    mkdir -p /etc/telemt
    echo "$inp_dom" > "$CUSTOM_DOMAIN_FILE"
    chmod 644 "$CUSTOM_DOMAIN_FILE"
    ok "Сохранён домен: ${BOLD}${inp_dom}${RESET}"
    info "Теперь в ссылках tg://proxy будет использоваться этот домен."
    pause
}

custom_domain_check() {
    draw_header
    echo -e "  ${BOLD}Проверка DNS${RESET}\n"
    local dom; dom=$(get_custom_domain)
    if [[ -z "$dom" ]]; then
        warn "Домен не задан"; pause; return
    fi
    info "Проверка резолва для ${BOLD}${dom}${RESET}..."

    # Несколько проверок
    echo ""
    echo -e "  ${BOLD}1) Системный getent (использует /etc/resolv.conf):${RESET}"
    local sys_ip; sys_ip=$(getent hosts "$dom" 2>/dev/null | awk '{print $1}' | head -1)
    [[ -n "$sys_ip" ]] && echo "    → $sys_ip" || warn "    не резолвится"

    if command -v dig &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}2) Через публичный DNS Cloudflare (1.1.1.1):${RESET}"
        local cf_ip; cf_ip=$(dig +short @1.1.1.1 "$dom" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        [[ -n "$cf_ip" ]] && echo "    → $cf_ip" || warn "    не резолвится"

        echo ""
        echo -e "  ${BOLD}3) Через публичный DNS Google (8.8.8.8):${RESET}"
        local g_ip; g_ip=$(dig +short @8.8.8.8 "$dom" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        [[ -n "$g_ip" ]] && echo "    → $g_ip" || warn "    не резолвится"
    fi

    echo ""
    local server_ip; server_ip=$(get_public_ip)
    echo -e "  ${BOLD}IP сервера:${RESET} ${BOLD}${server_ip}${RESET}"

    if [[ -n "$sys_ip" && "$sys_ip" == "$server_ip" ]]; then
        echo ""
        ok "Всё работает: домен правильно указывает на сервер"
    fi
    pause
}

custom_domain_remove() {
    draw_header
    echo -e "  ${BOLD}Удаление кастомного домена${RESET}\n"
    local dom; dom=$(get_custom_domain)
    if [[ -z "$dom" ]]; then
        warn "Домен не задан — нечего удалять"; pause; return
    fi
    warn "Текущий домен: ${dom}"
    warn "После удаления в ссылках будет реальный IP сервера"
    echo ""
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    rm -f "$CUSTOM_DOMAIN_FILE"
    ok "Кастомный домен удалён"
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  7. VLESS Reality upstream (xray-core SOCKS5)
# ════════════════════════════════════════════════════════════════════════
menu_vless() {
    while true; do
        draw_header
        echo -e "  ${BOLD}VLESS Reality upstream${RESET}\n"
        echo -e "  Статус: $(status_vless)"
        echo ""

        # Подробности
        local link_info="нет"
        local service_status="не установлен"
        local port_status="нет"
        local upstream_status="нет"

        if [[ -f "$VLESS_CONFIG_DIR/link.txt" ]]; then
            local raw_link host port
            raw_link=$(cat "$VLESS_CONFIG_DIR/link.txt" 2>/dev/null | tr -d '\n')
            # Извлекаем хост:порт через Python
            host=$(VL="$raw_link" python3 -c "import os,urllib.parse as up;p=up.urlparse(os.environ['VL']);print(f'{p.hostname}:{p.port}')" 2>/dev/null)
            [[ -n "$host" ]] && link_info="${host}"
        fi
        if systemctl is-active --quiet telemt-vless 2>/dev/null; then
            service_status="${GREEN}active${RESET}"
        elif [[ -f /etc/systemd/system/telemt-vless.service ]]; then
            service_status="${RED}inactive${RESET}"
        fi
        if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:40000"; then
            port_status="${GREEN}127.0.0.1:40000${RESET}"
        fi
        for f in /etc/telemt/telemt*.toml; do
            [[ -f "$f" ]] && grep -q "127.0.0.1:40000" "$f" 2>/dev/null && upstream_status="${GREEN}прицеплен${RESET}" && break
        done

        echo -e "  ${DIM}xray-core (telemt-vless):${RESET}   ${service_status}"
        echo -e "  ${DIM}VLESS-сервер:${RESET}              ${link_info}"
        echo -e "  ${DIM}SOCKS5 порт:${RESET}               ${port_status}"
        echo -e "  ${DIM}В конфигах telemt:${RESET}         ${upstream_status}"
        echo ""

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        if [[ ! -f /usr/local/bin/xray ]] || [[ ! -f "$VLESS_CONFIG_DIR/config.json" ]]; then
            echo -e "  ${BOLD}1.${RESET} Установить VLESS Reality (xray + конфиг)"
        else
            echo -e "  ${BOLD}1.${RESET} Запустить xray (если выключен)"
            echo -e "  ${BOLD}2.${RESET} Остановить xray"
            echo -e "  ${BOLD}3.${RESET} Изменить vless:// ссылку"
            echo -e "  ${BOLD}4.${RESET} Прицепить к telemt (добавить upstream)"
            echo -e "  ${BOLD}5.${RESET} ${YELLOW}Отцепить от telemt${RESET} (telemt пойдёт напрямую)"
            echo -e "  ${BOLD}6.${RESET} Тест: какой IP виден через VLESS"
            echo -e "  ${BOLD}7.${RESET} Показать логи xray"
            echo -e "  ${BOLD}8.${RESET} ${RED}Удалить полностью${RESET}"
        fi
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch

        if [[ ! -f /usr/local/bin/xray ]] || [[ ! -f "$VLESS_CONFIG_DIR/config.json" ]]; then
            case "$ch" in
                1) vless_install ;;
                0|b) return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
        else
            case "$ch" in
                1) vless_start ;;
                2) vless_stop ;;
                3) vless_change_link ;;
                4) vless_attach ;;
                5) vless_detach ;;
                6) vless_test ;;
                7) vless_logs ;;
                8) vless_remove ;;
                0|b) return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
        fi
    done
}

vless_ask_link() {
    # Запрашивает у пользователя vless:// ссылку, валидирует, возвращает через echo
    local link
    echo -e "  ${DIM}Пример: vless://uuid@server:443?security=reality&pbk=...&sni=...${RESET}"
    while true; do
        read -rp "  vless:// ссылка: " link
        if [[ "$link" == vless://*@*:*\?* ]] && [[ "$link" == *security=reality* ]] \
           && [[ "$link" == *pbk=* ]] && [[ "$link" == *sni=* ]]; then
            if VL="$link" python3 -c "import os,urllib.parse as up,sys;p=up.urlparse(os.environ['VL']);q=up.parse_qs(p.query);sys.exit(0 if (p.username and p.hostname and p.port and 'pbk' in q and 'sni' in q) else 1)" 2>/dev/null; then
                echo "$link"
                return 0
            fi
        fi
        warn "Неверный формат ссылки" >&2
        read -rp "  Попробовать ещё раз? [Y/n]: " retry >&2
        if [[ "${retry,,}" =~ ^(n|no)$ ]]; then
            return 1
        fi
    done
}

vless_generate_config() {
    # Аргумент: vless ссылка. Создаёт /etc/telemt-vless/config.json
    local link="$1"
    mkdir -p "$VLESS_CONFIG_DIR"
    VL="$link" python3 /dev/stdin << 'PYV'
import os, json, urllib.parse as up
url = os.environ['VL']
p = up.urlparse(url)
q = {k: v[0] for k, v in up.parse_qs(p.query).items()}
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
    "outbounds": [{
        "tag": "vless-reality",
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": p.hostname, "port": p.port or 443,
                "users": [{"id": p.username, "encryption": "none"}]
            }]
        },
        "streamSettings": {
            "network": q.get("type", "tcp"),
            "security": "reality",
            "realitySettings": {
                "show": False,
                "fingerprint": q.get("fp", "chrome"),
                "serverName": q.get("sni", ""),
                "publicKey": q.get("pbk", ""),
                "shortId": q.get("sid", ""),
                "spiderX": q.get("spx", "/")
            }
        }
    }, {"tag": "direct", "protocol": "freedom"}],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [{"type": "field", "inboundTag": ["socks-in"], "outboundTag": "vless-reality"}]
    }
}
flow = q.get("flow", "")
if flow:
    cfg["outbounds"][0]["settings"]["vnext"][0]["users"][0]["flow"] = flow
with open("/etc/telemt-vless/config.json", "w") as f:
    json.dump(cfg, f, indent=2)
with open("/etc/telemt-vless/link.txt", "w") as f:
    f.write(url + "\n")
PYV
    # Создаём пользователя xray если ещё нет (на случай если поставили из старой версии)
    if ! id xray &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --no-create-home --user-group xray 2>/dev/null \
        || useradd --system --shell /usr/sbin/nologin --no-create-home xray 2>/dev/null || true
    fi
    # Права: xray-пользователь должен читать конфиг
    chown -R xray:xray /etc/telemt-vless 2>/dev/null || chown -R root:root /etc/telemt-vless
    chmod 750 /etc/telemt-vless
    chmod 640 /etc/telemt-vless/config.json /etc/telemt-vless/link.txt 2>/dev/null || true
}

vless_install() {
    draw_header
    echo -e "  ${BOLD}Установка VLESS Reality${RESET}\n"
    echo -e "  ${DIM}Будет скачан xray-core с GitHub releases, создан systemd-сервис,${RESET}"
    echo -e "  ${DIM}и прописан upstream в конфиги telemt.${RESET}"
    echo ""
    read -rp "  Продолжить? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && return

    # 1) Запрашиваем ссылку
    local link
    link=$(vless_ask_link) || { info "Отменено"; pause; return; }

    # 2) Скачиваем xray-core если ещё нет
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
        xray_version=$(curl -s --max-time 10 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep tag_name | cut -d \" -f 4)
        [[ -z "$xray_version" ]] && { err "Не получили версию"; pause; return; }
        xray_url="https://github.com/XTLS/Xray-core/releases/download/${xray_version}/Xray-linux-${xray_arch}.zip"

        apt-get install -y unzip curl >/dev/null 2>&1
        cd /tmp
        if ! curl -fsSL --max-time 120 -o /tmp/xray.zip "$xray_url"; then
            err "Не удалось скачать xray-core"; pause; return
        fi
        unzip -o -q /tmp/xray.zip -d /tmp/xray-extract >/dev/null
        mv /tmp/xray-extract/xray /usr/local/bin/xray
        chmod +x /usr/local/bin/xray
        rm -rf /tmp/xray.zip /tmp/xray-extract
        ok "xray-core $xray_version установлен"
    fi

    # 3) Конфиг
    vless_generate_config "$link"
    ok "Конфиг создан"

    # Валидация
    if /usr/local/bin/xray -test -config /etc/telemt-vless/config.json 2>&1 | grep -q "Configuration OK"; then
        ok "Конфиг xray валиден"
    else
        warn "xray -test не прошёл, но продолжаем"
    fi

    # 4) systemd
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

    if systemctl is-active --quiet telemt-vless; then
        ok "Сервис telemt-vless запущен"
    else
        err "Сервис не запустился"
        warn "Логи: journalctl -u telemt-vless -n 30"
        pause; return
    fi

    # 5) Прицепляем к telemt
    echo ""
    read -rp "  Прицепить VLESS к telemt (добавить upstream в конфиги)? [Y/n]: " ans
    [[ ! "${ans,,}" =~ ^(n|no)$ ]] && vless_attach_silent
    pause
}

vless_start() {
    draw_header
    info "Запуск xray (telemt-vless)..."
    systemctl start telemt-vless 2>&1 || true
    sleep 2
    if systemctl is-active --quiet telemt-vless; then
        ok "xray активен"
    else
        err "Не удалось запустить"
    fi
    pause
}

vless_stop() {
    draw_header
    warn "Если VLESS прицеплен к telemt — инстансы не смогут коннектиться к Telegram!"
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return
    systemctl stop telemt-vless 2>/dev/null
    ok "xray остановлен"
    pause
}

vless_change_link() {
    draw_header
    echo -e "  ${BOLD}Изменение vless:// ссылки${RESET}\n"
    if [[ -f "$VLESS_CONFIG_DIR/link.txt" ]]; then
        echo -e "  ${DIM}Текущая ссылка:${RESET}"
        echo -e "  ${DIM}$(head -1 "$VLESS_CONFIG_DIR/link.txt")${RESET}"
        echo ""
    fi
    local link
    link=$(vless_ask_link) || { info "Отменено"; pause; return; }

    vless_generate_config "$link"
    if /usr/local/bin/xray -test -config /etc/telemt-vless/config.json 2>&1 | grep -q "Configuration OK"; then
        ok "Новый конфиг валиден"
    else
        warn "xray -test не прошёл"
    fi
    systemctl restart telemt-vless
    sleep 2
    if systemctl is-active --quiet telemt-vless; then
        ok "xray перезапущен с новой ссылкой"
        # Перезапускаем telemt чтобы он переподключился
        local insts; read -ra insts <<< "$(active_instances)"
        for n in "${insts[@]}"; do systemctl restart "telemt${n}" 2>/dev/null; done
    else
        err "xray не запустился — откатите ссылку через этот же пункт"
    fi
    pause
}

vless_attach_silent() {
    local count=0
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        if grep -q "127.0.0.1:40000" "$f" 2>/dev/null; then
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
        count=$((count + 1))
    done
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        systemctl restart "telemt${n}" 2>/dev/null
    done
    ok "Прицеплено к ${count} конфигам, инстансы перезапущены"
}

vless_attach() {
    draw_header
    echo -e "  ${BOLD}Прицепить VLESS к telemt${RESET}\n"
    echo -e "  В конфиги всех инстансов будет добавлен ${BOLD}[[upstreams]]${RESET} → 127.0.0.1:40000"
    echo -e "  ${DIM}telemt пойдёт к Telegram DC через VLESS-туннель.${RESET}"
    echo ""
    read -rp "  Применить и перезапустить инстансы? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && return
    vless_attach_silent
    pause
}

vless_detach() {
    draw_header
    echo -e "  ${BOLD}Отцепить VLESS от telemt${RESET}\n"
    warn "Из конфигов будут удалены секции [[upstreams]] — telemt пойдёт напрямую"
    echo ""
    read -rp "  Применить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    local count=0
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        if ! grep -q "127.0.0.1:40000" "$f" 2>/dev/null; then
            continue
        fi
        python3 - "$f" << 'PYU'
import sys, re
path = sys.argv[1]
content = open(path).read()
content = re.sub(r'\n*\[\[upstreams\]\][^\[]*', '\n', content, flags=re.DOTALL)
content = re.sub(r'\n{3,}', '\n\n', content)
if not content.endswith('\n'): content += '\n'
open(path, 'w').write(content)
PYU
        count=$((count + 1))
    done
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        systemctl restart "telemt${n}" 2>/dev/null
    done
    ok "Отцеплено от ${count} конфигов, инстансы перезапущены"
    pause
}

vless_test() {
    draw_header
    echo -e "  ${BOLD}Тест: какой IP виден через VLESS${RESET}\n"

    info "Прямое соединение (исходящий IP сервера):"
    local direct_ip; direct_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    echo -e "  ${BOLD}${direct_ip:-(не удалось)}${RESET}"

    echo ""
    info "Через VLESS SOCKS5 (должен быть IP вашего 3x-ui сервера):"
    local vless_ip; vless_ip=$(curl -s --max-time 10 --socks5 127.0.0.1:40000 https://api.ipify.org 2>/dev/null)
    if [[ -n "$vless_ip" ]]; then
        echo -e "  ${BOLD}${vless_ip}${RESET}"
        if [[ "$direct_ip" != "$vless_ip" ]]; then
            ok "VLESS-туннель работает"
        else
            warn "IP одинаковые — туннель может не работать"
        fi
    else
        err "Запрос через VLESS не прошёл"
        info "Логи: journalctl -u telemt-vless -n 30"
    fi
    pause
}

vless_logs() {
    draw_header
    echo -e "  ${BOLD}Последние логи xray (telemt-vless)${RESET}\n"
    journalctl -u telemt-vless -n 50 --no-pager
    pause
}

vless_remove() {
    draw_header
    echo -e "  ${BOLD}${RED}Полное удаление VLESS${RESET}\n"
    warn "Будут удалены: сервис telemt-vless, конфиги, upstream из telemt"
    warn "Бинарник /usr/local/bin/xray НЕ удаляется (может использоваться другими сервисами)"
    echo ""
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    # Отцепить от telemt
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        python3 - "$f" << 'PYU'
import sys, re
path = sys.argv[1]
content = open(path).read()
content = re.sub(r'\n*\[\[upstreams\]\][^\[]*', '\n', content, flags=re.DOTALL)
content = re.sub(r'\n{3,}', '\n\n', content)
open(path, 'w').write(content)
PYU
    done
    ok "Upstream-секции убраны из конфигов"

    # Остановить сервис
    systemctl stop telemt-vless 2>/dev/null || true
    systemctl disable telemt-vless 2>/dev/null || true
    rm -f /etc/systemd/system/telemt-vless.service
    rm -rf /etc/telemt-vless
    systemctl daemon-reload

    # Удаляем пользователя xray, если он не используется другими сервисами
    if id xray &>/dev/null && ! pgrep -u xray &>/dev/null; then
        userdel xray 2>/dev/null && info "Удалён системный пользователь xray" || true
    fi

    ok "Сервис, конфиги и пользователь VLESS удалены"

    # Перезапуск telemt
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do
        systemctl restart "telemt${n}" 2>/dev/null
    done
    ok "Инстансы telemt перезапущены"

    if [[ -f /usr/local/bin/xray ]]; then
        info "Бинарник /usr/local/bin/xray остался. Удалить вручную: rm -f /usr/local/bin/xray"
    fi
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  ТОЧКА ВХОДА
# ════════════════════════════════════════════════════════════════════════
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Требуется root (sudo mytelemtinfo)${RESET}"
    exit 1
fi

# Перенаправляем stdin на /dev/tty для работы через пайп
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec < /dev/tty
fi

main_menu
