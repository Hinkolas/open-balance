package api

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// notifyChannel carries "<groupId>:<head>" on every append, so every replica
// can wake its stream subscribers.
const notifyChannel = "group_events"

// Hub fans Postgres notifications out to stream subscribers of this replica.
type Hub struct {
	mu   sync.Mutex
	subs map[uuid.UUID]map[chan struct{}]struct{}
}

func NewHub() *Hub {
	return &Hub{subs: map[uuid.UUID]map[chan struct{}]struct{}{}}
}

// Subscribe returns a channel that receives a signal when the group's head
// moves. Signals coalesce; the subscriber reads the current head itself.
func (h *Hub) Subscribe(group uuid.UUID) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	if h.subs[group] == nil {
		h.subs[group] = map[chan struct{}]struct{}{}
	}
	h.subs[group][ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs[group], ch)
		if len(h.subs[group]) == 0 {
			delete(h.subs, group)
		}
		h.mu.Unlock()
	}
}

func (h *Hub) notify(group uuid.UUID) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs[group] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// Listen holds a dedicated connection on LISTEN until ctx ends, reconnecting
// on errors. After a reconnect every subscriber is woken once, since
// notifications may have been missed.
func (h *Hub) Listen(ctx context.Context, pool *pgxpool.Pool) {
	for ctx.Err() == nil {
		if err := h.listenOnce(ctx, pool); err != nil && ctx.Err() == nil {
			slog.Warn("listen failed, retrying", "err", err)
			select {
			case <-ctx.Done():
			case <-time.After(2 * time.Second):
			}
		}
	}
}

func (h *Hub) listenOnce(ctx context.Context, pool *pgxpool.Pool) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "LISTEN "+notifyChannel); err != nil {
		return err
	}
	h.wakeAll()
	for {
		n, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		id, _, _ := strings.Cut(n.Payload, ":")
		if group, err := uuid.Parse(id); err == nil {
			h.notify(group)
		}
	}
}

func (h *Hub) wakeAll() {
	h.mu.Lock()
	groups := make([]uuid.UUID, 0, len(h.subs))
	for g := range h.subs {
		groups = append(groups, g)
	}
	h.mu.Unlock()
	for _, g := range groups {
		h.notify(g)
	}
}
