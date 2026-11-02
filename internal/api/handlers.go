package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
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
	"github.com/jackc/pgx/v5/pgtype"
)

// ---- server owner ----

// createGroup registers a group with its admin and recovery keys. codeHash is
// the creation code used, nil for the server owner (§5.3, §5.4).
func (s *Server) createGroup(w http.ResponseWriter, r *http.Request, codeHash []byte) {
	var in struct {
		GroupID         uuid.UUID `json:"groupId"`
		AdminKey        string    `json:"adminKey"`
		RecoveryKey     string    `json:"recoveryKey"`
		RecoveryKeyring string    `json:"recoveryKeyring"`
	}
	body, _ := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err := decodeBody(caller{body: body}, &in); err != nil || in.GroupID == uuid.Nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "groupId, adminKey, recoveryKey and recoveryKeyring required")
		return
	}
	admin, ok := decodeKey(in.AdminKey)
	recovery, ok2 := decodeKey(in.RecoveryKey)
	if !ok || !ok2 || bytes.Equal(admin, recovery) {
		writeErr(w, http.StatusBadRequest, "bad_request", "adminKey and recoveryKey must be two different base64url Ed25519 public keys")
		return
	}
	keyring, ok := decodeKeyring(in.RecoveryKeyring)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_request", keyringRule)
		return
	}
	err := pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		if codeHash != nil {
			n, err := q.UseCreationCode(r.Context(), store.UseCreationCodeParams{CodeHash: codeHash, GroupID: pgtype.UUID{Bytes: in.GroupID, Valid: true}})
			if err != nil {
				return err
			}
			if n == 0 {
				return errBadCode
			}
		}
		n, err := q.CreateGroup(r.Context(), in.GroupID)
		if err != nil {
			return err
		}
		if n == 0 {
			return errConflict
		}
		// The admin key is the admin's seat (§5.2); the recovery key belongs to it.
		if _, err := q.InsertKey(r.Context(), store.InsertKeyParams{GroupID: in.GroupID, PublicKey: admin, Role: "admin", Status: "active", Seat: admin}); err != nil {
			return err
		}
		_, err = q.InsertKey(r.Context(), store.InsertKeyParams{GroupID: in.GroupID, PublicKey: recovery, Role: "recovery", Status: "active", Seat: admin, Keyring: keyring})
		return err
	})
	if errors.Is(err, errBadCode) {
		writeErr(w, http.StatusUnauthorized, "unauthorized", "creation code is unknown, used, withdrawn or expired")
		return
	} else if errors.Is(err, errConflict) {
		writeErr(w, http.StatusConflict, "exists", "group already exists")
		return
	} else if err != nil {
		internalErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"groupId": in.GroupID})
}

func (s *Server) createCreationCode(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ExpiresInHours *int `json:"expiresInHours"`
	}
	body, _ := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if len(bytes.TrimSpace(body)) > 0 {
		if err := decodeBody(caller{body: body}, &in); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
			return
		}
	}
	hours := defaultCodeLifetimeHour
	if in.ExpiresInHours != nil {
		hours = *in.ExpiresInHours
	}
	if hours < 1 || hours > maxCodeLifetimeHours {
		writeErr(w, http.StatusBadRequest, "bad_request", fmt.Sprintf("expiresInHours must be 1 to %d", maxCodeLifetimeHours))
		return
	}
	code := make([]byte, creationCodeBytes)
	if _, err := rand.Read(code); err != nil {
		internalErr(w, r, err)
		return
	}
	sum := sha256.Sum256(code)
	id := uuid.Must(uuid.NewV7())
	expires := s.now().Add(time.Duration(hours) * time.Hour).UTC().Truncate(time.Second)
	if _, err := s.q.InsertCreationCode(r.Context(), store.InsertCreationCodeParams{ID: id, CodeHash: sum[:], ExpiresAt: pgtype.Timestamptz{Time: expires, Valid: true}}); err != nil {
		internalErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "code": protocol.B64.EncodeToString(code), "expiresAt": expires})
}

func (s *Server) listCreationCodes(w http.ResponseWriter, r *http.Request) {
	rows, err := s.q.ListCreationCodes(r.Context())
	if err != nil {
		internalErr(w, r, err)
		return
	}
	type code struct {
		ID        uuid.UUID  `json:"id"`
		CreatedAt time.Time  `json:"createdAt"`
		ExpiresAt time.Time  `json:"expiresAt"`
		UsedAt    *time.Time `json:"usedAt"`
		GroupID   *uuid.UUID `json:"groupId"`
	}
	out := make([]code, 0, len(rows))
	for _, c := range rows {
		item := code{ID: c.ID, CreatedAt: c.CreatedAt.Time, ExpiresAt: c.ExpiresAt.Time}
		if c.UsedAt.Valid {
			item.UsedAt = &c.UsedAt.Time
		}
		if c.GroupID.Valid {
			g := uuid.UUID(c.GroupID.Bytes)
			item.GroupID = &g
		}
		out = append(out, item)
	}
	writeJSON(w, http.StatusOK, map[string]any{"codes": out})
}

func (s *Server) deleteCreationCode(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "unknown creation code")
		return
	}
	n, err := s.q.DeleteCreationCode(r.Context(), id)
	if err != nil {
		internalErr(w, r, err)
		return
	}
	if n == 0 {
		writeErr(w, http.StatusNotFound, "not_found", "no unused creation code with this id")
		return
	}
	w.WriteHeader(http.StatusNoContent)
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
		Keyring   string `json:"keyring"`
	}
	_ = decodeBody(c, &in)
	key, ok := decodeKey(in.InviteKey)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_request", "inviteKey must be a base64url Ed25519 public key")
		return
	}
	keyring, ok := decodeKeyring(in.Keyring)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_request", keyringRule)
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
	// Seats (§5.2): the admin inviting a member starts a new seat; every
	// other invite is for a further device of the caller's own seat.
	seat := c.seat
	if c.role == "admin" && grant == "member" {
		seat = key
	}
	n, err := s.q.InsertInvite(r.Context(), store.InsertInviteParams{GroupID: c.group, PublicKey: key, CreatedBy: c.key, GrantRole: &grant, Seat: seat, Keyring: keyring})
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
	key, ok := s.claimedKey(w, c)
	if !ok {
		return
	}
	var keyring []byte
	err := pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		inv, err := q.ClaimInvite(r.Context(), store.ClaimInviteParams{GroupID: c.group, PublicKey: c.key})
		if errors.Is(err, pgx.ErrNoRows) {
			return errConflict
		} else if err != nil {
			return err
		}
		role := "member"
		if inv.GrantRole != nil {
			role = *inv.GrantRole
		}
		keyring = inv.Keyring
		n, err := q.InsertKey(r.Context(), store.InsertKeyParams{GroupID: c.group, PublicKey: key, Role: role, Status: "active", Seat: inv.Seat, Keyring: inv.Keyring})
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
	writeJSON(w, http.StatusOK, map[string]any{"keyring": protocol.B64.EncodeToString(keyring)})
}

// keyring returns the keyring the caller's key got with its claim or
// recovery, for a client that lost that response (§5.3).
func (s *Server) keyring(w http.ResponseWriter, r *http.Request, c caller) {
	k, err := s.q.GetKeyring(r.Context(), store.GetKeyringParams{GroupID: c.group, PublicKey: c.key})
	if err != nil {
		internalErr(w, r, err)
		return
	}
	if k == nil {
		writeErr(w, http.StatusNotFound, "not_found", "this key got no keyring")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"keyring": protocol.B64.EncodeToString(k)})
}

// ---- removing keys and recovery ----

// removeKey removes a member or admin key and revokes the invites it created
// (§5.3). The admin removes any, a member only keys of its own seat.
func (s *Server) removeKey(w http.ResponseWriter, r *http.Request, c caller) {
	key, ok := decodeKey(r.PathValue("key"))
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "unknown key")
		return
	}
	err := pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		n, err := q.RemoveKey(r.Context(), store.RemoveKeyParams{GroupID: c.group, PublicKey: key, AnySeat: c.role == "admin", CallerSeat: c.seat})
		if err != nil {
			return err
		}
		if n == 0 {
			return errNotFound
		}
		return q.RevokeInvitesCreatedBy(r.Context(), store.RevokeInvitesCreatedByParams{GroupID: c.group, Creator: key})
	})
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no active key with this value that you may remove")
		return
	} else if err != nil {
		internalErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// replaceRecovery swaps the group's recovery key (§5.4 step 9).
func (s *Server) replaceRecovery(w http.ResponseWriter, r *http.Request, c caller) {
	var in struct {
		RecoveryKey string `json:"recoveryKey"`
		Keyring     string `json:"keyring"`
	}
	_ = decodeBody(c, &in)
	key, ok := decodeKey(in.RecoveryKey)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_request", "recoveryKey must be a base64url Ed25519 public key")
		return
	}
	keyring, ok := decodeKeyring(in.Keyring)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_request", keyringRule)
		return
	}
	err := pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		if err := q.RemoveRecoveryKeys(r.Context(), c.group); err != nil {
			return err
		}
		n, err := q.InsertKey(r.Context(), store.InsertKeyParams{GroupID: c.group, PublicKey: key, Role: "recovery", Status: "active", Seat: c.seat, Keyring: keyring})
		if err != nil {
			return err
		}
		if n == 0 {
			return errConflict
		}
		return nil
	})
	if errors.Is(err, errConflict) {
		writeErr(w, http.StatusConflict, "exists", "key already registered")
		return
	} else if err != nil {
		internalErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// recoverAdmin replaces every device of the admin's seat with memberKey (§5.4 step 8).
func (s *Server) recoverAdmin(w http.ResponseWriter, r *http.Request, c caller) {
	key, ok := s.claimedKey(w, c)
	if !ok {
		return
	}
	var keyring []byte
	err := pgx.BeginFunc(r.Context(), s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		var err error
		if keyring, err = q.GetKeyring(r.Context(), store.GetKeyringParams{GroupID: c.group, PublicKey: c.key}); err != nil {
			return err
		}
		if err := q.RevokeInvitesOfSeat(r.Context(), store.RevokeInvitesOfSeatParams{GroupID: c.group, Seat: c.seat}); err != nil {
			return err
		}
		if err := q.RemoveSeat(r.Context(), store.RemoveSeatParams{GroupID: c.group, Seat: c.seat}); err != nil {
			return err
		}
		n, err := q.InsertKey(r.Context(), store.InsertKeyParams{GroupID: c.group, PublicKey: key, Role: "admin", Status: "active", Seat: c.seat, Keyring: keyring})
		if err != nil {
			return err
		}
		if n == 0 {
			return errConflict
		}
		return nil
	})
	if errors.Is(err, errConflict) {
		writeErr(w, http.StatusConflict, "conflict", "member key already registered")
		return
	} else if err != nil {
		internalErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"keyring": protocol.B64.EncodeToString(keyring)})
}

// claimedKey reads `{memberKey, proof}` and checks that the proof is the
// member key's signature over the caller's key (§5.3).
func (s *Server) claimedKey(w http.ResponseWriter, c caller) ([]byte, bool) {
	var in struct {
		MemberKey string `json:"memberKey"`
		Proof     string `json:"proof"`
	}
	_ = decodeBody(c, &in)
	key, ok := decodeKey(in.MemberKey)
	proof, err := protocol.B64.DecodeString(in.Proof)
	if !ok || err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "memberKey and proof required")
		return nil, false
	}
	if !ed25519.Verify(key, protocol.ClaimInput(c.group, c.key), proof) {
		writeErr(w, http.StatusBadRequest, "bad_proof", "proof does not verify with memberKey")
		return nil, false
	}
	return key, true
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
		if _, epochErr := protocol.BlobEpoch(b); e.ID == uuid.Nil || err != nil || epochErr != nil || len(b) > maxBlobBytes {
			writeErr(w, http.StatusBadRequest, "bad_event", fmt.Sprintf("event %d: id and a version 2 blob up to %d bytes required", i, maxBlobBytes))
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

// stream sends `event: head` whenever the group's head moves, and every 30 s,
// for as long as the caller's key stays active.
func (s *Server) stream(w http.ResponseWriter, r *http.Request, c caller) {
	rc := http.NewResponseController(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	updates, cancel := s.hub.Subscribe(c.group)
	defer cancel()
	send := func() bool {
		// A key removed while the stream is open stops getting heads.
		if k, err := s.q.GetKey(r.Context(), store.GetKeyParams{GroupID: c.group, PublicKey: c.key}); err != nil || k.Status != "active" {
			return false
		}
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
	errNotFound = errors.New("not found")
	errBadCode  = errors.New("bad creation code")
)

const keyringRule = "keyring must be a base64url sealed keyring of at most 64 KiB"

// decodeKeyring checks the size of a sealed keyring (§3.5); its content is
// sealed to a box key the server doesn't have.
func decodeKeyring(s string) ([]byte, bool) {
	b, err := protocol.B64.DecodeString(s)
	return b, err == nil && len(b) >= 32+16+32 && len(b) <= 64<<10
}

func decodeKey(s string) ([]byte, bool) {
	b, err := protocol.B64.DecodeString(s)
	return b, err == nil && len(b) == ed25519.PublicKeySize
}
