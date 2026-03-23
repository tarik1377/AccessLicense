// Package ratelimit provides a simple per-key token bucket rate limiter.
package ratelimit

import (
	"sync"
	"time"
)

// Limiter tracks request counts per key within a sliding window.
type Limiter struct {
	mu     sync.Mutex
	counts map[string]int
	limit  int
	done   chan struct{}
}

// New creates a rate limiter allowing 'limit' requests per 'window' per key.
func New(limit int, window time.Duration) *Limiter {
	l := &Limiter{
		counts: make(map[string]int),
		limit:  limit,
		done:   make(chan struct{}),
	}
	go l.reset(window)
	return l
}

// Allow returns true if the key hasn't exceeded its rate limit.
func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.counts[key] >= l.limit {
		return false
	}
	l.counts[key]++
	return true
}

// Stop terminates the background cleanup goroutine.
func (l *Limiter) Stop() {
	close(l.done)
}

func (l *Limiter) reset(window time.Duration) {
	ticker := time.NewTicker(window)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			l.mu.Lock()
			l.counts = make(map[string]int)
			l.mu.Unlock()
		case <-l.done:
			return
		}
	}
}
