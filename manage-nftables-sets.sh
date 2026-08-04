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

# =============
# Текущий набор
# =============
SET_FAMILY=""
SET_TABLE=""
SET_NAME=""
SET_TYPE=""
SET_FLAGS=""
SET_AUTOMERGE=false
SET_COUNT=0

# =======
# Справка
# =======
help() {
    echo -e "
${BOLD}ИСПОЛЬЗОВАНИЕ:${NC} $(basename "$0") [опции]

${BOLD}ОБЩЕЕ:${NC}
  Интерактивное управление наборами (sets) в nftables: добавление и удаление
  элементов, импорт диапазонов из ASN, генерация конфигурации для вставки
  в декларативный файл.

  ${YELLOW}Все изменения применяются к ЗАГРУЖЕННОМУ ruleset и живут только до
  перезагрузки.${NC} Чтобы сохранить их, используйте пункт меню «Сгенерировать
  конфигурацию» и перенесите вывод в декларативный файл
  (например, /etc/nftables.d/cm_filter.nft).

  Префиксы ASN берутся из RIPEstat.

${BOLD}ПАРАМЕТРЫ:${NC}
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
        -h|--help) help ;;
        *) die "Неизвестный аргумент: $1. Используйте --help." ;;
    esac
done

# Проверка на администратора
[[ $EUID -ne 0 ]] && die "Необходимы права администратора (root/sudo)."

command -v nft >/dev/null 2>&1 || die "nftables не установлен (нет команды nft)."

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'echo; exit 130' INT

# nft >= 1.0.3 поддерживает --terse (список наборов без элементов), на старых версиях – обычный вывод
NFT_TERSE=""
nft -t list sets >/dev/null 2>&1 && NFT_TERSE="-t"

# ==========
# Валидаторы
# ==========
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o a b c d
    IFS='.' read -r a b c d <<< "$1"
    for o in $a $b $c $d; do (( o >= 0 && o <= 255 )) || return 1; done
}
is_ipv4_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    is_ipv4 "${1%%/*}" && (( ${1##*/} <= 32 ))
}
is_ipv6()      { [[ "$1" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$1" == *:* ]]; }
is_ipv6_cidr() {
    [[ "$1" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] || return 1
    is_ipv6 "${1%%/*}" && (( ${1##*/} <= 128 ))
}
is_timeout() { [[ "$1" =~ ^([0-9]+[dhms])+$|^[0-9]+$ ]]; }

# Есть ли флаг во флагах набора (список через запятую)
has_flag() { [[ ",${1}," == *",${2},"* ]]; }

# ====================
# Диалоговые примитивы
# ====================
ANSWER=""

ask() {
    local text="$1" def="${2-}" ans=""
    if [[ -n "$def" ]]; then
        echo -ne "${BOLD}${text}${NC} [${def}]: "
    else
        echo -ne "${BOLD}${text}${NC}: "
    fi
    read -r ans || { echo; exit 0; }
    ANSWER="${ans:-$def}"
}

confirm() {
    local text="$1" def="${2:-n}" ans hint
    if [[ "$def" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    while true; do
        echo -ne "${BOLD}${text}${NC} ${hint}: "
        read -r ans || { echo; exit 0; }
        ans="${ans:-$def}"
        case "${ans,,}" in
            y|yes|д|да)  return 0 ;;
            n|no|н|нет)  return 1 ;;
            *) warn "Введите y или n." ;;
        esac
    done
}

pause() {
    echo -ne "\n${CYAN}Нажмите Enter для продолжения...${NC}"
    read -r _ || true
    echo
}

# =====================
# Чтение наборов из nft
# =====================

# Вернуть набор в формате "family|table|set|type|flags|auto-merge"
nft_sets_list() {
    nft ${NFT_TERSE} list sets 2>/dev/null | awk '
        /^table[ \t]/ { fam=$2; tbl=$3; next }
        /^[ \t]*set[ \t]/ { name=$2; type=""; flags=""; am="no"; next }
        name != "" && /elements[ \t]*=[ \t]*\{/ { skip=1 }
        skip { if (/\}/) skip=0; next }
        name != "" && /^[ \t]*(type|typeof)[ \t]/ {
            line=$0; sub(/^[ \t]*(type|typeof)[ \t]+/, "", line); type=line; next
        }
        name != "" && /^[ \t]*flags[ \t]/ {
            line=$0; sub(/^[ \t]*flags[ \t]+/, "", line); gsub(/[ \t]/, "", line); flags=line; next
        }
        name != "" && /^[ \t]*auto-merge/ { am="yes"; next }
        name != "" && /^[ \t]*\}/ {
            printf "%s|%s|%s|%s|%s|%s\n", fam, tbl, name, type, flags, am
            name=""
        }
    '
}

# Метаданные конкретного набора
nft_set_meta() {
    nft_sets_list | awk -F'|' -v f="$1" -v t="$2" -v s="$3" '$1==f && $2==t && $3==s { print; exit }'
}

# Тело объявления набора без блока elements
set_decl_body() {
    nft list set "$1" "$2" "$3" 2>/dev/null | awk '
        /^[ \t]*set[ \t]+[^ \t]+[ \t]*\{/ { inside=1; next }
        inside && /elements[ \t]*=[ \t]*\{/ { skip=1 }
        skip { if (/\}/) skip=0; next }
        inside && /^[ \t]*\}[ \t]*$/ { inside=0; next }
        inside {
            sub(/^[ \t]+/, "")
            sub(/[ \t]*#[ \t]*count[ \t]+[0-9]+[ \t]*$/, "")
            print
        }
    '
}

# Элементы набора, по одному на строку
dump_elements() {
    nft list set "$1" "$2" "$3" 2>/dev/null \
        | sed -n '/elements = {/,$p' \
        | tr '\n' ' ' \
        | sed -e 's/^[^{]*{//' -e 's/}.*//' \
        | tr ',' '\n' \
        | sed -E 's/[[:space:]]+expires[[:space:]]+[^[:space:],]+//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        | grep -v '^$' || true
}

count_elements() { dump_elements "$1" "$2" "$3" | wc -l; }

refresh_count() { SET_COUNT=$(count_elements "$SET_FAMILY" "$SET_TABLE" "$SET_NAME"); }

# ====================
# Применение изменений
# ====================
CHUNK_SIZE=500

# Сборка команд "add/delete element" пачками по CHUNK_SIZE
build_batch() {
    local action="$1" fam="$2" tbl="$3" name="$4" src="$5"
    awk -v act="$action" -v fam="$fam" -v tbl="$tbl" -v st="$name" -v chunk="$CHUNK_SIZE" '
        NF == 0 { next }
        {
            buf = (n == 0 ? $0 : buf ", " $0)
            n++
            if (n >= chunk) {
                printf "%s element %s %s %s { %s }\n", act, fam, tbl, st, buf
                buf=""; n=0
            }
        }
        END { if (n > 0) printf "%s element %s %s %s { %s }\n", act, fam, tbl, st, buf }
    ' "$src"
}

# Применение пачкой, при неудаче – поэлементно (частичные совпадения, дубликаты)
apply_batch() {
    local action="$1" fam="$2" tbl="$3" name="$4" src="$5"
    local total tmpf errf el ok=0 fail=0

    total=$(grep -c '[^[:space:]]' "$src" || true)
    if (( total == 0 )); then
        warn "Нет элементов для обработки."
        return 1
    fi

    tmpf="${TMP_DIR}/batch.nft"
    errf="${TMP_DIR}/batch.err"
    build_batch "$action" "$fam" "$tbl" "$name" "$src" > "$tmpf"

    if nft -f "$tmpf" 2>"$errf"; then
        success "Обработано элементов: ${total} (${fam} ${tbl} ${name})."
        return 0
    fi

    warn "Пакетная операция не удалась:"
    sed 's/^/    /' "$errf" >&2
    info "Повтор поэлементно, неподходящие элементы будут пропущены..."

    while IFS= read -r el; do
        [[ -z "${el// /}" ]] && continue
        if nft "$action" element "$fam" "$tbl" "$name" "{ $el }" 2>/dev/null; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done < "$src"

    (( ok > 0 )) && success "Успешно: ${ok} из ${total}."
    (( fail > 0 )) && warn "Пропущено: ${fail} из ${total}."
    (( ok > 0 ))
}

remind_volatile() {
    warn "Изменение живёт только до перезагрузки. Сохраните его через пункт для генерации конфигурации."
}

# Есть ли у набора флаг interval (для подсетей и диапазонов)
set_has_interval() {
    local flags
    flags=$(nft_set_meta "$1" "$2" "$3" | cut -d'|' -f5)
    has_flag "$flags" "interval"
}

# ============
# Выбор набора
# ============
PICK_FAMILY=""
PICK_TABLE=""
PICK_SET=""

pick_set() {
    local want_type="${1-}"
    local -a rows=()
    local line fam tbl name type flags am ref
    local w_ref=0 i choice

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ -n "$want_type" ]]; then
            [[ "$(echo "$line" | cut -d'|' -f4)" == "$want_type" ]] || continue
        fi
        rows+=("$line")
    done < <(nft_sets_list)

    if [[ ${#rows[@]} -eq 0 ]]; then
        if [[ -n "$want_type" ]]; then
            warn "Наборов типа ${want_type} в ruleset не найдено."
        else
            warn "Наборы (sets) в текущем ruleset не найдены."
            info "Добавьте хотя бы один набор в ruleset, чтобы использовать утилиту."
        fi
        return 1
    fi

    for line in "${rows[@]}"; do
        IFS='|' read -r fam tbl name _ _ _ <<< "$line"
        ref="${fam} ${tbl} ${name}"
        (( ${#ref} > w_ref )) && w_ref=${#ref}
    done

    echo -e "\n   ${CYAN}${BOLD}Доступные наборы${NC}"
    echo ""

    i=0
    for line in "${rows[@]}"; do
        i=$((i + 1))
        IFS='|' read -r fam tbl name type flags am <<< "$line"
        [[ "$am" == "yes" ]] && flags="${flags:+${flags},}auto-merge"
        printf "  ${BOLD}%2s)${NC} ${GREEN}%-${w_ref}s${NC}   %s\n" \
            "$i" "${fam} ${tbl} ${name}" "${type}${flags:+, ${flags//,/, }}"
    done
    echo ""

    while true; do
        ask "Введите номер набора (0 – отмена)" ""
        choice="$ANSWER"
        [[ "$choice" == "0" ]] && return 1
        if is_uint "$choice" && (( choice >= 1 && choice <= ${#rows[@]} )); then
            IFS='|' read -r PICK_FAMILY PICK_TABLE PICK_SET _ _ _ <<< "${rows[$((choice - 1))]}"
            return 0
        fi
        warn "Введите число от 0 до ${#rows[@]}."
    done
}

load_set() {
    local meta am
    meta=$(nft_set_meta "$1" "$2" "$3")
    [[ -z "$meta" ]] && { error "Набор ${1} ${2} ${3} не найден."; return 1; }

    IFS='|' read -r SET_FAMILY SET_TABLE SET_NAME SET_TYPE SET_FLAGS am <<< "$meta"
    [[ "$am" == "yes" ]] && SET_AUTOMERGE=true || SET_AUTOMERGE=false
    refresh_count
    return 0
}

set_is_writable() {
    if has_flag "$SET_FLAGS" "constant"; then
        error "Набор «${SET_NAME}» помечен флагом constant и не может быть изменён."
        return 1
    fi
    return 0
}

# =================================
# Разбор пользовательских элементов
# =================================

# Проверка элемента на соответствие типу набора
# 0 – ок, 1 – требуется interval, 2 – некорректен
check_element() {
    local el="$1" type="$2"
    case "$type" in
        ipv4_addr)
            is_ipv4 "$el"      && return 0
            is_ipv4_cidr "$el" && return 1
            [[ "$el" == *-* ]] && is_ipv4 "${el%%-*}" && is_ipv4 "${el##*-}" && return 1
            return 2 ;;
        ipv6_addr)
            is_ipv6 "$el"      && return 0
            is_ipv6_cidr "$el" && return 1
            [[ "$el" == *-* ]] && is_ipv6 "${el%%-*}" && is_ipv6 "${el##*-}" && return 1
            return 2 ;;
        *)
            return 0 ;;
    esac
}

# Разбор строки в файл элементов с учётом флагов набора
# $1 – ввод пользователя, $2 – файл назначения, возвращает 1 при отмене
parse_elements() {
    local input="$1" dst="$2"
    local -a items=() plain=() ranges=()
    local el rc

    input=$(echo "$input" | sed -E 's/[[:space:]]*-[[:space:]]*/-/g')
    IFS=', ' read -ra items <<< "$input"

    for el in "${items[@]}"; do
        [[ -z "$el" ]] && continue

        # /32 и /128 в наборе без interval эквивалентны одиночному адресу
        if ! has_flag "$SET_FLAGS" "interval"; then
            [[ "$SET_TYPE" == "ipv4_addr" && "$el" == */32 ]]  && el="${el%%/*}"
            [[ "$SET_TYPE" == "ipv6_addr" && "$el" == */128 ]] && el="${el%%/*}"
        fi

        set +e
        check_element "$el" "$SET_TYPE"
        rc=$?
        set -e

        case "$rc" in
            0) plain+=("$el") ;;
            1) ranges+=("$el") ;;
            2) warn "«${el}» не подходит для набора типа ${SET_TYPE}, пропуск." ;;
        esac
    done

    if [[ ${#plain[@]} -eq 0 && ${#ranges[@]} -eq 0 ]]; then
        warn "Ни одного корректного элемента не введено."
        return 1
    fi

    # диапазоны и подсети требуют флага interval
    if [[ ${#ranges[@]} -gt 0 ]] && ! has_flag "$SET_FLAGS" "interval"; then
        warn "У набора «${SET_NAME}» нет флага interval, подсети и диапазоны (${#ranges[@]} шт.) добавить нельзя."

        if [[ ${#plain[@]} -eq 0 ]]; then
            info "Добавлять нечего: все элементы требуют флага interval."
            return 1
        fi
        confirm "Добавить только одиночные адреса (${#plain[@]} шт.)?" y || return 1
        ranges=()
    fi

    : > "$dst"
    [[ ${#plain[@]}  -gt 0 ]] && printf '%s\n' "${plain[@]}"  >> "$dst"
    [[ ${#ranges[@]} -gt 0 ]] && printf '%s\n' "${ranges[@]}" >> "$dst"
    return 0
}

# Запрос времени жизни элементов (только для наборов с флагом timeout)
ask_timeout() {
    ANSWER=""
    has_flag "$SET_FLAGS" "timeout" || return 0
    while true; do
        ask "Укажите таймаут для элементов (например 1h, 30m, 2d; пусто – без ограничения)" ""
        [[ -z "$ANSWER" ]] && return 0
        if is_timeout "$ANSWER"; then return 0; fi
        warn "Ожидается число с суффиксом d|h|m|s, например 12h."
    done
}

apply_timeout() {
    local src="$1" to="$2"
    [[ -z "$to" ]] && return 0
    sed -i -E "s/$/ timeout ${to}/" "$src"
}

# =====================
# Пункты меню: элементы
# =====================
menu_show() {
    section "Содержимое набора ${SET_NAME}"

    refresh_count
    info "Элементов: ${SET_COUNT}."
    (( SET_COUNT == 0 )) && return 0

    if (( SET_COUNT > 200 )); then
        confirm "Вывести все ${SET_COUNT} элементов?" n || return 0
    fi
    echo ""
    dump_elements "$SET_FAMILY" "$SET_TABLE" "$SET_NAME" | nl -w6 -s'  '
}

menu_add() {
    local src="${TMP_DIR}/add.txt" to=""

    section "Добавление элементов в ${SET_NAME}"
    set_is_writable || return 0

    info "Тип набора: ${SET_TYPE}. Флаги: ${SET_FLAGS:-—}."
    if has_flag "$SET_FLAGS" "interval"; then
        info "Допустимы адреса, подсети (1.2.3.0/24) и диапазоны (1.2.3.4-1.2.3.10)."
    else
        info "Допустимы только одиночные адреса (без маски)."
    fi

    ask "Введите элементы через запятую или пробел (пусто – отмена)" ""
    [[ -z "$ANSWER" ]] && { info "Отменено."; return 0; }

    parse_elements "$ANSWER" "$src" || return 0

    ask_timeout
    to="$ANSWER"
    apply_timeout "$src" "$to"

    echo ""
    info "К добавлению элементов: $(grep -c '[^[:space:]]' "$src" || true)."
    echo ""
    nl -w4 -s'  ' "$src"
    echo ""
    confirm "Добавить в ${SET_FAMILY} ${SET_TABLE} ${SET_NAME}?" y || { info "Отменено."; return 0; }

    if apply_batch "add" "$SET_FAMILY" "$SET_TABLE" "$SET_NAME" "$src"; then
        refresh_count
        info "Теперь в наборе элементов: ${SET_COUNT}."
        remind_volatile
    fi
}

menu_delete() {
    local src="${TMP_DIR}/del.txt"
    local -a items=()
    local el

    section "Удаление элементов из ${SET_NAME}"
    set_is_writable || return 0

    if has_flag "$SET_FLAGS" "interval"; then
        warn "У набора флаг interval. Диапазон удаляется ТОЛЬКО целиком."
    fi

    ask "Введите элементы через запятую или пробел (пусто – отмена)" ""
    [[ -z "$ANSWER" ]] && { info "Отменено."; return 0; }

    IFS=', ' read -ra items <<< "$(echo "$ANSWER" | sed -E 's/[[:space:]]*-[[:space:]]*/-/g')"
    : > "$src"
    for el in "${items[@]}"; do
        [[ -n "$el" ]] && echo "$el" >> "$src"
    done

    if [[ ! -s "$src" ]]; then
        warn "Ни одного элемента не введено."
        return 0
    fi

    echo ""
    info "К удалению элементов: $(grep -c '[^[:space:]]' "$src" || true)."
    echo ""
    nl -w4 -s'  ' "$src"
    echo ""
    confirm "Удалить из ${SET_FAMILY} ${SET_TABLE} ${SET_NAME}?" n || { info "Отменено."; return 0; }

    if apply_batch "delete" "$SET_FAMILY" "$SET_TABLE" "$SET_NAME" "$src"; then
        refresh_count
        info "Теперь в наборе элементов: ${SET_COUNT}."
        remind_volatile
    fi
}

menu_flush() {
    section "Очистка набора ${SET_NAME}"
    set_is_writable || return 0

    refresh_count
    if (( SET_COUNT == 0 )); then
        info "Набор уже пуст."
        return 0
    fi

    warn "Будут удалены ВСЕ элементы набора ${SET_NAME} (${SET_COUNT} шт.)."
    confirm "Продолжить?" n || { info "Отменено."; return 0; }

    nft flush set "$SET_FAMILY" "$SET_TABLE" "$SET_NAME"
    refresh_count
    success "Набор ${SET_NAME} очищен."
    remind_volatile
}

# ================
# Пункты меню: ASN
# ================
RIPESTAT_URL="https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS"

fetch_asn_prefixes() {
    local asn="$1" dst="$2"

    info "AS${asn}: запрос к RIPEstat..."
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "${RIPESTAT_URL}${asn}" 2>/dev/null \
        | grep -oE '"prefix"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/' \
        | grep -E '^[0-9a-fA-F:.]+/[0-9]{1,3}$' \
        | sort -u > "$dst" || true

    [[ -s "$dst" ]]
}

# Набор-получатель для нужного типа
TARGET_FAMILY=""
TARGET_TABLE=""
TARGET_SET=""

resolve_target() {
    local want_type="$1"

    if [[ "$SET_TYPE" == "$want_type" ]]; then
        TARGET_FAMILY="$SET_FAMILY"; TARGET_TABLE="$SET_TABLE"; TARGET_SET="$SET_NAME"
        return 0
    fi

    info "Текущий набор имеет тип ${SET_TYPE}, для ${want_type} нужен отдельный набор."
    if pick_set "$want_type"; then
        TARGET_FAMILY="$PICK_FAMILY"; TARGET_TABLE="$PICK_TABLE"; TARGET_SET="$PICK_SET"
        return 0
    fi
    return 1
}

menu_asn() {
    local action="$1"
    local title verb src4 src6 choice to=""
    local want4=false want6=false applied=false
    local -a asns=() parts=() t4=() t6=()
    local a n c4=0 c6=0

    if [[ "$action" == "add" ]]; then
        title="Добавление"; verb="добавить"
    else
        title="Удаление"; verb="удалить"
    fi
    section "${title} диапазонов ASN"

    set_is_writable || return 0
    command -v curl >/dev/null 2>&1 || { error "Не найден curl, загрузка префиксов невозможна."; return 0; }

    ask "Введите номер(а) ASN, например AS13335 или 13335,32934 (пусто – отмена)" ""
    [[ -z "$ANSWER" ]] && { info "Отменено."; return 0; }

    IFS=', ' read -ra parts <<< "$ANSWER"
    for a in "${parts[@]}"; do
        a="${a//[[:space:]]/}"
        a="${a#[Aa][Ss]}"
        [[ -z "$a" ]] && continue
        if ! is_uint "$a"; then
            warn "«${a}» не похоже на номер ASN, пропуск."
            continue
        fi
        asns+=("$a")
    done
    [[ ${#asns[@]} -eq 0 ]] && { warn "Корректных номеров ASN не введено."; return 0; }

    echo ""
    echo -e "  ${BOLD}1)${NC} только IPv4"
    echo -e "  ${BOLD}2)${NC} только IPv6"
    echo -e "  ${BOLD}3)${NC} и IPv4, и IPv6"
    echo ""
    while true; do
        ask "Что ${verb} (0 – отмена)?" "1"
        choice="$ANSWER"
        case "$choice" in
            0) info "Отменено."; return 0 ;;
            1) want4=true; break ;;
            2) want6=true; break ;;
            3) want4=true; want6=true; break ;;
            *) warn "Введите 1, 2, 3 или 0." ;;
        esac
    done

    # определение наборов-получателей
    if $want4; then
        if resolve_target "ipv4_addr"; then
            t4=("$TARGET_FAMILY" "$TARGET_TABLE" "$TARGET_SET")
        else
            warn "Набор для IPv4 не выбран, IPv4-префиксы будут пропущены."
            want4=false
        fi
    fi
    if $want6; then
        if resolve_target "ipv6_addr"; then
            t6=("$TARGET_FAMILY" "$TARGET_TABLE" "$TARGET_SET")
        else
            warn "Набор для IPv6 не выбран, IPv6-префиксы будут пропущены."
            want6=false
        fi
    fi

    # префиксы ASN – подсети, без флага interval набор их не примет
    if [[ "$action" == "add" ]]; then
        if $want4 && ! set_has_interval "${t4[@]}"; then
            warn "У набора ${t4[2]} нет флага interval, IPv4-префиксы добавить нельзя."
            info "Добавьте ${BOLD}flags interval${NC} в объявление набора и перезагрузите таблицу."
            want4=false
        fi
        if $want6 && ! set_has_interval "${t6[@]}"; then
            warn "У набора ${t6[2]} нет флага interval, IPv6-префиксы добавить нельзя."
            info "Добавьте ${BOLD}flags interval${NC} в объявление набора и перезагрузите таблицу."
            want6=false
        fi
    fi

    if ! $want4 && ! $want6; then
        warn "Нечего делать."
        return 0
    fi

    # загрузка префиксов
    src4="${TMP_DIR}/asn-v4.txt"
    src6="${TMP_DIR}/asn-v6.txt"
    : > "$src4"; : > "$src6"

    for n in "${asns[@]}"; do
        if ! fetch_asn_prefixes "$n" "${TMP_DIR}/asn-raw.txt"; then
            warn "AS${n}: префиксы получить не удалось, пропуск."
            continue
        fi
        grep -vF ':' "${TMP_DIR}/asn-raw.txt" >> "$src4" || true
        grep -F  ':' "${TMP_DIR}/asn-raw.txt" >> "$src6" || true
        success "AS${n}: получено $(grep -c '[^[:space:]]' "${TMP_DIR}/asn-raw.txt" || true) префиксов."
    done

    sort -u "$src4" -o "$src4"
    sort -u "$src6" -o "$src6"
    c4=$(grep -c '[^[:space:]]' "$src4" || true)
    c6=$(grep -c '[^[:space:]]' "$src6" || true)

    echo ""
    $want4 && info "IPv4-префиксов: ${c4}."
    $want6 && info "IPv6-префиксов: ${c6}."

    if (( c4 == 0 && c6 == 0 )); then
        warn "Ни одного префикса не получено."
        return 0
    fi

    confirm "Продолжить и ${verb} эти префиксы?" y || { info "Отменено."; return 0; }

    if [[ "$action" == "add" ]]; then
        ask_timeout
        to="$ANSWER"
    fi

    if $want4 && (( c4 > 0 )); then
        apply_timeout "$src4" "$to"
        apply_batch "$action" "${t4[0]}" "${t4[1]}" "${t4[2]}" "$src4" && applied=true
    fi
    if $want6 && (( c6 > 0 )); then
        apply_timeout "$src6" "$to"
        apply_batch "$action" "${t6[0]}" "${t6[1]}" "${t6[2]}" "$src6" && applied=true
    fi

    refresh_count
    $applied && remind_volatile
}

# ==============================
# Пункты меню: генерация конфига
# ==============================

# Ширина строки при компактном выводе элементов
LINE_WIDTH=92

format_elements() {
    local indent="$1" one_per_line="$2" width="$3"
    awk -v ind="$indent" -v one="$one_per_line" -v w="$width" '
        NF == 0 { next }
        { items[++n] = $0 }
        END {
            if (n == 0) exit
            if (one == "true") {
                for (i = 1; i <= n; i++) printf "%s%s%s\n", ind, items[i], (i < n ? "," : "")
                exit
            }
            line = ""
            for (i = 1; i <= n; i++) {
                item = items[i] (i < n ? "," : "")
                if (line == "") line = ind item
                else if (length(line) + 1 + length(item) > w) { print line; line = ind item }
                else line = line " " item
            }
            if (line != "") print line
        }
    '
}

build_config() {
    local one_per_line="$1" wrap_table="$2" dst="$3"
    local elems body_indent el_indent brace_indent count
    local -a body=()

    elems="${TMP_DIR}/gen-elements.txt"
    dump_elements "$SET_FAMILY" "$SET_TABLE" "$SET_NAME" > "$elems"
    count=$(grep -c '[^[:space:]]' "$elems" || true)

    mapfile -t body < <(set_decl_body "$SET_FAMILY" "$SET_TABLE" "$SET_NAME")
    if [[ ${#body[@]} -eq 0 ]]; then
        error "Не удалось прочитать объявление набора ${SET_NAME}."
        return 1
    fi

    brace_indent="    "
    body_indent="        "
    el_indent="            "

    : > "$dst"
    if $wrap_table; then
        {
            echo "#!/usr/sbin/nft -f"
            echo "table ${SET_FAMILY} ${SET_TABLE} {"
        } >> "$dst"
    fi

    {
        echo "${brace_indent}set ${SET_NAME} {"
        printf "${body_indent}%s\n" "${body[@]}"
        if (( count > 0 )); then
            echo "${body_indent}elements = {"
            format_elements "$el_indent" "$one_per_line" "$LINE_WIDTH" < "$elems"
            echo "${body_indent}}"
        fi
        echo "${brace_indent}}"
    } >> "$dst"

    $wrap_table && echo "}" >> "$dst"
    return 0
}

menu_generate() {
    local choice out="${TMP_DIR}/generated.nft"
    local one_per_line=false wrap_table=false

    echo -e "\n  ${CYAN}Генерация конфигурации для набора ${SET_NAME}${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} блок set, компактно (несколько элементов в строке)"
    echo -e "  ${BOLD}2)${NC} блок set, развёрнуто (по одному элементу на строку)"
    echo -e "  ${BOLD}3)${NC} полный блок table { ... }, готовый для nft -f"
    echo -e "  ${BOLD}0)${NC} назад"
    echo ""

    ask "Формат вывода" "1"
    choice="$ANSWER"
    case "$choice" in
        0) return 0 ;;
        1) ;;
        2) one_per_line=true ;;
        3) wrap_table=true ;;
        *) warn "Неизвестный пункт: ${choice}."; return 0 ;;
    esac

    build_config "$one_per_line" "$wrap_table" "$out" || return 0

    echo ""
    echo -e "${CYAN}────────────────────────── начало вывода ──────────────────────────${NC}"
    cat "$out"
    echo -e "${CYAN}─────────────────────────── конец вывода ──────────────────────────${NC}"
    echo ""

    if $wrap_table; then
        info "Вывод можно применить целиком: ${BOLD}nft -f <файл>${NC}"
    else
        echo -e "${CYAN}Вставьте блок внутрь объявления ${BOLD}table ${SET_FAMILY} ${SET_TABLE} { ... }${NC}${CYAN} в декларативном файле.${NC}"
    fi
}

# ============
# Главное меню
# ============
print_header() {
    local flags="$SET_FLAGS"
    $SET_AUTOMERGE && flags="${flags:+${flags},}auto-merge"
    flags="${flags//,/, }"
    [[ -z "$flags" ]] && flags="—"

    echo -e "  ${CYAN}${BOLD}Управление набором${NC}"
    echo ""
    echo -e "  ${CYAN}Набор:${NC}     ${BOLD}${SET_FAMILY} ${SET_TABLE} ${SET_NAME}${NC}"
    echo -e "  ${CYAN}Тип:${NC}       ${SET_TYPE}"
    echo -e "  ${CYAN}Флаги:${NC}     ${flags}"
    echo -e "  ${CYAN}Элементов:${NC} ${SET_COUNT}"
    echo ""
    echo -e "  ${BOLD}1)${NC} показать содержимое набора"
    echo -e "  ${BOLD}2)${NC} добавить элементы"
    echo -e "  ${BOLD}3)${NC} удалить элементы"
    echo -e "  ${BOLD}4)${NC} добавить диапазоны ASN"
    echo -e "  ${BOLD}5)${NC} удалить диапазоны ASN"
    echo -e "  ${BOLD}6)${NC} сгенерировать конфигурацию"
    echo -e "  ${BOLD}7)${NC} очистить набор (flush)"
    echo -e "  ${BOLD}8)${NC} выбрать другой набор"
    echo -e "  ${BOLD}0)${NC} выход"
    echo ""
}

# =========================
# Точка входа: выбор набора
# =========================
pick_set || exit 1
load_set "$PICK_FAMILY" "$PICK_TABLE" "$PICK_SET" || exit 1

info "Выбран набор: ${SET_FAMILY} ${SET_TABLE} ${SET_NAME}."

# =========
# Цикл меню
# =========
echo ""
while true; do
    print_header
    ask "Пункт меню" ""

    case "$ANSWER" in
        1) menu_show;         pause ;;
        2) menu_add;          pause ;;
        3) menu_delete;       pause ;;
        4) menu_asn add;      pause ;;
        5) menu_asn delete;   pause ;;
        6) menu_generate;     pause ;;
        7) menu_flush;        pause ;;
        8)
            if pick_set; then
                load_set "$PICK_FAMILY" "$PICK_TABLE" "$PICK_SET" || true
            fi ;;
        0|q|quit|exit)
            echo ""
            info "Выход. Изменения ruleset действуют до перезагрузки."
            echo -e "${CYAN}Смотреть набор:${NC}   ${BOLD}nft list set ${SET_FAMILY} ${SET_TABLE} ${SET_NAME}${NC}"
            echo -e "${CYAN}Все наборы:${NC}       ${BOLD}nft list sets${NC}"
            exit 0 ;;
        *) warn "Неизвестный пункт: ${ANSWER}."; pause ;;
    esac
done
