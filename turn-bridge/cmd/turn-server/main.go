// turn-server is the VPS-side component of the TURN bridge.
//
// It listens on a UDP port for KCP connections (encrypted with a PSK),
// multiplexes streams via smux, and relays each stream to a local TCP
// target (typically Xray VLESS+Reality on 127.0.0.1:443).
//
// Architecture:
//
//	Client → TURN relay (UDP) → [turn-server :19302] → KCP → smux → TCP → Xray
//
// Security:
//   - AES-128 encryption on all KCP packets (derived from PSK via PBKDF2)
//   - FEC (10+3) for ~23% packet loss tolerance
//   - Per-IP rate limiting on new connections
//   - Configurable max session/stream limits
//   - Graceful shutdown via SIGINT/SIGTERM
package main

import (
	"context"
	"crypto/sha256"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/tarik1377/AccessLicense/turn-bridge/internal/ratelimit"
	"github.com/xtaci/kcp-go/v5"
	"github.com/xtaci/smux"
	"golang.org/x/crypto/pbkdf2"
)

const (
	kcpMTU          = 1400
	kcpSndWnd       = 1024
	kcpRcvWnd       = 1024
	kcpDataShards   = 10
	kcpParityShards = 3
	dialTimeout     = 5 * time.Second
	relayBufSize    = 32 * 1024
)

func main() {
	listen := flag.String("listen", ":19302", "UDP listen address")
	target := flag.String("target", "127.0.0.1:443", "TCP target address (Xray)")
	psk := flag.String("psk", "", "Pre-shared key for encryption/authentication (required)")
	maxSessions := flag.Int("max-sessions", 500, "Maximum concurrent KCP sessions")
	maxStreams := flag.Int("max-streams", 100, "Maximum streams per session")
	rateLimit := flag.Int("rate-limit", 30, "New connections per second per source IP")
	flag.Parse()

	if *psk == "" {
		log.Fatal("[server] --psk is required")
	}

	// Derive AES key from PSK via PBKDF2.
	key := pbkdf2.Key([]byte(*psk), []byte("turn-bridge-v1-salt"), 4096, 16, sha256.New)
	block, err := kcp.NewAESBlockCrypt(key)
	if err != nil {
		log.Fatalf("[server] AES init: %v", err)
	}

	listener, err := kcp.ListenWithOptions(*listen, block, kcpDataShards, kcpParityShards)
	if err != nil {
		log.Fatalf("[server] listen %s: %v", *listen, err)
	}
	defer listener.Close()

	if err := listener.SetReadBuffer(4 * 1024 * 1024); err != nil {
		log.Printf("[server] set read buffer: %v", err)
	}
	if err := listener.SetWriteBuffer(4 * 1024 * 1024); err != nil {
		log.Printf("[server] set write buffer: %v", err)
	}

	log.Printf("[server] listening on %s (UDP/KCP) → %s (TCP)", *listen, *target)
	log.Printf("[server] max sessions=%d, max streams/session=%d, rate=%d/s",
		*maxSessions, *maxStreams, *rateLimit)

	// Graceful shutdown.
	ctx, cancel := context.WithCancel(context.Background())
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Printf("[server] received %v, shutting down...", sig)
		cancel()
		listener.Close()
	}()

	rl := ratelimit.New(*rateLimit, time.Second)
	defer rl.Stop()

	var (
		sessionCount int64
		wg           sync.WaitGroup
	)

	for {
		conn, err := listener.AcceptKCP()
		if err != nil {
			select {
			case <-ctx.Done():
				log.Println("[server] waiting for active sessions to finish...")
				wg.Wait()
				log.Println("[server] shutdown complete")
				return
			default:
				log.Printf("[server] accept: %v", err)
				continue
			}
		}

		current := atomic.LoadInt64(&sessionCount)
		if current >= int64(*maxSessions) {
			log.Printf("[server] session limit (%d), rejecting %s", *maxSessions, conn.RemoteAddr())
			conn.Close()
			continue
		}

		remoteIP := conn.RemoteAddr().(*net.UDPAddr).IP.String()
		if !rl.Allow(remoteIP) {
			log.Printf("[server] rate limited: %s", remoteIP)
			conn.Close()
			continue
		}

		atomic.AddInt64(&sessionCount, 1)
		wg.Add(1)

		go func() {
			defer wg.Done()
			defer atomic.AddInt64(&sessionCount, -1)
			serveSession(ctx, conn, *target, *maxStreams)
		}()
	}
}

func serveSession(ctx context.Context, conn *kcp.UDPSession, target string, maxStreams int) {
	defer conn.Close()

	conn.SetStreamMode(true)
	conn.SetWriteDelay(false)
	conn.SetNoDelay(1, 20, 2, 1)
	conn.SetMtu(kcpMTU)
	conn.SetWindowSize(kcpSndWnd, kcpRcvWnd)
	conn.SetACKNoDelay(true)

	cfg := smux.DefaultConfig()
	cfg.MaxFrameSize = 32768
	cfg.MaxReceiveBuffer = 4 * 1024 * 1024
	cfg.MaxStreamBuffer = 4 * 1024 * 1024
	cfg.KeepAliveInterval = 10 * time.Second
	cfg.KeepAliveTimeout = 30 * time.Second

	session, err := smux.Server(conn, cfg)
	if err != nil {
		log.Printf("[server] smux init for %s: %v", conn.RemoteAddr(), err)
		return
	}
	defer session.Close()

	log.Printf("[server] session opened: %s", conn.RemoteAddr())

	var (
		streamCount int64
		wg          sync.WaitGroup
	)

	for {
		stream, err := session.AcceptStream()
		if err != nil {
			if !session.IsClosed() {
				log.Printf("[server] accept stream from %s: %v", conn.RemoteAddr(), err)
			}
			break
		}

		if atomic.LoadInt64(&streamCount) >= int64(maxStreams) {
			log.Printf("[server] stream limit for %s", conn.RemoteAddr())
			stream.Close()
			continue
		}

		atomic.AddInt64(&streamCount, 1)
		wg.Add(1)

		go func() {
			defer wg.Done()
			defer atomic.AddInt64(&streamCount, -1)
			relayStream(ctx, stream, target)
		}()
	}

	wg.Wait()
	log.Printf("[server] session closed: %s", conn.RemoteAddr())
}

func relayStream(ctx context.Context, stream *smux.Stream, target string) {
	defer stream.Close()

	tcpConn, err := net.DialTimeout("tcp", target, dialTimeout)
	if err != nil {
		log.Printf("[server] dial %s: %v", target, err)
		return
	}
	defer tcpConn.Close()

	done := make(chan struct{}, 2)

	go func() {
		buf := make([]byte, relayBufSize)
		io.CopyBuffer(tcpConn, stream, buf)
		if tc, ok := tcpConn.(*net.TCPConn); ok {
			tc.CloseWrite()
		}
		done <- struct{}{}
	}()

	go func() {
		buf := make([]byte, relayBufSize)
		io.CopyBuffer(stream, tcpConn, buf)
		stream.Close()
		done <- struct{}{}
	}()

	select {
	case <-done:
		// Wait briefly for the other direction to finish.
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
	case <-ctx.Done():
	}
}
