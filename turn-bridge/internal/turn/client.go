package turn

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

// Client implements a minimal RFC 5766 TURN client over TCP.
type Client struct {
	conn     net.Conn
	username string
	password string
	realm    string
	nonce    []byte
	key      []byte

	relayAddr *net.UDPAddr
	channel   uint16
	peerAddr  *net.UDPAddr

	mu      sync.Mutex
	recvBuf chan []byte // channel data received from TURN
	closed  bool
	closeCh chan struct{}
}

// NewClient creates a TURN client connected to the given server via TCP.
func NewClient(serverAddr, username, password string) (*Client, error) {
	conn, err := net.DialTimeout("tcp", serverAddr, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("turn: dial %s: %w", serverAddr, err)
	}

	c := &Client{
		conn:     conn,
		username: username,
		password: password,
		recvBuf:  make(chan []byte, 256),
		closeCh:  make(chan struct{}),
	}

	return c, nil
}

// Allocate performs TURN allocation (RFC 5766 Section 6).
// Returns the relay address assigned by the server.
func (c *Client) Allocate() (*net.UDPAddr, error) {
	// First request without auth — expect 401 with realm+nonce.
	tid := NewTransactionID()
	b := NewBuilder(methodAllocate|classRequest, tid)
	// REQUESTED-TRANSPORT = UDP (17).
	transport := make([]byte, 4)
	transport[0] = transportUDP
	b.AddAttr(attrReqTransport, transport)

	if err := c.send(b.Build()); err != nil {
		return nil, err
	}

	resp, err := c.readSTUN()
	if err != nil {
		return nil, err
	}

	if resp.Type == methodAllocate|classError {
		code, _ := ParseErrorCode(resp.Attrs[attrErrorCode])
		if code != 401 {
			return nil, fmt.Errorf("turn: allocate error %d", code)
		}
		// Extract realm and nonce for authentication.
		realm, ok := resp.Attrs[attrRealm]
		if !ok {
			return nil, fmt.Errorf("turn: 401 without realm")
		}
		nonce, ok := resp.Attrs[attrNonce]
		if !ok {
			return nil, fmt.Errorf("turn: 401 without nonce")
		}
		c.realm = string(realm)
		c.nonce = nonce
		c.key = LongTermKey(c.username, c.realm, c.password)
	} else {
		return nil, fmt.Errorf("turn: expected 401, got 0x%04X", resp.Type)
	}

	// Retry with authentication.
	tid = NewTransactionID()
	b = NewBuilder(methodAllocate|classRequest, tid)
	b.AddAttr(attrReqTransport, transport)
	b.AddStringAttr(attrUsername, c.username)
	b.AddStringAttr(attrRealm, c.realm)
	b.AddAttr(attrNonce, c.nonce)

	if err := c.send(b.BuildWithIntegrity(c.key)); err != nil {
		return nil, err
	}

	resp, err = c.readSTUN()
	if err != nil {
		return nil, err
	}

	if resp.Type != methodAllocate|classSuccess {
		code, reason := ParseErrorCode(resp.Attrs[attrErrorCode])
		return nil, fmt.Errorf("turn: allocate failed: %d %s", code, reason)
	}

	// Parse XOR-RELAYED-ADDRESS.
	relayData, ok := resp.Attrs[attrXORRelayedAddr]
	if !ok {
		return nil, fmt.Errorf("turn: no XOR-RELAYED-ADDRESS in response")
	}
	ip, port, err := ParseXORAddress(relayData, resp.TransactionID)
	if err != nil {
		return nil, fmt.Errorf("turn: parse relay addr: %w", err)
	}

	c.relayAddr = &net.UDPAddr{IP: ip, Port: port}
	log.Printf("[turn] allocated relay: %s", c.relayAddr)

	return c.relayAddr, nil
}

// CreatePermission creates a permission for the given peer IP (RFC 5766 Section 9).
func (c *Client) CreatePermission(peerIP net.IP) error {
	tid := NewTransactionID()
	b := NewBuilder(methodPermisson|classRequest, tid)
	b.AddXORPeerAddress(peerIP, 0)
	b.AddStringAttr(attrUsername, c.username)
	b.AddStringAttr(attrRealm, c.realm)
	b.AddAttr(attrNonce, c.nonce)

	if err := c.send(b.BuildWithIntegrity(c.key)); err != nil {
		return err
	}

	resp, err := c.readSTUN()
	if err != nil {
		return err
	}

	if resp.Type != methodPermisson|classSuccess {
		code, reason := ParseErrorCode(resp.Attrs[attrErrorCode])
		return fmt.Errorf("turn: create-permission failed: %d %s", code, reason)
	}

	log.Printf("[turn] permission created for %s", peerIP)
	return nil
}

// ChannelBind binds a channel to the given peer address (RFC 5766 Section 11).
func (c *Client) ChannelBind(peerAddr *net.UDPAddr, channel uint16) error {
	if channel < 0x4000 || channel > 0x7FFF {
		return fmt.Errorf("turn: invalid channel number 0x%04X", channel)
	}

	tid := NewTransactionID()
	b := NewBuilder(methodChBind|classRequest, tid)
	b.AddChannelNumber(channel)
	b.AddXORPeerAddress(peerAddr.IP, peerAddr.Port)
	b.AddStringAttr(attrUsername, c.username)
	b.AddStringAttr(attrRealm, c.realm)
	b.AddAttr(attrNonce, c.nonce)

	if err := c.send(b.BuildWithIntegrity(c.key)); err != nil {
		return err
	}

	resp, err := c.readSTUN()
	if err != nil {
		return err
	}

	if resp.Type != methodChBind|classSuccess {
		code, reason := ParseErrorCode(resp.Attrs[attrErrorCode])
		return fmt.Errorf("turn: channel-bind failed: %d %s", code, reason)
	}

	c.channel = channel
	c.peerAddr = peerAddr
	log.Printf("[turn] channel 0x%04X bound to %s", channel, peerAddr)
	return nil
}

// SendChannelData sends data through the bound channel (RFC 5766 Section 11.4).
func (c *Client) SendChannelData(data []byte) error {
	if c.channel == 0 {
		return fmt.Errorf("turn: no channel bound")
	}

	// ChannelData header: 2 bytes channel + 2 bytes length + data.
	hdr := make([]byte, 4+len(data))
	binary.BigEndian.PutUint16(hdr[0:2], c.channel)
	binary.BigEndian.PutUint16(hdr[2:4], uint16(len(data)))
	copy(hdr[4:], data)

	// Pad to 4-byte boundary for TCP framing (RFC 5766 Section 11.5).
	if pad := len(data) % 4; pad != 0 {
		hdr = append(hdr, make([]byte, 4-pad)...)
	}

	return c.send(hdr)
}

// RecvChannelData reads the next channel data payload.
// Returns the data or an error on timeout/close.
func (c *Client) RecvChannelData(timeout time.Duration) ([]byte, error) {
	select {
	case data := <-c.recvBuf:
		return data, nil
	case <-time.After(timeout):
		return nil, nil
	case <-c.closeCh:
		return nil, fmt.Errorf("turn: client closed")
	}
}

// StartReceiver starts a goroutine that reads TURN messages and routes
// ChannelData to the recvBuf channel. Must be called after Allocate.
func (c *Client) StartReceiver() {
	go c.receiveLoop()
}

// Refresh sends an Allocate refresh to keep the allocation alive (RFC 5766 Section 7).
func (c *Client) Refresh(lifetime uint32) error {
	tid := NewTransactionID()
	b := NewBuilder(methodRefresh|classRequest, tid)
	b.AddUint32Attr(attrLifetime, lifetime)
	b.AddStringAttr(attrUsername, c.username)
	b.AddStringAttr(attrRealm, c.realm)
	b.AddAttr(attrNonce, c.nonce)

	if err := c.send(b.BuildWithIntegrity(c.key)); err != nil {
		return err
	}

	// Don't block waiting for response — the receiver loop handles it.
	return nil
}

// Close shuts down the TURN client.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	close(c.closeCh)
	return c.conn.Close()
}

// send writes raw data to the TCP connection.
func (c *Client) send(data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return fmt.Errorf("turn: client closed")
	}
	_ = c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err := c.conn.Write(data)
	return err
}

// readSTUN reads a single STUN message from the TCP stream.
func (c *Client) readSTUN() (*Message, error) {
	_ = c.conn.SetReadDeadline(time.Now().Add(10 * time.Second))

	// Read STUN header (20 bytes).
	header := make([]byte, 20)
	if _, err := io.ReadFull(c.conn, header); err != nil {
		return nil, fmt.Errorf("turn: read header: %w", err)
	}

	msgLen := int(binary.BigEndian.Uint16(header[2:4]))
	if msgLen > 65535 {
		return nil, fmt.Errorf("turn: message too large: %d", msgLen)
	}

	body := make([]byte, msgLen)
	if _, err := io.ReadFull(c.conn, body); err != nil {
		return nil, fmt.Errorf("turn: read body: %w", err)
	}

	return ParseMessage(append(header, body...))
}

// readFrame reads either a STUN message or ChannelData from TCP.
// RFC 5766 Section 11.5: first byte determines framing.
func (c *Client) readFrame() (isChannel bool, channel uint16, data []byte, err error) {
	_ = c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))

	// Peek at first 4 bytes.
	header := make([]byte, 4)
	if _, err = io.ReadFull(c.conn, header); err != nil {
		return
	}

	firstByte := header[0]

	if firstByte >= 0x40 && firstByte <= 0x7F {
		// ChannelData: channel(2) + length(2) + data.
		channel = binary.BigEndian.Uint16(header[0:2])
		length := int(binary.BigEndian.Uint16(header[2:4]))

		if length > 65535 {
			err = fmt.Errorf("turn: channel data too large: %d", length)
			return
		}

		data = make([]byte, length)
		if _, err = io.ReadFull(c.conn, data); err != nil {
			return
		}

		// Skip padding to 4-byte boundary.
		if pad := length % 4; pad != 0 {
			discard := make([]byte, 4-pad)
			_, err = io.ReadFull(c.conn, discard)
		}

		isChannel = true
		return
	}

	// STUN message: read remaining header + body.
	restHeader := make([]byte, 16)
	if _, err = io.ReadFull(c.conn, restHeader); err != nil {
		return
	}
	fullHeader := append(header, restHeader...)

	msgLen := int(binary.BigEndian.Uint16(fullHeader[2:4]))
	body := make([]byte, msgLen)
	if _, err = io.ReadFull(c.conn, body); err != nil {
		return
	}

	data = append(fullHeader, body...)
	return
}

// receiveLoop reads frames from the TURN connection and routes them.
func (c *Client) receiveLoop() {
	for {
		select {
		case <-c.closeCh:
			return
		default:
		}

		isChannel, _, payload, err := c.readFrame()
		if err != nil {
			select {
			case <-c.closeCh:
				return
			default:
				log.Printf("[turn] receive error: %v", err)
				return
			}
		}

		if isChannel {
			select {
			case c.recvBuf <- payload:
			default:
				log.Printf("[turn] recv buffer full, dropping %d bytes", len(payload))
			}
		}
		// Non-channel STUN messages (refresh responses, etc.) are ignored
		// in the receiver loop since we don't need them for data relay.
	}
}

// RelayPacketConn wraps a TURN Client as a net.PacketConn for use with KCP.
type RelayPacketConn struct {
	client   *Client
	peerAddr *net.UDPAddr
}

// NewRelayPacketConn creates a PacketConn that sends/receives through the TURN relay.
func NewRelayPacketConn(client *Client, peerAddr *net.UDPAddr) *RelayPacketConn {
	return &RelayPacketConn{
		client:   client,
		peerAddr: peerAddr,
	}
}

// ReadFrom reads the next packet from the TURN relay.
func (r *RelayPacketConn) ReadFrom(p []byte) (n int, addr net.Addr, err error) {
	data, err := r.client.RecvChannelData(60 * time.Second)
	if err != nil {
		return 0, nil, err
	}
	if data == nil {
		return 0, nil, fmt.Errorf("turn: read timeout")
	}
	n = copy(p, data)
	return n, r.peerAddr, nil
}

// WriteTo sends a packet through the TURN relay.
func (r *RelayPacketConn) WriteTo(p []byte, addr net.Addr) (n int, err error) {
	if err := r.client.SendChannelData(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// Close closes the TURN client.
func (r *RelayPacketConn) Close() error {
	return r.client.Close()
}

// LocalAddr returns the relay address.
func (r *RelayPacketConn) LocalAddr() net.Addr {
	return r.client.relayAddr
}

// SetDeadline sets read/write deadlines (no-op for channel-based impl).
func (r *RelayPacketConn) SetDeadline(t time.Time) error      { return nil }
func (r *RelayPacketConn) SetReadDeadline(t time.Time) error  { return nil }
func (r *RelayPacketConn) SetWriteDeadline(t time.Time) error { return nil }
