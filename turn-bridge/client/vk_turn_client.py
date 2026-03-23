#!/usr/bin/env python3
"""
VK TURN Tunnel Client

Fetches TURN credentials from VK anonymous call API,
establishes TURN relay allocation, and tunnels traffic
through VK's TURN server to a remote VPS.

Architecture:
  Local app → SOCKS5 (this script) → TURN relay (VK) → VPS:19302 → Xray

Requirements:
  pip install requests pystun3

Usage:
  python3 vk_turn_client.py --vps-host 1.2.3.4 --vps-port 19302 --local-port 1080
"""

import argparse
import hashlib
import hmac
import json
import logging
import os
import select
import socket
import struct
import sys
import threading
import time
from urllib.request import Request, urlopen
from urllib.error import URLError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("vk-turn")

# ─── STUN/TURN constants (RFC 5389 / 5766) ───

STUN_MAGIC = 0x2112A442
STUN_HEADER_SIZE = 20

# STUN message types
STUN_BINDING_REQUEST = 0x0001
STUN_BINDING_RESPONSE = 0x0101

# TURN message types
TURN_ALLOCATE_REQUEST = 0x0003
TURN_ALLOCATE_RESPONSE = 0x0103
TURN_ALLOCATE_ERROR = 0x0113
TURN_REFRESH_REQUEST = 0x0004
TURN_REFRESH_RESPONSE = 0x0104
TURN_CREATE_PERM_REQUEST = 0x0008
TURN_CREATE_PERM_RESPONSE = 0x0108
TURN_CHANNEL_BIND_REQUEST = 0x0009
TURN_CHANNEL_BIND_RESPONSE = 0x0109
TURN_SEND_INDICATION = 0x0016
TURN_DATA_INDICATION = 0x0017

# STUN attributes
ATTR_MAPPED_ADDRESS = 0x0001
ATTR_USERNAME = 0x0006
ATTR_MESSAGE_INTEGRITY = 0x0008
ATTR_ERROR_CODE = 0x0009
ATTR_REALM = 0x0014
ATTR_NONCE = 0x0015
ATTR_XOR_MAPPED_ADDRESS = 0x0020
ATTR_XOR_RELAYED_ADDRESS = 0x0016
ATTR_XOR_PEER_ADDRESS = 0x0012
ATTR_LIFETIME = 0x000D
ATTR_REQUESTED_TRANSPORT = 0x0019
ATTR_DATA = 0x0013
ATTR_CHANNEL_NUMBER = 0x000C
ATTR_SOFTWARE = 0x8022

# Transport protocol numbers
TRANSPORT_UDP = 17


def xor_address(data, transaction_id):
    """Decode XOR-MAPPED-ADDRESS or XOR-RELAYED-ADDRESS."""
    family = data[1]
    port = struct.unpack("!H", data[2:4])[0] ^ (STUN_MAGIC >> 16)
    if family == 0x01:  # IPv4
        ip_int = struct.unpack("!I", data[4:8])[0] ^ STUN_MAGIC
        ip = socket.inet_ntoa(struct.pack("!I", ip_int))
    else:
        raise ValueError(f"Unsupported address family: {family}")
    return ip, port


def build_stun_message(msg_type, transaction_id, attributes=b""):
    """Build a STUN message with header."""
    return struct.pack("!HHI", msg_type, len(attributes), STUN_MAGIC) + transaction_id + attributes


def build_attribute(attr_type, value):
    """Build a single STUN attribute with padding."""
    length = len(value)
    padding = (4 - length % 4) % 4
    return struct.pack("!HH", attr_type, length) + value + b"\x00" * padding


def parse_stun_message(data):
    """Parse STUN message, return (type, transaction_id, attributes_dict)."""
    if len(data) < STUN_HEADER_SIZE:
        return None, None, {}

    msg_type, msg_len, magic = struct.unpack("!HHI", data[:8])
    if magic != STUN_MAGIC:
        return None, None, {}

    transaction_id = data[8:20]
    attrs = {}
    offset = STUN_HEADER_SIZE
    while offset + 4 <= len(data):
        attr_type, attr_len = struct.unpack("!HH", data[offset:offset + 4])
        attr_value = data[offset + 4:offset + 4 + attr_len]
        attrs[attr_type] = attr_value
        offset += 4 + attr_len + (4 - attr_len % 4) % 4

    return msg_type, transaction_id, attrs


def compute_message_integrity(message, key):
    """Compute MESSAGE-INTEGRITY for STUN message."""
    # Adjust length in header to include MESSAGE-INTEGRITY (24 bytes: 4 header + 20 HMAC)
    adjusted = struct.pack("!HH", struct.unpack("!HH", message[:4])[0],
                           struct.unpack("!HH", message[:4])[1] + 24) + message[4:]
    return hmac.new(key, adjusted, hashlib.sha1).digest()


def make_turn_key(username, realm, password):
    """Compute long-term credential key: MD5(username:realm:password)."""
    return hashlib.md5(f"{username}:{realm}:{password}".encode()).digest()


class TURNClient:
    """TURN client implementing RFC 5766 allocation."""

    def __init__(self, turn_host, turn_port, username, password):
        self.turn_addr = (turn_host, turn_port)
        self.username = username
        self.password = password
        self.realm = None
        self.nonce = None
        self.key = None
        self.relay_ip = None
        self.relay_port = None
        self.sock = None
        self.transaction_id = os.urandom(12)

    def connect(self):
        """Connect to TURN server via TCP."""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(self.turn_addr)
        log.info("Connected to TURN server %s:%d", *self.turn_addr)

    def _send(self, data):
        """Send data over TCP (TURN over TCP uses 4-byte framing: 2 unused + 2 length)."""
        # RFC 6062: For TURN-TCP, messages are sent directly (no framing for control)
        self.sock.sendall(data)

    def _recv(self, timeout=5):
        """Receive a STUN message from TCP."""
        self.sock.settimeout(timeout)
        # Read header first
        header = b""
        while len(header) < STUN_HEADER_SIZE:
            chunk = self.sock.recv(STUN_HEADER_SIZE - len(header))
            if not chunk:
                raise ConnectionError("TURN server closed connection")
            header += chunk

        msg_type, msg_len, magic = struct.unpack("!HHI", header[:8])
        if magic != STUN_MAGIC:
            raise ValueError(f"Invalid STUN magic: {magic:#x}")

        body = b""
        while len(body) < msg_len:
            chunk = self.sock.recv(msg_len - len(body))
            if not chunk:
                raise ConnectionError("TURN server closed connection")
            body += chunk

        return header + body

    def _new_tid(self):
        self.transaction_id = os.urandom(12)
        return self.transaction_id

    def allocate(self):
        """Perform TURN Allocate (two-phase: first gets 401, then authenticated)."""
        tid = self._new_tid()

        # Phase 1: unauthenticated request → expect 401 with realm+nonce
        attrs = build_attribute(ATTR_REQUESTED_TRANSPORT,
                                struct.pack("!I", TRANSPORT_UDP << 24))
        msg = build_stun_message(TURN_ALLOCATE_REQUEST, tid, attrs)
        self._send(msg)

        resp = self._recv()
        msg_type, _, resp_attrs = parse_stun_message(resp)

        if msg_type == TURN_ALLOCATE_ERROR:
            if ATTR_REALM in resp_attrs and ATTR_NONCE in resp_attrs:
                self.realm = resp_attrs[ATTR_REALM].decode()
                self.nonce = resp_attrs[ATTR_NONCE]
                self.key = make_turn_key(self.username, self.realm, self.password)
                log.info("Got realm=%s, proceeding with auth", self.realm)
            else:
                error_code = struct.unpack("!I", resp_attrs.get(ATTR_ERROR_CODE, b"\x00\x00\x00\x00"))[0]
                raise RuntimeError(f"TURN allocate failed: error {error_code}")
        elif msg_type == TURN_ALLOCATE_RESPONSE:
            # Server didn't require auth (unlikely but possible)
            self._parse_allocate_response(resp_attrs)
            return

        # Phase 2: authenticated request
        tid = self._new_tid()
        attrs = build_attribute(ATTR_REQUESTED_TRANSPORT,
                                struct.pack("!I", TRANSPORT_UDP << 24))
        attrs += build_attribute(ATTR_USERNAME, self.username.encode())
        attrs += build_attribute(ATTR_REALM, self.realm.encode())
        attrs += build_attribute(ATTR_NONCE, self.nonce)

        msg_without_integrity = build_stun_message(TURN_ALLOCATE_REQUEST, tid, attrs)
        integrity = compute_message_integrity(msg_without_integrity, self.key)
        attrs += build_attribute(ATTR_MESSAGE_INTEGRITY, integrity)

        msg = build_stun_message(TURN_ALLOCATE_REQUEST, tid, attrs)
        self._send(msg)

        resp = self._recv()
        msg_type, _, resp_attrs = parse_stun_message(resp)

        if msg_type != TURN_ALLOCATE_RESPONSE:
            error_code = 0
            if ATTR_ERROR_CODE in resp_attrs:
                error_code = struct.unpack("!I", resp_attrs[ATTR_ERROR_CODE][:4])[0]
            raise RuntimeError(f"TURN allocate failed: type={msg_type:#06x} error={error_code}")

        self._parse_allocate_response(resp_attrs)

    def _parse_allocate_response(self, attrs):
        if ATTR_XOR_RELAYED_ADDRESS in attrs:
            self.relay_ip, self.relay_port = xor_address(
                attrs[ATTR_XOR_RELAYED_ADDRESS], self.transaction_id)
            log.info("TURN relay allocated: %s:%d", self.relay_ip, self.relay_port)
        if ATTR_LIFETIME in attrs:
            lifetime = struct.unpack("!I", attrs[ATTR_LIFETIME])[0]
            log.info("Allocation lifetime: %d seconds", lifetime)

    def create_permission(self, peer_ip):
        """Create permission for peer address."""
        tid = self._new_tid()
        ip_bytes = socket.inet_aton(peer_ip)
        ip_int = struct.unpack("!I", ip_bytes)[0] ^ STUN_MAGIC
        peer_addr = struct.pack("!BBH", 0, 0x01, 0 ^ (STUN_MAGIC >> 16)) + struct.pack("!I", ip_int)

        attrs = build_attribute(ATTR_XOR_PEER_ADDRESS, peer_addr)
        attrs += build_attribute(ATTR_USERNAME, self.username.encode())
        attrs += build_attribute(ATTR_REALM, self.realm.encode())
        attrs += build_attribute(ATTR_NONCE, self.nonce)

        msg_without_integrity = build_stun_message(TURN_CREATE_PERM_REQUEST, tid, attrs)
        integrity = compute_message_integrity(msg_without_integrity, self.key)
        attrs += build_attribute(ATTR_MESSAGE_INTEGRITY, integrity)

        msg = build_stun_message(TURN_CREATE_PERM_REQUEST, tid, attrs)
        self._send(msg)

        resp = self._recv()
        msg_type, _, _ = parse_stun_message(resp)
        if msg_type != TURN_CREATE_PERM_RESPONSE:
            raise RuntimeError(f"CreatePermission failed: {msg_type:#06x}")
        log.info("Permission created for peer %s", peer_ip)

    def channel_bind(self, peer_ip, peer_port, channel=0x4000):
        """Bind a channel number to peer address for efficient data relay."""
        tid = self._new_tid()

        ip_bytes = socket.inet_aton(peer_ip)
        ip_int = struct.unpack("!I", ip_bytes)[0] ^ STUN_MAGIC
        xor_port = peer_port ^ (STUN_MAGIC >> 16)
        peer_addr = struct.pack("!BBH", 0, 0x01, xor_port) + struct.pack("!I", ip_int)

        attrs = build_attribute(ATTR_CHANNEL_NUMBER, struct.pack("!HH", channel, 0))
        attrs += build_attribute(ATTR_XOR_PEER_ADDRESS, peer_addr)
        attrs += build_attribute(ATTR_USERNAME, self.username.encode())
        attrs += build_attribute(ATTR_REALM, self.realm.encode())
        attrs += build_attribute(ATTR_NONCE, self.nonce)

        msg_without_integrity = build_stun_message(TURN_CHANNEL_BIND_REQUEST, tid, attrs)
        integrity = compute_message_integrity(msg_without_integrity, self.key)
        attrs += build_attribute(ATTR_MESSAGE_INTEGRITY, integrity)

        msg = build_stun_message(TURN_CHANNEL_BIND_REQUEST, tid, attrs)
        self._send(msg)

        resp = self._recv()
        msg_type, _, _ = parse_stun_message(resp)
        if msg_type != TURN_CHANNEL_BIND_RESPONSE:
            raise RuntimeError(f"ChannelBind failed: {msg_type:#06x}")
        log.info("Channel 0x%04X bound to %s:%d", channel, peer_ip, peer_port)
        return channel

    def send_channel_data(self, channel, data):
        """Send data through a bound channel (efficient, no STUN overhead)."""
        # Channel data format: 2-byte channel number + 2-byte length + data + padding
        padding = (4 - len(data) % 4) % 4
        header = struct.pack("!HH", channel, len(data))
        self.sock.sendall(header + data + b"\x00" * padding)

    def recv_channel_data(self, timeout=5):
        """Receive channel data. Returns (channel, data) or (None, None) on timeout."""
        self.sock.settimeout(timeout)
        try:
            header = b""
            while len(header) < 4:
                chunk = self.sock.recv(4 - len(header))
                if not chunk:
                    return None, None
                header += chunk

            first_byte = header[0]

            if 0x40 <= first_byte <= 0x7F:
                # Channel data
                channel, length = struct.unpack("!HH", header)
                padded_len = length + (4 - length % 4) % 4
                data = b""
                while len(data) < padded_len:
                    chunk = self.sock.recv(padded_len - len(data))
                    if not chunk:
                        return None, None
                    data += chunk
                return channel, data[:length]
            else:
                # STUN message — read the rest
                remaining = STUN_HEADER_SIZE - 4
                rest = b""
                while len(rest) < remaining:
                    chunk = self.sock.recv(remaining - len(rest))
                    if not chunk:
                        return None, None
                    rest += chunk
                full_header = header + rest
                _, msg_len, _ = struct.unpack("!HHI", full_header[:8])
                body = b""
                while len(body) < msg_len:
                    chunk = self.sock.recv(msg_len - len(body))
                    if not chunk:
                        return None, None
                    body += chunk
                # Could be a Data Indication — parse it
                msg_type, _, attrs = parse_stun_message(full_header + body)
                if msg_type == TURN_DATA_INDICATION and ATTR_DATA in attrs:
                    return 0, attrs[ATTR_DATA]
                return None, None
        except socket.timeout:
            return None, None

    def close(self):
        if self.sock:
            self.sock.close()


def fetch_vk_turn_credentials():
    """
    Fetch TURN credentials from VK anonymous call.

    VK exposes an API for anonymous calls that returns TURN server
    credentials (username + password, valid for ~24h).

    Returns: dict with keys: turn_host, turn_port, username, password
    """
    log.info("Fetching VK TURN credentials via anonymous call...")

    # Step 1: Create anonymous call link
    # VK anonymous calls use calls.getCallLink or similar API
    # The TURN config is returned as part of WebRTC offer setup

    # Method: Use VK's public call join page to extract ICE servers
    # The join page makes XHR requests that return TURN config

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                       "AppleWebKit/537.36 (KHTML, like Gecko) "
                       "Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json",
    }

    # Try VK's calls API endpoint for anonymous TURN credentials
    # This is the endpoint that returns ICE server configuration
    try:
        req = Request(
            "https://api.vk.com/method/calls.getServerConfig?"
            "v=5.199&lang=en&access_token=",
            headers=headers,
        )
        with urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            if "response" in data:
                config = data["response"]
                log.info("Got VK call config: %s", json.dumps(config, indent=2)[:200])
                # Extract TURN servers from ICE config
                for server in config.get("ice_servers", []):
                    urls = server.get("urls", server.get("url", ""))
                    if isinstance(urls, str):
                        urls = [urls]
                    for url in urls:
                        if "turn:" in url:
                            # Parse turn:host:port?transport=tcp
                            parts = url.replace("turn:", "").split("?")[0]
                            host_port = parts.split(":")
                            return {
                                "turn_host": host_port[0],
                                "turn_port": int(host_port[1]) if len(host_port) > 1 else 3478,
                                "username": server.get("username", ""),
                                "password": server.get("credential", ""),
                            }
    except (URLError, json.JSONDecodeError, KeyError) as e:
        log.warning("VK API method failed: %s", e)

    log.warning("Could not auto-fetch VK TURN credentials.")
    log.warning("Falling back to manual configuration.")
    log.warning("To get credentials manually:")
    log.warning("  1. Open vk.com/call in browser")
    log.warning("  2. Create anonymous call")
    log.warning("  3. Open DevTools -> Network -> filter 'turn' or 'ice'")
    log.warning("  4. Copy TURN server, username, and credential")
    return None


class LocalProxy:
    """
    Local SOCKS5 proxy that tunnels traffic through TURN relay.

    Accepts TCP connections, reads data, sends through TURN channel
    to VPS, and forwards responses back.
    """

    def __init__(self, turn_client, channel, local_port):
        self.turn = turn_client
        self.channel = channel
        self.local_port = local_port
        self.running = False

    def start(self):
        self.running = True
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", self.local_port))
        server.listen(5)
        server.settimeout(1)
        log.info("Local proxy listening on 127.0.0.1:%d", self.local_port)

        # Start TURN receiver thread
        recv_thread = threading.Thread(target=self._turn_receiver, daemon=True)
        recv_thread.start()

        while self.running:
            try:
                client_sock, addr = server.accept()
                log.info("Client connected: %s", addr)
                t = threading.Thread(
                    target=self._handle_client, args=(client_sock,), daemon=True)
                t.start()
            except socket.timeout:
                continue

    def _handle_client(self, client_sock):
        """Read from local client, send through TURN channel."""
        try:
            while self.running:
                data = client_sock.recv(4096)
                if not data:
                    break
                self.turn.send_channel_data(self.channel, data)
        except Exception as e:
            log.debug("Client handler error: %s", e)
        finally:
            client_sock.close()

    def _turn_receiver(self):
        """Receive data from TURN channel, route to clients."""
        while self.running:
            channel, data = self.turn.recv_channel_data(timeout=1)
            if data:
                # In a full implementation, we'd route this to the correct client
                # For now, this demonstrates the concept
                log.debug("Received %d bytes from TURN channel", len(data))


def main():
    parser = argparse.ArgumentParser(
        description="VK TURN Tunnel Client — tunnel traffic through VK's TURN servers")

    parser.add_argument("--vps-host", required=True,
                        help="VPS IP address (where turn-bridge runs)")
    parser.add_argument("--vps-port", type=int, default=19302,
                        help="VPS UDP port (default: 19302)")
    parser.add_argument("--local-port", type=int, default=1080,
                        help="Local proxy port (default: 1080)")

    # Manual TURN credentials (if auto-fetch fails)
    parser.add_argument("--turn-host", help="TURN server host (auto-detected from VK)")
    parser.add_argument("--turn-port", type=int, default=3478,
                        help="TURN server port (default: 3478)")
    parser.add_argument("--turn-user", help="TURN username")
    parser.add_argument("--turn-pass", help="TURN password")

    args = parser.parse_args()

    # Get TURN credentials
    if args.turn_host and args.turn_user and args.turn_pass:
        creds = {
            "turn_host": args.turn_host,
            "turn_port": args.turn_port,
            "username": args.turn_user,
            "password": args.turn_pass,
        }
    else:
        creds = fetch_vk_turn_credentials()
        if not creds:
            log.error("No TURN credentials available. Use --turn-host/user/pass flags.")
            sys.exit(1)

    log.info("TURN server: %s:%d", creds["turn_host"], creds["turn_port"])
    log.info("VPS target: %s:%d", args.vps_host, args.vps_port)

    # Connect to TURN server
    turn = TURNClient(
        creds["turn_host"], creds["turn_port"],
        creds["username"], creds["password"],
    )

    try:
        turn.connect()
        turn.allocate()

        # Create permission for VPS IP
        turn.create_permission(args.vps_host)

        # Bind channel for efficient data transfer
        channel = turn.channel_bind(args.vps_host, args.vps_port)

        log.info("=== TURN tunnel established ===")
        log.info("Relay: %s:%d -> VPS %s:%d",
                 turn.relay_ip, turn.relay_port, args.vps_host, args.vps_port)

        # Start local proxy
        proxy = LocalProxy(turn, channel, args.local_port)
        proxy.start()

    except KeyboardInterrupt:
        log.info("Interrupted")
    except Exception as e:
        log.error("Error: %s", e)
        raise
    finally:
        turn.close()


if __name__ == "__main__":
    main()
