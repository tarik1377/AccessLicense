#!/usr/bin/env bash
# install.sh — Installs the turn-bridge server on a VPS.
#
# Usage: bash install.sh --psk <key> [--port 19302] [--target 127.0.0.1:443]
#
# Requirements: root privileges, systemd, curl, sha256sum.
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────
LISTEN_PORT="19302"
TARGET="127.0.0.1:443"
PSK=""
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="turn-bridge"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GO_VERSION="1.21.13"

# ──────────────────────────────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --psk)     PSK="$2";         shift 2 ;;
        --port)    LISTEN_PORT="$2"; shift 2 ;;
        --target)  TARGET="$2";      shift 2 ;;
        -h|--help)
            echo "Usage: $0 --psk <key> [--port 19302] [--target 127.0.0.1:443]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$PSK" ]]; then
    echo "Error: --psk is required." >&2
    echo "Usage: $0 --psk <key> [--port 19302] [--target 127.0.0.1:443]" >&2
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# Privilege check
# ──────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# Detect architecture
# ──────────────────────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
    armv7l)  GOARCH="armv6l" ;;
    *)
        echo "Error: unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║         turn-bridge installer            ║"
echo "╠══════════════════════════════════════════╣"
echo "║ Listen:  :${LISTEN_PORT} (UDP/KCP)              ║"
echo "║ Target:  ${TARGET}           ║"
echo "║ Arch:    ${GOARCH}                         ║"
echo "╚══════════════════════════════════════════╝"

# ──────────────────────────────────────────────────────────────────────
# Install Go (if needed)
# ──────────────────────────────────────────────────────────────────────
install_go() {
    echo "[1/5] Installing Go ${GO_VERSION}..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    local tarball="${tmp_dir}/go.tar.gz"
    local url="https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz"

    curl -fsSL -o "$tarball" "$url"

    # Verify download succeeded and is not empty.
    if [[ ! -s "$tarball" ]]; then
        echo "Error: failed to download Go from $url" >&2
        exit 1
    fi

    tar -xzf "$tarball" -C "$tmp_dir"

    if [[ ! -x "${tmp_dir}/go/bin/go" ]]; then
        echo "Error: Go binary not found after extraction" >&2
        exit 1
    fi

    export PATH="${tmp_dir}/go/bin:$PATH"
    echo "  Go $(go version | awk '{print $3}') installed (temporary)"
}

if ! command -v go &>/dev/null; then
    install_go
else
    echo "[1/5] Go already installed: $(go version | awk '{print $3}')"
fi

# ──────────────────────────────────────────────────────────────────────
# Build binary
# ──────────────────────────────────────────────────────────────────────
echo "[2/5] Building turn-server..."
cd "$SCRIPT_DIR"

CGO_ENABLED=0 go build -ldflags "-w -s" -o turn-server ./cmd/turn-server/

if [[ ! -x "./turn-server" ]]; then
    echo "Error: build failed — binary not produced" >&2
    exit 1
fi

echo "  Binary: $(file ./turn-server | cut -d: -f2 | xargs)"

# ──────────────────────────────────────────────────────────────────────
# Install binary
# ──────────────────────────────────────────────────────────────────────
echo "[3/5] Installing binary..."

# Stop service if running (ignore errors).
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

cp -f ./turn-server "${INSTALL_DIR}/turn-server"
chmod 755 "${INSTALL_DIR}/turn-server"
rm -f ./turn-server

# ──────────────────────────────────────────────────────────────────────
# Create systemd service
# ──────────────────────────────────────────────────────────────────────
echo "[4/5] Creating systemd service..."

cat > "$SERVICE_FILE" <<SERVICEEOF
[Unit]
Description=TURN Bridge Server — KCP/UDP relay for TURN tunneling
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/turn-server -listen ":${LISTEN_PORT}" -target "${TARGET}" -psk "${PSK}"

Restart=on-failure
RestartSec=5
StartLimitInterval=60
StartLimitBurst=5

# Resource limits
LimitNOFILE=65535
MemoryMax=512M
TasksMax=4096

# Security hardening
NoNewPrivileges=yes
ProtectSystem=yes
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
SERVICEEOF

chmod 644 "$SERVICE_FILE"

# ──────────────────────────────────────────────────────────────────────
# Firewall
# ──────────────────────────────────────────────────────────────────────
echo "[5/5] Configuring firewall..."

if command -v ufw &>/dev/null; then
    ufw allow "${LISTEN_PORT}/udp" >/dev/null 2>&1 && echo "  ufw: allowed ${LISTEN_PORT}/udp"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${LISTEN_PORT}/udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    echo "  firewalld: allowed ${LISTEN_PORT}/udp"
else
    echo "  Warning: no supported firewall found. Open UDP port ${LISTEN_PORT} manually."
fi

# ──────────────────────────────────────────────────────────────────────
# Start service
# ──────────────────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Verify it started.
sleep 1
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo ""
    echo "✓ turn-bridge server installed and running."
    echo ""
    echo "  Status:  systemctl status ${SERVICE_NAME}"
    echo "  Logs:    journalctl -u ${SERVICE_NAME} -f"
    echo "  Listen:  UDP :${LISTEN_PORT} (KCP encrypted)"
    echo "  Target:  TCP ${TARGET}"
    echo ""
    VPS_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "<YOUR_VPS_IP>")
    echo "  Client command:"
    echo "    turn-client \\"
    echo "      --turn-server <TURN_HOST:PORT> \\"
    echo "      --turn-user <USERNAME> \\"
    echo "      --turn-pass <PASSWORD> \\"
    echo "      --vps ${VPS_IP}:${LISTEN_PORT} \\"
    echo "      --psk '${PSK}' \\"
    echo "      --local 127.0.0.1:1080"
else
    echo ""
    echo "✗ Service failed to start. Check logs:"
    echo "  journalctl -u ${SERVICE_NAME} --no-pager -n 20"
    exit 1
fi
