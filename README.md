Automate **initial server setup** using **bash scripts**.

## 🔩 Script descriptions

- `configure-iptables.sh`: configures the `rules.v4`, `rules.v6`, and `ipsets.conf` files according to the specified parameters (uses `iptables-persistent` to load `iptables` rules and `ipset-restore.service` to set `ipsets`);
- `configure-user.sh`: creates a nonroot user, configures SSH key authentication, changes the port and other settings in `/etc/ssh/sshd_config` to improve server security.

# 📌 Usage

## Configuring `iptables` (`configure-iptables.sh`)

Description of actions:

1. Update and install the following packages: iptables, ipset, iptables-persistent, curl.
2. Download and configure `ipset` sets from the [traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists) repository.
3. Generate `rules.v4` and `rules.v6` files based on the passed parameters (see below).
4. Apply `iptables` rules from the generated files.
5. Configure `ipset` to autoload via `systemd` (the `ipset-restore.service` service).
6. Restart `docker` (if installed).

## Configuring the user and SSH (`configure-user.sh`)

Description of actions:

1. Update the system.
2. Create an unprivileged user.
3. Configure the `/etc/sudoers` file (disable the password for the created user).
4. Configure the mask for new files (umask) and add an SSH key.
5. Disable the root shell (change to `/usr/sbin/nologin`).
6. Configure the port and other options in `/etc/ssh/sshd_config` based on the passed parameters.
