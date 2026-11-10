# Base on Ubuntu LTSC 24.04
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install required dependencies:
# - iptables & iproute2: for TUN device management, NAT MASQUERADE, and packet routing
# - openssl & ca-certificates: for TLS certificate and token generation
# - procps & kmod: process management and kernel modules support
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
    iproute2 \
    iptables \
    procps \
    kmod \
    && rm -rf /var/lib/apt/lists/*

# Create config directory and mount point
RUN mkdir -p /etc/qwdtt /usr/local/bin

# Copy qwdtt binary and entrypoint script
COPY server /usr/local/bin/qwdtt
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/qwdtt /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
