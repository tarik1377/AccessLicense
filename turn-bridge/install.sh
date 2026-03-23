#!/bin/bash
# Install turn-bridge on VPS
# Usage: bash turn-bridge/install.sh [--port PORT] [--target HOST:PORT] [--mode tcp|udp]
set -euo pipefail

LISTEN_PORT="${1:-19302}"
TARGET="${2:-127.0.0.1:443}"
MODE="${3:-tcp}"
INSTALL_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/turn-bridge.service"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== TURN Bridge Installer ==="
echo "Mode:   $MODE"
echo "Listen: :$LISTEN_PORT (UDP)"
echo "Target: $TARGET ($MODE)"

# Check if Go is available for building
if ! command -v go &>/dev/null; then
    echo "[!] Go not found. Downloading pre-built binary..."

    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  GOARCH="amd64" ;;
        aarch64) GOARCH="arm64" ;;
        armv7l)  GOARCH="arm" ;;
        *)
            echo "[!] Unsupported architecture: $ARCH"
            echo "[!] Install Go manually: https://go.dev/dl/"
            exit 1
            ;;
    esac

    # Build from source using temporary Go installation
    GO_VERSION="1.21.13"
    TMP_GO="/tmp/go-install"
    mkdir -p "$TMP_GO"
    echo "[*] Downloading Go $GO_VERSION for $GOARCH..."
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" \
        | tar -xz -C "$TMP_GO"
    export PATH="$TMP_GO/go/bin:$PATH"
    export GOPATH="$TMP_GO/gopath"
fi

# Build
echo "[*] Building turn-bridge..."
cd "$SCRIPT_DIR"
CGO_ENABLED=0 go build -ldflags="-w -s" -o turn-bridge main.go
chmod +x turn-bridge

# Install binary
echo "[*] Installing to $INSTALL_DIR/turn-bridge"
cp -f turn-bridge "$INSTALL_DIR/turn-bridge"

# Install systemd service
echo "[*] Installing systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=TURN Bridge - UDP relay for VK TURN tunnel
After=network.target x-ui.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/turn-bridge -mode $MODE -listen :$LISTEN_PORT -target $TARGET
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

# Open firewall port
if command -v ufw &>/dev/null; then
    ufw allow "$LISTEN_PORT"/udp 2>/dev/null || true
    echo "[*] UFW: allowed UDP $LISTEN_PORT"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="$LISTEN_PORT"/udp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    echo "[*] firewalld: allowed UDP $LISTEN_PORT"
fi

# Enable and start
systemctl daemon-reload
systemctl enable turn-bridge
systemctl restart turn-bridge

echo ""
echo "=== TURN Bridge installed ==="
echo "Status: systemctl status turn-bridge"
echo "Logs:   journalctl -u turn-bridge -f"
echo ""
echo "Client usage:"
echo "  python3 turn-bridge/client/vk_turn_client.py \\"
echo "    --vps-host $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_VPS_IP') \\"
echo "    --vps-port $LISTEN_PORT"

# Cleanup temp Go if we installed it
[ -d "/tmp/go-install" ] && rm -rf /tmp/go-install
