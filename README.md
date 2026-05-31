Automate **initial server setup** using **bash scripts**.

## 📃 Description

### `configure-iptables.sh` / [Go](#configuring-iptables-configure-iptablessh)

Configures the `rules.v4`, `rules.v6`, and `ipsets.conf` files according to the specified parameters (uses `iptables-persistent` to load `iptables` rules and `ipset-restore.service` to `ipset` sets);

### `configure-user.sh` / [Go](#configuring-the-user-and-ssh-configure-usersh)

Creates a nonroot user, configures SSH key authentication, changes the port and other settings in `/etc/ssh/sshd_config` to improve server security.

# Configuring `iptables` (`configure-iptables.sh`)

Description of actions:

1. Update and install the following packages: iptables, ipset, iptables-persistent, curl.
2. Download and configure `ipset` sets from the [traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists) repository.
3. Generate `rules.v4` and `rules.v6` files based on the passed parameters (see below).
4. Apply `iptables` rules from the generated files.
5. Configure `ipset` to autoload via `systemd` (the `ipset-restore.service` service).
6. Restart `docker` (if installed).

## Usage

### Run directly from GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-iptables.sh | sudo bash -s -- [options]
```

Example with arguments:

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-iptables.sh \
  | sudo bash -s -- --allow-icmp --allow-ports 80,443 --allow-ipv6
```

### Download and run locally

```bash
wget -O configure-iptables.sh https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-iptables.sh
chmod +x configure-iptables.sh
sudo ./configure-iptables.sh [options]
```

---

## Arguments

### `--allow-icmp`

Allows incoming ICMP echo-request (ping) for IPv4.
By default, service ICMP types (destination-unreachable, time-exceeded, parameter-problem) are allowed, while ping is not.

```bash
sudo ./configure-iptables.sh --allow-icmp
```

---

### `--allow-ports <PORT[,PORT,...]>`

Opens additional incoming TCP ports. Ports are specified as a comma-separated list. Rules are applied to both IPv4 and IPv6 (if IPv6 is enabled via `--allow-ipv6`).

> [!WARNING]
> The SSH port is opened automatically — there is no need to specify it here. The script detects the port from the `sshd` configuration (default: 22).

```bash
sudo ./configure-iptables.sh --allow-ports 80,443,8080
```

---

### `--allow-port-from <IP:PORT[,IP:PORT,...]>`

Restricts access to specific TCP ports to the given IPv4 addresses only. Each entry is specified in `IP:PORT` format; multiple entries are separated by commas.

```bash
sudo ./configure-iptables.sh --allow-port-from 1.2.3.4:22,5.6.7.8:443
```

---

### `--allow-ipv6`

Enables IPv6 with a full set of rules (mirroring IPv4: scanner blocklist via ipset, allowing established connections, SSH, and additional ports).
By default, all IPv6 traffic is dropped.

```bash
sudo ./configure-iptables.sh --allow-ipv6
```

---

### `--allow-icmpv6`

Allows ICMPv6 echo-request (ping6). NDP traffic (Neighbour Discovery) is always allowed when `--allow-ipv6` is active, as IPv6 routing requires it.
Must be used together with `--allow-ipv6`. Without it, this flag is ignored with a warning.

```bash
sudo ./configure-iptables.sh --allow-ipv6 --allow-icmpv6
```

---

### `-h`, `--help`

Prints usage information.

```bash
./configure-iptables.sh --help
```

# Configuring the user and SSH (`configure-user.sh`)

Description of actions:

1. Update the system.
2. Create an unprivileged user.
3. Configure the `/etc/sudoers` file (disable the password for the created user).
4. Configure the mask for new files (umask) and add an SSH key.
5. Disable the root shell (change to `/usr/sbin/nologin`).
6. Configure the port and other options in `/etc/ssh/sshd_config` based on the passed parameters.

## Usage

### Run directly from GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-user.sh | sudo bash -s -- <username> <public_key> <ssh_port>
```

### Download and run locally
 
```bash
wget -O configure-user.sh https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-user.sh
chmod +x configure-user.sh
sudo ./configure-user.sh <username> <public_key> <ssh_port>
```

---

## Parameters

The script accepts exactly three mandatory positional parameters, in the order listed below.

### `<username>`

The name of the user to create. If the user already exists, the creation step is skipped.

```bash
sudo ./configure-user.sh myuser <public_key> <ssh_port>
```

---

### `<public_key>`

The SSH public key to add to the user's `~/.ssh/authorized_keys`. Supported key types: `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`. The key must be passed in quotes.

```bash
sudo ./configure-user.sh <username> 'ssh-ed25519 AAAA...xyz user@host' <ssh_port>
```

---

### `<ssh_port>`

The new port on which the SSH server will listen. Must be a number between 1 and 65535 and must not already be in use by another process.

> [!WARNING]
> Once the script completes, SSH will only be accessible on the specified port. Do not close the current session without verifying the connection in a new terminal first.

```bash
sudo ./configure-user.sh <username> <public_key> 8132
```
