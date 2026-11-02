package api

import (
	"crypto/ed25519"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/Hinkolas/open-balance/internal/protocol"
	"github.com/Hinkolas/open-balance/internal/store"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// ---- server owner ----

func (s *Server) createGroup(w http.ResponseWriter, r *http.Request) {
	var in struct {
		GroupID  uuid.UUID `json:"groupId"`
		AdminKey string    `json:"adminKey"`
	}
	body, _ := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err := decodeBody(caller{body: body}, &in); err != nil || in.GroupID == uuid.Nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "groupId and adminKey required")
		return
	}
	key, ok := decodeKey(in.AdminKey)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_request", "adminKey must be a base64url Ed25519 public key")
		return
	}
	err := pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		n, err := q.CreateGroup(r.Context(), in.GroupID)
		if err != nil {
			return err
		}
		if n == 0 {
			return errConflict
		}
		_, err = q.InsertKey(r.Context(), store.InsertKeyParams{GroupID: in.GroupID, PublicKey: key, Role: "admin", Status: "active"})
		return err
	})
	if errors.Is(err, errConflict) {
		writeErr(w, http.StatusConflict, "exists", "group already exists")
		return
	} else if err != nil {
		internalErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"groupId": in.GroupID})
}

func (s *Server) listGroups(w http.ResponseWriter, r *http.Request) {
	rows, err := s.q.ListGroups(r.Context())
	if err != nil {
		internalErr(w, r, err)
		return
	}
	type group struct {
		GroupID     uuid.UUID  `json:"groupId"`
		CreatedAt   time.Time  `json:"createdAt"`
		LastWriteAt *time.Time `json:"lastWriteAt"`
		Events      int64      `json:"events"`
		Bytes       int64      `json:"bytes"`
	}
	out := make([]group, 0, len(rows))
	for _, g := range rows {
		var last *time.Time
		if g.LastWriteAt.Valid {
			last = &g.LastWriteAt.Time
		}
		out = append(out, group{g.ID, g.CreatedAt.Time, last, g.HeadSeq, g.BytesUsed})
	}
	writeJSON(w, http.StatusOK, map[string]any{"groups": out})
}

func (s *Server) deleteGroup(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.PathValue("group"))
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "unknown group")
		return
	}
	n, err := s.q.DeleteGroup(r.Context(), id)
	if err != nil {
		internalErr(w, r, err)
		return
	}
	if n == 0 {
		writeErr(w, http.StatusNotFound, "not_found", "unknown group")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- invites and claims ----

// createInvite registers an invite key (§5.3). Any member may: the ledger
// decides whose seat or device it is. Only the admin may grant `admin`, for
// its own further devices.
func (s *Server) createInvite(w http.ResponseWriter, r *http.Request, c caller) {
	var in struct {
		InviteKey string `json:"inviteKey"`
		Role      string `json:"role"`
	}
	_ = decodeBody(c, &in)
	key, ok := decodeKey(in.InviteKey)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_request", "inviteKey must be a base64url Ed25519 public key")
		return
	}
	grant := in.Role
	switch grant {
	case "":
		grant = "member"
	case "member":
	case "admin":
		if c.role != "admin" {
			writeErr(w, http.StatusForbidden, "forbidden", "only the admin may create invites that grant admin")
			return
		}
	default:
		writeErr(w, http.StatusBadRequest, "bad_request", "role must be member or admin")
		return
	}
	n, err := s.q.InsertInvite(r.Context(), store.InsertInviteParams{GroupID: c.group, PublicKey: key, CreatedBy: c.key, GrantRole: &grant})
	if err != nil {
		internalErr(w, r, err)
		return
	}
	if n == 0 {
		writeErr(w, http.StatusConflict, "exists", "key already registered")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{})
}

func (s *Server) revokeInvite(w http.ResponseWriter, r *http.Request, c caller) {
	key, ok := decodeKey(r.PathValue("key"))
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "unknown invite")
		return
	}
	n, err := s.q.RevokeInvite(r.Context(), store.RevokeInviteParams{GroupID: c.group, PublicKey: key, AnyCreator: c.role == "admin", Caller: c.key})
	if err != nil {
		internalErr(w, r, err)
		return
	}
	if n == 0 {
		writeErr(w, http.StatusNotFound, "not_found", "no pending invite with this key that you may revoke")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) claim(w http.ResponseWriter, r *http.Request, c caller) {
	var in struct {
		MemberKey string `json:"memberKey"`
		Proof     string `json:"proof"`
	}
	_ = decodeBody(c, &in)
	key, ok := decodeKey(in.MemberKey)
	proof, err := protocol.B64.DecodeString(in.Proof)
	if !ok || err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "memberKey and proof required")
		return
	}
	if !ed25519.Verify(key, protocol.ClaimInput(c.group, c.key), proof) {
		writeErr(w, http.StatusBadRequest, "bad_proof", "proof does not verify with memberKey")
		return
	}
	err = pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		grant, err := q.ClaimInvite(r.Context(), store.ClaimInviteParams{GroupID: c.group, PublicKey: c.key})
		if errors.Is(err, pgx.ErrNoRows) {
			return errConflict
		} else if err != nil {
			return err
		}
		role := "member"
		if grant != nil {
			role = *grant
		}
		n, err := q.InsertKey(r.Context(), store.InsertKeyParams{GroupID: c.group, PublicKey: key, Role: role, Status: "active"})
		if err != nil {
			return err
		}
		if n == 0 {
			return errConflict
		}
		return nil
	})
	if errors.Is(err, errConflict) {
		writeErr(w, http.StatusConflict, "conflict", "invite already used or member key already registered")
		return
	} else if err != nil {
		internalErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{})
}

// ---- events ----

type eventIn struct {
	ID   uuid.UUID `json:"id"`
	Blob string    `json:"blob"`
}

type seqOut struct {
	ID  uuid.UUID `json:"id"`
	Seq int64     `json:"seq"`
}

func (s *Server) appendEvents(w http.ResponseWriter, r *http.Request, c caller) {
	var in struct {
		Events []eventIn `json:"events"`
	}
	if err := decodeBody(c, &in); err != nil || len(in.Events) == 0 || len(in.Events) > maxEventsPerPost {
		writeErr(w, http.StatusBadRequest, "bad_request", fmt.Sprintf("events: 1 to %d required", maxEventsPerPost))
		return
	}
	blobs := make([][]byte, len(in.Events))
	for i, e := range in.Events {
		b, err := protocol.B64.DecodeString(e.Blob)
		if e.ID == uuid.Nil || err != nil || len(b) < 1+12+16 || len(b) > maxBlobBytes || b[0] != protocol.BlobVersion {
			writeErr(w, http.StatusBadRequest, "bad_event", fmt.Sprintf("event %d: id and a v1 blob up to %d bytes required", i, maxBlobBytes))
			return
		}
		blobs[i] = b
	}
	if !s.limiter.allow(string(c.key), len(in.Events)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many events, slow down")
		return
	}

	out := make([]seqOut, len(in.Events))
	err := pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		g, err := q.LockGroup(r.Context(), c.group)
		if err != nil {
			return err
		}
		head, bytes := g.HeadSeq, g.BytesUsed
		for i, e := range in.Events {
			seq, err := q.GetEventSeq(r.Context(), store.GetEventSeqParams{GroupID: c.group, ID: e.ID})
			if err == nil {
				out[i] = seqOut{e.ID, seq}
				continue
			} else if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
			if head+1 > s.cfg.MaxGroupEvents || bytes+int64(len(blobs[i])) > s.cfg.MaxGroupBytes {
				return errQuota
			}
			head++
			bytes += int64(len(blobs[i]))
			if err := q.InsertEvent(r.Context(), store.InsertEventParams{GroupID: c.group, Seq: head, ID: e.ID, Blob: blobs[i], AuthorKey: c.key}); err != nil {
				return err
			}
			out[i] = seqOut{e.ID, head}
		}
		if head == g.HeadSeq {
			return nil
		}
		if err := q.AdvanceHead(r.Context(), store.AdvanceHeadParams{ID: c.group, HeadSeq: head, BytesUsed: bytes}); err != nil {
			return err
		}
		_, err = tx.Exec(r.Context(), "SELECT pg_notify($1, $2)", notifyChannel, fmt.Sprintf("%s:%d", c.group, head))
		return err
	})
	if errors.Is(err, errQuota) {
		writeErr(w, http.StatusTooManyRequests, "quota", "group storage quota exceeded")
		return
	} else if err != nil {
		internalErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out})
}

func (s *Server) readEvents(w http.ResponseWriter, r *http.Request, c caller) {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	limit, err := strconv.ParseInt(r.URL.Query().Get("limit"), 10, 32)
	if err != nil || limit <= 0 {
		limit = defaultReadLimit
	}
	limit = min(limit, maxReadLimit)
	head, err := s.q.GetHead(r.Context(), c.group)
	if err != nil {
		internalErr(w, r, err)
		return
	}
	rows, err := s.q.ListEvents(r.Context(), store.ListEventsParams{GroupID: c.group, Seq: max(after, 0), Limit: int32(limit)})
	if err != nil {
		internalErr(w, r, err)
		return
	}
	type eventOut struct {
		Seq        int64     `json:"seq"`
		ID         uuid.UUID `json:"id"`
		Blob       string    `json:"blob"`
		AuthorKey  string    `json:"authorKey"`
		ReceivedAt time.Time `json:"receivedAt"`
	}
	out := make([]eventOut, 0, len(rows))
	for _, e := range rows {
		out = append(out, eventOut{e.Seq, e.ID, protocol.B64.EncodeToString(e.Blob), protocol.B64.EncodeToString(e.AuthorKey), e.ReceivedAt.Time})
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out, "head": head})
}

// stream sends `event: head` whenever the group's head moves, and every 30 s.
func (s *Server) stream(w http.ResponseWriter, r *http.Request, c caller) {
	rc := http.NewResponseController(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	updates, cancel := s.hub.Subscribe(c.group)
	defer cancel()
	send := func() bool {
		head, err := s.q.GetHead(r.Context(), c.group)
		if err != nil {
			return false
		}
		if _, err := fmt.Fprintf(w, "event: head\ndata: {\"seq\": %d}\n\n", head); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	if !send() {
		return
	}
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-updates:
		case <-tick.C:
		}
		if !send() {
			return
		}
	}
}

// ---- helpers ----

var (
	errConflict = errors.New("conflict")
	errQuota    = errors.New("quota exceeded")
)

func decodeKey(s string) ([]byte, bool) {
	b, err := protocol.B64.DecodeString(s)
	return b, err == nil && len(b) == ed25519.PublicKeySize
}
