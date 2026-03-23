// turn-bridge — VPS-side relay for tunneling traffic through TURN servers.
//
// Modes:
//
//	udp  — UDP→UDP relay (for WireGuard, QUIC-based VPN)
//	tcp  — UDP→TCP relay (for TCP-based proxies like Xray VLESS/VMess)
//
// In TCP mode, each UDP datagram is forwarded as a raw TCP stream segment
// to the target. A new TCP connection is created per unique source address
// (i.e., per TURN relay allocation). This works because TURN relay sends
// raw UDP payloads — if the client sends a proper TLS/VLESS handshake
// inside the UDP datagram, it arrives intact at Xray.
//
// Usage:
//
//	turn-bridge -mode udp -listen :19302 -target 127.0.0.1:51820
//	turn-bridge -mode tcp -listen :19302 -target 127.0.0.1:443
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

const (
	maxUDPPacket    = 65535
	maxUDPPayload   = 1400 // Safe UDP payload size (MTU 1500 - IP/UDP headers - margin)
	sessionTimeout  = 5 * time.Minute
	cleanupInterval = 30 * time.Second
	dialTimeout     = 5 * time.Second
	writeTimeout    = 5 * time.Second
)

// session tracks one client connection through the TURN relay.
type session struct {
	mu         sync.Mutex
	clientAddr *net.UDPAddr
	conn       net.Conn // TCP conn (tcp mode) or UDP conn (udp mode)
	lastActive time.Time
	closed     bool
	ready      bool // true after dial() succeeds
}

func (s *session) touch() {
	s.mu.Lock()
	s.lastActive = time.Now()
	s.mu.Unlock()
}

func (s *session) expired() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return time.Since(s.lastActive) > sessionTimeout
}

func (s *session) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.closed = true
	if s.conn != nil {
		s.conn.Close()
	}
}

func (s *session) isClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

// bridge is the main server.
type bridge struct {
	mode       string // "tcp" or "udp"
	listenAddr string
	targetAddr string
	listener   *net.UDPConn

	mu       sync.Mutex
	sessions map[string]*session
}

func (b *bridge) run() error {
	addr, err := net.ResolveUDPAddr("udp", b.listenAddr)
	if err != nil {
		return fmt.Errorf("resolve: %w", err)
	}

	b.listener, err = net.ListenUDP("udp", addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer b.listener.Close()

	_ = b.listener.SetReadBuffer(4 * 1024 * 1024)
	_ = b.listener.SetWriteBuffer(4 * 1024 * 1024)

	log.Printf("[bridge] %s mode | UDP %s -> %s %s", b.mode, b.listenAddr, b.mode, b.targetAddr)

	go b.cleanup()

	buf := make([]byte, maxUDPPacket)
	for {
		n, clientAddr, err := b.listener.ReadFromUDP(buf)
		if err != nil {
			// listener closed
			if b.listener == nil {
				return nil
			}
			log.Printf("[bridge] read: %v", err)
			continue
		}
		if n == 0 {
			continue
		}

		data := make([]byte, n)
		copy(data, buf[:n])

		go b.handle(clientAddr, data)
	}
}

func (b *bridge) handle(clientAddr *net.UDPAddr, data []byte) {
	key := clientAddr.String()

	b.mu.Lock()
	s, exists := b.sessions[key]
	if exists && s.isClosed() {
		delete(b.sessions, key)
		exists = false
	}
	if !exists {
		// Create placeholder session while holding the lock.
		// Don't dial yet — other goroutines will see ready=false and skip.
		s = &session{
			clientAddr: clientAddr,
			lastActive: time.Now(),
		}
		b.sessions[key] = s
		b.mu.Unlock()

		if err := b.dial(s); err != nil {
			log.Printf("[bridge] dial failed %s: %v", key, err)
			b.mu.Lock()
			delete(b.sessions, key)
			b.mu.Unlock()
			return
		}
		// Mark ready only after conn is established.
		s.mu.Lock()
		s.ready = true
		s.mu.Unlock()
		log.Printf("[bridge] new session: %s", key)
	} else {
		b.mu.Unlock()
	}

	// Wait briefly if session is not ready yet (another goroutine is dialing).
	s.mu.Lock()
	ready := s.ready
	s.mu.Unlock()
	if !ready {
		return
	}

	s.touch()

	if err := b.sendToTarget(s, data); err != nil {
		log.Printf("[bridge] send error %s: %v", key, err)
		s.close()
		b.mu.Lock()
		delete(b.sessions, key)
		b.mu.Unlock()
	}
}

func (b *bridge) dial(s *session) error {
	conn, err := net.DialTimeout(b.mode, b.targetAddr, dialTimeout)
	if err != nil {
		return err
	}
	s.conn = conn

	go b.readFromTarget(s)
	return nil
}

func (b *bridge) sendToTarget(s *session, data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return fmt.Errorf("closed")
	}

	_ = s.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
	_, err := s.conn.Write(data)
	return err
}

// readFromTarget reads responses from the target and sends back via UDP.
func (b *bridge) readFromTarget(s *session) {
	defer func() {
		s.close()
		b.mu.Lock()
		delete(b.sessions, s.clientAddr.String())
		b.mu.Unlock()
	}()

	// Use MTU-safe buffer to avoid sending oversized UDP datagrams.
	// TCP Read() fills at most this much — each chunk becomes one UDP datagram.
	buf := make([]byte, maxUDPPayload)
	for {
		_ = s.conn.SetReadDeadline(time.Now().Add(sessionTimeout))
		n, err := s.conn.Read(buf)
		if err != nil {
			return
		}
		if n == 0 {
			continue
		}

		s.touch()

		_, err = b.listener.WriteToUDP(buf[:n], s.clientAddr)
		if err != nil {
			log.Printf("[bridge] udp write to %s: %v", s.clientAddr, err)
			return
		}
	}
}

func (b *bridge) cleanup() {
	ticker := time.NewTicker(cleanupInterval)
	defer ticker.Stop()

	for range ticker.C {
		b.mu.Lock()
		for key, s := range b.sessions {
			if s.expired() {
				log.Printf("[bridge] expired: %s", key)
				s.close()
				delete(b.sessions, key)
			}
		}
		b.mu.Unlock()
	}
}

func main() {
	mode := flag.String("mode", "tcp", "relay mode: tcp or udp")
	listen := flag.String("listen", ":19302", "UDP listen address")
	target := flag.String("target", "127.0.0.1:443", "target address (tcp: Xray, udp: WireGuard)")
	flag.Parse()

	if *mode != "tcp" && *mode != "udp" {
		log.Fatalf("invalid mode %q: must be tcp or udp", *mode)
	}

	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)

	b := &bridge{
		mode:       *mode,
		listenAddr: *listen,
		targetAddr: *target,
		sessions:   make(map[string]*session),
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("[bridge] shutting down")
		if b.listener != nil {
			b.listener.Close()
		}
		os.Exit(0)
	}()

	if err := b.run(); err != nil {
		log.Fatalf("[bridge] fatal: %v", err)
	}
}
