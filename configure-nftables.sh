#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

success() { echo -e "${GREEN}[SUCCESS] $*${NC}"; }
info()    { echo -e "${CYAN}[INFO] $*${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $*${NC}"; }
error()   { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${CYAN}▶  $*${NC}"; }

# =====================
# Значения по умолчанию
# =====================
ALLOW_IPV6=true
ALLOW_ICMP=true
ALLOW_ICMPV6=true
SSH_PROTECTION=true

# Порты и адреса
TCP_EXTRA_PORTS=()
UDP_EXTRA_PORTS=()
ALLOW_FROM=()

# Лимиты SSH
SSH_RATE=15
SSH_BURST=10
SSH_BAN_TIME="1h"

# Лимиты TCP-портов (--allow-ports)
SYN_PROTECTION=true
SYN_RATE=200
SYN_BURST=400

# Лимиты UDP-портов (--allow-udp-ports)
UDP_PROTECTION=true
UDP_RATE=1000
UDP_BURST=2000

# 0 – выключен, per-IP лимит ОДНОВРЕМЕННЫХ соединений
CONN_LIMIT=0

# Параметры анти-скан
ANTI_SCAN=true
PORTSCAN_RATE=20
PORTSCAN_BURST=40
PORTSCAN_BAN_TIME="1h"

# Блок-листы
ENABLE_BLOCKLISTS=true
EXTRA_BLOCKLIST_URLS=()

# Bogon-фильтр
BOGON_FILTER=true
WAN_IFACE_OVERRIDE=""

# ICMP rate-limit
ICMP_RATE=20
ICMP_BURST=40

DRY_RUN=false

ANTISCANNER_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
GOVERNMENT_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"

TABLE_FAMILY="inet"
TABLE_NAME="cm_filter"
NFT_DIR="/etc/nftables.d"
NFT_FILE="${NFT_DIR}/${TABLE_NAME}.nft"
SERVICE_NAME="cm-filter.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

# =======
# Справка
# =======
help() {
    echo -e "
${BOLD}ИСПОЛЬЗОВАНИЕ:${NC} $(basename "$0") [опции]

${BOLD}ОБЩЕЕ:${NC}
  По умолчанию открыт ТОЛЬКО порт SSH (определяется автоматически через
  sshd -T). IPv6, ICMP echo-request (v4+v6) и защита SSH включены по
  умолчанию.

${BOLD}ОТКЛЮЧЕНИЕ ФУНКЦИЙ ПО УМОЛЧАНИЮ:${NC}
  ${GREEN}--disable-ipv6${NC}
      Полностью заблокировать IPv6 (input/forward/output, кроме loopback).

  ${GREEN}--disable-icmp${NC}
      Запретить входящий ICMP echo-request (ping) для IPv4.

  ${GREEN}--disable-icmpv6${NC}
      Запретить входящий ICMPv6 echo-request (ping6).
      NDP/MLD разрешены всегда (их дроп ломает IPv6).
      Игнорируется при --disable-ipv6.

  ${GREEN}--disable-ssh-protection${NC}
      Отключить per-IP rate-limit + автобан для SSH.

${BOLD}РАЗРЕШЕНИЕ ДОПОЛНИТЕЛЬНЫХ ПОРТОВ:${NC}
  ${GREEN}--allow-ports${NC} <PORT[,PORT,...]>
      Открыть дополнительные TCP-порты для всех (v4+v6).

  ${GREEN}--allow-udp-ports${NC} <PORT[,PORT,...]>
      Открыть дополнительные UDP-порты для всех (v4+v6).

  ${GREEN}--allow-port-from${NC} <ENTRY[,ENTRY,...]>
      Разрешить TCP-порт только с конкретных адресов.
      Формат для IPv4: IP:PORT  (например 1.2.3.4:8080)
      Формат для IPv6: [ADDR]:PORT  (например [2001:db8::1]:8080)

${BOLD}ЛИМИТЫ SSH:${NC}
  Порт определяется автоматически (sshd -T).

  ${GREEN}--ssh-rate${NC} <N>          per-IP новых SSH-соединений/мин (умолч. ${SSH_RATE})
  ${GREEN}--ssh-burst${NC} <N>         burst (умолч. ${SSH_BURST})
  ${GREEN}--ssh-ban-time${NC} <DUR>    время автобана (умолч. ${SSH_BAN_TIME})

${BOLD}АНТИ-ФЛУД ДЛЯ СЕРВИСНЫХ ПОРТОВ:${NC}

  ${GREEN}--disable-syn-protection${NC}
      Отключить per-IP SYN-rate-limit на TCP-портах (--allow-ports).

  ${GREEN}--syn-rate${NC} <N>          per-IP новых TCP-соединений/сек (умолч. ${SYN_RATE})
  ${GREEN}--syn-burst${NC} <N>         burst (умолч. ${SYN_BURST})

  ${GREEN}--disable-udp-protection${NC}
      Отключить per-IP rate-limit на UDP-портах (--allow-udp-ports).

  ${GREEN}--udp-rate${NC} <N>          per-IP UDP-пакетов/сек (умолч. ${UDP_RATE})
  ${GREEN}--udp-burst${NC} <N>         burst (умолч. ${UDP_BURST})

  ${GREEN}--conn-limit${NC} <N>
      ОПЦИОНАЛЬНО. per-IP лимит ОДНОВРЕМЕННЫХ TCP-соединений на TCP-портах (--allow-ports).
      ${YELLOW}ВНИМАНИЕ: для прокси-протоколов без мультиплексирования (VLESS без
      mux и т.п.) пользователи за общим CGNAT-IP легко превышают тысячи
      одновременных соединений. Слишком низкий лимит = массовый ложный бан
      целого CGNAT-пула.${NC}

${BOLD}ICMP RATE-LIMIT:${NC}
  ${GREEN}--icmp-rate${NC} <N>         per-IP ping/сек (умолч. ${ICMP_RATE})
  ${GREEN}--icmp-burst${NC} <N>        burst (умолч. ${ICMP_BURST})

${BOLD}АНТИ-СКАН:${NC}
  ${GREEN}--disable-anti-scan${NC}
      Отключить дроп заведомо невалидных комбинаций TCP-флагов
      (XMAS/NULL/SYN+FIN и т.д.) и автобан за portscan.

  ${GREEN}--portscan-rate${NC} <N>         SYN на закрытые порты/мин до автобана (умолч. ${PORTSCAN_RATE})
  ${GREEN}--portscan-burst${NC} <N>        burst (умолч. ${PORTSCAN_BURST})
  ${GREEN}--portscan-ban-time${NC} <DUR>   время автобана (умолч. ${PORTSCAN_BAN_TIME})

${BOLD}БЛОК-ЛИСТЫ:${NC}
  ${GREEN}--disable-blocklists${NC}
      Не скачивать и не подключать antiscanner/government списки.

  ${GREEN}--blocklist-url${NC} <URL>
      Добавить свой список (формат: одна сеть/IP на строку, v4 и v6
      определяются по наличию ':'). Можно указывать несколько раз.

${BOLD}АНТИ-СПУФИНГ (BOGON):${NC}
  ${GREEN}--disable-bogon-filter${NC}
      Не дропать bogon/private source-адреса на WAN.

  ${GREEN}--wan-iface${NC} <IFACE>
      Переопределить автоопределение WAN-интерфейса (для bogon-фильтра).

${BOLD}ПРОЧЕЕ:${NC}
  ${GREEN}--dry-run${NC}
      Сгенерировать и проверить (nft -c) ruleset, но не применять его.

  ${GREEN}-h, --help${NC}
      Показать эту справку.
"
    exit 0
}

# =================
# Разбор аргументов
# =================
while [[ $# -gt 0 ]]; do
    case "$1" in
        # disable
        --disable-ipv6)             ALLOW_IPV6=false; shift ;;
        --disable-icmp)             ALLOW_ICMP=false; shift ;;
        --disable-icmpv6)           ALLOW_ICMPV6=false; shift ;;
        --disable-ssh-protection)   SSH_PROTECTION=false; shift ;;
        --disable-syn-protection)   SYN_PROTECTION=false; shift ;;
        --disable-udp-protection)   UDP_PROTECTION=false; shift ;;
        --disable-anti-scan)        ANTI_SCAN=false; shift ;;
        --disable-blocklists)       ENABLE_BLOCKLISTS=false; shift ;;
        --disable-bogon-filter)     BOGON_FILTER=false; shift ;;

        # allow
        --allow-ports)
            [[ -z "${2-}" ]] && die "--allow-ports требует список портов через запятую."
            IFS=',' read -ra TCP_EXTRA_PORTS <<< "$2"; shift 2 ;;
        --allow-udp-ports)
            [[ -z "${2-}" ]] && die "--allow-udp-ports требует список портов через запятую."
            IFS=',' read -ra UDP_EXTRA_PORTS <<< "$2"; shift 2 ;;
        --allow-port-from)
            [[ -z "${2-}" ]] && die "--allow-port-from требует список вида IP:PORT через запятую."
            IFS=',' read -ra ALLOW_FROM <<< "$2"; shift 2 ;;
        
				# tuning
        --ssh-rate)          SSH_RATE="${2-}"; shift 2 ;;
        --ssh-burst)         SSH_BURST="${2-}"; shift 2 ;;
        --ssh-ban-time)      SSH_BAN_TIME="${2-}"; shift 2 ;;
        --syn-rate)          SYN_RATE="${2-}"; shift 2 ;;
        --syn-burst)         SYN_BURST="${2-}"; shift 2 ;;
        --udp-rate)          UDP_RATE="${2-}"; shift 2 ;;
        --udp-burst)         UDP_BURST="${2-}"; shift 2 ;;
        --conn-limit)        CONN_LIMIT="${2-}"; shift 2 ;;
        --portscan-rate)     PORTSCAN_RATE="${2-}"; shift 2 ;;
        --portscan-burst)    PORTSCAN_BURST="${2-}"; shift 2 ;;
        --portscan-ban-time) PORTSCAN_BAN_TIME="${2-}"; shift 2 ;;
        --icmp-rate)         ICMP_RATE="${2-}"; shift 2 ;;
        --icmp-burst)        ICMP_BURST="${2-}"; shift 2 ;;
        --blocklist-url)
            [[ -z "${2-}" ]] && die "--blocklist-url требует URL."
            EXTRA_BLOCKLIST_URLS+=("$2"); shift 2 ;;
        --wan-iface)         WAN_IFACE_OVERRIDE="${2-}"; shift 2 ;;

				# other
        --dry-run)           DRY_RUN=true; shift ;;
        -h|--help)           help ;;
        *) die "Неизвестный аргумент: $1. Используйте --help." ;;
    esac
done

# Проверка на администратора
[[ $EUID -ne 0 ]] && die "Необходимы права администратора (root/sudo)."

if ! $ALLOW_IPV6; then
    ALLOW_ICMPV6=false
fi

# =============================
# Валидация числовых параметров
# =============================
is_uint()  { [[ "$1" =~ ^[0-9]+$ ]]; }
is_port()  { is_uint "$1" && (( $1 >= 1 && $1 <= 65535 )); }
is_ipv4()  {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o a b c d
    IFS='.' read -r a b c d <<< "$1"
    for o in $a $b $c $d; do (( o >= 0 && o <= 255 )) || return 1; done
}
is_ipv4_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    is_ipv4 "${1%%/*}"
}
is_ipv6_loose() { [[ "$1" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]] && [[ "$1" == *:* ]]; }

for _k in SSH_RATE SSH_BURST SYN_RATE SYN_BURST UDP_RATE UDP_BURST CONN_LIMIT \
          PORTSCAN_RATE PORTSCAN_BURST ICMP_RATE ICMP_BURST; do
    is_uint "${!_k}" || die "$_k='${!_k}' – ожидается целое число."
done
for _k in SSH_BAN_TIME PORTSCAN_BAN_TIME; do
    [[ "${!_k}" =~ ^[0-9]+(s|m|h|d)?$ ]] || die "$_k='${!_k}' – ожидается число с суффиксом s|m|h|d."
done
unset _k

# =======================
# [1/8] Установка пакетов
# =======================
echo -e "${CYAN}▶  Шаг 1/8 – Установка пакетов...${NC}";

apt-get update -qq
apt-get install -y nftables curl ca-certificates iproute2 2>&1 || true

success "Пакеты установлены."

# ===========================
# [2/8] Обнаружение окружения
# ===========================
section "Шаг 2/8 – Обнаружение окружения..."

SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)
SSH_PORT=${SSH_PORT:-22}
info "Найденный порт SSH: $SSH_PORT."

WAN_IFACE="${WAN_IFACE_OVERRIDE:-}"
if [[ -z "$WAN_IFACE" ]]; then
    WAN_IFACE=$(ip -4 route show default 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    [[ -z "$WAN_IFACE" ]] && WAN_IFACE=$(ip -6 route show default 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
fi
if [[ -z "$WAN_IFACE" ]]; then
    if $BOGON_FILTER; then
        warn "WAN-интерфейс не определён. Bogon-фильтр отключён (см. --wan-iface)."
        BOGON_FILTER=false
    fi
else
    info "WAN-интерфейс: $WAN_IFACE."
fi

# ================
# [3/8] Блок-листы
# ================
BL4_ELEMENTS=""
BL6_ELEMENTS=""

if $ENABLE_BLOCKLISTS; then
    section "Шаг 3/8 – Загрузка блок-листов..."

    TMP_LIST=$(mktemp)
    trap 'rm -f "$TMP_LIST"' EXIT

    download_list() {
        local url="$1" name="$2"
        info "Скачивание $name..."
        if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 "$url" >> "$TMP_LIST"; then
            warn "Не удалось загрузить $name: $url. Пропуск."
            return 0
        fi
        echo >> "$TMP_LIST"
    }

    download_list "$ANTISCANNER_URL" "antiscanner.list"
    download_list "$GOVERNMENT_URL"  "government_networks.list"
    for u in "${EXTRA_BLOCKLIST_URLS[@]}"; do
        download_list "$u" "custom: $u"
    done

    sort -u "$TMP_LIST" | grep -v '^#' | grep -v '^$' > "${TMP_LIST}.clean" || true
    mv "${TMP_LIST}.clean" "$TMP_LIST"

    mapfile -t BL4_LIST < <(grep -vF ':' "$TMP_LIST" || true)
    mapfile -t BL6_LIST < <(grep -F  ':' "$TMP_LIST" || true)

    [[ ${#BL4_LIST[@]} -gt 0 ]] && BL4_ELEMENTS="elements = { $(IFS=,; echo "${BL4_LIST[*]}") }"
    [[ ${#BL6_LIST[@]} -gt 0 ]] && BL6_ELEMENTS="elements = { $(IFS=,; echo "${BL6_LIST[*]}") }"

    success "Загружено: ${#BL4_LIST[@]} IPv4-сетей, ${#BL6_LIST[@]} IPv6-сетей."
else
    section "Шаг 3/8 – Блок-листы отключены (--disable-blocklists)..."
fi

# =======================
# [4/8] Генерация ruleset
# =======================
section "Шаг 4/8 – Генерация ruleset для nftables..."

# Наборы (sets)
AUTOBAN_SETS="
    # автобаны (SSH bruteforce, portscan)
    set autoban_v4 { type ipv4_addr; flags timeout; size 262144; }
    set autoban_v6 { type ipv6_addr; flags timeout; size 262144; }"

BLOCKLIST_SETS=""
BLOCKLIST_DROP=""
if $ENABLE_BLOCKLISTS; then
    BLOCKLIST_SETS="
    # antiscanner + government_networks + кастомные списки
    set blocklist_v4 { type ipv4_addr; flags interval; auto-merge; size 1048576; $BL4_ELEMENTS }
    set blocklist_v6 { type ipv6_addr; flags interval; auto-merge; size 262144; $BL6_ELEMENTS }"
    BLOCKLIST_DROP="
        ip  saddr @blocklist_v4 drop
        ip6 saddr @blocklist_v6 drop"
fi

BOGON_SETS=""
BOGON_DROP=""
if $BOGON_FILTER; then
    BOGON_SETS="
    # bogon/martian-источники, на WAN их быть не может, если не спуф
    set bogon_v4 {
        type ipv4_addr; flags interval; auto-merge
        elements = {
            0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
            169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
            192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24,
            224.0.0.0/3
        }
    }

    # IPv6 bogon, без fe80::/10 (NDP link-local) и ff00::/8
    set bogon_v6 {
        type ipv6_addr; flags interval; auto-merge
        elements = { ::1/128, ::/128, ::ffff:0:0/96, 100::/64, 2001:db8::/32, fc00::/7 }
    }"
    BOGON_DROP="
        # анти-спуфинг, bogon-источники на WAN = подмена адреса
        iifname \"${WAN_IFACE}\" ip  saddr @bogon_v4 drop
        iifname \"${WAN_IFACE}\" ip6 saddr @bogon_v6 drop"
fi

# IPv6: disable-блок (если --disable-ipv6)
IPV6_DISABLE_INPUT=""
IPV6_DISABLE_FORWARD=""
IPV6_DISABLE_OUTPUT=""

if ! $ALLOW_IPV6; then
    IPV6_DISABLE_INPUT="
        # IPv6 полностью выключен (кроме loopback, см. iifname \"lo\" выше)
        meta nfproto ipv6 counter drop"
    IPV6_DISABLE_FORWARD="
        meta nfproto ipv6 counter drop"
    IPV6_DISABLE_OUTPUT="
        oifname \"lo\" accept
        meta nfproto ipv6 counter drop"
fi

# ICMP / ICMPv6
ICMP_RULES="
        # ICMP, служебные типы всегда разрешены
        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept"

if $ALLOW_ICMP; then
    ICMP_RULES+="
        ip protocol icmp icmp type echo-request meter icmp4 { ip saddr limit rate ${ICMP_RATE}/second burst ${ICMP_BURST} packets } accept"
fi

if $ALLOW_IPV6; then
    ICMP_RULES+="

        # ICMPv6, NDP/MLD обязательны для работы IPv6, разрешены всегда
        icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit,
                      nd-neighbor-advert, packet-too-big, time-exceeded,
                      parameter-problem, destination-unreachable,
                      mld-listener-query, mld-listener-report,
                      mld-listener-done } accept"
    if $ALLOW_ICMPV6; then
        ICMP_RULES+="
        icmpv6 type echo-request meter icmp6 { ip6 saddr limit rate ${ICMP_RATE}/second burst ${ICMP_BURST} packets } accept"
    fi
fi

# SSH (per-IP rate-limit + автобан)
if $SSH_PROTECTION; then
    SSH_RULES="
        # SSH, per-IP rate-limit новых соединений, превышение = автобан ${SSH_BAN_TIME}
        tcp dport ${SSH_PORT} ct state new meter ssh4 { ip  saddr limit rate ${SSH_RATE}/minute burst ${SSH_BURST} packets } accept
        tcp dport ${SSH_PORT} ct state new meter ssh6 { ip6 saddr limit rate ${SSH_RATE}/minute burst ${SSH_BURST} packets } accept
        tcp dport ${SSH_PORT} ct state new limit rate 5/minute log prefix \"[${TABLE_NAME} ssh-flood] \" level warn
        tcp dport ${SSH_PORT} ct state new meta nfproto ipv4 add @autoban_v4 { ip  saddr timeout ${SSH_BAN_TIME} } drop
        tcp dport ${SSH_PORT} ct state new meta nfproto ipv6 add @autoban_v6 { ip6 saddr timeout ${SSH_BAN_TIME} } drop"
else
    SSH_RULES="
        tcp dport ${SSH_PORT} accept"
fi

# IP:PORT (--allow-port-from)
ALLOW_FROM_RULES=""
if [[ ${#ALLOW_FROM[@]} -gt 0 ]]; then
    ALLOW_FROM_RULES="
        # точечный доступ к портам с конкретных адресов (--allow-port-from)"
    for entry in "${ALLOW_FROM[@]}"; do
        entry="${entry// /}"
        if [[ "$entry" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
            _ip="${BASH_REMATCH[1]}"; _port="${BASH_REMATCH[2]}"
            is_port "$_port" || { warn "Некорректная запись, пропуск: $entry."; continue; }
            ALLOW_FROM_RULES+="
        ip6 saddr ${_ip} tcp dport ${_port} accept"
            info "IPv6: разрешён ${_ip}, порт ${_port}."
        else
            _ip="${entry%:*}"; _port="${entry##*:}"
            if is_ipv4 "$_ip" && is_port "$_port"; then
                ALLOW_FROM_RULES+="
        ip saddr ${_ip} tcp dport ${_port} accept"
                info "IPv4: разрешён ${_ip}, порт ${_port}."
            else
                warn "Некорректная запись, пропуск: $entry."
            fi
        fi
    done
fi

# TCP extra ports (--allow-ports)
TCP_RULES=""
if [[ ${#TCP_EXTRA_PORTS[@]} -gt 0 ]]; then
    declare -A _seen_tcp=()
    for p in "${TCP_EXTRA_PORTS[@]}"; do
        p="${p// /}"
        if ! is_port "$p"; then
            warn "--allow-ports: '$p' – некорректный порт, пропуск."
            continue
        fi
        [[ -n "${_seen_tcp[$p]:-}" ]] && continue
        _seen_tcp[$p]=1

        [[ -z "$TCP_RULES" ]] && TCP_RULES="
        # сервисные TCP-порты"

				_comment_parts=()
        (( CONN_LIMIT > 0 )) && _comment_parts+=("лимит соединений (${CONN_LIMIT})")
        $SYN_PROTECTION && _comment_parts+=("per-IP SYN-rate-limit (${SYN_RATE}/s)")
        if [[ ${#_comment_parts[@]} -gt 0 ]]; then
            _comment=$(IFS=', '; echo "${_comment_parts[*]}")
            TCP_RULES+="
        # порт ${p}: ${_comment}"
        fi

        if (( CONN_LIMIT > 0 )); then
            TCP_RULES+="
        tcp dport ${p} ct state new meter cc4_${p} { ip  saddr ct count over ${CONN_LIMIT} } drop
        tcp dport ${p} ct state new meter cc6_${p} { ip6 saddr ct count over ${CONN_LIMIT} } drop"
        fi
        if $SYN_PROTECTION; then
            TCP_RULES+="
        tcp dport ${p} ct state new meter syn4_${p} { ip  saddr limit rate ${SYN_RATE}/second burst ${SYN_BURST} packets } accept
        tcp dport ${p} ct state new meter syn6_${p} { ip6 saddr limit rate ${SYN_RATE}/second burst ${SYN_BURST} packets } accept
        tcp dport ${p} ct state new limit rate 5/second log prefix \"[${TABLE_NAME} synflood] \" level info
        tcp dport ${p} ct state new drop"
        else
            TCP_RULES+="
        tcp dport ${p} accept"
        fi
        info "TCP: открыт порт ${p}."
    done
    unset _seen_tcp
fi

# UDP extra ports (--allow-udp-ports)
UDP_RULES=""
if [[ ${#UDP_EXTRA_PORTS[@]} -gt 0 ]]; then
    declare -A _seen_udp=()
    for p in "${UDP_EXTRA_PORTS[@]}"; do
        p="${p// /}"
        if ! is_port "$p"; then
            warn "--allow-udp-ports: '$p' – некорректный порт, пропуск."
            continue
        fi
        [[ -n "${_seen_udp[$p]:-}" ]] && continue
        _seen_udp[$p]=1

        [[ -z "$UDP_RULES" ]] && UDP_RULES="
        # сервисные UDP-порты"

				_comment_parts=()
        $UDP_PROTECTION && _comment_parts+=("per-IP rate-limit (${UDP_RATE}/s)")
        if [[ ${#_comment_parts[@]} -gt 0 ]]; then
            _comment=$(IFS=', '; echo "${_comment_parts[*]}")
            UDP_RULES+="
        # порт ${p}/udp: ${_comment}"
        fi

        if $UDP_PROTECTION; then
            UDP_RULES+="
        udp dport ${p} meter udp4_${p} { ip  saddr limit rate ${UDP_RATE}/second burst ${UDP_BURST} packets } accept
        udp dport ${p} meter udp6_${p} { ip6 saddr limit rate ${UDP_RATE}/second burst ${UDP_BURST} packets } accept
        udp dport ${p} drop"
        else
            UDP_RULES+="
        udp dport ${p} accept"
        fi
        info "UDP: открыт порт ${p}."
    done
    unset _seen_udp
fi

# Анти-скан: невалидные флаги + portscan = автобан
SCAN_CHAIN=""
FLAGDROP_RULES=""
PORTSCAN_RULES=""
if $ANTI_SCAN; then
    SCAN_CHAIN="
    # заведомо невалидные/скан-комбинации TCP-флагов = лог (rl) + drop
    chain scan_drop {
        limit rate 5/second log prefix \"[${TABLE_NAME} badflags] \" level info
        counter drop
    }"
    FLAGDROP_RULES="
        # flag-drop, NULL, XMAS, SYN+FIN, SYN+RST, FIN+RST и прочие комбинации
        tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0                       jump scan_drop
        tcp flags & (fin|syn|rst|psh|ack|urg) == (fin|syn|rst|psh|ack|urg) jump scan_drop
        tcp flags & (fin|psh|urg) == (fin|psh|urg)                         jump scan_drop
        tcp flags & (syn|fin) == (syn|fin)                                 jump scan_drop
        tcp flags & (syn|rst) == (syn|rst)                                 jump scan_drop
        tcp flags & (fin|rst) == (fin|rst)                                 jump scan_drop
        tcp flags & (fin|ack) == fin                                       jump scan_drop
        tcp flags & (psh|ack) == psh                                       jump scan_drop
        tcp flags & (ack|urg) == urg                                       jump scan_drop"
    PORTSCAN_RULES="
        # АНТИ-СКАН, SYN на закрытые порты быстрее ${PORTSCAN_RATE}/мин = автобан ${PORTSCAN_BAN_TIME}.
        meta nfproto ipv4 tcp flags & (fin|syn|rst|ack) == syn ct state new limit rate 5/second log prefix \"[${TABLE_NAME} portscan] \" level info
        meta nfproto ipv4 tcp flags & (fin|syn|rst|ack) == syn ct state new meter psc4 { ip  saddr limit rate over ${PORTSCAN_RATE}/minute burst ${PORTSCAN_BURST} packets } add @autoban_v4 { ip  saddr timeout ${PORTSCAN_BAN_TIME} } drop
        meta nfproto ipv6 tcp flags & (fin|syn|rst|ack) == syn ct state new meter psc6 { ip6 saddr limit rate over ${PORTSCAN_RATE}/minute burst ${PORTSCAN_BURST} packets } add @autoban_v6 { ip6 saddr timeout ${PORTSCAN_BAN_TIME} } drop"
fi

# Сборка итогового .nft файла
mkdir -p "$NFT_DIR"

cat > "$NFT_FILE" <<NFT
#!/usr/sbin/nft -f
# https://github.com/assailance/server-scripts/
# Дата генерации: $(date -Is)

table ${TABLE_FAMILY} ${TABLE_NAME} {}
delete table ${TABLE_FAMILY} ${TABLE_NAME}

table ${TABLE_FAMILY} ${TABLE_NAME} {
${AUTOBAN_SETS}
${BLOCKLIST_SETS}
${BOGON_SETS}
${SCAN_CHAIN}

    chain input {
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
${IPV6_DISABLE_INPUT}

        ct state established,related accept
        ct state invalid drop

        # уже забаненные (SSH bruteforce / portscan)
        ip  saddr @autoban_v4 drop
        ip6 saddr @autoban_v6 drop
${BLOCKLIST_DROP}
${BOGON_DROP}
${FLAGDROP_RULES}
${ICMP_RULES}
${SSH_RULES}
${ALLOW_FROM_RULES}
${TCP_RULES}
${UDP_RULES}
${PORTSCAN_RULES}

        counter drop
    }

    chain forward {
        # accept по умолчанию, чтобы не перебивать FORWARD-цепочки Docker/др. таблиц.
        type filter hook forward priority filter; policy accept;
${IPV6_DISABLE_FORWARD}
    }

    chain output {
        type filter hook output priority filter; policy accept;
${IPV6_DISABLE_OUTPUT}
    }
}
NFT

# Нормализация файла
perl -i -0pe '
    s/\n[^\S\n]+\n/\n\n/g;
    s/\n{3,}/\n\n/g;
    s/\n\n(\s*\})/\n$1/g;
' "$NFT_FILE"

success "Файл ${NFT_FILE} сгенерирован."

# =========================
# [5/8] Проверка синтаксиса
# =========================
section "Шаг 5/8 – Проверка синтаксиса (nft -c)..."

if ! nft -c -f "$NFT_FILE"; then
    die "nft -c не прошёл. Файл $NFT_FILE НЕ применён, текущий ruleset не тронут."
fi
success "Синтаксис валиден."

if $DRY_RUN; then
    info "DRY-RUN: применение пропущено. Файл: $NFT_FILE"
    exit 0
fi

# =======================
# [6/8] Применение правил
# =======================
section "Шаг 6/8 – Применение правил..."

nft -f "$NFT_FILE"
success "Ruleset применён."

# ================================
# [7/8] Автозагрузка через systemd
# ================================
section "Шаг 7/8 – Автозагрузка..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=nftables ruleset: ${TABLE_NAME}
After=network-pre.target nftables.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${NFT_FILE}
ExecReload=/usr/sbin/nft -f ${NFT_FILE}
ExecStop=/usr/sbin/nft delete table ${TABLE_FAMILY} ${TABLE_NAME}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
success "Сервис ${SERVICE_NAME} включён в автозагрузку."

# ==========
# [8/8] Итог
# ==========
section "Шаг 8/8 – Готово."

echo ""
info "Настройка завершена!"
echo ""
echo -e "${CYAN}Смотреть правила:${NC}       ${BOLD}nft list table ${TABLE_FAMILY} ${TABLE_NAME}${NC}"
echo -e "${CYAN}Счётчики:${NC}               ${BOLD}nft -a list table ${TABLE_FAMILY} ${TABLE_NAME}${NC}"
echo -e "${CYAN}Автобан IPv4:${NC}           ${BOLD}nft list set ${TABLE_FAMILY} ${TABLE_NAME} autoban_v4${NC}"
echo -e "${CYAN}Автобан IPv6:${NC}           ${BOLD}nft list set ${TABLE_FAMILY} ${TABLE_NAME} autoban_v6${NC}"
echo -e "${CYAN}Логи (реальное время):${NC}  ${BOLD}journalctl -kf -g '${TABLE_NAME}'${NC}"
echo -e "${CYAN}Логи (история):${NC}         ${BOLD}journalctl -k -g '${TABLE_NAME}'${NC}"
echo -e "${CYAN}Расположение:${NC}           ${BOLD}${NFT_FILE}${NC}"
echo -e "${CYAN}Сервис автозагрузки:${NC}    ${BOLD}systemctl status ${SERVICE_NAME}${NC}"
echo -e "${CYAN}Снять правила:${NC}          ${BOLD}systemctl disable --now ${SERVICE_NAME} && nft delete table ${TABLE_FAMILY} ${TABLE_NAME}${NC}"