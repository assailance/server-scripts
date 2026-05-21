#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

log()     { echo -e "\n${CYAN}[LOG] $*${RESET}"; }
success() { echo -e "${GREEN}[SUCCESS] $*${RESET}"; }
warn()    { echo -e "${YELLOW}[WARN] $*${RESET}"; }
error()   { echo -e "${RED}[ERROR] $*${RESET}" >&2; exit 1; }

# Проверка аргументов
if [[ $# -ne 3 ]]; then
  error "Использование: $0 <username> <публичный_ключ> <новый_порт_ssh>
        Пример: $0 yuno 'ssh-ed25519 AAAA...xyz user@host' 8132"
fi

if [[ $EUID -ne 0 ]]; then
  error "Для запуска необходимы права администратора."
fi

USERNAME="$1"
PUBKEY_CONTENT="$2"
SSH_PORT="$3"

# Проверка ключа
if ! echo "$PUBKEY_CONTENT" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256) '; then
  error "Переданный ключ не похож на публичный SSH-ключ."
fi

# Проверка порта
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
  error "Порт должен быть числом: ${SSH_PORT}."
fi

if [[ "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]]; then
  error "Порт должен быть в диапазоне от 1 до 65535: ${SSH_PORT}."
fi

if ss -tlnH sport = ":${SSH_PORT}" | grep -q .; then
  error "Порт ${SSH_PORT} уже занят."
fi

echo -e "${CYAN}=============================================${RESET}"
echo -e "${CYAN}  Пользователь  : ${YELLOW}${USERNAME}${RESET}"
echo -e "${CYAN}  Публичный ключ: ${YELLOW}${PUBKEY_CONTENT:0:30}...${RESET}"
echo -e "${CYAN}  SSH-порт      : ${YELLOW}${SSH_PORT}${RESET}"
echo -e "${CYAN}=============================================${RESET}"

# =====================
# 1. Обновление системы
# =====================
log "Шаг 1/6 – Обновление системы..."
apt-get update -q
apt-get dist-upgrade -y -q
success "Система обновлена."

# ========================
# 2. Создание пользователя
# ========================
log "Шаг 2/6 – Создание пользователя «${USERNAME}»..."

if id "$USERNAME" &>/dev/null; then
    warn "Пользователь «${USERNAME}» уже существует — пропуск создания."
else
    useradd -m "$USERNAME" -G sudo -s /bin/bash
    success "Пользователь «${USERNAME}» создан."
fi

HOME_DIR="/home/${USERNAME}"

# ====================
# 3. Настройка sudoers
# ====================
log "Шаг 3/6 – Настройка /etc/sudoers..."

cp /etc/sudoers /etc/sudoers.bak

# Настройка sudo без пароля
if ! grep -q "NOPASSWD:ALL" /etc/sudoers; then
    sed -i 's/^%sudo\s.*ALL$/%sudo   ALL=(ALL:ALL) NOPASSWD:ALL/' /etc/sudoers
fi

# Отключение @includedir и запрет admin
sed -i 's|^@includedir|#@includedir|' /etc/sudoers
sed -i 's|^#includedir|##includedir|' /etc/sudoers
sed -i 's|^%admin ALL=(ALL) ALL|#%admin ALL=(ALL) ALL|' /etc/sudoers

# Проверка синтаксиса
visudo -c -f /etc/sudoers || {
    warn "Синтаксис sudoers нарушен, возврат резервной копии..."
    cp /etc/sudoers.bak /etc/sudoers
    error "Не удалось настроить /etc/sudoers."
}

success "Файл /etc/sudoers настроен."

# ==========================
# 4. umask и директория .ssh
# ==========================
log "Шаг 4/6 – Настройка umask и директории .ssh..."

BASHRC="${HOME_DIR}/.bashrc"
if ! grep -q 'umask 0077' "$BASHRC" 2>/dev/null; then
    echo 'umask 0077' >> "$BASHRC"
fi

# Создание директории и настройка прав
SSH_DIR="${HOME_DIR}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

AUTH_KEYS="${SSH_DIR}/authorized_keys"

# Проверка на дублирование
if ! grep -qF "$PUBKEY_CONTENT" "$AUTH_KEYS" 2>/dev/null; then
    echo "$PUBKEY_CONTENT" >> "$AUTH_KEYS"
fi

chmod 600 "$AUTH_KEYS"
chown -R "${USERNAME}:${USERNAME}" "$SSH_DIR"
success "SSH-ключ и umask настроены."

# ========================
# 5. Отключение root shell
# ========================
log "Шаг 5/6 – Отключение shell для root..."

if grep -q '^root:.*:/bin/bash$\|^root:.*:/bin/sh$' /etc/passwd; then
    sed -i 's|^\(root:.*:\)/bin/bash$|\1/usr/sbin/nologin|' /etc/passwd
    sed -i 's|^\(root:.*:\)/bin/sh$|\1/usr/sbin/nologin|' /etc/passwd
    success "Root shell заменён на /usr/sbin/nologin."
else
    warn "Root использует нестандартный shell, пропуск..."
fi

# ========================
# 6. Настройка sshd_config
# ========================
log "Шаг 6/6 – Настройка /etc/ssh/sshd_config..."

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

set_sshd_param() {
    local key="$1" value="$2"
	sed -i "/^[[:space:]]*#\?[[:space:]]*${key}[[:space:]]/d" "$SSHD_CONFIG"
    echo "${key} ${value}" >> "$SSHD_CONFIG"
}

sed -i 's|^[[:space:]]*Include /etc/ssh/sshd_config\.d/\*\.conf|#Include /etc/ssh/sshd_config.d/*.conf|' "$SSHD_CONFIG"

echo "" >> "$SSHD_CONFIG"
set_sshd_param "Port"                            "$SSH_PORT"
set_sshd_param "PermitRootLogin"                 "no"
set_sshd_param "PasswordAuthentication"          "no"
set_sshd_param "PermitEmptyPasswords"            "no"
set_sshd_param "PubkeyAuthentication"            "yes"
set_sshd_param "KbdInteractiveAuthentication"    "no"
set_sshd_param "ChallengeResponseAuthentication" "no"
set_sshd_param "IgnoreRhosts"                    "yes"

mkdir -p /run/sshd

# Проверка синтаксиса
sshd -t || {
	warn "Синтаксис sshd_config нарушен, возврат резервной копии..."
	cp "${SSHD_CONFIG}.bak" "$SSHD_CONFIG"
	error "Не удалось настроить sshd_config."
}

systemctl daemon-reload
systemctl restart ssh || systemctl restart sshd
success "SSH-сервер перенастроен (порт ${SSH_PORT})."

# ==================
# Итоговый результат
# ==================
echo ""
success "Настройка завершена успешно!"
warn "Резервные копии сохранены: /etc/sudoers.bak, /etc/ssh/sshd_config.bak"
warn "Проверьте вход в новом терминале перед закрытием сессии."
