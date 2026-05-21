Automate **initial server setup** using **bash scripts**.

## 🔩 Script descriptions

- `configure-iptables.sh`: configures the `rules.v4`, `rules.v6`, and `ipsets.conf` files according to the specified parameters (uses `iptables-persistent` to load `iptables` rules and `ipset-restore.service` to set `ipsets`);
- `configure-user.sh`: creates a nonroot user, configures SSH key authentication, changes the port and other settings in `/etc/ssh/sshd_config` to improve server security.
