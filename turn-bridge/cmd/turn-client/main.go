// turn-client is the user-side component of the TURN bridge.
//
// It establishes a TURN relay through a VK TURN server, creates a KCP
// connection over that relay to the VPS, and multiplexes local TCP
// connections through smux streams.
//
// Architecture:
//
//	Local app → TCP → [turn-client :1080] → smux → KCP → TURN relay → UDP → VPS
//
// Usage:
//
//	turn-client \
//	  --turn-server turn.vk.com:3478 \
//	  --turn-user "username" \
//	  --turn-pass "password" \
//	  --vps 203.0.113.1:19302 \
//	  --psk "shared-secret" \
//	  --local 127.0.0.1:1080
package main

import (
	"context"
	"crypto/sha256"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/tarik1377/AccessLicense/turn-bridge/internal/turn"
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
	turnChannel     = 0x4000
	relayBufSize    = 32 * 1024
	refreshInterval = 3 * time.Minute
)

func main() {
	turnServer := flag.String("turn-server", "", "TURN server address (host:port)")
	turnUser := flag.String("turn-user", "", "TURN username")
	turnPass := flag.String("turn-pass", "", "TURN password")
	vpsAddr := flag.String("vps", "", "VPS bridge address (IP:port)")
	psk := flag.String("psk", "", "Pre-shared key (must match server)")
	localAddr := flag.String("local", "127.0.0.1:1080", "Local TCP listen address")
	flag.Parse()

	if *turnServer == "" || *turnUser == "" || *turnPass == "" {
		log.Fatal("[client] --turn-server, --turn-user, --turn-pass are required")
	}
	if *vpsAddr == "" || *psk == "" {
		log.Fatal("[client] --vps and --psk are required")
	}

	// Resolve VPS address.
	vpsUDP, err := net.ResolveUDPAddr("udp", *vpsAddr)
	if err != nil {
		log.Fatalf("[client] resolve VPS: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("[client] shutting down...")
		cancel()
	}()

	// Step 1: Establish TURN relay.
	log.Printf("[client] connecting to TURN server %s", *turnServer)
	turnClient, err := turn.NewClient(*turnServer, *turnUser, *turnPass)
	if err != nil {
		log.Fatalf("[client] TURN connect: %v", err)
	}
	defer turnClient.Close()

	relayAddr, err := turnClient.Allocate()
	if err != nil {
		log.Fatalf("[client] TURN allocate: %v", err)
	}
	log.Printf("[client] relay allocated: %s", relayAddr)

	// Step 2: Create permission and bind channel for VPS.
	if err := turnClient.CreatePermission(vpsUDP.IP); err != nil {
		log.Fatalf("[client] TURN permission: %v", err)
	}

	if err := turnClient.ChannelBind(vpsUDP, turnChannel); err != nil {
		log.Fatalf("[client] TURN channel bind: %v", err)
	}

	// Start receiving TURN data.
	turnClient.StartReceiver()

	// Step 3: Start TURN refresh loop.
	go refreshLoop(ctx, turnClient)

	// Step 4: Establish KCP connection over TURN relay.
	relayConn := turn.NewRelayPacketConn(turnClient, vpsUDP)

	key := pbkdf2.Key([]byte(*psk), []byte("turn-bridge-v1-salt"), 4096, 16, sha256.New)
	block, err := kcp.NewAESBlockCrypt(key)
	if err != nil {
		log.Fatalf("[client] AES init: %v", err)
	}

	kcpConn, err := kcp.NewConn2(vpsUDP, block, kcpDataShards, kcpParityShards, relayConn)
	if err != nil {
		log.Fatalf("[client] KCP dial: %v", err)
	}
	defer kcpConn.Close()

	kcpConn.SetStreamMode(true)
	kcpConn.SetWriteDelay(false)
	kcpConn.SetNoDelay(1, 20, 2, 1)
	kcpConn.SetMtu(kcpMTU)
	kcpConn.SetWindowSize(kcpSndWnd, kcpRcvWnd)
	kcpConn.SetACKNoDelay(true)

	// Step 5: Create smux session.
	cfg := smux.DefaultConfig()
	cfg.MaxFrameSize = 32768
	cfg.MaxReceiveBuffer = 4 * 1024 * 1024
	cfg.MaxStreamBuffer = 4 * 1024 * 1024
	cfg.KeepAliveInterval = 10 * time.Second
	cfg.KeepAliveTimeout = 30 * time.Second

	smuxSession, err := smux.Client(kcpConn, cfg)
	if err != nil {
		log.Fatalf("[client] smux init: %v", err)
	}
	defer smuxSession.Close()

	log.Printf("[client] KCP+smux tunnel established via relay %s → %s", relayAddr, *vpsAddr)

	// Step 6: Accept local TCP connections.
	ln, err := net.Listen("tcp", *localAddr)
	if err != nil {
		log.Fatalf("[client] listen %s: %v", *localAddr, err)
	}
	defer ln.Close()

	log.Printf("[client] accepting connections on %s", *localAddr)

	// Close listener on context cancel.
	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	var (
		connCount int64
		wg        sync.WaitGroup
	)

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				wg.Wait()
				log.Println("[client] shutdown complete")
				return
			default:
				log.Printf("[client] accept: %v", err)
				continue
			}
		}

		if atomic.LoadInt64(&connCount) >= 100 {
			log.Printf("[client] connection limit reached")
			conn.Close()
			continue
		}

		stream, err := smuxSession.OpenStream()
		if err != nil {
			log.Printf("[client] open stream: %v", err)
			conn.Close()
			if smuxSession.IsClosed() {
				log.Println("[client] smux session closed, exiting")
				cancel()
				break
			}
			continue
		}

		atomic.AddInt64(&connCount, 1)
		wg.Add(1)

		go func() {
			defer wg.Done()
			defer atomic.AddInt64(&connCount, -1)
			relay(conn, stream)
		}()
	}

	wg.Wait()
}

func relay(local net.Conn, stream *smux.Stream) {
	defer local.Close()
	defer stream.Close()

	done := make(chan struct{}, 2)

	go func() {
		buf := make([]byte, relayBufSize)
		io.CopyBuffer(stream, local, buf)
		stream.Close()
		done <- struct{}{}
	}()

	go func() {
		buf := make([]byte, relayBufSize)
		io.CopyBuffer(local, stream, buf)
		if tc, ok := local.(*net.TCPConn); ok {
			tc.CloseWrite()
		}
		done <- struct{}{}
	}()

	<-done
	select {
	case <-done:
	case <-time.After(5 * time.Second):
	}
}

func refreshLoop(ctx context.Context, client *turn.Client) {
	ticker := time.NewTicker(refreshInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			if err := client.Refresh(600); err != nil {
				log.Printf("[client] TURN refresh failed: %v", err)
			}
		case <-ctx.Done():
			// Send zero-lifetime refresh to deallocate.
			if err := client.Refresh(0); err != nil {
				log.Printf("[client] TURN dealloc: %v", err)
			}
			return
		}
	}
}

func init() {
	// Validate flags at runtime.
	log.SetFlags(log.LstdFlags | log.Lshortfile)
}

// version information, set at build time.
var version = "dev"

func init() {
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Printf("turn-client %s\n", version)
		os.Exit(0)
	}
}
