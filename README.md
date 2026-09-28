# QWDTT Container Deployment

Production-ready Podman & Quadlet container deployment for the **WDTT VPN Server**.

---

## 📁 Directory Overview

- **`Dockerfile`**: Builds the Ubuntu 24.04-based container image with `iptables`, `iproute2`, and dependencies.
- **`entrypoint.sh`**: Handles certificate & token generation, sets up iptables NAT/masquerade and MSS clamping for both WireGuard (`10.66.0.0/16`) and RAW (`10.70.0.0/16`) subnets, and launches the server.
- **`qwdtt.container`**: Systemd Quadlet unit file for rootless service user container execution.
- **`create_service_user.sh`**: Helper script to create the dedicated system service user with lingering and subuid/subgid mapping.
- **`.env`**: Template configuration file containing default ports, secrets, and optional parameters.
- **`server`**: Precompiled WDTT server binary (obtained by unpacking the client Android APK from `assets/server`).

---

## 🔌 Port Mapping

| Port | Protocol | Scope | Description |
| :--- | :--- | :--- | :--- |
| **56000** | UDP & TCP | Public | DTLS listen port (`WDTT_DTLS_PORT`) |
| **56001** | UDP | Public | WireGuard UDP listen port (`WDTT_WG_PORT`) |
| **56002** | UDP & TCP | Public | DIRECT listen port (`WDTT_DIRECT_PORT`) |
| **56003** | UDP | Public | RAW listen port (`WDTT_RAW_PORT`) |
| **56004** | TCP | **127.0.0.1** (Localhost only) | HTTPS Admin API (`WDTT_ADMIN_PORT`) |

---

## 🚀 Rootless Service User Deployment

This repository uses a dedicated system service user (`qwdtt`) running Podman in user space with systemd lingering and Quadlet.

### 1. Create the Service User
A helper script [create_service_user.sh](./create_service_user.sh) is provided to configure the system service user with non-overlapping subuid/subgid ranges and linger mode:

```bash
./create_service_user.sh qwdtt
```

### 2. Obtain the Server Binary
The `server` binary is embedded directly inside the Android client APK (downloadable from [GitHub Releases](https://github.com/SpaceNeuroX/proxy-turn-vk-android/releases/)).
```bash
# Unzip/extract the APK and copy the server binary to this directory:
unzip -p qwdtt.apk assets/server > ./server
chmod +x ./server
```
*(Or copy from the extracted repository root: `cp ../assets/server ./server`)*

### 3. Build the Container Image
Build the image as the `qwdtt` user:
```bash
sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" podman build -t localhost/qwdtt:latest $(pwd)
```

### 4. Configure Environment
Copy `.env` to `/var/lib/qwdtt/config` and set secure permissions:
```bash
sudo cp .env /var/lib/qwdtt/config
sudo chown qwdtt:qwdtt /var/lib/qwdtt/config
sudo chmod 0600 /var/lib/qwdtt/config
```
Edit `/var/lib/qwdtt/config` to uncomment and set `WDTT_MAIN_PASSWORD`:
```ini
# REQUIRED: Uncomment and set your master password
WDTT_MAIN_PASSWORD=your_super_secret_password

WDTT_DNS_SERVERS=1.1.1.1,1.0.0.1

# Optional Telegram management bot:
# WDTT_BOT_TOKEN=123456789:ABC...
# WDTT_ADMIN_ID=987654321
```

### 5. Install the User Quadlet Unit
Place `qwdtt.container` into the user Quadlet directory `/var/lib/qwdtt/.config/containers/systemd/`:
```bash
sudo mkdir -p /var/lib/qwdtt/.config/containers/systemd/
sudo cp qwdtt.container /var/lib/qwdtt/.config/containers/systemd/
sudo chown -R qwdtt:qwdtt /var/lib/qwdtt/.config
```

### 6. Enable Host IP Forwarding (Kernel)
VPN tunneling requires packet forwarding on the host machine:
```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ipforward.conf
sudo sysctl --system
```

### 7. Start the Service
Reload the user systemd daemon and start `qwdtt.service`:
```bash
sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" systemctl --user daemon-reload
sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" systemctl --user enable --now qwdtt.service
```

Check the status:
```bash
sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" systemctl --user status qwdtt.service
```

---

## 🛡️ Host Firewall Configuration (iptables)

If your host has default policies set to `DROP` (`-P INPUT DROP` and `-P FORWARD DROP`), run the following commands to create dedicated chains:

```bash
# 1. Create chains
sudo iptables -N INPUT_QWDTT
sudo iptables -N FORWARD_QWDTT

# 2. Allow inbound VPN client traffic
sudo iptables -A INPUT_QWDTT -p udp -m multiport --dports 56000,56001,56002,56003 -j ACCEPT
sudo iptables -A INPUT_QWDTT -p tcp -m multiport --dports 56000,56002 -j ACCEPT

# 3. Allow incoming connections forwarded from outside network (ens3) to container ports on podman0
sudo iptables -A FORWARD_QWDTT -i ens3 -o podman0 -p udp -m multiport --dports 56000,56001,56002,56003 -j ACCEPT
sudo iptables -A FORWARD_QWDTT -i ens3 -o podman0 -p tcp -m multiport --dports 56000,56002 -j ACCEPT

# 4. Attach chains to INPUT and FORWARD
sudo iptables -I INPUT 3 -j INPUT_QWDTT
sudo iptables -A FORWARD -j FORWARD_QWDTT
```
> [!NOTE]
> Outbound internet traffic (`podman0 -> ens3`) and return established connections (`ens3 -> podman0`) are already handled by Podman's built-in `NETAVARK_FORWARD` chain. `FORWARD_QWDTT` only needs to accept new incoming client connections to the published ports.
> *(Adjust `ens3` if your WAN interface name differs).*

---

## 🔑 Retrieving Admin PIN & Token

On initial startup, `qwdtt` generates an admin TLS certificate and an admin token inside persistent volume `qwdtt-cfg`.

View them via journal logs:
```bash
sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" journalctl --user -u qwdtt.service -n 50 --no-pager
```
Look for:
```text
WDTT_ADMIN_PIN|sha256/...
Admin token: ...
```

---

## ⚙️ Maintenance & Updates

- **Interactive bash shell as `qwdtt`:**
  ```bash
  sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" /bin/bash
  ```
- **Restarting the service:**
  ```bash
  sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" systemctl --user restart qwdtt.service
  ```
- **Viewing live logs:**
  ```bash
  sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" journalctl --user -u qwdtt.service -f
  ```
- **Updating configuration:**
  Edit `/var/lib/qwdtt/config`, then restart the user service.
- **Rebuilding after script edits:**
  ```bash
  sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" podman build -t localhost/qwdtt:latest $(pwd)
  sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" systemctl --user restart qwdtt.service
  ```
