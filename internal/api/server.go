// Package api is the headless JSON API (docs/PROTOCOL.md §5). It stores and
// orders encrypted blobs and checks who may read and write; it never parses
// event content.
package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/KiloHertz-IT/group-balance/internal/protocol"
	"github.com/KiloHertz-IT/group-balance/internal/store"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Config holds the server settings that come from the environment.
type Config struct {
	Name           string
	Version        string
	AdminToken     string
	MaxGroupEvents int64
	MaxGroupBytes  int64
	AppendsPerMin  int
}

const (
	maxBlobBytes     = 64 << 10
	maxEventsPerPost = 100
	maxBodyBytes     = 12 << 20
	defaultReadLimit = 500
	maxReadLimit     = 1000
)

// Server wires handlers to the database.
type Server struct {
	cfg     Config
	pool    *pgxpool.Pool
	q       *store.Queries
	hub     *Hub
	limiter *limiter
	now     func() time.Time
}

func New(cfg Config, pool *pgxpool.Pool, hub *Hub) *Server {
	return &Server{
		cfg:     cfg,
		pool:    pool,
		q:       store.New(pool),
		hub:     hub,
		limiter: newLimiter(cfg.AppendsPerMin, time.Minute),
		now:     time.Now,
	}
}

// Handler returns the router with request logging.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /readyz", s.ready)
	mux.HandleFunc("GET /v1/info", s.info)

	mux.HandleFunc("POST /v1/groups", s.owner(s.createGroup))
	mux.HandleFunc("GET /v1/admin/groups", s.owner(s.listGroups))
	mux.HandleFunc("DELETE /v1/admin/groups/{group}", s.owner(s.deleteGroup))

	mux.HandleFunc("POST /v1/groups/{group}/invites", s.signed(roleAdmin, s.createInvite))
	mux.HandleFunc("DELETE /v1/groups/{group}/invites/{key}", s.signed(roleAdmin, s.revokeInvite))
	mux.HandleFunc("POST /v1/groups/{group}/claim", s.signed(roleInvite, s.claim))
	mux.HandleFunc("POST /v1/groups/{group}/events", s.signed(roleMember, s.appendEvents))
	mux.HandleFunc("GET /v1/groups/{group}/events", s.signed(roleMember, s.readEvents))
	mux.HandleFunc("GET /v1/groups/{group}/stream", s.signed(roleMember, s.stream))
	return logRequests(mux)
}

func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	if err := s.pool.Ping(r.Context()); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "database unreachable")
		return
	}
	w.Write([]byte("ok"))
}

func (s *Server) info(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"name": s.cfg.Name, "version": s.cfg.Version, "protocols": []int{1}})
}

// owner guards the server-owner endpoints with ADMIN_TOKEN.
func (s *Server) owner(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if s.cfg.AdminToken == "" || !ok || subtle.ConstantTimeCompare([]byte(token), []byte(s.cfg.AdminToken)) != 1 {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "server owner token required")
			return
		}
		next(w, r)
	}
}

type role int

const (
	roleMember role = iota // admin or member, active
	roleAdmin              // admin, active
	roleInvite             // invite, pending
)

type caller struct {
	group uuid.UUID
	key   []byte
	role  string
	body  []byte
}

type signedHandler func(w http.ResponseWriter, r *http.Request, c caller)

// signed verifies a GB1 request signature and the key's role in the group (§5.1, §5.2).
func (s *Server) signed(need role, next signedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		group, err := uuid.Parse(r.PathValue("group"))
		if err != nil {
			writeErr(w, http.StatusNotFound, "not_found", "unknown group")
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
		if err != nil {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "request body too large")
			return
		}
		req, err := protocol.ParseAuthHeader(r.Header.Get("Authorization"))
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "unauthorized", err.Error())
			return
		}
		if skew := s.now().Unix() - req.TS; skew > protocol.MaxClockSkewSeconds || skew < -protocol.MaxClockSkewSeconds {
			writeErr(w, http.StatusUnauthorized, "clock_skew", "request timestamp too far from server time")
			return
		}
		if !req.Verify(r.Method, r.RequestURI, body) {
			writeErr(w, http.StatusUnauthorized, "bad_signature", "request signature does not verify")
			return
		}
		k, err := s.q.GetKey(r.Context(), store.GetKeyParams{GroupID: group, PublicKey: req.Key})
		if errors.Is(err, pgx.ErrNoRows) {
			writeErr(w, http.StatusForbidden, "forbidden", "key is not registered for this group")
			return
		} else if err != nil {
			internalErr(w, r, err)
			return
		}
		allowed := false
		switch need {
		case roleMember:
			allowed = (k.Role == "admin" || k.Role == "member") && k.Status == "active"
		case roleAdmin:
			allowed = k.Role == "admin" && k.Status == "active"
		case roleInvite:
			allowed = k.Role == "invite" && k.Status == "pending"
		}
		if !allowed {
			writeErr(w, http.StatusForbidden, "forbidden", "key may not do this")
			return
		}
		next(w, r, caller{group: group, key: req.Key, role: k.Role, body: body})
	}
}

func decodeBody(c caller, v any) error {
	if err := json.Unmarshal(c.body, v); err != nil {
		return errors.New("invalid JSON body")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": msg}})
}

func internalErr(w http.ResponseWriter, r *http.Request, err error) {
	slog.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
	writeErr(w, http.StatusInternalServerError, "internal", "internal error")
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

// logRequests logs method, path, status and duration. Never headers: they
// carry the owner token and signatures.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			return
		}
		slog.Info("request", "method", r.Method, "path", r.URL.Path, "status", rec.status, "ms", time.Since(start).Milliseconds())
	})
}
