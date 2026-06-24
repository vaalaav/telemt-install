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

# ─── Health check: проверка цепочки telemt → upstream → Telegram DC ─────────
# Универсальная функция, вызывается после изменений через mytelemtinfo.
# Возвращает 0 если всё ок, !=0 если есть проблемы.
# Аргумент: уровень детализации
#   "brief"  — короткий отчёт после операций (5-7 строк)
#   "full"   — полный отчёт со всеми проверками
health_check() {
    local mode="${1:-brief}"
    local issues=0
    local results=()  # массив строк "STATUS\tNAME\tDETAILS"

    # 1. telemt инстансы — все ли active?
    local insts; read -ra insts <<< "$(active_instances)"
    if [[ ${#insts[@]} -eq 0 ]]; then
        results+=("WARN\tИнстансы telemt\tнет установленных инстансов")
    else
        local all_active=true broken=()
        for n in "${insts[@]}"; do
            local st; st=$(systemctl is-active "telemt${n}" 2>/dev/null)
            if [[ "$st" != "active" ]]; then
                all_active=false
                broken+=("telemt${n}:${st}")
            fi
        done
        if [[ "$all_active" == true ]]; then
            results+=("OK\tИнстансы telemt\tвсе ${#insts[@]} active")
        else
            results+=("FAIL\tИнстансы telemt\tпроблемы: ${broken[*]}")
            issues=$((issues+1))
        fi
    fi

    # 2. Если VLESS установлен — проверяем сервис и SOCKS5 порт
    if [[ -f /etc/telemt-vless/config.json ]]; then
        local vless_active=false vless_port=false
        systemctl is-active --quiet telemt-vless && vless_active=true
        ss -tlnp 2>/dev/null | grep -q "127.0.0.1:40000" && vless_port=true

        if [[ "$vless_active" == true && "$vless_port" == true ]]; then
            results+=("OK\tVLESS сервис\txray active, SOCKS5 на 40000")
        elif [[ "$vless_active" == true ]]; then
            results+=("FAIL\tVLESS сервис\txray active, но порт 40000 не слушает")
            issues=$((issues+1))
        else
            results+=("FAIL\tVLESS сервис\txray не active")
            issues=$((issues+1))
        fi

        # 3. upstream блоки в telemt-конфигах — соответствуют ли реальности?
        local upstream_count=0
        for f in /etc/telemt/telemt*.toml; do
            [[ -f "$f" ]] && grep -q "127.0.0.1:40000" "$f" 2>/dev/null && upstream_count=$((upstream_count+1))
        done
        if [[ ${#insts[@]} -gt 0 && $upstream_count -eq 0 ]]; then
            results+=("WARN\tVLESS прицеплен к telemt\tнет, инстансы идут напрямую")
        elif [[ $upstream_count -gt 0 && $upstream_count -lt ${#insts[@]} ]]; then
            results+=("WARN\tVLESS прицеплен к telemt\tтолько ${upstream_count}/${#insts[@]} инстансов")
        elif [[ $upstream_count -eq ${#insts[@]} && $upstream_count -gt 0 ]]; then
            results+=("OK\tVLESS прицеплен к telemt\tвсе ${upstream_count} конфигов")
        fi

        # 4. Тест туннеля — пакет через SOCKS5 доходит?
        if [[ "$vless_active" == true && "$vless_port" == true ]]; then
            local vless_test_ip
            vless_test_ip=$(curl -s --max-time 5 --socks5 127.0.0.1:40000 https://api.ipify.org 2>/dev/null)
            if [[ -n "$vless_test_ip" ]]; then
                results+=("OK\tТуннель VLESS\tвыход через IP ${vless_test_ip}")
            else
                results+=("FAIL\tТуннель VLESS\tне отвечает на запрос через SOCKS5")
                issues=$((issues+1))
            fi
        fi

        # 5. Refresh timer (только в full режиме)
        if [[ "$mode" == "full" && -f /etc/systemd/system/telemt-vless-refresh.timer ]]; then
            if systemctl is-active --quiet telemt-vless-refresh.timer; then
                local next_run; next_run=$(systemctl list-timers telemt-vless-refresh.timer --no-pager 2>/dev/null | grep telemt-vless | awk '{print $1,$2}')
                results+=("OK\tАвто-обновление подписки\tследующий запуск: ${next_run:-?}")
            else
                results+=("WARN\tАвто-обновление подписки\ttimer не активен")
            fi
        fi
    fi

    # 6. Keepalive sysctl
    if [[ "$mode" == "full" ]]; then
        if [[ -f /etc/sysctl.d/99-telemt-net.conf ]] && grep -q tcp_keepalive_time /etc/sysctl.d/99-telemt-net.conf; then
            local t i p
            t=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
            if [[ "$t" == "60" ]]; then
                results+=("OK\tTCP Keepalive\ttime=$t (применён)")
            else
                results+=("WARN\tTCP Keepalive\tconf есть, но sysctl=$t (нужно sysctl --system)")
            fi
        fi
        # BBR
        if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
            results+=("OK\tBBR + fq\tactive")
        fi
        # nft limiter
        if nft list table inet telemt_limit &>/dev/null 2>&1; then
            local nft_rules; nft_rules=$(nft list chain inet telemt_limit input 2>/dev/null | grep -c "dport")
            results+=("OK\tnft SYN limiter\t${nft_rules} правил активно")
        elif [[ -f /usr/local/sbin/telemt-nft-limit.sh ]]; then
            results+=("WARN\tnft SYN limiter\tскрипт есть, таблица не активна")
        fi
        # UFW
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            results+=("OK\tUFW фаервол\tactive")
            # Проверяем что все порты инстансов открыты
            for n in "${insts[@]}"; do
                local port="${INSTANCE_PORTS[$n]}"
                if ! ufw status 2>/dev/null | grep -qE "^${port}/tcp\s+ALLOW"; then
                    results+=("WARN\tUFW порт инстанса ${n}\t${port}/tcp не открыт")
                fi
            done
        fi
    fi

    # 7. WireGuard warp (legacy) — должен быть удалён
    if [[ "$mode" == "full" && -f /etc/wireguard/warp.conf ]]; then
        results+=("WARN\tWARP legacy\tобнаружен /etc/wireguard/warp.conf — удалите если не используется")
    fi

    # 8. Сайт-заглушка (если установлена)
    if [[ -f /etc/nginx/sites-enabled/telemt-site.conf ]]; then
        # nginx active
        if systemctl is-active --quiet nginx; then
            results+=("OK\tnginx (сайт)\tactive")
        else
            results+=("FAIL\tnginx (сайт)\tне active")
            issues=$((issues+1))
        fi

        # Сертификат + дата
        local site_dom; site_dom=$(get_site_domain 2>/dev/null)
        local cert="/etc/letsencrypt/live/${site_dom}/fullchain.pem"
        if [[ -f "$cert" ]]; then
            local exp_epoch now_epoch days
            exp_epoch=$(date -d "$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null)
            now_epoch=$(date +%s)
            if [[ -n "$exp_epoch" ]]; then
                days=$(( (exp_epoch - now_epoch) / 86400 ))
                if [[ $days -gt 30 ]]; then
                    results+=("OK\tSSL-сертификат\tвалиден ещё ${days} дней")
                elif [[ $days -gt 0 ]]; then
                    results+=("WARN\tSSL-сертификат\tистекает через ${days} дней — обновить через раздел 8")
                else
                    results+=("FAIL\tSSL-сертификат\tИСТЁК")
                    issues=$((issues+1))
                fi
            fi
        elif [[ -n "$site_dom" ]]; then
            results+=("FAIL\tSSL-сертификат\tне найден для ${site_dom}")
            issues=$((issues+1))
        fi

        # Тест URL (только в full)
        if [[ "$mode" == "full" && -n "$site_dom" ]]; then
            local site_port; site_port=$(get_site_port 2>/dev/null)
            local su; [[ "$site_port" == "443" ]] && su="https://${site_dom}" || su="https://${site_dom}:${site_port}"
            local code; code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 3 "${su}/" 2>/dev/null)
            if [[ "$code" == "200" || "$code" == "30"* ]]; then
                results+=("OK\tСайт URL\t${su}/ → ${code}")
            else
                results+=("WARN\tСайт URL\tкод ${code:-—} (ожидался 200)")
            fi
        fi

        # tls_domain в telemt совпадает
        if [[ -f /etc/telemt/telemt1.toml && -n "$site_dom" ]]; then
            if grep -q "tls_domain = \"${site_dom}\"" /etc/telemt/telemt1.toml; then
                results+=("OK\ttls_domain telemt\tсовпадает с доменом сайта")
            else
                results+=("WARN\ttls_domain telemt\tне равен ${site_dom} в telemt1.toml")
            fi
        fi
    fi

    # 9. Панель управления (если установлена)
    if [[ -x "$PANEL_BIN" ]]; then
        if systemctl is-active --quiet "$PANEL_SVC" 2>/dev/null; then
            local panel_ver; panel_ver=$("$PANEL_BIN" version 2>/dev/null | awk '{print $NF; exit}' || echo "?")
            results+=("OK\tПанель telemt_panel\t${panel_ver}, сервис active")
        else
            results+=("FAIL\tПанель telemt_panel\tустановлена, но сервис не active")
            issues=$((issues+1))
        fi
    fi

    # Печать результата
    echo ""
    echo -e "  ${BOLD}${CYAN}── Проверка состояния (${mode}) ──${RESET}"
    for line in "${results[@]}"; do
        local status name details
        status=$(echo -e "$line" | awk -F'\t' '{print $1}')
        name=$(echo -e "$line" | awk -F'\t' '{print $2}')
        details=$(echo -e "$line" | awk -F'\t' '{print $3}')
        case "$status" in
            OK)   echo -e "  ${GREEN}✓${RESET} ${name}  ${DIM}— ${details}${RESET}" ;;
            WARN) echo -e "  ${YELLOW}⚠${RESET} ${name}  ${DIM}— ${details}${RESET}" ;;
            FAIL) echo -e "  ${RED}✗${RESET} ${name}  ${DIM}— ${details}${RESET}" ;;
        esac
    done
    echo ""
    if [[ $issues -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}Всё работает корректно.${RESET}"
    else
        echo -e "  ${YELLOW}${BOLD}Найдено проблем: ${issues}${RESET}"
    fi
    echo ""
    return $issues
}

# Короткая обёртка для использования после операций
health_check_brief() { health_check brief; }
health_check_full()  { health_check full;  }

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

# Статус client_mss = "tspu" по всем конфигам telemt
status_tspu() {
    local on=0 off=0 absent=0 total=0
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        total=$((total+1))
        if grep -qE '^\s*client_mss\s*=\s*"tspu"' "$f" 2>/dev/null; then
            on=$((on+1))
        elif grep -qE '^\s*#\s*client_mss\s*=\s*"tspu"' "$f" 2>/dev/null; then
            off=$((off+1))
        else
            absent=$((absent+1))
        fi
    done
    if [[ $total -eq 0 ]]; then
        echo -e "${DIM}нет инстансов${RESET}"
    elif [[ $on -eq $total ]]; then
        echo -e "${GREEN}включено${RESET} во всех ${total} конфигах"
    elif [[ $off -eq $total ]]; then
        echo -e "${YELLOW}отключено${RESET} (закомментировано) во всех конфигах"
    elif [[ $absent -eq $total ]]; then
        echo -e "${DIM}нет строки${RESET} (дефолт telemt)"
    else
        echo -e "${YELLOW}смешано${RESET}: вкл=$on, выкл=$off, отсутствует=$absent"
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

# ─── Сайт-заглушка ──────────────────────────────────────────────────────────
SITE_CONFIG_FILE="/etc/nginx/sites-enabled/telemt-site.conf"
SITE_WWW_DIR="/var/www/telemt-site"
SITE_INFO_FILE="/etc/telemt/.site-info"  # хранит DOMAIN|EMAIL|TEMPLATE_URL|PORT

# Получить сохранённые параметры сайта
get_site_info() {
    [[ -f "$SITE_INFO_FILE" ]] && cat "$SITE_INFO_FILE" 2>/dev/null
}

# Извлечь домен сайта из конфига nginx (резервно если .site-info нет)
get_site_domain() {
    local saved; saved=$(get_site_info)
    if [[ -n "$saved" ]]; then
        echo "$saved" | cut -d'|' -f1
        return
    fi
    # Fallback: парсим из nginx-конфига
    if [[ -f "$SITE_CONFIG_FILE" ]]; then
        grep -m1 "server_name" "$SITE_CONFIG_FILE" 2>/dev/null | awk '{print $2}' | tr -d ';'
    fi
}

get_site_port() {
    # telemt mask-режим: сайт доступен на 443 через telemt
    local dom; dom=$(get_site_domain 2>/dev/null)
    if [[ -n "$dom" ]]; then
        local toml
        for toml in /etc/telemt/telemt[0-9]*.toml; do
            [[ -f "$toml" ]] || continue
            grep -qE '^\s*port\s*=\s*443\b' "$toml" || continue
            grep -qE "^\s*tls_domain\s*=\s*\"${dom}\"" "$toml" || continue
            grep -qE '^\s*mask\s*=\s*true' "$toml" || continue
            echo "443"; return
        done
    fi
    local saved; saved=$(get_site_info)
    if [[ -n "$saved" ]]; then
        echo "$saved" | cut -d'|' -f4
        return
    fi
    grep "listen" "$SITE_CONFIG_FILE" 2>/dev/null | grep "ssl" | grep -oE '[0-9]+' | head -1 || echo "8443"
}

site_url() {
    local dom; dom=$(get_site_domain)
    local port; port=$(get_site_port)
    [[ "$port" == "443" ]] && echo "https://${dom}" || echo "https://${dom}:${port}"
}

status_site() {
    if [[ ! -f "$SITE_CONFIG_FILE" ]] && [[ ! -d "$SITE_WWW_DIR" ]]; then
        echo -e "${DIM}не установлен${RESET}"
        return
    fi
    local nginx_st="inactive" domain="?" port="?" cert_status=""
    systemctl is-active --quiet nginx && nginx_st="active"
    domain=$(get_site_domain)
    port=$(get_site_port)

    local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    if [[ -f "$cert" ]]; then
        local exp_epoch now_epoch days
        exp_epoch=$(date -d "$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null)
        now_epoch=$(date +%s)
        if [[ -n "$exp_epoch" ]]; then
            days=$(( (exp_epoch - now_epoch) / 86400 ))
            if [[ $days -gt 30 ]]; then
                cert_status="${GREEN}cert ${days}д${RESET}"
            elif [[ $days -gt 0 ]]; then
                cert_status="${YELLOW}cert ${days}д${RESET}"
            else
                cert_status="${RED}cert истёк${RESET}"
            fi
        fi
    else
        cert_status="${RED}нет cert${RESET}"
    fi

    local label; [[ "$port" == "443" ]] && label="${domain}" || label="${domain}:${port}"
    local href="https://${label}"

    if [[ "$nginx_st" == "active" ]]; then
        echo -e "\e]8;;${href}\a${GREEN}${label}${RESET}\e]8;;\a  ${cert_status}"
    else
        echo -e "${YELLOW}nginx ${nginx_st}${RESET}  ${label}"
    fi
}

status_server_ip() {
    [[ -z "$_PUBLIC_IP_CACHE" ]] && _PUBLIC_IP_CACHE=$(get_public_ip)
    if [[ -n "$_PUBLIC_IP_CACHE" ]]; then
        echo -e "${GREEN}${_PUBLIC_IP_CACHE}${RESET}"
    else
        echo -e "${RED}не определён${RESET}"
    fi
}

status_version() {
    local ver
    ver=$(/bin/telemt --version 2>&1 | head -1) || ver=""
    if [[ -n "$ver" ]]; then
        echo -e "${GREEN}${ver}${RESET}"
    else
        echo -e "${DIM}не установлен${RESET}"
    fi
}

# ─── Панель управления (telemt_panel) ────────────────────────────────────
PANEL_REPO="amirotin/telemt_panel"
PANEL_BIN="/usr/local/bin/telemt-panel"
PANEL_CFG_DIR="/etc/telemt-panel"
PANEL_CFG="${PANEL_CFG_DIR}/config.toml"
PANEL_DATA="/var/lib/telemt-panel"
PANEL_SVC="telemt-panel"
PANEL_USER="telemt-panel"

status_panel() {
    if [[ ! -x "$PANEL_BIN" ]]; then
        echo -e "${DIM}не установлена${RESET}"
        return
    fi
    local ver; ver=$("$PANEL_BIN" version 2>/dev/null | awk '{print $NF; exit}' || echo "?")
    if systemctl is-active --quiet "$PANEL_SVC" 2>/dev/null; then
        local port; port=$(grep -m1 '^\s*listen' "$PANEL_CFG" 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':')
        port="${port:-8080}"
        [[ -z "$_PUBLIC_IP_CACHE" ]] && _PUBLIC_IP_CACHE=$(get_public_ip)
        echo -e "${GREEN}активна${RESET}  ${DIM}v${ver}${RESET}  http://${_PUBLIC_IP_CACHE:-<IP>}:${port}"
    else
        echo -e "${YELLOW}не запущена${RESET}  ${DIM}v${ver}${RESET}"
    fi
}

status_link() {
    local insts; read -ra insts <<< "$(active_instances)"
    [[ ${#insts[@]} -eq 0 ]] && { echo -e "${DIM}нет инстансов${RESET}"; return; }
    local first="${insts[0]}"
    local api="${INSTANCE_APIS[$first]:-}"
    [[ -z "$api" ]] && { echo -e "${DIM}API не найден${RESET}"; return; }
    local link; link=$(get_link "$api")
    if [[ -n "$link" ]]; then
        echo -e "${GREEN}${link}${RESET}"
    else
        echo -e "${DIM}не удалось получить${RESET}"
    fi
}

# ════════════════════════════════════════════════════════════════════════
#  ГЛАВНОЕ МЕНЮ
# ════════════════════════════════════════════════════════════════════════
main_menu() {
    while true; do
        draw_header

        echo -e "  ${BOLD}Состояние:${RESET} IP: $(status_server_ip)"
        echo -e "  Свой домен: $(status_custom_domain)"
        echo -e "  Прокси:     $(status_proxy)"
        echo -e "  Версия:     $(status_version)"
        echo -e "  Keepalive:  $(status_keepalive)"
        echo -e "  BBR:        $(status_bbr)"
        echo -e "  nft SYN:    $(status_nft)"
        echo -e "  Таймауты:   $(status_timeouts)"
        echo -e "  UFW:        $(status_ufw)"
        echo -e "  VLESS:      $(status_vless)"
        echo -e "  Сайт:       $(status_site)"
        echo -e "  Панель:     $(status_panel)"
        echo -e "  Ссылка:     $(status_link)"
        echo ""
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo -e "  ${BOLD}1.${RESET} Управление прокси"
        echo -e "  ${BOLD}2.${RESET} Сетевой тюнинг (Keepalive + BBR)"
        echo -e "  ${BOLD}3.${RESET} nft SYN Limiter"
        echo -e "  ${BOLD}4.${RESET} Настройки конфигов telemt"
        echo -e "  ${BOLD}5.${RESET} UFW / Rate-limit"
        echo -e "  ${BOLD}6.${RESET} Свой домен в ссылках"
        echo -e "  ${BOLD}7.${RESET} VLESS Reality upstream"
        echo -e "  ${BOLD}8.${RESET} Сайт-заглушка"
        echo -e "  ${BOLD}9.${RESET} Панель управления (telemt_panel)"
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
            8) menu_site ;;
            9) menu_panel ;;
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
        echo -e "  ${BOLD}${CYAN}10.${RESET} ${BOLD}${CYAN}Проверка работоспособности${RESET} ${DIM}(полный health check)${RESET}"
        echo -e "  ${BOLD}11.${RESET} ${RED}Удалить telemt полностью${RESET}"
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
            10) draw_header; health_check_full; pause ;;
            11) proxy_remove ;;
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
    local ver_before; ver_before=$(/bin/telemt --version 2>&1 | head -1 || echo "неизвестна")
    info "Текущая версия: ${BOLD}${ver_before}${RESET}"
    echo ""
    read -rp "  Скачать и установить новую версию? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return
    echo ""

    # 1) Бэкап старого бинарника
    if [[ -f /bin/telemt ]]; then
        cp /bin/telemt "/tmp/telemt.backup.$(date +%s)" 2>/dev/null && \
            info "Бэкап старого бинарника: /tmp/telemt.backup.$(date +%s)"
    fi

    # 2) Останавливаем инстансы
    info "Остановка инстансов..."
    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do systemctl stop "telemt${n}" 2>/dev/null || true; done

    # 3) Скачивание
    info "Скачивание новой версии..."
    cd /tmp
    if ! wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz" | tar -xz; then
        err "Не удалось скачать новую версию"
        info "Восстанавливаем старые инстансы..."
        for n in "${insts[@]}"; do systemctl start "telemt${n}" 2>/dev/null || true; done
        pause; return
    fi
    mv /tmp/telemt /bin/telemt && chmod +x /bin/telemt
    local ver_after; ver_after=$(/bin/telemt --version 2>&1 | head -1 || echo "?")

    # 4) Сравнение версий
    echo ""
    if [[ "$ver_before" == "$ver_after" ]]; then
        info "Версия не изменилась: ${BOLD}${ver_after}${RESET}"
    else
        ok "Обновлено: ${DIM}${ver_before}${RESET} → ${BOLD}${ver_after}${RESET}"
    fi

    # 5) Валидация конфигов через тестовый запуск (telemt не имеет --check-config,
    #    но запускается с ошибкой если конфиг битый — поэтому смотрим journalctl
    #    первые 5 секунд после рестарта каждого инстанса)
    echo ""
    info "Проверка совместимости конфигов с новой версией..."
    local broken=()
    for n in "${insts[@]}"; do
        # Чистим логи перед рестартом, чтобы видеть только новые
        systemctl reset-failed "telemt${n}" 2>/dev/null || true
        local before_ts; before_ts=$(date +%s)
        systemctl start "telemt${n}" 2>/dev/null || true
        sleep 3

        # Проверяем что сервис запустился И не упал в первые 3 секунды
        local st; st=$(systemctl is-active "telemt${n}" 2>/dev/null)
        if [[ "$st" != "active" ]]; then
            broken+=("telemt${n}")
            err "telemt${n} не запустился"
            # Показываем ошибки из логов
            echo -e "  ${DIM}Логи (последние ошибки):${RESET}"
            journalctl -u "telemt${n}" --since "@${before_ts}" 2>/dev/null \
                | grep -iE "error|fatal|panic|fail" | head -5 | sed 's/^/    /'
        else
            # Проверим что нет ошибок в логах с момента старта
            local errors_count; errors_count=$(journalctl -u "telemt${n}" --since "@${before_ts}" 2>/dev/null \
                | grep -ciE "error|fatal|panic" || echo 0)
            if [[ "$errors_count" -gt 0 ]]; then
                warn "telemt${n}: active, но в логах ${errors_count} ошибок — проверьте"
            else
                ok "telemt${n}: запущен, ошибок в логах нет"
            fi
        fi
    done

    # 6) Если есть проблемы — предложить откат
    if [[ ${#broken[@]} -gt 0 ]]; then
        echo ""
        err "Сломанные инстансы: ${broken[*]}"
        warn "Возможные причины: формат конфига изменился, нужно скорректировать /etc/telemt/telemt*.toml"
        echo ""
        local backup; backup=$(ls -t /tmp/telemt.backup.* 2>/dev/null | head -1)
        if [[ -n "$backup" ]]; then
            info "Доступен бэкап: ${backup}"
            read -rp "  Откатить к старой версии? [y/N]: " roll
            if [[ "${roll,,}" =~ ^(y|yes|д|да)$ ]]; then
                cp "$backup" /bin/telemt && chmod +x /bin/telemt
                for n in "${insts[@]}"; do systemctl restart "telemt${n}" 2>/dev/null || true; done
                ok "Откат выполнен — ${ver_before}"
            fi
        fi
    fi

    # 7) Если есть VLESS upstream — проверим что xray ещё работает (он от telemt не зависит,
    #    но на всякий случай покажем статус)
    if [[ -f /etc/telemt-vless/config.json ]]; then
        echo ""
        info "Проверка зависимых компонентов..."
        if systemctl is-active --quiet telemt-vless; then
            ok "VLESS upstream работает (xray active)"
        else
            warn "VLESS upstream не активен — telemt не сможет подключаться к Telegram"
        fi
    fi

    # 8) Полный health check
    health_check_full
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

    # mask_port: если tls_domain совпадает с доменом сайта, пересылаем на nginx 8443
    local _mask_port_val=443
    local _site_dom; _site_dom=$(get_site_domain 2>/dev/null)
    [[ -n "$_site_dom" && "$new_sni" == "$_site_dom" ]] && _mask_port_val=8443

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
mask_port = ${_mask_port_val}
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
    health_check_brief
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
    health_check_brief
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
    health_check_brief
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
    health_check_brief
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
    health_check_brief
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
    health_check_brief
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
    health_check_brief
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
    health_check_brief
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
    health_check_brief
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
    health_check_brief
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  4. ТАЙМАУТЫ TELEMT
# ════════════════════════════════════════════════════════════════════════
menu_timeouts() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Настройки конфигов telemt${RESET}\n"
        echo -e "  ${BOLD}── Таймауты [timeouts]:${RESET} $(status_timeouts)"

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

        # client_mss = "tspu" статус
        echo -e "  ${BOLD}── client_mss=\"tspu\":${RESET} $(status_tspu)"
        if [[ ${#insts[@]} -gt 0 ]]; then
            for n in "${insts[@]}"; do
                local f="/etc/telemt/telemt${n}.toml" mss_st
                if grep -qE '^\s*client_mss\s*=\s*"tspu"' "$f" 2>/dev/null; then
                    mss_st="${GREEN}вкл${RESET}"
                elif grep -qE '^\s*#\s*client_mss\s*=\s*"tspu"' "$f" 2>/dev/null; then
                    mss_st="${YELLOW}выкл${RESET} (закомментировано)"
                else
                    mss_st="${DIM}нет в конфиге${RESET}"
                fi
                echo -e "  Инстанс ${BOLD}$n${RESET}: $mss_st"
            done
            echo ""
        fi

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo -e "  ${BOLD}── Таймауты:${RESET}"
        echo -e "  ${BOLD}1.${RESET} Установить / изменить значения"
        echo -e "  ${BOLD}2.${RESET} Сбросить к дефолтам (удалить секцию [timeouts])"
        echo ""
        echo -e "  ${BOLD}── client_mss=\"tspu\" (обход ТСПУ для РФ):${RESET}"
        echo -e "  ${BOLD}3.${RESET} ${GREEN}Включить${RESET} (раскомментировать или добавить во все конфиги)"
        echo -e "  ${BOLD}4.${RESET} ${YELLOW}Отключить${RESET} (закомментировать во всех конфигах)"
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch
        case "$ch" in
            1) timeouts_set ;;
            2) timeouts_reset ;;
            3) tspu_enable ;;
            4) tspu_disable ;;
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
    health_check_brief
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
    health_check_brief
    pause
}

# ─── client_mss = "tspu" — включение / отключение ──────────────────────────
# Включает (раскомментирует или добавляет) во всех конфигах /etc/telemt/telemt*.toml
tspu_enable() {
    draw_header
    echo -e "  ${BOLD}Включение client_mss = \"tspu\"${RESET}\n"
    info "Включает обход ТСПУ во всех инстансах."
    info "Если строка есть закомментированная — раскомментирует."
    info "Если строки нет — добавит в секцию [server]."
    echo ""
    read -rp "  Применить ко всем конфигам? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && return

    local insts; read -ra insts <<< "$(active_instances)"
    if [[ ${#insts[@]} -eq 0 ]]; then
        warn "Нет установленных инстансов"; pause; return
    fi

    for n in "${insts[@]}"; do
        local f="/etc/telemt/telemt${n}.toml"
        python3 - "$f" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()

# Случай 1: уже включена — ничего не делаем
if re.search(r'^\s*client_mss\s*=\s*"tspu"', content, flags=re.MULTILINE):
    print("already_on")
    sys.exit(0)

# Случай 2: закомментирована — раскомментировать
new = re.sub(
    r'^(\s*)#\s*client_mss\s*=\s*"tspu".*$',
    r'\1client_mss = "tspu"',
    content,
    flags=re.MULTILINE
)
if new != content:
    open(path, 'w').write(new)
    print("uncommented")
    sys.exit(0)

# Случай 3: строки вообще нет — добавляем в секцию [server] после listen_addr_ipv4
new = re.sub(
    r'(^\s*listen_addr_ipv4\s*=\s*"[^"]+"\s*$)',
    r'\1\nclient_mss = "tspu"',
    content,
    count=1,
    flags=re.MULTILINE
)
if new != content:
    open(path, 'w').write(new)
    print("added")
else:
    # Резерв: вставка после [server] заголовка
    new = re.sub(
        r'(^\[server\]\s*$)',
        r'\1\nclient_mss = "tspu"',
        content,
        count=1,
        flags=re.MULTILINE
    )
    if new != content:
        open(path, 'w').write(new)
        print("added_after_section")
    else:
        print("failed")
        sys.exit(1)
PYEOF
        local rc=$?
        if [[ $rc -eq 0 ]]; then
            ok "Инстанс $n: client_mss=\"tspu\" включён"
        else
            err "Инстанс $n: не удалось обновить конфиг"
        fi
    done

    echo ""
    read -rp "  Перезапустить инстансы? [Y/n]: " ans2
    if [[ ! "${ans2,,}" =~ ^(n|no)$ ]]; then
        for n in "${insts[@]}"; do
            systemctl restart "telemt${n}" 2>/dev/null && ok "telemt${n} перезапущен" || err "Ошибка"
        done
    fi
    health_check_brief
    pause
}

# Отключает (закомментирует) client_mss во всех конфигах
tspu_disable() {
    draw_header
    echo -e "  ${BOLD}Отключение client_mss = \"tspu\"${RESET}\n"
    warn "Строка будет закомментирована во всех конфигах telemt."
    warn "Это может ухудшить работу прокси если сервер в РФ или провайдер фильтрует MSS."
    echo ""
    read -rp "  Применить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    local insts; read -ra insts <<< "$(active_instances)"
    if [[ ${#insts[@]} -eq 0 ]]; then
        warn "Нет установленных инстансов"; pause; return
    fi

    for n in "${insts[@]}"; do
        local f="/etc/telemt/telemt${n}.toml"
        python3 - "$f" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()

# Случай 1: уже закомментирована — ничего не делаем
if re.search(r'^\s*#\s*client_mss\s*=\s*"tspu"', content, flags=re.MULTILINE):
    print("already_off")
    sys.exit(0)

# Случай 2: активная — комментируем
new = re.sub(
    r'^(\s*)client_mss\s*=\s*"tspu"(.*)$',
    r'\1#client_mss = "tspu"\2',
    content,
    flags=re.MULTILINE
)
if new != content:
    open(path, 'w').write(new)
    print("commented")
else:
    # Строки нет — фактически уже отключено (дефолт telemt)
    print("absent_no_action")
PYEOF
        ok "Инстанс $n: client_mss обработан"
    done

    echo ""
    read -rp "  Перезапустить инстансы? [Y/n]: " ans2
    if [[ ! "${ans2,,}" =~ ^(n|no)$ ]]; then
        for n in "${insts[@]}"; do
            systemctl restart "telemt${n}" 2>/dev/null && ok "telemt${n} перезапущен" || err "Ошибка"
        done
    fi
    health_check_brief
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
    health_check_brief
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
    health_check_brief
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  6. СВОЙ ДОМЕН В ССЫЛКАХ
# ════════════════════════════════════════════════════════════════════════
menu_custom_domain() {
    # Если установлен сайт-заглушка — домен управляется через раздел 8
    if [[ -f "$SITE_CONFIG_FILE" ]]; then
        draw_header
        echo -e "  ${BOLD}Свой домен в ссылках для клиентов${RESET}\n"
        warn "Установлена сайт-заглушка — домен ${BOLD}$(get_site_domain)${RESET} управляется автоматически"
        info "Этот домен совпадает с доменом сайта и используется в ссылках клиентов."
        info "Для смены домена удалите сайт (раздел 8 → пункт 5), затем настройте заново."
        echo ""
        pause
        return
    fi

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
    health_check_brief
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
    health_check_brief
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  7. VLESS Reality upstream (xray-core SOCKS5)
# ════════════════════════════════════════════════════════════════════════

# Получить тип ссылки (single | subscription)
vless_link_type() {
    cat "$VLESS_CONFIG_DIR/type.txt" 2>/dev/null || echo "single"
}

# Получить стратегию (только для subscription)
vless_strategy() {
    cat "$VLESS_CONFIG_DIR/strategy.txt" 2>/dev/null || echo "leastPing"
}

# Кол-во узлов в текущем конфиге
vless_node_count() {
    [[ -f "$VLESS_CONFIG_DIR/nodes.txt" ]] && wc -l < "$VLESS_CONFIG_DIR/nodes.txt" || echo 0
}

menu_vless() {
    while true; do
        draw_header
        echo -e "  ${BOLD}VLESS Reality upstream${RESET}\n"
        echo -e "  Статус: $(status_vless)"
        echo ""

        local link_type service_status port_status upstream_status nodes
        link_type=$(vless_link_type)
        nodes=$(vless_node_count)

        service_status="${DIM}не установлен${RESET}"
        if systemctl is-active --quiet telemt-vless 2>/dev/null; then
            service_status="${GREEN}active${RESET}"
        elif [[ -f /etc/systemd/system/telemt-vless.service ]]; then
            service_status="${RED}inactive${RESET}"
        fi
        port_status="${DIM}нет${RESET}"
        ss -tlnp 2>/dev/null | grep -q "127.0.0.1:40000" && port_status="${GREEN}слушает${RESET}"
        upstream_status="${DIM}нет${RESET}"
        for f in /etc/telemt/telemt*.toml; do
            [[ -f "$f" ]] && grep -q "127.0.0.1:40000" "$f" 2>/dev/null && upstream_status="${GREEN}прицеплен${RESET}" && break
        done

        echo -e "  ${DIM}Тип:${RESET}              ${BOLD}${link_type}${RESET}"
        if [[ "$link_type" == "subscription" ]]; then
            echo -e "  ${DIM}Стратегия:${RESET}        ${BOLD}$(vless_strategy)${RESET}"
            echo -e "  ${DIM}Узлов в конфиге:${RESET}  ${BOLD}${nodes}${RESET}"
            if [[ -f /etc/systemd/system/telemt-vless-refresh.timer ]] && systemctl is-active --quiet telemt-vless-refresh.timer 2>/dev/null; then
                local next_run; next_run=$(systemctl list-timers telemt-vless-refresh.timer --no-pager 2>/dev/null | grep telemt-vless | awk '{print $1, $2}')
                echo -e "  ${DIM}Авто-обновление:${RESET}  ${GREEN}вкл${RESET} (следующее: ${next_run:-?})"
            else
                echo -e "  ${DIM}Авто-обновление:${RESET}  ${YELLOW}выкл${RESET}"
            fi
        fi
        echo -e "  ${DIM}xray service:${RESET}     ${service_status}"
        echo -e "  ${DIM}SOCKS5 порт:${RESET}      ${port_status}"
        echo -e "  ${DIM}В конфигах telemt:${RESET} ${upstream_status}"
        echo ""

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        if [[ ! -f /usr/local/bin/xray ]] || [[ ! -f "$VLESS_CONFIG_DIR/config.json" ]]; then
            echo -e "  ${BOLD}1.${RESET} Установить VLESS Reality (одна ссылка или подписка)"
        else
            echo -e "  ${BOLD}1.${RESET} Запустить xray"
            echo -e "  ${BOLD}2.${RESET} Остановить xray"
            echo -e "  ${BOLD}3.${RESET} Изменить vless ссылку / подписку"
            if [[ "$link_type" == "subscription" ]]; then
                echo -e "  ${BOLD}4.${RESET} ${BOLD}${CYAN}Обновить подписку сейчас${RESET}"
                echo -e "  ${BOLD}5.${RESET} Включить / выключить авто-обновление"
                echo -e "  ${BOLD}6.${RESET} Сменить стратегию (leastPing/roundRobin/random)"
                echo -e "  ${BOLD}7.${RESET} Показать узлы из подписки"
                echo -e "  ${BOLD}8.${RESET} Прицепить к telemt / отцепить"
                echo -e "  ${BOLD}9.${RESET} Тест: IP через VLESS"
                echo -e "  ${BOLD}10.${RESET} Логи xray"
                echo -e "  ${BOLD}11.${RESET} ${RED}Удалить полностью${RESET}"
            else
                echo -e "  ${BOLD}4.${RESET} Прицепить к telemt / отцепить"
                echo -e "  ${BOLD}5.${RESET} Тест: IP через VLESS"
                echo -e "  ${BOLD}6.${RESET} Логи xray"
                echo -e "  ${BOLD}7.${RESET} ${RED}Удалить полностью${RESET}"
            fi
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
        elif [[ "$link_type" == "subscription" ]]; then
            case "$ch" in
                1)  vless_start ;;
                2)  vless_stop ;;
                3)  vless_change_link ;;
                4)  vless_refresh_now ;;
                5)  vless_toggle_autorefresh ;;
                6)  vless_change_strategy ;;
                7)  vless_show_nodes ;;
                8)  vless_attach_toggle ;;
                9)  vless_test ;;
                10) vless_logs ;;
                11) vless_remove ;;
                0|b) return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
        else
            case "$ch" in
                1) vless_start ;;
                2) vless_stop ;;
                3) vless_change_link ;;
                4) vless_attach_toggle ;;
                5) vless_test ;;
                6) vless_logs ;;
                7) vless_remove ;;
                0|b) return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
        fi
    done
}

# Запрос ссылки/подписки. echo'ит обратно через stdout: type|link[|strategy]
vless_ask_link_or_subscription() {
    echo -e "" >&2
    echo -e "  ${BOLD}Тип подключения:${RESET}" >&2
    echo -e "  ${GREEN}1${RESET} — одна ${BOLD}vless://${RESET} ссылка ${DIM}(vless://uuid@server:port?...)${RESET}" >&2
    echo -e "  ${GREEN}2${RESET} — ${BOLD}подписка${RESET} 3x-ui ${DIM}(https://server:port/path/sub-id)${RESET}" >&2
    echo -e "" >&2
    local choice
    while true; do
        read -rp "  Тип [1/2]: " choice >&2
        case "$choice" in 1|2) break ;; *) warn "1 или 2" >&2 ;; esac
    done

    if [[ "$choice" == "1" ]]; then
        local lnk
        while true; do
            read -rp "  vless:// ссылка: " lnk >&2
            if [[ "$lnk" == vless://*@*:*\?* ]] && [[ "$lnk" == *security=reality* ]] \
               && [[ "$lnk" == *pbk=* ]] && [[ "$lnk" == *sni=* ]]; then
                if VL="$lnk" python3 -c "import os,urllib.parse as up,sys;p=up.urlparse(os.environ['VL']);q=up.parse_qs(p.query);sys.exit(0 if (p.username and p.hostname and p.port and 'pbk' in q and 'sni' in q) else 1)" 2>/dev/null; then
                    # Проверка петли: сервер в vless != наш публичный IP
                    local vless_host vless_ip our_ip
                    vless_host=$(VL="$lnk" python3 -c "import os,urllib.parse as up;print(up.urlparse(os.environ['VL']).hostname)" 2>/dev/null)
                    vless_ip=$(getent hosts "$vless_host" 2>/dev/null | awk '{print $1}' | head -1)
                    our_ip=$(get_public_ip)
                    if [[ -n "$vless_ip" && -n "$our_ip" && "$vless_ip" == "$our_ip" ]]; then
                        err "VLESS-сервер (${vless_host} → ${vless_ip}) совпадает с этим сервером!" >&2
                        err "Это создаст петлю: telemt → xray → этот же сервер. Используйте VLESS от другого сервера." >&2
                        read -rp "  Попробовать другую ссылку? [Y/n]: " r >&2
                        [[ "${r,,}" =~ ^(n|no)$ ]] && return 1
                        continue
                    fi
                    printf '%s\n' "single|${lnk}"
                    return 0
                fi
            fi
            warn "Неверный формат ссылки" >&2
            read -rp "  Попробовать ещё? [Y/n]: " r >&2
            [[ "${r,,}" =~ ^(n|no)$ ]] && return 1
        done
    else
        local sub
        while true; do
            read -rp "  URL подписки: " sub >&2
            if [[ "$sub" =~ ^https?:// ]]; then
                local nodes_count
                info "Получение и парсинг подписки..." >&2
                nodes_count=$(SUB_URL="$sub" python3 << 'PYT'
import os, sys, urllib.request, base64, ssl
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
PYT
)
                if [[ -n "$nodes_count" && "$nodes_count" =~ ^[0-9]+$ ]]; then
                    ok "Подписка работает: найдено ${nodes_count} узлов" >&2
                    # Выбор стратегии
                    echo "" >&2
                    echo -e "  ${BOLD}Стратегия балансировки:${RESET}" >&2
                    echo -e "  ${GREEN}1${RESET} — leastPing (рекомендуется)" >&2
                    echo -e "  ${GREEN}2${RESET} — roundRobin" >&2
                    echo -e "  ${GREEN}3${RESET} — random" >&2
                    local stratch strat
                    while true; do
                        read -rp "  Стратегия [1/2/3]: " stratch >&2
                        case "$stratch" in
                            1|"") strat="leastPing"; break ;;
                            2)    strat="roundRobin"; break ;;
                            3)    strat="random"; break ;;
                            *)    warn "1-3" >&2 ;;
                        esac
                    done
                    printf '%s\n' "subscription|${sub}|${strat}"
                    return 0
                fi
                warn "Не удалось извлечь узлы. Формат подписки base64-plain?" >&2
            else
                warn "URL должен начинаться с http:// или https://" >&2
            fi
            read -rp "  Попробовать ещё? [Y/n]: " r >&2
            [[ "${r,,}" =~ ^(n|no)$ ]] && return 1
        done
    fi
}

vless_install() {
    draw_header
    echo -e "  ${BOLD}Установка VLESS Reality${RESET}\n"
    read -rp "  Продолжить? [Y/n]: " ans
    [[ "${ans,,}" =~ ^(n|no)$ ]] && return

    # 1) Запрашиваем ссылку или подписку
    local got
    got=$(vless_ask_link_or_subscription) || { info "Отменено"; pause; return; }
    local link_type link strategy
    IFS='|' read -r link_type link strategy <<< "$got"

    # 2) Скачиваем xray если ещё нет
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

    # 3) Установка генератора конфига (тот же скрипт что и install.sh использует)
    install_xray_refresh_helper
    ok "Генератор конфига установлен"

    # 4) Сохраняем link/type/strategy
    mkdir -p "$VLESS_CONFIG_DIR"
    echo "$link" > "$VLESS_CONFIG_DIR/link.txt"
    echo "$link_type" > "$VLESS_CONFIG_DIR/type.txt"
    [[ -n "$strategy" ]] && echo "$strategy" > "$VLESS_CONFIG_DIR/strategy.txt"

    # 5) Создаём xray user если нет
    if ! id xray &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --no-create-home --user-group xray 2>/dev/null \
        || useradd --system --shell /usr/sbin/nologin --no-create-home xray 2>/dev/null || true
    fi

    # 6) Генерация конфига
    if ! /usr/local/sbin/telemt-vless-refresh; then
        err "Не удалось сгенерировать конфиг"
        pause; return
    fi
    ok "Конфиг создан"

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

    # 8) Если подписка — спросить про авто-обновление
    if [[ "$link_type" == "subscription" ]]; then
        read -rp "  Включить авто-обновление подписки (каждые 6ч)? [Y/n]: " auto
        if [[ ! "${auto,,}" =~ ^(n|no)$ ]]; then
            install_xray_refresh_timer_helper
            ok "Авто-обновление включено"
        fi
    fi

    # 9) Прицепить к telemt?
    read -rp "  Прицепить VLESS к telemt (добавить upstream)? [Y/n]: " att
    [[ ! "${att,,}" =~ ^(n|no)$ ]] && vless_attach_silent

    health_check_brief
    pause
}

# Установка скрипта-генератора (для случая когда mytelemtinfo запускают без install.sh)
install_xray_refresh_helper() {
    if [[ -f /usr/local/sbin/telemt-vless-refresh ]]; then
        return 0  # уже установлен
    fi
    # Скачиваем из репо
    if curl -fsSL "https://raw.githubusercontent.com/vaalaav/telemt-install/main/telemt-vless-refresh.sh?v=$(date +%s)" -o /usr/local/sbin/telemt-vless-refresh 2>/dev/null; then
        chmod +x /usr/local/sbin/telemt-vless-refresh
    else
        warn "Не удалось скачать telemt-vless-refresh — нужно переустановить через install.sh"
    fi
}

install_xray_refresh_timer_helper() {
    cat > /etc/systemd/system/telemt-vless-refresh.service << 'RUNIT'
[Unit]
Description=Refresh telemt VLESS subscription
After=network-online.target

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

vless_start() {
    draw_header
    info "Запуск xray..."
    systemctl start telemt-vless 2>&1 || true
    sleep 2
    systemctl is-active --quiet telemt-vless && ok "xray active" || err "не запустился"
    health_check_brief
    pause
}

vless_stop() {
    draw_header
    warn "Если VLESS прицеплен к telemt — инстансы не смогут коннектиться к Telegram!"
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return
    systemctl stop telemt-vless 2>/dev/null
    ok "xray остановлен"
    health_check_brief
    pause
}

vless_change_link() {
    draw_header
    echo -e "  ${BOLD}Изменение vless ссылки или подписки${RESET}\n"
    if [[ -f "$VLESS_CONFIG_DIR/link.txt" ]]; then
        echo -e "  ${DIM}Текущая ссылка ($(vless_link_type)):${RESET}"
        echo -e "  ${DIM}$(head -c 80 "$VLESS_CONFIG_DIR/link.txt")...${RESET}"
        echo ""
    fi

    local got
    got=$(vless_ask_link_or_subscription) || { info "Отменено"; pause; return; }
    local link_type link strategy
    IFS='|' read -r link_type link strategy <<< "$got"

    # Обновляем файлы
    echo "$link" > "$VLESS_CONFIG_DIR/link.txt"
    echo "$link_type" > "$VLESS_CONFIG_DIR/type.txt"
    if [[ "$link_type" == "subscription" ]]; then
        echo "$strategy" > "$VLESS_CONFIG_DIR/strategy.txt"
    else
        rm -f "$VLESS_CONFIG_DIR/strategy.txt"
    fi

    # Регенерация
    info "Регенерация конфига xray..."
    if /usr/local/sbin/telemt-vless-refresh; then
        ok "Конфиг обновлён"
        # Перезапустить telemt чтобы переподключился через свежий upstream
        local insts; read -ra insts <<< "$(active_instances)"
        for n in "${insts[@]}"; do systemctl restart "telemt${n}" 2>/dev/null; done

        # Если подписка - предложить таймер если ещё не настроен
        if [[ "$link_type" == "subscription" ]] && [[ ! -f /etc/systemd/system/telemt-vless-refresh.timer ]]; then
            read -rp "  Включить авто-обновление? [Y/n]: " auto
            [[ ! "${auto,,}" =~ ^(n|no)$ ]] && install_xray_refresh_timer_helper && ok "Авто-обновление включено"
        fi
    else
        err "Не удалось обновить конфиг"
    fi
    health_check_brief
    pause
}

vless_refresh_now() {
    draw_header
    echo -e "  ${BOLD}Обновление подписки${RESET}\n"
    info "Скачивание свежего списка узлов..."
    if /usr/local/sbin/telemt-vless-refresh; then
        ok "Подписка обновлена. Узлов: $(vless_node_count)"
    else
        err "Не удалось обновить подписку"
    fi
    health_check_brief
    pause
}

vless_toggle_autorefresh() {
    draw_header
    echo -e "  ${BOLD}Авто-обновление подписки${RESET}\n"
    if systemctl is-active --quiet telemt-vless-refresh.timer 2>/dev/null; then
        warn "Автообновление сейчас ВКЛЮЧЕНО (каждые 6 часов)"
        read -rp "  Выключить? [y/N]: " a
        if [[ "${a,,}" =~ ^(y|yes|д|да)$ ]]; then
            systemctl disable --now telemt-vless-refresh.timer 2>/dev/null
            ok "Авто-обновление выключено"
        fi
    else
        info "Авто-обновление сейчас ВЫКЛЮЧЕНО"
        read -rp "  Включить (каждые 6 часов)? [Y/n]: " a
        if [[ ! "${a,,}" =~ ^(n|no)$ ]]; then
            install_xray_refresh_timer_helper
            ok "Авто-обновление включено"
        fi
    fi
    pause
}

vless_change_strategy() {
    draw_header
    echo -e "  ${BOLD}Смена стратегии балансировки${RESET}\n"
    local cur; cur=$(vless_strategy)
    echo -e "  Текущая: ${BOLD}${cur}${RESET}"
    echo ""
    echo -e "  ${GREEN}1${RESET} — leastPing (рекомендуется)"
    echo -e "  ${GREEN}2${RESET} — roundRobin"
    echo -e "  ${GREEN}3${RESET} — random"
    local ch new
    read -rp "  Выбрать [1/2/3]: " ch
    case "$ch" in
        1) new="leastPing" ;;
        2) new="roundRobin" ;;
        3) new="random" ;;
        *) info "Отменено"; pause; return ;;
    esac
    echo "$new" > "$VLESS_CONFIG_DIR/strategy.txt"
    if /usr/local/sbin/telemt-vless-refresh; then
        ok "Стратегия изменена на ${new}, конфиг применён"
    else
        err "Ошибка применения"
    fi
    health_check_brief
    pause
}

vless_show_nodes() {
    draw_header
    echo -e "  ${BOLD}Узлы из подписки${RESET}\n"
    if [[ -f "$VLESS_CONFIG_DIR/nodes.txt" ]]; then
        cat "$VLESS_CONFIG_DIR/nodes.txt" | nl -ba | sed 's/^/  /'
    else
        warn "nodes.txt не найден (выполните 'Обновить подписку сейчас')"
    fi
    pause
}

# Прицепить или отцепить — выбор внутри
vless_attach_toggle() {
    draw_header
    echo -e "  ${BOLD}Прицепить / отцепить VLESS к telemt${RESET}\n"

    # Проверим текущее состояние
    local attached=0 total=0
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        total=$((total+1))
        grep -q "127.0.0.1:40000" "$f" 2>/dev/null && attached=$((attached+1))
    done

    if [[ $attached -eq $total && $total -gt 0 ]]; then
        info "Сейчас VLESS прицеплен ко всем ${total} инстансам"
        read -rp "  Отцепить (telemt пойдёт напрямую)? [y/N]: " a
        [[ "${a,,}" =~ ^(y|yes|д|да)$ ]] && vless_detach_silent
    elif [[ $attached -eq 0 ]]; then
        info "VLESS сейчас не прицеплен"
        read -rp "  Прицепить ко всем ${total} инстансам? [Y/n]: " a
        [[ ! "${a,,}" =~ ^(n|no)$ ]] && vless_attach_silent
    else
        warn "Прицеплен частично: ${attached}/${total}"
        read -rp "  Привести в единое состояние — [a]прицепить всё / [d]отцепить всё: " a
        case "${a,,}" in
            a) vless_attach_silent ;;
            d) vless_detach_silent ;;
        esac
    fi
    health_check_brief
    pause
}

vless_attach_silent() {
    local count=0
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        grep -q "127.0.0.1:40000" "$f" 2>/dev/null && continue
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

vless_detach_silent() {
    local count=0
    for f in /etc/telemt/telemt*.toml; do
        [[ ! -f "$f" ]] && continue
        if ! grep -q "127.0.0.1:40000" "$f" 2>/dev/null; then continue; fi
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
}

vless_test() {
    draw_header
    echo -e "  ${BOLD}Тест: какой IP виден через VLESS${RESET}\n"
    info "Прямой запрос:"
    local direct_ip; direct_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    echo -e "  ${BOLD}${direct_ip:-(не удалось)}${RESET}"
    echo ""
    info "Через VLESS SOCKS5:"
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
    fi
    pause
}

vless_logs() {
    draw_header
    echo -e "  ${BOLD}Последние логи xray${RESET}\n"
    journalctl -u telemt-vless -n 50 --no-pager
    pause
}

vless_remove() {
    draw_header
    echo -e "  ${BOLD}${RED}Полное удаление VLESS${RESET}\n"
    warn "Будут удалены: сервис, refresh-timer, конфиги, upstream из telemt"
    warn "Бинарник /usr/local/bin/xray НЕ удаляется"
    echo ""
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    vless_detach_silent
    systemctl stop telemt-vless 2>/dev/null || true
    systemctl disable telemt-vless 2>/dev/null || true
    systemctl stop telemt-vless-refresh.timer 2>/dev/null || true
    systemctl disable telemt-vless-refresh.timer 2>/dev/null || true
    rm -f /etc/systemd/system/telemt-vless.service
    rm -f /etc/systemd/system/telemt-vless-refresh.service
    rm -f /etc/systemd/system/telemt-vless-refresh.timer
    rm -f /usr/local/sbin/telemt-vless-refresh
    rm -rf /etc/telemt-vless
    systemctl daemon-reload

    if id xray &>/dev/null && ! pgrep -u xray &>/dev/null; then
        userdel xray 2>/dev/null && info "Удалён системный пользователь xray" || true
    fi

    ok "VLESS компоненты удалены"

    local insts; read -ra insts <<< "$(active_instances)"
    for n in "${insts[@]}"; do systemctl restart "telemt${n}" 2>/dev/null; done

    if [[ -f /usr/local/bin/xray ]]; then
        info "Бинарник /usr/local/bin/xray остался — удалите вручную если не нужен"
    fi
    health_check_brief
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  8. САЙТ-ЗАГЛУШКА
# ════════════════════════════════════════════════════════════════════════

menu_site() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Сайт-заглушка${RESET}\n"

        local installed=false
        [[ -f "$SITE_CONFIG_FILE" ]] && installed=true

        if [[ "$installed" == true ]]; then
            local dom port saved
            dom=$(get_site_domain)
            port=$(get_site_port)
            saved=$(get_site_info)
            local template_url=""
            [[ -n "$saved" ]] && template_url=$(echo "$saved" | cut -d'|' -f3)

            local nginx_st; nginx_st=$(systemctl is-active nginx 2>/dev/null)
            if [[ "$nginx_st" == "active" ]]; then
                echo -e "  Статус nginx:  ${GREEN}active${RESET}"
            else
                echo -e "  Статус nginx:  ${RED}${nginx_st}${RESET}"
            fi
            echo -e "  Домен:         ${BOLD}${dom}${RESET}"
            echo -e "  Порт:          ${BOLD}${port}${RESET}"
            echo -e "  Шаблон:        ${DIM}${template_url:-?}${RESET}"

            # Сертификат
            local cert="/etc/letsencrypt/live/${dom}/fullchain.pem"
            if [[ -f "$cert" ]]; then
                local exp; exp=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
                echo -e "  Сертификат:    ${GREEN}валиден до ${exp}${RESET}"
            else
                echo -e "  Сертификат:    ${RED}нет${RESET}"
            fi

            # Тест URL
            local su; [[ "$port" == "443" ]] && su="https://${dom}" || su="https://${dom}:${port}"
            local http_code
            http_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 3 \
                "${su}/" 2>/dev/null || echo "—")
            echo -e "  Тест URL:      ${su}/ → ${BOLD}${http_code}${RESET}"
            echo ""

            echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
            echo -e "  ${BOLD}1.${RESET} Сменить шаблон сайта"
            echo -e "  ${BOLD}2.${RESET} Обновить сертификат вручную"
            echo -e "  ${BOLD}3.${RESET} Проверка работоспособности"
            echo -e "  ${BOLD}4.${RESET} Просмотр логов nginx"
            echo -e "  ${BOLD}5.${RESET} ${RED}Удалить сайт-заглушку${RESET}"
            echo -e "  ${BOLD}0.${RESET} ← Назад"
            echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
            echo ""
            read -rp "  Выберите: " ch
            case "$ch" in
                1) site_change_template ;;
                2) site_renew_cert ;;
                3) site_health_check ;;
                4) site_show_logs ;;
                5) site_remove ;;
                0|b) return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
        else
            warn "Сайт-заглушка не установлена"
            echo ""
            echo -e "  Установка через mytelemtinfo требует ввести домен (с проверкой DNS),"
            echo -e "  email для Let's Encrypt и URL шаблона из GitHub."
            echo ""
            echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
            echo -e "  ${BOLD}1.${RESET} ${GREEN}Установить сайт${RESET}"
            echo -e "  ${BOLD}0.${RESET} ← Назад"
            echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
            echo ""
            read -rp "  Выберите: " ch
            case "$ch" in
                1) site_install ;;
                0|b) return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
        fi
    done
}

# Установка сайта из mytelemtinfo (повторяет логику step_* из install.sh)
site_install() {
    draw_header
    echo -e "  ${BOLD}Установка сайта-заглушки${RESET}\n"

    # 1. Запрос домена с проверкой DNS
    local site_dom server_ip resolved_ip
    server_ip=$(get_public_ip)
    [[ -n "$server_ip" ]] && info "IP сервера: ${BOLD}${server_ip}${RESET}"
    while true; do
        read -rp "  Домен сайта: " site_dom
        [[ -z "$site_dom" || "$site_dom" != *.* ]] && { warn "Введите FQDN (например site.example.com)"; continue; }
        resolved_ip=$(getent hosts "$site_dom" 2>/dev/null | awk '{print $1}' | head -1)
        if [[ -z "$resolved_ip" ]]; then
            err "Домен не резолвится"
            read -rp "  Попробовать другой? [Y/n]: " r
            [[ "${r,,}" =~ ^(n|no)$ ]] && { info "Отменено"; pause; return; }
            continue
        fi
        if [[ -n "$server_ip" && "$resolved_ip" != "$server_ip" ]]; then
            err "DNS не совпадает: $site_dom → $resolved_ip, IP сервера → $server_ip"
            read -rp "  Попробовать другой? [Y/n]: " r
            [[ "${r,,}" =~ ^(n|no)$ ]] && { info "Отменено"; pause; return; }
            continue
        fi
        ok "DNS корректен: $site_dom → $resolved_ip"
        break
    done

    # 2. Email
    local site_email
    while true; do
        read -rp "  Email для Let's Encrypt: " site_email
        [[ "$site_email" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
        warn "Введите корректный email"
    done

    # 3. Шаблон
    local site_template_url
    echo -e "  Шаблон:"
    echo -e "  ${GREEN}1${RESET} — vaalaav/Market-Terminal-Template ${DIM}(по умолчанию)${RESET}"
    echo -e "  ${GREEN}2${RESET} — другой GitHub-репозиторий"
    local tc
    read -rp "  Выбор [1/2]: " tc
    case "$tc" in
        2) read -rp "  URL: " site_template_url ;;
        *) site_template_url="https://github.com/vaalaav/Market-Terminal-Template" ;;
    esac

    local site_port="8443"

    # Сохраняем параметры
    mkdir -p /etc/telemt
    echo "${site_dom}|${site_email}|${site_template_url}|${site_port}" > "$SITE_INFO_FILE"
    chmod 644 "$SITE_INFO_FILE"

    info "Установка зависимостей..."
    apt-get install -y nginx certbot python3-certbot-nginx git curl 2>&1 | tail -3 || { err "Ошибка apt"; pause; return; }
    ok "nginx + certbot + git установлены"

    info "Клонирование шаблона..."
    rm -rf "$SITE_WWW_DIR"
    if ! git clone --depth 1 "$site_template_url" "$SITE_WWW_DIR" 2>&1 | tail -3; then
        warn "Шаблон не клонировался — создаю простую заглушку"
        mkdir -p "$SITE_WWW_DIR"
        echo "<h1>Сайт в разработке</h1>" > "$SITE_WWW_DIR/index.html"
    fi
    chown -R www-data:www-data "$SITE_WWW_DIR"
    chmod -R o+rX "$SITE_WWW_DIR"

    info "Настройка nginx (HTTP для ACME)..."
    mkdir -p /var/www/letsencrypt
    cat > /etc/nginx/sites-available/telemt-site.conf << NGINX
server {
    listen 80;
    server_name ${site_dom};
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; default_type "text/plain"; }
    location / { return 301 https://\$host\$request_uri; }
}
NGINX
    ln -sf /etc/nginx/sites-available/telemt-site.conf "$SITE_CONFIG_FILE"
    rm -f /etc/nginx/sites-enabled/default
    nginx -t 2>&1 | tail -3 && systemctl reload nginx

    info "Получение сертификата Let's Encrypt..."
    if ! certbot certonly --webroot -w /var/www/letsencrypt \
        -d "$site_dom" --email "$site_email" \
        --agree-tos --non-interactive --no-eff-email 2>&1 | tail -5; then
        err "certbot не смог выпустить сертификат"
        warn "Проверьте: A-запись, порт 80 не заблокирован, не превышен rate-limit Let's Encrypt"
        pause; return
    fi
    ok "Сертификат получен"

    # Дописываем HTTPS-блок
    cat > /etc/nginx/sites-available/telemt-site.conf << NGINX
server {
    listen 80;
    server_name ${site_dom};
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; default_type "text/plain"; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen ${site_port} ssl http2;
    server_name ${site_dom};
    ssl_certificate     /etc/letsencrypt/live/${site_dom}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${site_dom}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root ${SITE_WWW_DIR};
    index index.html index.htm;
    server_tokens off;
    location / { try_files \$uri \$uri/ /index.html; }
}
NGINX
    nginx -t 2>&1 | tail -3 && systemctl restart nginx
    ok "nginx переключён на HTTPS на порту ${site_port}"

    # UFW открыть порты
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp 2>/dev/null && info "UFW: открыт 80"
        ufw allow "${site_port}/tcp" 2>/dev/null && info "UFW: открыт ${site_port}"
    fi

    # Сохраняем кастомный домен (он будет использоваться в ссылках telemt)
    echo "$site_dom" > /etc/telemt/.custom_domain
    chmod 644 /etc/telemt/.custom_domain

    # Если есть инстансы telemt — обновить tls_domain и mask_port первого инстанса
    if [[ -f /etc/telemt/telemt1.toml ]]; then
        sed -i "s|^tls_domain = .*|tls_domain = \"${site_dom}\"|" /etc/telemt/telemt1.toml
        sed -i "s|^mask_port = .*|mask_port = 8443|" /etc/telemt/telemt1.toml
        systemctl restart telemt1 2>/dev/null && ok "telemt1 перезапущен с tls_domain=${site_dom}, mask_port=8443"
    fi

    ok "${BOLD}Сайт-заглушка установлена${RESET}"
    health_check_brief
    pause
}

site_change_template() {
    draw_header
    echo -e "  ${BOLD}Смена шаблона сайта${RESET}\n"
    local saved; saved=$(get_site_info)
    local cur_template; cur_template=$(echo "$saved" | cut -d'|' -f3)
    echo -e "  Текущий шаблон: ${DIM}${cur_template}${RESET}\n"

    local new_url
    read -rp "  Новый URL GitHub-репо: " new_url
    [[ -z "$new_url" || ! "$new_url" =~ ^https://github\.com/ ]] && { warn "Неверный URL"; pause; return; }

    # Бэкап старого
    local backup="/tmp/telemt-site.backup.$(date +%s)"
    if [[ -d "$SITE_WWW_DIR" ]]; then
        cp -a "$SITE_WWW_DIR" "$backup"
        info "Бэкап старого шаблона: $backup"
    fi

    rm -rf "$SITE_WWW_DIR"
    if ! git clone --depth 1 "$new_url" "$SITE_WWW_DIR" 2>&1 | tail -3; then
        err "Не удалось клонировать новый шаблон"
        if [[ -d "$backup" ]]; then
            info "Восстанавливаем старый..."
            mv "$backup" "$SITE_WWW_DIR"
        fi
        pause; return
    fi
    chown -R www-data:www-data "$SITE_WWW_DIR"
    chmod -R o+rX "$SITE_WWW_DIR"

    # Обновить URL в .site-info
    local dom email port
    dom=$(echo "$saved" | cut -d'|' -f1)
    email=$(echo "$saved" | cut -d'|' -f2)
    port=$(echo "$saved" | cut -d'|' -f4)
    echo "${dom}|${email}|${new_url}|${port}" > "$SITE_INFO_FILE"

    systemctl reload nginx 2>/dev/null
    ok "Шаблон заменён"
    health_check_brief
    pause
}

site_renew_cert() {
    draw_header
    echo -e "  ${BOLD}Обновление сертификата${RESET}\n"
    local dom; dom=$(get_site_domain)
    info "Запуск certbot renew для $dom..."
    if certbot renew --cert-name "$dom" --force-renewal --non-interactive 2>&1 | tail -5; then
        ok "Сертификат обновлён"
        systemctl reload nginx 2>/dev/null
    else
        err "Обновление не удалось"
    fi
    pause
}

site_health_check() {
    draw_header
    echo -e "  ${BOLD}Проверка работоспособности сайта${RESET}\n"

    local dom port; dom=$(get_site_domain); port=$(get_site_port)
    local issues=0

    if systemctl is-active --quiet nginx; then
        ok "nginx: active"
    else
        err "nginx: НЕ active"; issues=$((issues+1))
    fi

    local cert="/etc/letsencrypt/live/${dom}/fullchain.pem"
    if [[ -f "$cert" ]]; then
        local exp; exp=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        ok "Сертификат: до ${exp}"
    else
        err "Сертификат отсутствует"; issues=$((issues+1))
    fi

    local su; [[ "$port" == "443" ]] && su="https://${dom}" || su="https://${dom}:${port}"
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "${su}/" 2>/dev/null)
    if [[ "$code" == "200" || "$code" == "30"* ]]; then
        ok "URL отвечает: ${su}/ → ${code}"
    else
        err "URL отвечает кодом: ${code}"; issues=$((issues+1))
    fi

    # tls_domain в telemt
    if [[ -f /etc/telemt/telemt1.toml ]]; then
        if grep -q "tls_domain = \"${dom}\"" /etc/telemt/telemt1.toml; then
            ok "tls_domain в telemt = ${dom}"
        else
            warn "tls_domain в /etc/telemt/telemt1.toml не равен ${dom}"
        fi
    fi

    echo ""
    [[ $issues -eq 0 ]] && ok "${BOLD}Всё работает${RESET}" || warn "${BOLD}Проблем: $issues${RESET}"
    pause
}

site_show_logs() {
    draw_header
    echo -e "  ${BOLD}Логи nginx${RESET}\n"
    echo -e "  ${DIM}── access log (последние 30):${RESET}"
    tail -30 /var/log/nginx/access.log 2>/dev/null | sed 's/^/    /'
    echo ""
    echo -e "  ${DIM}── error log (последние 20):${RESET}"
    tail -20 /var/log/nginx/error.log 2>/dev/null | sed 's/^/    /'
    pause
}

site_remove() {
    draw_header
    echo -e "  ${BOLD}${RED}Удаление сайта-заглушки${RESET}\n"
    warn "Будут удалены: nginx-конфиг сайта, /var/www/telemt-site, опционально серт"
    warn "nginx сам НЕ удаляется. telemt и его конфиги тоже остаются."
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    local dom; dom=$(get_site_domain)

    rm -f /etc/nginx/sites-enabled/telemt-site.conf
    rm -f /etc/nginx/sites-available/telemt-site.conf
    rm -rf "$SITE_WWW_DIR" /var/www/letsencrypt
    rm -f "$SITE_INFO_FILE"

    if systemctl is-active --quiet nginx; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    fi
    ok "Конфиги сайта удалены"

    # Сертификат
    if [[ -n "$dom" && -d "/etc/letsencrypt/live/$dom" ]]; then
        echo ""
        warn "Найден сертификат Let's Encrypt для ${dom}"
        read -rp "  Удалить сертификат? [y/N]: " ans
        if [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]; then
            certbot delete --cert-name "$dom" --non-interactive 2>&1 | tail -2 || true
            ok "Сертификат удалён"
        fi
    fi

    # UFW закрыть 80 и порт сайта (если они были открыты только для сайта)
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow 80/tcp 2>/dev/null && info "UFW: закрыт 80"
        # Порт сайта — может быть в .site-info, но мы его уже стёрли. Не трогаем 8443 явно
    fi

    # Кастомный домен — оставляем (он может использоваться отдельно), но предупреждаем
    if [[ -f /etc/telemt/.custom_domain ]]; then
        warn "Файл /etc/telemt/.custom_domain не удалён — снимите домен через меню 6, если нужно"
    fi

    ok "Сайт-заглушка удалена"
    health_check_brief
    pause
}

# ════════════════════════════════════════════════════════════════════════
#  9. ПАНЕЛЬ УПРАВЛЕНИЯ (telemt_panel)
# ════════════════════════════════════════════════════════════════════════
_panel_detect_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "x86_64"  ;;
        aarch64) echo "aarch64" ;;
        *)       err "Архитектура $arch не поддерживается"; return 1 ;;
    esac
}

panel_install() {
    draw_header
    echo -e "  ${BOLD}Установка telemt_panel${RESET}\n"

    if [[ -x "$PANEL_BIN" ]]; then
        warn "Панель уже установлена: $($PANEL_BIN version 2>/dev/null | awk '{print $NF; exit}')"
        read -rp "  Переустановить/обновить? [y/N]: " ans
        [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return
    fi

    local arch
    arch=$(_panel_detect_arch) || { pause; return; }

    info "Определение последней версии..."
    local tag
    tag=$(curl -fsSL "https://api.github.com/repos/${PANEL_REPO}/releases/latest" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null)
    [[ -z "$tag" ]] && { err "Не удалось получить версию"; pause; return; }
    info "Версия: $tag"

    local tarball="telemt-panel-${arch}-linux-gnu.tar.gz"
    local url="https://github.com/${PANEL_REPO}/releases/download/${tag}/${tarball}"
    local tmp_dir; tmp_dir=$(mktemp -d)
    info "Скачивание ${tarball}..."
    if ! curl -fSL "$url" -o "${tmp_dir}/${tarball}" 2>&1 | tail -3; then
        err "Ошибка загрузки"; rm -rf "$tmp_dir"; pause; return
    fi
    tar -xzf "${tmp_dir}/${tarball}" -C "$tmp_dir"
    install -m 0755 "${tmp_dir}/telemt-panel-${arch}-linux" "$PANEL_BIN"
    rm -rf "$tmp_dir"
    ok "Бинарник: ${PANEL_BIN} (${tag})"

    if ! id "$PANEL_USER" &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --home /nonexistent "$PANEL_USER" 2>/dev/null \
            || adduser --system --shell /usr/sbin/nologin --home /nonexistent --disabled-password "$PANEL_USER" 2>/dev/null
        ok "Создан пользователь ${PANEL_USER}"
    fi
    if getent group telemt &>/dev/null; then
        usermod -aG telemt "$PANEL_USER" 2>/dev/null || true
    fi

    mkdir -p "$PANEL_CFG_DIR" "$PANEL_DATA/staging"
    chown "$PANEL_USER:$PANEL_USER" "$PANEL_CFG_DIR" "$PANEL_DATA" "$PANEL_DATA/staging"

    if [[ -f "$PANEL_CFG" ]]; then
        info "Конфиг уже существует: ${PANEL_CFG}"
    else
        echo ""
        # Автоопределение API URL
        local first_inst telemt_url telemt_auth=""
        read -ra _tmp_insts <<< "$(active_instances)"
        first_inst="${_tmp_insts[0]:-1}"
        local api_port="${INSTANCE_APIS[$first_inst]:-9091}"
        telemt_url="http://127.0.0.1:${api_port}"
        info "Telemt API: ${telemt_url} (инстанс ${first_inst})"

        local admin_user admin_pass
        read -rp "  Admin логин [admin]: " admin_user
        admin_user="${admin_user:-admin}"
        read -rsp "  Admin пароль: " admin_pass; echo ""
        [[ -z "$admin_pass" ]] && { err "Пароль не может быть пустым"; pause; return; }

        info "Генерация хеша пароля..."
        local pass_hash
        pass_hash=$(printf '%s\n' "$admin_pass" | "$PANEL_BIN" hash-password 2>/dev/null)
        [[ -z "$pass_hash" ]] && { err "Не удалось создать хеш"; pause; return; }

        local jwt_secret; jwt_secret=$(openssl rand -hex 32)
        local telemt_path; telemt_path=$(command -v telemt 2>/dev/null || echo "/bin/telemt")

        cat > "$PANEL_CFG" <<TOML
listen = "0.0.0.0:8080"
data_dir = "${PANEL_DATA}"

[telemt]
url = "${telemt_url}"
binary_path = "${telemt_path}"
service_name = "telemt${first_inst}"

[panel]
binary_path = "${PANEL_BIN}"
service_name = "${PANEL_SVC}"

[auth]
username = "${admin_user}"
password_hash = "${pass_hash}"
jwt_secret = "${jwt_secret}"
session_ttl = "24h"
TOML
        chown "$PANEL_USER:$PANEL_USER" "$PANEL_CFG"
        chmod 600 "$PANEL_CFG"
        ok "Конфиг: ${PANEL_CFG}"
    fi

    # Sudoers drop-in
    local sudoers="/etc/sudoers.d/${PANEL_SVC}"
    local cp_bin mv_bin chmod_bin rm_bin systemctl_bin
    cp_bin=$(command -v cp); mv_bin=$(command -v mv)
    chmod_bin=$(command -v chmod); rm_bin=$(command -v rm)
    systemctl_bin=$(command -v systemctl)
    cat > "$sudoers" <<SUDO
${PANEL_USER} ALL=(root) NOPASSWD: ${cp_bin} -f ${PANEL_BIN} ${PANEL_DATA}/staging/telemt-panel.bak
${PANEL_USER} ALL=(root) NOPASSWD: ${cp_bin} -f ${PANEL_DATA}/staging/telemt-panel ${PANEL_BIN}.tmp
${PANEL_USER} ALL=(root) NOPASSWD: ${chmod_bin} 0755 ${PANEL_BIN}.tmp
${PANEL_USER} ALL=(root) NOPASSWD: ${mv_bin} -f ${PANEL_BIN}.tmp ${PANEL_BIN}
${PANEL_USER} ALL=(root) NOPASSWD: ${rm_bin} -f ${PANEL_BIN}.tmp
${PANEL_USER} ALL=(root) NOPASSWD: ${systemctl_bin} restart ${PANEL_SVC}
${PANEL_USER} ALL=(root) NOPASSWD: ${systemctl_bin} restart telemt*
${PANEL_USER} ALL=(root) NOPASSWD: ${systemctl_bin} start ${PANEL_SVC}
SUDO
    chmod 0440 "$sudoers"
    ok "Sudoers: ${sudoers}"

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
    systemctl start "${PANEL_SVC}"
    ok "Сервис ${PANEL_SVC} запущен"

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 8080/tcp 2>/dev/null && info "UFW: открыт 8080"
    fi

    echo ""
    [[ -z "$_PUBLIC_IP_CACHE" ]] && _PUBLIC_IP_CACHE=$(get_public_ip)
    ok "${BOLD}Панель: http://${_PUBLIC_IP_CACHE:-<IP>}:8080${RESET}"
    health_check_brief
    pause
}

panel_remove_full() {
    draw_header
    echo -e "  ${BOLD}${RED}Удаление telemt_panel${RESET}\n"
    warn "Будут удалены: бинарник, конфиг, данные, systemd-сервис, пользователь"
    read -rp "  Подтвердить? [y/N]: " ans
    [[ ! "${ans,,}" =~ ^(y|yes|д|да)$ ]] && return

    systemctl stop "$PANEL_SVC" 2>/dev/null || true
    systemctl disable "$PANEL_SVC" 2>/dev/null || true
    rm -f "/etc/systemd/system/${PANEL_SVC}.service"
    rm -f "/etc/sudoers.d/${PANEL_SVC}"
    rm -f "$PANEL_BIN"
    rm -rf "$PANEL_CFG_DIR" "$PANEL_DATA"
    if id "$PANEL_USER" &>/dev/null; then
        userdel "$PANEL_USER" 2>/dev/null || true
    fi
    systemctl daemon-reload

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow 8080/tcp 2>/dev/null && info "UFW: закрыт 8080"
    fi

    ok "Панель полностью удалена"
    health_check_brief
    pause
}

panel_show_logs() {
    draw_header
    echo -e "  ${BOLD}Логи telemt-panel${RESET}\n"
    journalctl -u "$PANEL_SVC" -n 40 --no-pager 2>/dev/null | sed 's/^/    /'
    pause
}

menu_panel() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Панель управления (telemt_panel)${RESET}\n"

        if [[ -x "$PANEL_BIN" ]]; then
            local ver st port
            ver=$("$PANEL_BIN" version 2>/dev/null | awk '{print $NF; exit}' || echo "?")
            st=$(systemctl is-active "$PANEL_SVC" 2>/dev/null || echo "не установлен")
            port=$(grep -m1 '^\s*listen' "$PANEL_CFG" 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':')
            port="${port:-8080}"
            echo -e "  Версия:  ${BOLD}${ver}${RESET}"
            echo -e "  Статус:  $(svc_status_color "$st")"
            echo -e "  Порт:    ${BOLD}${port}${RESET}"
            echo -e "  Конфиг:  ${DIM}${PANEL_CFG}${RESET}"
        else
            warn "Панель не установлена"
        fi

        echo ""
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        if [[ -x "$PANEL_BIN" ]]; then
            echo -e "  ${BOLD}1.${RESET} Перезапустить панель"
            echo -e "  ${BOLD}2.${RESET} Остановить панель"
            echo -e "  ${BOLD}3.${RESET} Запустить панель"
            echo -e "  ${BOLD}4.${RESET} Просмотр логов"
            echo -e "  ${BOLD}5.${RESET} Переустановить / обновить"
            echo -e "  ${RED}${BOLD}6.${RESET} ${RED}Удалить панель${RESET}"
        else
            echo -e "  ${GREEN}${BOLD}1.${RESET} ${GREEN}Установить панель${RESET}"
        fi
        echo -e "  ${BOLD}0.${RESET} ← Назад"
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
        echo ""
        read -rp "  Выберите: " ch
        if [[ -x "$PANEL_BIN" ]]; then
            case "$ch" in
                1) systemctl restart "$PANEL_SVC" && ok "Перезапущена" || err "Ошибка"; pause ;;
                2) systemctl stop "$PANEL_SVC" && ok "Остановлена" || err "Ошибка"; pause ;;
                3) systemctl start "$PANEL_SVC" && ok "Запущена" || err "Ошибка"; pause ;;
                4) panel_show_logs ;;
                5) panel_install ;;
                6) panel_remove_full ;;
                0|b) return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
        else
            case "$ch" in
                1) panel_install ;;
                0|b) return ;;
                *) warn "Неверный пункт"; sleep 1 ;;
            esac
        fi
    done
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
