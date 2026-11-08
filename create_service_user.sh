#!/usr/bin/env bash
set -euo pipefail

create_podman_service_user() {
    local NEW_USER="${1:-}"

    if [ -z "$NEW_USER" ]; then
        echo "[!] Username cannot be empty." >&2
        echo "[*] Usage: create_podman_service_user <username>"
        return 1
    fi

    echo "[*] Creating system service user: $NEW_USER"
    sudo useradd -r -m -d "/var/lib/$NEW_USER" -s /sbin/nologin "$NEW_USER"

    echo "[*] Assigning non-overlapping subuid/subgid ranges"
    sudo awk '-F[:-]' -v user="$NEW_USER" 'NR>0 {if ($2+ $3 > max) max = $2 + $3} END {print user ":" max ":" 65536}' /etc/subuid | sudo tee -a /etc/subuid
    sudo awk '-F[:-]' -v user="$NEW_USER" 'NR>0 {if ($2+ $3 > max) max = $2 + $3} END {print user ":" max ":" 65536}' /etc/subgid | sudo tee -a /etc/subgid

    echo "[*] Enabling systemd lingering"
    sudo loginctl enable-linger "$NEW_USER"

    echo "[*] Initializing user bus and systemd manager"
    local uid
    uid=$(id -u "$NEW_USER")

    # Explicitly start the user's systemd manager instance (required for non-login nologin shells)
    sudo systemctl start "user@$uid.service"

    # Enable and start the Podman socket for the user
    sudo runuser -u "$NEW_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" systemctl --user enable --now podman.socket

    echo "[*] Success! Service user '$NEW_USER' is ready."
    echo "    Home path: /var/lib/$NEW_USER"
    echo "    To run commands as this user, use:"
    echo "      sudo runuser -u $NEW_USER -- env XDG_RUNTIME_DIR=\"/run/user/$uid\" DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/$uid/bus\" /bin/bash"
}

create_podman_service_user "$@"
