Автоматизация **первоначальной настройки** сервера с помощью **bash-скриптов**.

## 🔩 Описание скриптов

- `configure-iptables.sh`: настраивает файлы `rules.v4`, `rules.v6` и `ipsets.conf` в соответствии с указанными параметрами (использует `iptables-persistent` для загрузки правил `iptables` и сервис `ipset-restore.service` для наборов `ipset`).
