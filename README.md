Automate **initial server setup** using **bash scripts**.

## 📃 Description

### configure-iptables.sh / [Go](#configuring-iptables-configure-iptablessh)

Configures the `rules.v4`, `rules.v6`, and `ipsets.conf` files according to the specified parameters (uses iptables-persistent to load iptables rules and `ipset-restore.service` to ipset sets);

### configure-user.sh / [Go](#configuring-the-user-and-ssh-configure-usersh)

Creates a nonroot user, configures SSH key authentication, changes the port and other settings in `/etc/ssh/sshd_config` to improve server security.

### configure-nftables.sh / [Go](#configuring-nftables-configure-nftablessh)

Configures an nftables ruleset with automatic SSH detection, per-IP rate limits, autoban mechanisms, anti-scan protection, bogon filtering, and optional blocklists. Generates `/etc/nftables.d/cm_filter.nft`, applies the rules, validates the configuration before activation, and enables automatic loading through systemd.

### configure-sysctl.sh / [Go](#configuring-sysctl-configure-sysctlsh)

Configures Linux kernel (sysctl) parameters, file descriptor and process limits, network stack performance, RPS/RFS/XPS, and optimizes network interface and memory settings. Automatically detects the environment (including OpenVZ), applies the configuration, and ensures it persists across reboots.

<!-- ========================================== -->
<!-- ====  Docs for configure-iptables.sh  ==== -->
<!-- ========================================== -->

<details>
<summary>

# Configuring iptables (configure-iptables.sh)

</summary>

Description of actions:

1. Update and install the following packages: iptables, ipset, iptables-persistent, curl.
2. Download and configure ipset sets from the [traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists) repository.
3. Generate `rules.v4` and `rules.v6` files based on the passed parameters (see below).
4. Apply iptables rules from the generated files.
5. Configure ipset to autoload via systemd (the `ipset-restore.service` service).
6. Restart docker (if installed).

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

> ⚠️ The SSH port is opened automatically — there is no need to specify it here. The script detects the port from the sshd configuration (default: 22).

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

</details>

<!-- ====================================== -->
<!-- ====  Docs for configure-user.sh  ==== -->
<!-- ====================================== -->

<details>
<summary>

# Configuring the user and SSH (`configure-user.sh`)

</summary>

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

> ⚠️ Once the script completes, SSH will only be accessible on the specified port. Do not close the current session without verifying the connection in a new terminal first.

```bash
sudo ./configure-user.sh <username> <public_key> 8132
```

</details>

<!-- ========================================== -->
<!-- ====  Docs for configure-nftables.sh  ==== -->
<!-- ========================================== -->

<details>
<summary>

# Configuring nftables (configure-nftables.sh)

</summary>

Description of actions:

1. Update and install the following packages: nftables, curl, ca-certificates, iproute2.
2. Detect the SSH port from the current sshd configuration.
3. Detect the WAN interface (used by the bogon filter).
4. Download and configure blocklists from the [traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists) repository (unless disabled).
5. Generate an nftables ruleset based on the passed parameters (see below).
6. Validate the generated ruleset using `nft -c`.
7. Apply the generated ruleset.
8. Configure automatic loading through systemd (`cm-filter.service`).

## Usage

### Run directly from GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-nftables.sh | sudo bash -s -- [options]
```

Example with arguments:

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-nftables.sh \
| sudo bash -s -- --allow-ports 80,443 --allow-udp-ports 51820
```

### Download and run locally

```bash
wget -O configure-nftables.sh https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-nftables.sh
chmod +x configure-nftables.sh
sudo ./configure-nftables.sh [options]
```

---

## Arguments

### `--disable-ipv6`

Completely disables IPv6 traffic.

```bash
sudo ./configure-nftables.sh --disable-ipv6
```

---

### `--disable-icmp`

Disables incoming ICMP echo-request (ping) for IPv4.

```bash
sudo ./configure-nftables.sh --disable-icmp
```

---

### `--disable-icmpv6`

Disables incoming ICMPv6 echo-request (ping6).
NDP and MLD traffic remain allowed because IPv6 requires them.

```bash
sudo ./configure-nftables.sh --disable-icmpv6
```

---

### `--allow-ports`

Opens additional incoming TCP ports.
Ports are specified as a comma-separated list.

> ⚠️ The SSH port is opened automatically and does not need to be specified.

```bash
sudo ./configure-nftables.sh --allow-ports 80,443,8080
```

---

### `--allow-udp-ports`

Opens additional incoming UDP ports.
Ports are specified as a comma-separated list.

```bash
sudo ./configure-nftables.sh --allow-udp-ports 53,51820
```

---

### `--allow-port-from`

Restricts access to specific TCP ports to selected addresses.
IPv4 entries use the `IP:PORT` format, while IPv6 entries use `[ADDR]:PORT`. Multiple entries are separated by commas.

```bash
sudo ./configure-nftables.sh --allow-port-from 1.2.3.4:443,[2001:db8::1]:8080
```

---

### `--disable-ssh-protection`

Disables per-IP SSH rate limiting and automatic banning.

```bash
sudo ./configure-nftables.sh --disable-ssh-protection
```

---

### `--disable-syn-protection`

Disables per-IP SYN rate limiting on ports opened through `--allow-ports`.

```bash
sudo ./configure-nftables.sh --disable-syn-protection
```

---

### `--disable-udp-protection`

Disables per-IP rate limiting on ports opened through `--allow-udp-ports`.

```bash
sudo ./configure-nftables.sh --disable-udp-protection
```

---

### `--conn-limit`

Limits the number of simultaneous TCP connections per source IP on ports opened through `--allow-ports`.

```bash
sudo ./configure-nftables.sh --allow-ports 443 --conn-limit 500
```

---

### `--disable-anti-scan`

Disables invalid TCP flag detection and automatic banning for port scanning attempts.

```bash
sudo ./configure-nftables.sh --disable-anti-scan
```

---

### `--disable-blocklists`

Disables downloading and using external blocklists ([traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists)).

```bash
sudo ./configure-nftables.sh --disable-blocklists
```

---

### `--blocklist-url`

Adds a custom blocklist URL.
The list must contain one network or IP address per line.

```bash
sudo ./configure-nftables.sh --blocklist-url https://example.com/blocklist.txt
```

---

### `--disable-bogon-filter`

Disables filtering of bogon and private source addresses on the WAN interface.

```bash
sudo ./configure-nftables.sh --disable-bogon-filter
```

---

### `--wan-iface`

Overrides automatic WAN interface detection.

```bash
sudo ./configure-nftables.sh --wan-iface eth0
```

---

### `--dry-run`

Generates and validates the ruleset without applying it.

```bash
sudo ./configure-nftables.sh --dry-run
```

---

### `-h`, `--help`

Prints usage information.

```bash
sudo ./configure-nftables.sh --help
```

</details>

<!-- ======================================== -->
<!-- ====  Docs for configure-sysctl.sh  ==== -->
<!-- ======================================== -->

<details>
<summary>

# Configuring sysctl (configure-sysctl.sh)

</summary>

Description of actions:

1. Updates and installs the following packages: ca-certificates, ethtool, iproute2.
2. Detects the environment type, WAN interface, the number of CPU cores, and the availability of the tcp_bbr and nf_conntrack kernel modules.
3. Generates the `/etc/sysctl.d/99-node.conf` file containing performance, security, and network stack parameters.
4. Configures file descriptor and process limits through PAM and systemd.
5. Configures RPS/RFS/XPS, tunes the network interface, and creates a systemd service to apply these settings automatically (skipped on OpenVZ).
6. Disables Transparent Huge Pages (THP) and creates a systemd service to keep this setting after reboot.
7. Applies the sysctl configuration and runs `systemctl daemon-reload`.

## Usage

### Run directly from GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-sysctl.sh | sudo bash -s -- [options]
```

Example with arguments:

```bash
curl -fsSL https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-sysctl.sh \
| sudo bash -s -- --disable-ipv6
```

### Download and run locally

```bash
wget -O configure-sysctl.sh https://raw.githubusercontent.com/assailance/server-scripts/refs/heads/master/configure-sysctl.sh
chmod +x configure-sysctl.sh
sudo ./configure-sysctl.sh [options]
```

---

## Arguments

### `--disable-ipv6`

Completely disables IPv6 at the kernel level.

```bash
sudo ./configure-sysctl.sh --disable-ipv6
```

---

### `-h`, `--help`

Prints usage information.

```bash
sudo ./configure-sysctl.sh --help
```

</details>
