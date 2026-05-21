Автоматизация **первоначальной настройки** сервера с помощью **bash-скриптов**.

## 📃 Описание

### `configure-iptables.sh`

Настраивает файлы `rules.v4`, `rules.v6` и `ipsets.conf` в соответствии с указанными параметрами. Использует `iptables-persistent` для загрузки правил `iptables` и сервис `ipset-restore.service` для наборов `ipset`.

### `configure-user.sh`

Создаёт непривилегированного пользователя, настраивает SSH-авторизацию по ключу, изменяет порт и другие параметры в `/etc/ssh/sshd_config` для повышения безопасности сервера.

# Настройка `iptables` (`configure-iptables.sh`)

Описание действий:

1. Обновление и установка следующих пакетов: iptables, ipset, iptables-persistent, curl.
2. Загрузка и настройка наборов для `ipset` из репозитория [traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists).
3. Генерация файлов `rules.v4` и `rules.v6` на основе переданных параметров (см. ниже).
4. Применение правил `iptables` из созданных файлов.
5. Настройка автозагрузки `ipset` через `systemd` (сервис `ipset-restore.service`).
6. Перезапуск `docker` (если установлен).

## Запуск

### Напрямую с GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-iptables.sh | sudo bash -- [опции]
```

Пример с аргументами:
```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-iptables.sh \
  | sudo bash -- --allow-icmp --allow-ports 80,443 --allow-ipv6
```

### Локальная загрузка и запуск
```bash
wget -O configure-iptables.sh https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-iptables.sh
chmod +x configure-iptables.sh
sudo ./configure-iptables.sh [опции]
```

---

## Аргументы

### `--allow-icmp`

Разрешает входящий ICMP echo-request (ping) для IPv4.
По умолчанию служебные типы ICMP (destination-unreachable, time-exceeded, parameter-problem) разрешены, а ping — нет.

```bash
sudo ./configure-iptables.sh --allow-icmp
```

---

### `--allow-ports <PORT[,PORT,...]>`

Открывает дополнительные входящие TCP-порты. Порты указываются через запятую. Правила применяются одновременно для IPv4 и IPv6 (если IPv6 включён флагом --allow-ipv6).

> [!WARNING]
> SSH-порт открывается автоматически — указывать его здесь не нужно. Скрипт определяет порт из конфигурации `sshd` (по умолчанию 22).

```bash
sudo ./configure-iptables.sh --allow-ports 80,443,8080
```

---

### `--allow-port-from <IP:PORT[,IP:PORT,...]>`

Разрешает доступ к указанным TCP-портам только с конкретных IPv4-адресов. Каждая запись задаётся в формате IP:PORT, несколько записей — через запятую.

```bash
sudo ./configure-iptables.sh --allow-port-from 1.2.3.4:22,5.6.7.8:443
```

---

### `--allow-ipv6`

Включает IPv6 с полным набором правил (аналогично IPv4: блокировка сканеров через ipset, разрешение установленных соединений, SSH и дополнительных портов).
По умолчанию весь IPv6-трафик дропается.

```bash
sudo ./configure-iptables.sh --allow-ipv6
```

---

### `--allow-icmpv6`

Разрешает ICMPv6 echo-request (ping6). NDP-трафик (Neighbour Discovery) всегда разрешается при активном --allow-ipv6, так как без него IPv6-маршрутизация не работает.
Требует совместного использования с --allow-ipv6. Без него флаг игнорируется с предупреждением.

```bash
sudo ./configure-iptables.sh --allow-ipv6 --allow-icmpv6
```

---

### `-h`, `--help`

Выводит справку по использованию скрипта.

```bash
./configure-iptables.sh --help
```

# Настройка пользователя и SSH (`configure-user.sh`)

Описание действий:

1. Обновление системы.
2. Создание непривилегированного пользователя.
3. Настройка файла `/etc/sudoers` (отключение пароля для созданного пользователя).
4. Настройка маски для новых файлов (umask) и добавление SSH-ключа.
5. Отключение root shell (смена на `/usr/sbin/nologin`).
6. Настройка порта и других опций в `/etc/ssh/sshd_config` на основе переданных параметров.
