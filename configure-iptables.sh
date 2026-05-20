#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
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

# Значения по умолчанию
ALLOW_ICMP=false
ALLOW_IPV6=false
ALLOW_ICMPV6=false
EXTRA_PORTS=()
ALLOW_FROM=()

ANTISCANNER_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
GOVERNMENT_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"

IPSET_V4="SCANNERS-BLOCK-V4"
IPSET_V6="SCANNERS-BLOCK-V6"

RULES_V4="/etc/iptables/rules.v4"
RULES_V6="/etc/iptables/rules.v6"
IPSETS_CONF="/etc/ipsets.conf"

# Разбор аргументов
help() {
    echo -e "
${BOLD}ИСПОЛЬЗОВАНИЕ:${NC} $(basename "$0") [опции]
 
${BOLD}ОПЦИИ:${NC}
  ${GREEN}--allow-icmp${NC}
      Разрешить входящий ICMP echo-request (ping) для IPv4.
      По умолчанию служебные типы ICMP разрешены, ping – нет.
 
  ${GREEN}--allow-ports${NC} <PORT[,PORT,...]>
      Открыть дополнительные TCP-порты. Указываются через запятую.
      Применяется и к IPv4, и к IPv6 (если включён).
      Пример: --allow-ports 80,8080,3000

  ${GREEN}--allow-port-from${NC} <IP:PORT[,IP:PORT,...]>  
      Разрешить доступ к конкретным TCP-портам только с указанных IPv4-адресов.  
      Каждая запись задаётся в формате IP:PORT.  
      Пример: --allow-port-from 1.2.3.4:22,5.6.7.8:443

  ${GREEN}--allow-ipv6${NC}
      Включить IPv6 с полным набором правил (аналогично IPv4).
      По умолчанию весь IPv6-трафик дропается.
 
  ${GREEN}--allow-icmpv6${NC}
      Разрешить ICMPv6 echo-request (ping6).
      NDP-трафик (Neighbour Discovery) разрешается всегда при --allow-ipv6,
      иначе IPv6-маршрутизация не работает.
      Требует --allow-ipv6.
 
  ${GREEN}-h, --help${NC}
      Показать эту справку.
"
    exit 0
}
 
while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-icmp)   ALLOW_ICMP=true; shift ;;
        --allow-ipv6)   ALLOW_IPV6=true; shift ;;
        --allow-icmpv6) ALLOW_ICMPV6=true; shift ;;
        --allow-ports)
            [[ -z "${2-}" ]] && die "Флаг --allow-ports требует список портов через запятую."
            IFS=',' read -ra EXTRA_PORTS <<< "$2"
            shift 2 ;;
        --allow-port-from)  
			[[ -z "${2-}" ]] && die "Флаг --allow-port-from требует список вида IP:PORT через запятую."  
			IFS=',' read -ra ALLOW_FROM <<< "$2"  
			shift 2 ;;
        -h|--help) help ;;
        *) die "Неизвестный аргумент: $1. Используйте --help." ;;
    esac
done

# Проверка прав пользователя
if [[ $EUID -ne 0 ]]; then  
	die "Необходимы права администратора (root/sudo)."  
fi

# ICMPv6 без IPv6
if $ALLOW_ICMPV6 && ! $ALLOW_IPV6; then
    warn "Флаг --allow-icmpv6 игнорируется без --allow-ipv6."
    echo -e ""
    ALLOW_ICMPV6=false
fi

# =======================
# [1/8] Установка пакетов
# =======================
echo -e "${CYAN}▶  Шаг 1/8 – Установка пакетов...${NC}"

apt-get update -qq
apt-get install -y iptables ipset iptables-persistent curl 2>&1 || true

success "Пакеты установлены."

# ================================
# [2/8] Загрузка списков для ipset
# ================================
section "Шаг 2/8 – Загрузка списков (ipset)..."

TMP_LIST=$(mktemp)
TMP_V4=$(mktemp)
TMP_V6=$(mktemp)
trap 'rm -f "$TMP_LIST" "$TMP_V4" "$TMP_V6"' EXIT

download_list() {
    local url="$1"
    local name="$2"
    
    info "Скачивание $name..."
    
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 "$url" >> "$TMP_LIST"; then
        die "Не удалось загрузить $name: $url."
    fi
    
    echo >> "$TMP_LIST"
}

download_list "$ANTISCANNER_URL" "antiscanner.list"
download_list "$GOVERNMENT_URL" "government_networks.list"

# Удаление дублей, пустых строк и комментариев
sort -u "$TMP_LIST" | grep -v '^#' | grep -v '^$' > "${TMP_LIST}.clean"
mv "${TMP_LIST}.clean" "$TMP_LIST"

# Разделение IPv4 и IPv6
grep -v ':' "$TMP_LIST" > "$TMP_V4" || true
grep  ':' "$TMP_LIST" > "$TMP_V6" || true

V4_COUNT=$(wc -l < "$TMP_V4")
V6_COUNT=$(wc -l < "$TMP_V6")
success "Загружено: ${V4_COUNT} IPv4-сетей, ${V6_COUNT} IPv6-сетей."

# =====================
# [3/8] Настройка ipset
# =====================
section "Шаг 3/8 – Настройка ipset..."

setup_ipset() {
    local setname="$1"
    local family="$2"
    local listfile="$3"

    info "Создание набора $setname ($family) ..."
	
	# Создание временного набора (для swap)
    local tmpset="${setname}-NEW"
    ipset destroy "$tmpset" 2>/dev/null || true
    ipset create "$tmpset" hash:net family "$family" maxelem 500000

    local count=0
    while IFS= read -r net; do
        [[ -z "$net" ]] && continue
        if ipset add "$tmpset" "$net" 2>/dev/null; then
            (( count++ )) || true
        else
            warn "Пропуск некорректной записи: $net."
        fi
    done < "$listfile"

    if ipset list "$setname" &>/dev/null; then
        ipset swap "$tmpset" "$setname"
        ipset destroy "$tmpset"
    else
        ipset rename "$tmpset" "$setname"
    fi

    success "$setname: добавлено $count записей."
}

setup_ipset "$IPSET_V4" "inet" "$TMP_V4"
setup_ipset "$IPSET_V6" "inet6" "$TMP_V6"

# Сохранение ipset
ipset save > "$IPSETS_CONF"
success "Ipset сохранён в $IPSETS_CONF."

# ========================
# [4/8] Генерация rules.v4
# ========================
section "Шаг 4/8 – Генерация rules.v4..."

mkdir -p /etc/iptables

# Правила политик
cat > "$RULES_V4" <<POLICY_RULES
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
POLICY_RULES

# Цепочка для блокировки сканеров (ipset)
cat >> "$RULES_V4" <<CHAIN_BLOCK

:SCANNERS-BLOCK-V4 - [0:0]
-A INPUT -m set --match-set SCANNERS-BLOCK-V4 src -j SCANNERS-BLOCK-V4
-A SCANNERS-BLOCK-V4 -j DROP
CHAIN_BLOCK

# Базовые правила
cat >> "$RULES_V4" <<BASE_RULES

-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
BASE_RULES

# ICMP
if $ALLOW_ICMP; then
    info "IPv4 ICMP: разрешён."
    cat >> "$RULES_V4" <<ICMP_ON

-A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
-A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
-A INPUT -p icmp --icmp-type parameter-problem -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -j ACCEPT
ICMP_ON
else
    info "IPv4 ICMP: служебные типы разрешены, ping запрещён."
    cat >> "$RULES_V4" <<ICMP_OFF

-A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
-A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
-A INPUT -p icmp --icmp-type parameter-problem -j ACCEPT
ICMP_OFF
fi

# SSH
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)
SSH_PORT=${SSH_PORT:-22}
info "Найденный порт SSH: $SSH_PORT."

cat >> "$RULES_V4" <<SSH

-A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
SSH

# Правила вида IP:PORT
if [[ ${#ALLOW_FROM[@]} -gt 0 ]]; then
	is_ipv4() {
		[[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
		IFS='.' read -r a b c d <<< "$1"  
		for o in $a $b $c $d; do
			(( o >= 0 && o <= 255 )) || return 1
		done
	}

	for entry in "${ALLOW_FROM[@]}"; do
		entry="${entry// /}"
		IFS=':' read -r ip port <<< "$entry"

		if is_ipv4 "$ip" && [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
			echo "-A INPUT -p tcp -s ${ip} --dport ${port} -j ACCEPT" >> "$RULES_V4"
			info "IPv4: разрешён ${ip}, порт ${port}."
		else
			warn "Некорректная запись, пропуск: $entry."
		fi
	done
fi

# Дополнительные порты
if [[ ${#EXTRA_PORTS[@]} -gt 0 ]]; then
    for port in "${EXTRA_PORTS[@]}"; do
        port="${port// /}"
        if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
            echo "-A INPUT -p tcp --dport ${port} -j ACCEPT" >> "$RULES_V4"
            info "IPv4: открыт порт $port."
        else
            warn "Некорректный порт, пропуск: $port."
        fi
    done
fi

echo "COMMIT" >> "$RULES_V4"

success "Файл rules.v4 сгенерирован."

# ========================
# [5/8] Генерация rules.v6
# ========================
section "Шаг 5/8 – Генерация rules.v6..."

if $ALLOW_IPV6; then
    info "IPv6: включён."

    cat > "$RULES_V6" <<V6_FULL_START
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

:SCANNERS-BLOCK-V6 - [0:0]
-A INPUT -m set --match-set SCANNERS-BLOCK-V6 src -j SCANNERS-BLOCK-V6
-A SCANNERS-BLOCK-V6 -j DROP

-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
V6_FULL_START

    if $ALLOW_ICMPV6; then
        info "IPv6 ICMPv6: разрешён."
        cat >> "$RULES_V6" <<ICMPV6_ON

-A INPUT -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type time-exceeded -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type parameter-problem -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type neighbour-solicitation -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type neighbour-advertisement -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type router-solicitation -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type router-advertisement -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type echo-request -j ACCEPT
ICMPV6_ON
    else
        info "IPv6 ICMPv6: только NDP и служебные (ping запрещён)."
        cat >> "$RULES_V6" <<ICMPV6_NDP

-A INPUT -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type time-exceeded -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type parameter-problem -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type neighbour-solicitation -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type neighbour-advertisement -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type router-solicitation -j ACCEPT
-A INPUT -p ipv6-icmp --icmpv6-type router-advertisement -j ACCEPT
ICMPV6_NDP
    fi

    cat >> "$RULES_V6" <<V6_PORTS

-A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
V6_PORTS

    if [[ ${#EXTRA_PORTS[@]} -gt 0 ]]; then
        for port in "${EXTRA_PORTS[@]}"; do
            port="${port// /}"
			if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
	            echo "-A INPUT -p tcp --dport ${port} -j ACCEPT" >> "$RULES_V6"
	            info "IPv6: открыт порт $port."
	        else
	            warn "Некорректный порт, пропуск: $port."
	        fi
        done
    fi

    echo "COMMIT" >> "$RULES_V6"

else
    info "IPv6: отключён (DROP)."
    cat > "$RULES_V6" <<V6_DROP
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
V6_DROP
fi

success "Файл rules.v6 сгенерирован."

# =======================
# [6/8] Применение правил
# =======================
section "Шаг 6/8 – Применение правил..."

iptables-restore < "$RULES_V4"
success "Правила для iptables (IPv4) применены."

ip6tables-restore < "$RULES_V6"
success "Правила для ip6tables (IPv6) применены."

# ================================================
# [7/8] Настройка автозагрузки ipset через systemd
# ================================================
section "Шаг 7/8 – Автозагрузка ipset..."

cat > /etc/systemd/system/ipset-restore.service <<SYSTEMD
[Unit]
Description=Restore ipset blocklists
Before=netfilter-persistent.service
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ipset restore -f /etc/ipsets.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable ipset-restore.service
success "Сервис ipset-restore.service включён в автозагрузку."

# =======================
# [8/8] Перезапуск Docker
# =======================
section "Шаг 8/8 – Перезапуск Docker..."
 
if command -v docker &>/dev/null && systemctl is-enabled docker &>/dev/null; then
    systemctl restart docker
    success "Docker перезапущен."
else
    warn "Docker не установлен или не активирован."
fi

# ====
# Итог
# ====
echo ""
info "Настройка завершена!"
