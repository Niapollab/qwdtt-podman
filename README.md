# QWDTT & CSQTT Container Deployment

Production-ready Podman & Quadlet container deployment for **QWDTT** and **CSQTT** (`v2.5.0-legacy`) VPN servers.

---

## 📁 Repository Structure

```text
.
├── create_service_user.sh   # Helper script to create dedicated rootless Podman service users
├── qwdtt/                   # QWDTT VPN Server container files
│   ├── Containerfile
│   ├── config
│   ├── entrypoint.sh
│   └── qwdtt.container
└── csqtt/                   # CSQTT VPN Server (v2.5.0-legacy) container files
    ├── Containerfile
    ├── config
    ├── entrypoint.sh
    └── csqtt.container
```

---

## 🔌 Port Mapping

### QWDTT (`qwdtt/`)

| Port | Protocol | Scope | Description |
| :--- | :--- | :--- | :--- |
| **56000** | UDP & TCP | Public | DTLS listen port (`WDTT_DTLS_PORT`) |
| **56001** | UDP | Public | WireGuard UDP listen port (`WDTT_WG_PORT`) |
| **56002** | UDP & TCP | Public | DIRECT listen port (`WDTT_DIRECT_PORT`) |
| **56003** | UDP | Public | RAW listen port (`WDTT_RAW_PORT`) |
| **56004** | TCP | **127.0.0.1** (Localhost only) | HTTPS Admin API (`WDTT_ADMIN_PORT`) |

### CSQTT (`csqtt/`)

| Port | Protocol | Scope | Description |
| :--- | :--- | :--- | :--- |
| **46000** | UDP | Public | RTP AEAD / Peer listen port (`CSQTT_PEER_PORT`) |
| **46002** | TCP | **127.0.0.1** (Localhost only) | HTTPS Web Panel (`CSQTT_WEB_PORT`) |

---

## 🚀 Rootless Service User Deployment

Each server runs under its own dedicated system service user (`qwdtt` and/or `csqtt`) using rootless Podman with systemd lingering and Quadlet.

### 1. Enable Host IP Forwarding (Kernel)
VPN tunneling requires packet forwarding on the host machine:
```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ipforward.conf
sudo sysctl --system
```

---

### Option A: Deploying QWDTT

#### 1. Create the `qwdtt` Service User
```bash
./create_service_user.sh qwdtt
```

#### 2. Obtain the QWDTT Server Binary
Extract `assets/server` from the QWDTT Android client APK ([GitHub Releases](https://github.com/SpaceNeuroX/proxy-turn-vk-android/releases/)) into `./qwdtt/server`:
```bash
unzip -p qwdtt.apk assets/server > ./qwdtt/server
chmod +x ./qwdtt/server
```

#### 3. Build the QWDTT Container Image
```bash
sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" podman build -t localhost/qwdtt:latest $(pwd)/qwdtt
```

#### 4. Configure QWDTT Environment
```bash
sudo mkdir -p /var/lib/qwdtt/.config/qwdtt
sudo cp ./qwdtt/config /var/lib/qwdtt/.config/qwdtt/config
sudo chown -R qwdtt:qwdtt /var/lib/qwdtt/.config
sudo chmod 0600 /var/lib/qwdtt/.config/qwdtt/config
```
Edit `/var/lib/qwdtt/.config/qwdtt/config` and set `WDTT_MAIN_PASSWORD`.

#### 5. Install and Start the QWDTT Quadlet Unit
```bash
sudo mkdir -p /var/lib/qwdtt/.config/containers/systemd/
sudo cp ./qwdtt/qwdtt.container /var/lib/qwdtt/.config/containers/systemd/
sudo chown -R qwdtt:qwdtt /var/lib/qwdtt/.config

sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" systemctl --user daemon-reload
sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" systemctl --user enable --now qwdtt.service
```

---

### Option B: Deploying CSQTT (`v2.5.0-legacy`)

#### 1. Create the `csqtt` Service User
```bash
./create_service_user.sh csqtt
```

#### 2. Obtain the CSQTT Server Binary
Extract `assets/csqtt-linux-amd64` (or `assets/csqtt-linux-arm64` / `assets/csqtt-linux-armv7`) from the CSQTT Android client APK ([MRTT v2.5.0-legacy Releases](https://github.com/ttrroyy/MRTT/releases/tag/v2.5.0-legacy)) into `./csqtt/server`:
```bash
unzip -p CSQTT-arm64-v8a.apk assets/csqtt-linux-amd64 > ./csqtt/server
chmod +x ./csqtt/server
```

#### 3. Build the CSQTT Container Image
```bash
sudo runuser -u csqtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u csqtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u csqtt)/bus" podman build -t localhost/csqtt:latest $(pwd)/csqtt
```

#### 4. Configure CSQTT Environment
```bash
sudo mkdir -p /var/lib/csqtt/.config/csqtt
sudo cp ./csqtt/config /var/lib/csqtt/.config/csqtt/config
sudo chown -R csqtt:csqtt /var/lib/csqtt/.config
sudo chmod 0600 /var/lib/csqtt/.config/csqtt/config
```
Edit `/var/lib/csqtt/.config/csqtt/config` and set `CSQTT_MAIN_PASSWORD` (and optionally `CSQTT_WEB_PASS` and `CSQTT_PUBLIC_IP`).

#### 5. Install and Start the CSQTT Quadlet Unit
```bash
sudo mkdir -p /var/lib/csqtt/.config/containers/systemd/
sudo cp ./csqtt/csqtt.container /var/lib/csqtt/.config/containers/systemd/
sudo chown -R csqtt:csqtt /var/lib/csqtt/.config

sudo runuser -u csqtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u csqtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u csqtt)/bus" systemctl --user daemon-reload
sudo runuser -u csqtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u csqtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u csqtt)/bus" systemctl --user enable --now csqtt.service
```

---

## 🛡️ Host Firewall Configuration (iptables)

If your host has default policies set to `DROP` (`-P INPUT DROP` and `-P FORWARD DROP`), run the following commands for the deployed services:

### For QWDTT
```bash
sudo iptables -N INPUT_QWDTT
sudo iptables -N FORWARD_QWDTT

sudo iptables -A INPUT_QWDTT -p udp -m multiport --dports 56000,56001,56002,56003 -j ACCEPT
sudo iptables -A INPUT_QWDTT -p tcp -m multiport --dports 56000,56002 -j ACCEPT

sudo iptables -A FORWARD_QWDTT -i ens3 -o podman0 -p udp -m multiport --dports 56000,56001,56002,56003 -j ACCEPT
sudo iptables -A FORWARD_QWDTT -i ens3 -o podman0 -p tcp -m multiport --dports 56000,56002 -j ACCEPT

sudo iptables -I INPUT 3 -j INPUT_QWDTT
sudo iptables -A FORWARD -j FORWARD_QWDTT
```

### For CSQTT
```bash
sudo iptables -N INPUT_CSQTT
sudo iptables -N FORWARD_CSQTT

sudo iptables -A INPUT_CSQTT -p udp --dport 46000 -j ACCEPT
sudo iptables -A FORWARD_CSQTT -i ens3 -o podman0 -p udp --dport 46000 -j ACCEPT

sudo iptables -I INPUT 3 -j INPUT_CSQTT
sudo iptables -A FORWARD -j FORWARD_CSQTT
```
> [!NOTE]
> Outbound internet traffic (`podman0 -> ens3`) and return established connections (`ens3 -> podman0`) are already handled by Podman's built-in `NETAVARK_FORWARD` chain.
> *(Adjust `ens3` if your WAN interface name differs).*

---

## 🔑 Retrieving Credentials & TLS Pins

### QWDTT Admin PIN & Token
```bash
sudo runuser -u qwdtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u qwdtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u qwdtt)/bus" journalctl --user -u qwdtt.service -n 50 --no-pager
```
Look for `WDTT_ADMIN_PIN|sha256/...` and `Admin token: ...`.

### CSQTT Web Panel Credentials & TLS Pin
```bash
sudo runuser -u csqtt -- env XDG_RUNTIME_DIR="/run/user/$(id -u csqtt)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u csqtt)/bus" journalctl --user -u csqtt.service -n 50 --no-pager
```
Look for `CSQTT_WEB_CERT_PIN|sha256/...`, `Web panel user: ...`, and `Web panel password: ...`.

---

## ⚙️ Maintenance & Updates

Replace `<service>` with `qwdtt` or `csqtt`:

- **Interactive bash shell as `<service>`:**
  ```bash
  sudo runuser -u <service> -- env XDG_RUNTIME_DIR="/run/user/$(id -u <service>)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u <service>)/bus" /bin/bash
  ```
- **Restarting the service:**
  ```bash
  sudo runuser -u <service> -- env XDG_RUNTIME_DIR="/run/user/$(id -u <service>)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u <service>)/bus" systemctl --user restart <service>.service
  ```
- **Viewing live logs:**
  ```bash
  sudo runuser -u <service> -- env XDG_RUNTIME_DIR="/run/user/$(id -u <service>)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u <service>)/bus" journalctl --user -u <service>.service -f
  ```
- **Updating configuration:**
  Edit `/var/lib/<service>/.config/<service>/config`, then restart the user service.
- **Rebuilding after script or binary updates:**
  ```bash
  sudo runuser -u <service> -- env XDG_RUNTIME_DIR="/run/user/$(id -u <service>)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u <service>)/bus" podman build -t localhost/<service>:latest $(pwd)/<service>
  sudo runuser -u <service> -- env XDG_RUNTIME_DIR="/run/user/$(id -u <service>)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u <service>)/bus" systemctl --user restart <service>.service
  ```
