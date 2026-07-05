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

SYSCTL_FILE="/etc/sysctl.d/99-node.conf"
LIMITS_FILE="/etc/security/limits.d/99-node.conf"
SYSTEMD_LIMITS_FILE="/etc/systemd/system.conf.d/99-node.conf"
RPS_SCRIPT="/usr/local/sbin/node-rps-setup"
RPS_SERVICE_NAME="node-rps.service"
RPS_SERVICE="/etc/systemd/system/${RPS_SERVICE_NAME}"
THP_SERVICE_NAME="node-thp-off.service"
THP_SERVICE="/etc/systemd/system/${THP_SERVICE_NAME}"

# Значения по умолчанию
DISABLE_IPV6=false

# =======
# Справка
# =======
help() {
    echo -e "
${BOLD}ИСПОЛЬЗОВАНИЕ:${NC} $(basename "$0") [опции]

${BOLD}ПАРАМЕТРЫ:${NC}

  ${GREEN}--disable-ipv6${NC}
      Полностью отключить IPv6 на уровне ядра (net.ipv6.conf.*.disable_ipv6 = 1).
      По умолчанию IPv6 включён с hardening-параметрами (отключены RA,
      autoconf, временные адреса, source route, redirects).
 
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
        --disable-ipv6) DISABLE_IPV6=true; shift ;;
        -h|--help)      help ;;
        *) die "Неизвестный аргумент: $1. Используйте --help." ;;
    esac
done

# Проверка на администратора
[[ $EUID -ne 0 ]] && die "Необходимы права администратора (root/sudo)."

# =================
# [1/6] Зависимости
# =================
echo -e "${CYAN}▶  Шаг 1/6 – Установка зависимостей...${NC}";

apt-get update -qq
apt-get install -y ca-certificates ethtool iproute2 2>&1 || true

success "Зависимости установлены."

# =======================
# [2/6] Обнаружение среды
# =======================
section "Шаг 2/6 – Обнаружение окружения..."

# Определение OpenVZ
IS_OPENVZ=false
[[ -f /proc/user_beancounters ]] && IS_OPENVZ=true
$IS_OPENVZ && info "Обнаружен OpenVZ-контейнер. NIC/RPS-тюнинг будет пропущен (нет доступа к очередям устройства)."

# Определение основного WAN-интерфейса
WAN_IFACE=""
WAN_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
[[ -z "$WAN_IFACE" ]] && WAN_IFACE=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
[[ -n "$WAN_IFACE" ]] && info "WAN-интерфейс: $WAN_IFACE." || warn "WAN-интерфейс не определён, NIC-тюнинг и RPS будут пропущены."

# Количество CPU-ядер (для RPS-маски)
NCPU=$(nproc)
info "CPU ядер: $NCPU."

# Проверка BBR
BBR_AVAILABLE=false
modprobe tcp_bbr 2>/dev/null && BBR_AVAILABLE=true || true
if $BBR_AVAILABLE; then
    info "Модуль tcp_bbr: доступен."
else
    warn "Модуль tcp_bbr недоступен, congestion_control будет cubic. Обновите ядро (>= 4.9)."
fi

# Проверка conntrack
CT_AVAILABLE=false
modprobe nf_conntrack 2>/dev/null && CT_AVAILABLE=true || true
$CT_AVAILABLE && info "Модуль nf_conntrack: доступен." || warn "Модуль nf_conntrack недоступен, conntrack-параметры могут не применяться."

success "Окружение определено."

# ============
# [3/6] Sysctl
# ============
section "Шаг 3/6 – Запись sysctl параметров..."

# генерация ipv6-блока
if $DISABLE_IPV6; then
    IPV6_BLOCK="# disable ipv6
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1"
else
    IPV6_BLOCK="# ipv6
net.ipv6.conf.all.forwarding               = 0
net.ipv6.conf.all.accept_ra                = 0
net.ipv6.conf.default.accept_ra            = 0
net.ipv6.conf.all.autoconf                 = 0
net.ipv6.conf.default.autoconf             = 0
net.ipv6.conf.all.use_tempaddr             = 0
net.ipv6.conf.default.use_tempaddr         = 0
net.ipv6.conf.all.accept_redirects         = 0
net.ipv6.conf.default.accept_redirects     = 0
net.ipv6.conf.all.accept_source_route      = 0
net.ipv6.conf.default.accept_source_route  = 0"
fi

if $BBR_AVAILABLE; then
    CC_BLOCK="# congestion control
net.core.default_qdisc            = fq
net.ipv4.tcp_congestion_control   = bbr"
else
    CC_BLOCK="# congestion control
net.core.default_qdisc            = fq
net.ipv4.tcp_congestion_control   = cubic"
fi

cat > "$SYSCTL_FILE" << 'EOF'
# сеть
net.core.netdev_max_backlog       = 65535
net.core.somaxconn                = 65535
net.core.rps_sock_flow_entries    = 65536

# буферы сокетов по умолчанию и максимум
net.core.rmem_default             = 2097152
net.core.wmem_default             = 2097152
net.core.rmem_max                 = 67108864
net.core.wmem_max                 = 67108864

# дополнительная память на опции/метаданные сокета
net.core.optmem_max               = 65536

# tcp
net.ipv4.tcp_fastopen             = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse             = 1
net.ipv4.tcp_max_tw_buckets       = 2000000
net.ipv4.tcp_fin_timeout          = 15

# keepalive
net.ipv4.tcp_keepalive_time       = 1200
net.ipv4.tcp_keepalive_intvl      = 30
net.ipv4.tcp_keepalive_probes     = 5

net.ipv4.tcp_max_syn_backlog      = 65535
net.ipv4.tcp_mtu_probing          = 1
net.ipv4.tcp_no_metrics_save      = 1
net.ipv4.tcp_rfc1337              = 1
net.ipv4.tcp_sack                 = 1
net.ipv4.tcp_window_scaling       = 1
net.ipv4.tcp_timestamps           = 1
net.ipv4.tcp_ecn                  = 1

# буферы
net.ipv4.tcp_rmem                 = 4096 87380 67108864
net.ipv4.tcp_wmem                 = 4096 65536 67108864

net.ipv4.tcp_notsent_lowat        = 131072
net.ipv4.ip_local_port_range      = 10000 65535

# udp
net.ipv4.udp_rmem_min             = 16384
net.ipv4.udp_wmem_min             = 16384

# conntrack
net.netfilter.nf_conntrack_max                     = 2000000
net.netfilter.nf_conntrack_buckets                 = 500000
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait    = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30

# syn flood
net.ipv4.tcp_syncookies           = 1
net.ipv4.tcp_synack_retries       = 2
net.ipv4.tcp_syn_retries          = 2

# anti-spoofing
net.ipv4.conf.all.rp_filter                = 2
net.ipv4.conf.default.rp_filter            = 2

# игнорировать source route опции в ip-заголовке
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.default.accept_source_route  = 0
net.ipv6.conf.all.accept_source_route      = 0
net.ipv6.conf.default.accept_source_route  = 0

# не отправлять и не принимать icmp redirect
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.default.send_redirects       = 0
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv4.conf.all.secure_redirects         = 0
net.ipv4.conf.default.secure_redirects     = 0
net.ipv6.conf.all.accept_redirects         = 0
net.ipv6.conf.default.accept_redirects     = 0

# ICMP
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_ratelimit                    = 100
net.ipv4.icmp_ratemask                     = 88089

# безопасность ядра
kernel.yama.ptrace_scope                   = 1
kernel.randomize_va_space                  = 2
fs.suid_dumpable                           = 0

# файловые дескрипторы
fs.file-max                                = 2097152
fs.nr_open                                 = 2097152

# лимиты inotify
fs.inotify.max_user_watches                = 524288
fs.inotify.max_user_instances              = 8192

# память и vm
vm.swappiness                              = 10
vm.dirty_ratio                             = 10
vm.dirty_background_ratio                  = 5
vm.max_map_count                           = 262144
EOF

# запись ipv6 и congestion control блоков
printf '\n%s\n\n%s\n' "$IPV6_BLOCK" "$CC_BLOCK" >> "$SYSCTL_FILE"

success "Файл $SYSCTL_FILE записан."

# =====================
# [4/6] Лимиты FD/nproc
# =====================
section "Шаг 4/6 – Настройка лимитов файловых дескрипторов..."

# PAM limits (для shell-сессий и процессов, запущенных через PAM)
mkdir -p /etc/security/limits.d
cat > "$LIMITS_FILE" << 'EOF'
*       soft    nofile  1048576
*       hard    nofile  1048576
*       soft    nproc   1048576
*       hard    nproc   1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
root    hard    nproc   1048576
EOF

# проверка, что pam_limits.so подключён (без него limits.d не применяются)
for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    if [[ -f "$pam_file" ]] && ! grep -q '^session.*pam_limits.so' "$pam_file"; then
        echo "session required pam_limits.so" >> "$pam_file"
        info "pam_limits.so добавлен в $pam_file."
    fi
done

# systemd limits (для всех юнитов, запущенных через systemd)
mkdir -p /etc/systemd/system.conf.d
cat > "$SYSTEMD_LIMITS_FILE" << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

success "Лимиты FD/nproc настроены (shell-сессии применят после перелогина, systemd-юниты — после daemon-reload)."

# =======================
# [5/6] RPS/RFS/XPS + NIC
# =======================
section "Шаг 5/6 – Настройка RPS/RFS/XPS и NIC..."

if [[ -n "$WAN_IFACE" ]] && ! $IS_OPENVZ; then
    # CPU-маска для rps_cpus (все ядра, big-endian hex, группы по 32)
    RPS_MASK=$(python3 -c "
n = $NCPU
chunks = []
while n > 0:
    b = min(n, 32)
    chunks.append((1 << b) - 1)
    n -= b
chunks.reverse()
print(','.join(hex(c)[2:] for c in chunks))
" 2>/dev/null || awk -v n="$NCPU" 'BEGIN{printf \"%x\", (2^n)-1; exit}')

    # применение RPS (выполняется при старте, после того как NIC поднят)
    cat > "$RPS_SCRIPT" << RPSEOF
#!/usr/bin/env bash
set -euo pipefail

NIC="${WAN_IFACE}"
MASK="${RPS_MASK}"
NCPU=${NCPU}

echo 65536 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

for q in /sys/class/net/"\${NIC}"/queues/rx-*; do
    echo "\${MASK}" > "\${q}/rps_cpus"    2>/dev/null || true
    echo 4096       > "\${q}/rps_flow_cnt" 2>/dev/null || true
done

for q in /sys/class/net/"\${NIC}"/queues/tx-*; do
    echo "\${MASK}" > "\${q}/xps_cpus" 2>/dev/null || true
done

ethtool -G "\${NIC}" rx 4096 tx 4096 2>/dev/null || true
ethtool -K "\${NIC}" gro on gso on tso on 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 10000 2>/dev/null || true

echo "[node-rps] NIC=\${NIC} mask=\${MASK} cpus=\${NCPU}: OK"
RPSEOF
    chmod +x "$RPS_SCRIPT"

    cat > "$RPS_SERVICE" << EOF
[Unit]
Description=RPS/RFS/XPS and NIC tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${RPS_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$RPS_SERVICE_NAME" >/dev/null 2>&1
    # применение немедленно (NIC уже поднят)
    "$RPS_SCRIPT" && success "RPS/RFS/XPS и NIC настроены (${NCPU} ядер, интерфейс ${WAN_IFACE})." \
                  || warn "RPS/RFS/XPS применились с ошибками, проверьте вывод выше."
else
    if $IS_OPENVZ; then
        warn "RPS/RFS/XPS и NIC-тюнинг недоступны в контейнере (OpenVZ), пропуск."
    else
        warn "WAN-интерфейс не определён. RPS/RFS/XPS и NIC tuning пропущены."
        warn "После подключения интерфейса запустите вручную: ${RPS_SCRIPT}"
    fi
fi

# выключение transparent huge ages
if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
    cat > "$THP_SERVICE" << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$THP_SERVICE_NAME" >/dev/null 2>&1
    success "Transparent Huge Pages (THP) отключены."
else
    info "THP не обнаружен, пропуск."
fi

# ================
# [6/6] Применение
# ================
section "Шаг 6/6 – Применение sysctl параметров..."

# применение sysctl (--system применяет все файлы из /etc/sysctl.d/)
if sysctl -e --system > /tmp/sysctl-apply.log 2>&1; then
    success "sysctl --system применён успешно."
else
    warn "sysctl --system завершился с предупреждениями (возможно, часть параметров"
    warn "недоступна в этом окружении/ядре). Детали: /tmp/sysctl-apply.log"
fi

# применение systemd-лимитов
systemctl daemon-reload

# ====
# Итог
# ====
echo ""
info "Настройка завершена!"
echo ""

echo -e "${CYAN}Параметры sysctl:${NC}   ${BOLD}${SYSCTL_FILE}${NC}"
echo -e "${CYAN}Лимиты:${NC}             ${BOLD}${LIMITS_FILE}${NC}"
echo -e "${CYAN}Systemd-лимиты:${NC}     ${BOLD}${SYSTEMD_LIMITS_FILE}${NC}"
[[ -f "$RPS_SCRIPT" ]] && \
echo -e "${CYAN}Скрипт RPS:${NC}         ${BOLD}${RPS_SCRIPT}${NC}"
[[ -f "$RPS_SERVICE" ]] && \
echo -e "${CYAN}Сервис RPS:${NC}         ${BOLD}systemctl status ${RPS_SERVICE_NAME}${NC}"
[[ -f "$THP_SERVICE" ]] && \
echo -e "${CYAN}Сервис THP:${NC}         ${BOLD}systemctl status ${THP_SERVICE_NAME}${NC}"
echo -e "${CYAN}Применить sysctl:${NC}   ${BOLD}sysctl --system${NC}"