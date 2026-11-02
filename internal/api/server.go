// Package api is the headless JSON API (docs/PROTOCOL.md §5). It stores and
// orders encrypted blobs and checks who may read and write; it never parses
// event content.
package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/Hinkolas/open-balance/internal/protocol"
	"github.com/Hinkolas/open-balance/internal/store"
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

	creationCodeBytes       = 32
	defaultCodeLifetimeHour = 168
	maxCodeLifetimeHours    = 720
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

	mux.HandleFunc("POST /v1/groups", s.creator(s.createGroup))
	mux.HandleFunc("POST /v1/admin/creation-codes", s.owner(s.createCreationCode))
	mux.HandleFunc("GET /v1/admin/creation-codes", s.owner(s.listCreationCodes))
	mux.HandleFunc("DELETE /v1/admin/creation-codes/{id}", s.owner(s.deleteCreationCode))
	mux.HandleFunc("GET /v1/admin/groups", s.owner(s.listGroups))
	mux.HandleFunc("DELETE /v1/admin/groups/{group}", s.owner(s.deleteGroup))

	mux.HandleFunc("POST /v1/groups/{group}/invites", s.signed(roleMember, s.createInvite))
	mux.HandleFunc("DELETE /v1/groups/{group}/invites/{key}", s.signed(roleMember, s.revokeInvite))
	mux.HandleFunc("POST /v1/groups/{group}/claim", s.signed(roleInvite, s.claim))
	mux.HandleFunc("DELETE /v1/groups/{group}/keys/{key}", s.signed(roleMember, s.removeKey))
	mux.HandleFunc("GET /v1/groups/{group}/keyring", s.signed(roleMember, s.keyring))
	mux.HandleFunc("PUT /v1/groups/{group}/recovery", s.signed(roleAdmin, s.replaceRecovery))
	mux.HandleFunc("POST /v1/groups/{group}/recover", s.signed(roleRecovery, s.recoverAdmin))
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
		if !s.isOwner(r) {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "server owner token required")
			return
		}
		next(w, r)
	}
}

func (s *Server) isOwner(r *http.Request) bool {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return s.cfg.AdminToken != "" && ok && subtle.ConstantTimeCompare([]byte(token), []byte(s.cfg.AdminToken)) == 1
}

// creator lets the server owner or the holder of a creation code create a
// group (§5.3). codeHash is nil for the owner; the handler uses the code up.
func (s *Server) creator(next func(w http.ResponseWriter, r *http.Request, codeHash []byte)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.isOwner(r) {
			next(w, r, nil)
			return
		}
		token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		code, err := protocol.B64.DecodeString(token)
		if err != nil || len(code) != creationCodeBytes {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "server owner token or creation code required")
			return
		}
		sum := sha256.Sum256(code)
		next(w, r, sum[:])
	}
}

type role int

const (
	roleMember   role = iota // admin or member, active
	roleAdmin                // admin, active
	roleInvite               // invite, pending
	roleRecovery             // recovery, active
)

type caller struct {
	group uuid.UUID
	key   []byte
	role  string
	seat  []byte
	body  []byte
}

type signedHandler func(w http.ResponseWriter, r *http.Request, c caller)

// signed verifies a OB1 request signature and the key's role in the group (§5.1, §5.2).
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
		case roleRecovery:
			allowed = k.Role == "recovery" && k.Status == "active"
		}
		if !allowed {
			writeErr(w, http.StatusForbidden, "forbidden", "key may not do this")
			return
		}
		next(w, r, caller{group: group, key: req.Key, role: k.Role, seat: k.Seat, body: body})
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
