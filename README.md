# QWDTT Container Deployment

Production-ready Podman & Quadlet container deployment for the **WDTT VPN Server**.

---

## 📁 Directory Overview

- **`Dockerfile`**: Builds the Ubuntu 24.04-based container image with `iptables`, `iproute2`, and dependencies.
- **`entrypoint.sh`**: Handles certificate & token generation, sets up iptables NAT/masquerade and MSS clamping for both WireGuard (`10.66.0.0/16`) and RAW (`10.70.0.0/16`) subnets, and launches the server.
- **`qwdtt.container`**: Systemd Quadlet unit file for rootful container execution.
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

## 🚀 Quick Start Deployment

### 1. Obtain the Server Binary
The `server` binary is embedded directly inside the Android client APK (downloadable from [GitHub Releases](https://github.com/SpaceNeuroX/proxy-turn-vk-android/releases/)). If updating or setting up from scratch:
```bash
# Unzip/extract the APK and copy the server binary to this directory:
unzip -p qwdtt.apk assets/server > ./server
chmod +x ./server
```
*(Or copy from the extracted repository root: `cp ../assets/server ./server`)*

### 2. Build the Container Image
From this directory:
```bash
podman build -t localhost/qwdtt:latest .
```

### 3. Configure Environment
Copy `.env` to the system location `/etc/default/qwdtt` and set a strong master password:
```bash
sudo cp .env /etc/default/qwdtt
sudo chmod 0600 /etc/default/qwdtt
```
Edit `/etc/default/qwdtt` to uncomment and set `WDTT_MAIN_PASSWORD`:
```ini
# REQUIRED: Uncomment and set your master password
WDTT_MAIN_PASSWORD=your_super_secret_password

WDTT_DNS_SERVERS=1.1.1.1,1.0.0.1

# Optional Telegram management bot:
# WDTT_BOT_TOKEN=123456789:ABC...
# WDTT_ADMIN_ID=987654321
```

### 4. Install the Quadlet Service
Copy `qwdtt.container` to the systemd Quadlet directory:
```bash
sudo cp qwdtt.container /etc/containers/systemd/
```

### 5. Enable Host IP Forwarding (Kernel)
VPN tunneling requires packet forwarding on the host machine:
```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ipforward.conf
sudo sysctl --system
```

### 6. Start the Service
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now qwdtt.service
```

Check the status:
```bash
sudo systemctl status qwdtt.service
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
sudo journalctl -u qwdtt.service -n 50 --no-pager
```
Look for:
```text
WDTT_ADMIN_PIN|sha256/...
Admin token: ...
```

---

## ⚙️ Maintenance & Updates

- **Restarting the service:**
  ```bash
  sudo systemctl restart qwdtt.service
  ```
- **Viewing live logs:**
  ```bash
  sudo journalctl -u qwdtt.service -f
  ```
- **Updating configuration:**
  Edit `/etc/default/qwdtt`, then run `sudo systemctl restart qwdtt.service`.
- **Rebuilding after script edits:**
  ```bash
  podman build -t localhost/qwdtt:latest .
  sudo systemctl restart qwdtt.service
  ```
