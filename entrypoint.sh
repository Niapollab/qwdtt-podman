#!/bin/bash
set -eo pipefail

validate_port() {
    local name="$1" value="$2"
    if [ -z "$value" ]; then
        echo "ERROR: $name is not set." >&2
        exit 1
    fi
    case "$value" in
        ''|*[!0-9]*)
            echo "ERROR: $name must be an integer between 1 and 65535, got: $value" >&2
            exit 1
            ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        echo "ERROR: $name out of range 1..65535, got: $value" >&2
        exit 1
    fi
}

validate_dns() {
    local dns="$1"
    if [ -z "$dns" ]; then
        echo "ERROR: WDTT_DNS_SERVERS is not set." >&2
        exit 1
    fi
}

# 1. Validate required environment variables (defaults are defined in Dockerfile)
validate_port "WDTT_DTLS_PORT" "$WDTT_DTLS_PORT"
validate_port "WDTT_WG_PORT" "$WDTT_WG_PORT"
validate_port "WDTT_ADMIN_PORT" "$WDTT_ADMIN_PORT"
validate_port "WDTT_DIRECT_PORT" "$WDTT_DIRECT_PORT"
validate_port "WDTT_RAW_PORT" "$WDTT_RAW_PORT"
validate_dns "$WDTT_DNS_SERVERS"

WDTT_IFACE="wdtt0"
WDTT_RAW_IFACE="wdttraw0"
WDTT_CONFIG_DIR="/etc/qwdtt"
IPT_COMMENT="WDTT_MANAGED"

mkdir -p "$WDTT_CONFIG_DIR"

# 2. Password check (Mandatory: must be provided via env or already exist in volume)
if [ -n "$WDTT_MAIN_PASSWORD" ]; then
    echo -n "$WDTT_MAIN_PASSWORD" > "$WDTT_CONFIG_DIR/main.password"
    chmod 0600 "$WDTT_CONFIG_DIR/main.password"
elif [ ! -s "$WDTT_CONFIG_DIR/main.password" ]; then
    echo "ERROR: WDTT_MAIN_PASSWORD environment variable is required and cannot be empty." >&2
    echo "Please provide a password via: -e WDTT_MAIN_PASSWORD=<secret>" >&2
    exit 1
fi

# 3. Admin token setup
if [ -n "$WDTT_ADMIN_TOKEN" ]; then
    echo -n "$WDTT_ADMIN_TOKEN" > "$WDTT_CONFIG_DIR/admin.token"
    chmod 0600 "$WDTT_CONFIG_DIR/admin.token"
elif [ ! -f "$WDTT_CONFIG_DIR/admin.token" ]; then
    openssl rand -hex 16 > "$WDTT_CONFIG_DIR/admin.token"
    chmod 0600 "$WDTT_CONFIG_DIR/admin.token"
fi

# 4. Bot token setup
if [ -n "$WDTT_BOT_TOKEN" ]; then
    echo -n "$WDTT_BOT_TOKEN" > "$WDTT_CONFIG_DIR/bot.token"
    chmod 0600 "$WDTT_CONFIG_DIR/bot.token"
fi

# 5. Admin TLS cert generation if missing
if [ ! -s "$WDTT_CONFIG_DIR/admin.crt" ] || [ ! -s "$WDTT_CONFIG_DIR/admin.key" ]; then
    echo "Generating self-signed TLS certificate for Admin API..."
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -keyout "$WDTT_CONFIG_DIR/admin.key" \
        -out "$WDTT_CONFIG_DIR/admin.crt" \
        -subj "/CN=qwdtt-admin" >/dev/null 2>&1
    chmod 0600 "$WDTT_CONFIG_DIR/admin.key" "$WDTT_CONFIG_DIR/admin.crt"
fi

PIN=$(openssl x509 -in "$WDTT_CONFIG_DIR/admin.crt" -outform DER | openssl dgst -sha256 -binary | openssl base64 -A)
echo "WDTT_ADMIN_PIN|sha256/$PIN"
echo "Admin token: $(cat "$WDTT_CONFIG_DIR/admin.token")"

# 6. Determine WAN/default interface for NAT
WAN_IFACE=$(ip route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -z "$WAN_IFACE" ] && WAN_IFACE=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1)
[ -z "$WAN_IFACE" ] && WAN_IFACE="eth0"
echo "Default WAN interface for NAT: $WAN_IFACE"

# 7. Configure iptables firewall & NAT masquerade
if command -v iptables >/dev/null 2>&1; then
    # Masquerade outbound traffic from WDTT subnets (10.66.0.0/16 for WireGuard, 10.70.0.0/16 for RAW)
    for subnet in "10.66.0.0/16" "10.70.0.0/16"; do
        iptables -t nat -C POSTROUTING -s "$subnet" -o "$WAN_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$subnet" -o "$WAN_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || true

        # MSS Clamping
        iptables -t mangle -C FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -I FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -C FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -I FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    done

    # Forwarding rules for WireGuard (wdtt0) and RAW (wdttraw0) interfaces
    for iface in "$WDTT_IFACE" "$WDTT_RAW_IFACE"; do
        iptables -C FORWARD -i "$iface" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -i "$iface" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -o "$iface" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -o "$iface" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
    done
fi

# Clean up old interfaces if exist
for iface in "$WDTT_IFACE" "$WDTT_RAW_IFACE"; do
    ip link show "$iface" >/dev/null 2>&1 && ip link del "$iface" 2>/dev/null || true
done

# 9. Build server arguments
ARGS=(
    "-listen" "0.0.0.0:${WDTT_DTLS_PORT}"
    "-wg-port" "${WDTT_WG_PORT}"
    "-config-dir" "${WDTT_CONFIG_DIR}"
    "-password-file" "${WDTT_CONFIG_DIR}/main.password"
    "-dns" "${WDTT_DNS_SERVERS}"
    "-admin-listen" "0.0.0.0:${WDTT_ADMIN_PORT}"
    "-admin-token-file" "${WDTT_CONFIG_DIR}/admin.token"
    "-admin-cert" "${WDTT_CONFIG_DIR}/admin.crt"
    "-admin-key" "${WDTT_CONFIG_DIR}/admin.key"
    "-listen-direct" "0.0.0.0:${WDTT_DIRECT_PORT}"
    "-listen-raw" "0.0.0.0:${WDTT_RAW_PORT}"
)

if [ -n "$WDTT_ADMIN_ID" ]; then
    ARGS+=("-admin" "${WDTT_ADMIN_ID}")
fi

if [ -s "$WDTT_CONFIG_DIR/bot.token" ]; then
    ARGS+=("-bot-token-file" "${WDTT_CONFIG_DIR}/bot.token")
fi

exec /usr/local/bin/qwdtt "${ARGS[@]}"
