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
        echo "ERROR: CSQTT_DNS is not set." >&2
        exit 1
    fi
}

# Defaults if not provided by environment
CSQTT_PEER_PORT="${CSQTT_PEER_PORT:-46000}"
CSQTT_WEB_PORT="${CSQTT_WEB_PORT:-46002}"
CSQTT_DNS="${CSQTT_DNS:-1.1.1.1,1.0.0.1}"
CSQTT_WEB_USER="${CSQTT_WEB_USER:-admin}"

# 1. Validate required environment variables
validate_port "CSQTT_PEER_PORT" "$CSQTT_PEER_PORT"
validate_port "CSQTT_WEB_PORT" "$CSQTT_WEB_PORT"
validate_dns "$CSQTT_DNS"

if [ "$CSQTT_PEER_PORT" = "$CSQTT_WEB_PORT" ]; then
    echo "ERROR: CSQTT_PEER_PORT cannot be equal to CSQTT_WEB_PORT ($CSQTT_PEER_PORT)." >&2
    exit 1
fi

CSQTT_IFACE="csqtt1"
CSQTT_SUBNET="10.66.67.0/24"
CSQTT_SUBNET6="fd66:67::/64"
CSQTT_CONFIG_DIR="/etc/csqtt"
IPT_COMMENT="CSQTT_MANAGED"

mkdir -p "$CSQTT_CONFIG_DIR"
chmod 0700 "$CSQTT_CONFIG_DIR"

# 2. Main password check (Mandatory on first run: must be provided via env or persisted in volume)
if [ -n "${CSQTT_MAIN_PASSWORD:-}" ]; then
    echo -n "$CSQTT_MAIN_PASSWORD" > "$CSQTT_CONFIG_DIR/main.password"
    chmod 0600 "$CSQTT_CONFIG_DIR/main.password"
elif [ -s "$CSQTT_CONFIG_DIR/main.password" ]; then
    CSQTT_MAIN_PASSWORD="$(cat "$CSQTT_CONFIG_DIR/main.password")"
elif [ ! -s "$CSQTT_CONFIG_DIR/csqtt.db" ]; then
    echo "ERROR: CSQTT_MAIN_PASSWORD environment variable is required and cannot be empty." >&2
    echo "Please provide a password via: CSQTT_MAIN_PASSWORD=<secret> in config" >&2
    exit 1
fi

# 3. Web panel password setup (persist across restarts if auto-generated)
if [ -n "${CSQTT_WEB_PASS:-}" ]; then
    echo -n "$CSQTT_WEB_PASS" > "$CSQTT_CONFIG_DIR/web.password"
    chmod 0600 "$CSQTT_CONFIG_DIR/web.password"
elif [ ! -s "$CSQTT_CONFIG_DIR/web.password" ]; then
    openssl rand -hex 16 > "$CSQTT_CONFIG_DIR/web.password"
    chmod 0600 "$CSQTT_CONFIG_DIR/web.password"
fi
CSQTT_WEB_PASS="$(cat "$CSQTT_CONFIG_DIR/web.password")"

# 4. Web Panel TLS certificate generation if missing
if [ ! -s "$CSQTT_CONFIG_DIR/web_cert.pem" ] || [ ! -s "$CSQTT_CONFIG_DIR/web_key.pem" ]; then
    echo "Generating self-signed TLS certificate for CSQTT Web Panel..."
    SAN_EXT="subjectAltName = DNS:localhost,IP:127.0.0.1"
    if [ -n "${CSQTT_PUBLIC_IP:-}" ]; then
        SAN_EXT="${SAN_EXT},IP:${CSQTT_PUBLIC_IP}"
    fi
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -keyout "$CSQTT_CONFIG_DIR/web_key.pem" \
        -out "$CSQTT_CONFIG_DIR/web_cert.pem" \
        -subj "/CN=rcgen self signed cert" \
        -addext "$SAN_EXT" >/dev/null 2>&1 || \
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -keyout "$CSQTT_CONFIG_DIR/web_key.pem" \
        -out "$CSQTT_CONFIG_DIR/web_cert.pem" \
        -subj "/CN=rcgen self signed cert" >/dev/null 2>&1
    chmod 0600 "$CSQTT_CONFIG_DIR/web_key.pem"
    chmod 0644 "$CSQTT_CONFIG_DIR/web_cert.pem"
fi

PIN=$(openssl x509 -in "$CSQTT_CONFIG_DIR/web_cert.pem" -outform DER | openssl dgst -sha256 -binary | openssl base64 -A)
echo "CSQTT_WEB_CERT_PIN|sha256/$PIN"
echo "Web panel user: $CSQTT_WEB_USER"
echo "Web panel password: $CSQTT_WEB_PASS"

# 5. Determine WAN/default interface for NAT
WAN_IFACE=$(ip route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -z "$WAN_IFACE" ] && WAN_IFACE=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1)
[ -z "$WAN_IFACE" ] && WAN_IFACE="eth0"
echo "Default WAN interface for NAT: $WAN_IFACE"

# 6. Configure iptables firewall & NAT masquerade
if command -v iptables >/dev/null 2>&1; then
    # Masquerade outbound traffic from CSQTT subnet (10.66.67.0/24)
    iptables -w 2 -t nat -C POSTROUTING -s "$CSQTT_SUBNET" -o "$WAN_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || \
        iptables -w 2 -t nat -A POSTROUTING -s "$CSQTT_SUBNET" -o "$WAN_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || true
    iptables -w 2 -t nat -C POSTROUTING -s "$CSQTT_SUBNET" ! -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || \
        iptables -w 2 -t nat -A POSTROUTING -s "$CSQTT_SUBNET" ! -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || true

    # MSS Clamping
    iptables -w 2 -t mangle -C FORWARD -s "$CSQTT_SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -w 2 -t mangle -I FORWARD -s "$CSQTT_SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -w 2 -t mangle -C FORWARD -d "$CSQTT_SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -w 2 -t mangle -I FORWARD -d "$CSQTT_SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

    # Input & Forwarding rules for TUN interface (csqtt1)
    iptables -w 2 -C INPUT -i "$CSQTT_IFACE" -s "$CSQTT_SUBNET" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I INPUT -i "$CSQTT_IFACE" -s "$CSQTT_SUBNET" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
    iptables -w 2 -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -w 2 -C FORWARD -i "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I FORWARD -i "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
    iptables -w 2 -C FORWARD -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I FORWARD -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
fi

if command -v ip6tables >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q .; then
    ip6tables -w 2 -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        ip6tables -w 2 -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    ip6tables -w 2 -C FORWARD -i "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        ip6tables -w 2 -I FORWARD -i "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
    ip6tables -w 2 -C FORWARD -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        ip6tables -w 2 -I FORWARD -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
    ip6tables -w 2 -t nat -C POSTROUTING -s "$CSQTT_SUBNET6" ! -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || \
        ip6tables -w 2 -t nat -A POSTROUTING -s "$CSQTT_SUBNET6" ! -o "$CSQTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || true
    ip6tables -w 2 -t mangle -C FORWARD -s "$CSQTT_SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        ip6tables -w 2 -t mangle -I FORWARD -s "$CSQTT_SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -w 2 -t mangle -C FORWARD -d "$CSQTT_SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        ip6tables -w 2 -t mangle -I FORWARD -d "$CSQTT_SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi

# 7. Clean up stale TUN interface if it exists
ip link show "$CSQTT_IFACE" >/dev/null 2>&1 && ip link del "$CSQTT_IFACE" 2>/dev/null || true

# 8. Build server arguments
export CSQTT_SERVICE_MANAGER="docker"
export CSQTT_MAIN_PASSWORD
export CSQTT_WEB_USER
export CSQTT_WEB_PASS

ARGS=(
    "--listen" "0.0.0.0:${CSQTT_PEER_PORT}"
    "--web-port" "${CSQTT_WEB_PORT}"
    "--config-dir" "${CSQTT_CONFIG_DIR}"
    "--dns" "${CSQTT_DNS}"
    "--web-user" "${CSQTT_WEB_USER}"
)

if [ -n "${CSQTT_PUBLIC_IP:-}" ]; then
    ARGS+=("--public-ip" "${CSQTT_PUBLIC_IP}")
fi

if [ -n "${CSQTT_WEB_SECRET_PATH:-}" ]; then
    ARGS+=("--web-secret-path" "${CSQTT_WEB_SECRET_PATH}")
fi

if [ "${CSQTT_SECURE_COOKIE:-false}" = "true" ] || [ "${CSQTT_SECURE_COOKIE:-0}" = "1" ]; then
    ARGS+=("--secure-cookie")
fi

exec /usr/local/bin/csqtt "${ARGS[@]}"
