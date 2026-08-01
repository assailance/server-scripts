Автоматизация **первоначальной настройки** сервера с помощью **bash-скриптов**.

## 📃 Описание

### configure-user.sh / [Перейти](#настройка-пользователя-и-ssh-configure-usersh)

Создаёт непривилегированного пользователя, настраивает SSH-авторизацию по ключу, изменяет порт и другие параметры в `/etc/ssh/sshd_config` для повышения безопасности сервера.

### configure-nftables.sh / [Перейти](#настройка-nftables-configure-nftablessh)

Настраивает ruleset для nftables с автоматическим определением SSH-порта, ограничением частоты запросов по IP, автобаном, защитой от сканирования, фильтрацией bogon-адресов и внешними блок-листами. Генерирует файл `/etc/nftables.d/cm_filter.nft`, проверяет его перед применением и настраивает автозагрузку через systemd.

### configure-sysctl.sh / [Перейти](#настройка-sysctl-configure-sysctlsh)

Настраивает параметры ядра Linux (sysctl), лимиты файловых дескрипторов и процессов, производительность сетевого стека, RPS/RFS/XPS, а также оптимизирует сетевой интерфейс и параметры памяти. Автоматически определяет окружение (включая OpenVZ), применяет изменения и настраивает их сохранение после перезагрузки.

<!-- ====================================== -->
<!-- ====  Docs for configure-user.sh  ==== -->
<!-- ====================================== -->

<details>
<summary>

# Настройка пользователя и SSH (configure-user.sh)

</summary>

Описание действий:

1. Обновление системы.
2. Создание непривилегированного пользователя.
3. Настройка файла `/etc/sudoers` (отключение пароля для созданного пользователя).
4. Настройка маски для новых файлов (umask) и добавление SSH-ключа.
5. Отключение root shell (смена на `/usr/sbin/nologin`).
6. Настройка порта и других опций в `/etc/ssh/sshd_config` на основе переданных параметров.

## Запуск

### Напрямую с GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-user.sh | sudo bash -s -- <имя_пользователя> <публичный_ключ> <порт_ssh>
```

### Локальная загрузка и запуск

```bash
wget -O configure-user.sh https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-user.sh
chmod +x configure-user.sh
sudo ./configure-user.sh <имя_пользователя> <публичный_ключ> <порт_ssh>
```

---

## Параметры

Скрипт принимает ровно три обязательных позиционных параметра.

### `<имя_пользователя>`

Имя создаваемого пользователя. Если пользователь уже существует, шаг создания пропускается.

```bash
sudo ./configure-user.sh myuser <публичный_ключ> <порт_ssh>
```

---

### `<публичный_ключ>`

Публичный SSH-ключ, который будет добавлен в `~/.ssh/authorized_keys` пользователя. Поддерживаемые типы: `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`. Ключ нужно передавать в кавычках.

```bash
sudo ./configure-user.sh <имя_пользователя> 'ssh-ed25519 AAAA...xyz user@host' <порт_ssh>
```

---

### `<порт_ssh>`

Новый порт, на котором будет слушать SSH-сервер. Должен быть числом в диапазоне от 1 до 65535 и не занятым другим процессом.

> ⚠️ После выполнения скрипта SSH будет доступен только на указанном порту. Не закрывайте текущую сессию, не проверив подключение в новом терминале.

```bash
sudo ./configure-user.sh <имя_пользователя> <публичный_ключ> 8132
```

</details>

<!-- ========================================== -->
<!-- ====  Docs for configure-nftables.sh  ==== -->
<!-- ========================================== -->

<details>
<summary>

# Настройка nftables (configure-nftables.sh)

</summary>

Описание действий:

1. Обновляет и устанавливает пакеты: nftables, curl, ca-certificates, iproute2.
2. Определяет OpenVZ, SSH-порт из конфигурации sshd и WAN-интерфейс (используется для bogon-фильтра).
3. Загружает и подключает блок-листы из репозитория [traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists) (если они не отключены).
4. Генерирует ruleset nftables на основе переданных параметров (см. ниже).
5. Проверяет корректность сгенерированного ruleset с помощью `nft -c`.
6. Применяет сгенерированные правила.
7. Настраивает автозагрузку через systemd (`cm-filter.service`).

> ℹ️ При обнаружении OpenVZ скрипт автоматически отключает функции, требующие поддержки conntrack и других расширенных возможностей netfilter: SSH_PROTECTION, SYN_PROTECTION, UDP_PROTECTION, ANTI_SCAN и CONN_LIMIT.

## Использование

### Запуск напрямую из GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-nftables.sh | sudo bash -s -- [параметры]
```

Пример запуска с параметрами:

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-nftables.sh \
| sudo bash -s -- --allow-ports 80,443 --allow-udp-ports 51820
```

### Загрузка и локальный запуск

```bash
wget -O configure-nftables.sh https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-nftables.sh
chmod +x configure-nftables.sh
sudo ./configure-nftables.sh [параметры]
```

---

## Параметры

### `--disable-ipv6`

Полностью отключает IPv6-трафик.

```bash
sudo ./configure-nftables.sh --disable-ipv6
```

---

### `--disable-icmp`

Запрещает входящие ICMP echo-request (ping) для IPv4.

```bash
sudo ./configure-nftables.sh --disable-icmp
```

---

### `--disable-icmpv6`

Запрещает входящие ICMPv6 echo-request (ping6).
Трафик NDP и MLD остаётся разрешённым, поскольку необходим для работы IPv6.

```bash
sudo ./configure-nftables.sh --disable-icmpv6
```

---

### `--allow-ports`

Открывает дополнительные входящие TCP-порты.
Порты указываются через запятую.

> ⚠️ SSH-порт определяется и открывается автоматически, указывать его вручную не требуется.

```bash
sudo ./configure-nftables.sh --allow-ports 80,443,8080
```

---

### `--allow-udp-ports`

Открывает дополнительные входящие UDP-порты.
Порты указываются через запятую.

```bash
sudo ./configure-nftables.sh --allow-udp-ports 53,51820
```

---

### `--allow-port-from`

Разрешает доступ к определённым TCP-портам только с указанных адресов.
Для IPv4 используется формат `IP:PORT`, для IPv6 — `[ADDR]:PORT`. Несколько записей перечисляются через запятую.

```bash
sudo ./configure-nftables.sh --allow-port-from 1.2.3.4:443,[2001:db8::1]:8080
```

---

### `--disable-ssh-protection`

Отключает ограничение частоты новых SSH-подключений и механизм автобана.

```bash
sudo ./configure-nftables.sh --disable-ssh-protection
```

---

### `--disable-syn-protection`

Отключает ограничение частоты SYN-пакетов на портах, открытых через `--allow-ports`.

```bash
sudo ./configure-nftables.sh --disable-syn-protection
```

---

### `--disable-udp-protection`

Отключает ограничение частоты UDP-пакетов на портах, открытых через `--allow-udp-ports`.

```bash
sudo ./configure-nftables.sh --disable-udp-protection
```

---

### `--conn-limit`

Ограничивает количество одновременных TCP-соединений с одного IP-адреса на портах, открытых через `--allow-ports`.

```bash
sudo ./configure-nftables.sh --allow-ports 443 --conn-limit 500
```

---

### `--disable-anti-scan`

Отключает обнаружение невалидных TCP-флагов и автобан за попытки сканирования портов.

```bash
sudo ./configure-nftables.sh --disable-anti-scan
```

---

### `--disable-blocklists`

Отключает загрузку и использование внешних блок-листов ([traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists)).

```bash
sudo ./configure-nftables.sh --disable-blocklists
```

---

### `--blocklist-url`

Добавляет собственный URL блок-листа.
Список должен содержать по одному IP-адресу или подсети в каждой строке.

```bash
sudo ./configure-nftables.sh --blocklist-url https://example.com/blocklist.txt
```

---

### `--disable-bogon-filter`

Отключает фильтрацию bogon-адресов на WAN-интерфейсе.

```bash
sudo ./configure-nftables.sh --disable-bogon-filter
```

---

### `--wan-iface`

Позволяет вручную указать WAN-интерфейс вместо автоматического определения.

```bash
sudo ./configure-nftables.sh --wan-iface eth0
```

---

### `--dry-run`

Генерирует и проверяет ruleset без его применения.

```bash
sudo ./configure-nftables.sh --dry-run
```

---

### `-h`, `--help`

Показывает справку по использованию скрипта.

```bash
sudo ./configure-nftables.sh --help
```

</details>

<!-- ======================================== -->
<!-- ====  Docs for configure-sysctl.sh  ==== -->
<!-- ======================================== -->

<details>
<summary>

# Настройка sysctl (configure-sysctl.sh)

</summary>

Описание действий:

1. Обновляет и устанавливает пакеты: ca-certificates, ethtool, iproute2.
2. Определяет тип окружения, WAN-интерфейс, количество процессорных ядер, доступность модулей tcp_bbr и nf_conntrack.
3. Генерирует файл `/etc/sysctl.d/99-node.conf` с параметрами производительности, безопасности и сетевого стека.
4. Настраивает лимиты файловых дескрипторов и процессов через PAM и systemd.
5. Настраивает RPS/RFS/XPS, параметры сетевого интерфейса и создаёт systemd-сервис для их автоматического применения (пропускается в OpenVZ).
6. Отключает Transparent Huge Pages (THP) и создаёт systemd-сервис для сохранения настройки после перезагрузки.
7. Применяет параметры sysctl и выполняет `systemctl daemon-reload`.

## Использование

### Запуск напрямую из GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-sysctl.sh | sudo bash -s -- [параметры]
```

Пример запуска с параметрами:

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-sysctl.sh \
| sudo bash -s -- --disable-ipv6
```

### Загрузка и локальный запуск

```bash
wget -O configure-sysctl.sh https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-sysctl.sh
chmod +x configure-sysctl.sh
sudo ./configure-sysctl.sh [параметры]
```

---

## Параметры

### `--disable-ipv6`

Полностью отключает IPv6 на уровне ядра.

```bash
sudo ./configure-sysctl.sh --disable-ipv6
```

---

### `-h`, `--help`

Показывает справку по использованию скрипта.

```bash
sudo ./configure-sysctl.sh --help
```

</details>
