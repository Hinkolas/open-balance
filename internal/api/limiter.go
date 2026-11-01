package api

import (
	"sync"
	"time"
)

// limiter is a fixed-window counter per key, per replica. Good enough to stop
// a runaway client; quotas in the database are the hard limit.
type limiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	counts map[string]*windowCount
	now    func() time.Time
}

type windowCount struct {
	start time.Time
	n     int
}

func newLimiter(max int, window time.Duration) *limiter {
	return &limiter{max: max, window: window, counts: map[string]*windowCount{}, now: time.Now}
}

func (l *limiter) allow(key string, n int) bool {
	if l.max <= 0 {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if len(l.counts) > 10000 {
		for k, c := range l.counts {
			if now.Sub(c.start) >= l.window {
				delete(l.counts, k)
			}
		}
	}
	c := l.counts[key]
	if c == nil || now.Sub(c.start) >= l.window {
		c = &windowCount{start: now}
		l.counts[key] = c
	}
	if c.n+n > l.max {
		return false
	}
	c.n += n
	return true
}
