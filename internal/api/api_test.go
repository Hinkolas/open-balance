package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Hinkolas/open-balance/internal/protocol"
	"github.com/Hinkolas/open-balance/migrations"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
)

const ownerToken = "test-owner-token-0123456789abcdef"

// testServer runs the real router against TEST_DATABASE_URL
// (`skali dev run test` sets it to the dev database). Skipped without it.
func testServer(t *testing.T) *httptest.Server {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := migrations.Up(ctx, stdlib.OpenDBFromPool(pool)); err != nil {
		t.Fatal(err)
	}
	hub := NewHub()
	lctx, cancel := context.WithCancel(ctx)
	t.Cleanup(cancel)
	go hub.Listen(lctx, pool)
	srv := httptest.NewServer(New(Config{Name: "test", AdminToken: ownerToken, MaxGroupEvents: 5, MaxGroupBytes: 1 << 20, AppendsPerMin: 1000}, pool, hub).Handler())
	t.Cleanup(srv.Close)
	return srv
}

type client struct {
	t   *testing.T
	srv *httptest.Server
}

func (c client) do(method, path string, key ed25519.PrivateKey, owner bool, body any) (int, map[string]any) {
	c.t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	req, _ := http.NewRequest(method, c.srv.URL+path, bytes.NewReader(raw))
	if owner {
		req.Header.Set("Authorization", "Bearer "+ownerToken)
	} else if key != nil {
		req.Header.Set("Authorization", protocol.AuthHeader(key, method, path, time.Now().Unix(), raw))
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	var out map[string]any
	json.Unmarshal(b, &out)
	return res.StatusCode, out
}

func newKey() ed25519.PrivateKey {
	_, k, _ := ed25519.GenerateKey(nil)
	return k
}

func pubB64(k ed25519.PrivateKey) string {
	return protocol.B64.EncodeToString(k.Public().(ed25519.PublicKey))
}

func blob(n byte) string {
	b := make([]byte, 1+12+16+256)
	b[0] = protocol.BlobVersion
	b[20] = n
	return protocol.B64.EncodeToString(b)
}

func TestGroupLifecycle(t *testing.T) {
	c := client{t, testServer(t)}
	group := uuid.Must(uuid.NewV7())
	g := "/v1/groups/" + group.String()
	admin, invite, member, stranger := newKey(), newKey(), newKey(), newKey()

	expect := func(what string, got, want int) {
		t.Helper()
		if got != want {
			t.Fatalf("%s: status %d, want %d", what, got, want)
		}
	}

	// Only the server owner creates groups.
	st, _ := c.do("POST", "/v1/groups", nil, false, map[string]any{"groupId": group, "adminKey": pubB64(admin)})
	expect("create without owner token", st, 401)
	st, _ = c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": group, "adminKey": pubB64(admin)})
	expect("create", st, 201)
	st, _ = c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": group, "adminKey": pubB64(admin)})
	expect("create twice", st, 409)

	// Admin appends; strangers can't read.
	e1 := uuid.Must(uuid.NewV7())
	st, out := c.do("POST", g+"/events", admin, false, map[string]any{"events": []any{map[string]any{"id": e1, "blob": blob(1)}}})
	expect("append", st, 200)
	if seq := out["events"].([]any)[0].(map[string]any)["seq"].(float64); seq != 1 {
		t.Fatalf("first seq %v", seq)
	}
	st, out = c.do("POST", g+"/events", admin, false, map[string]any{"events": []any{map[string]any{"id": e1, "blob": blob(1)}}})
	expect("append again", st, 200)
	if seq := out["events"].([]any)[0].(map[string]any)["seq"].(float64); seq != 1 {
		t.Fatalf("replayed append got seq %v", seq)
	}
	st, _ = c.do("GET", g+"/events?after=0", stranger, false, nil)
	expect("stranger reads", st, 403)

	// Invite, claim, member writes.
	st, _ = c.do("POST", g+"/invites", admin, false, map[string]any{"inviteKey": pubB64(invite)})
	expect("invite", st, 201)
	st, _ = c.do("POST", g+"/events", invite, false, map[string]any{"events": []any{map[string]any{"id": uuid.Must(uuid.NewV7()), "blob": blob(2)}}})
	expect("invite key appends", st, 403)
	proof := ed25519.Sign(member, protocol.ClaimInput(group, invite.Public().(ed25519.PublicKey)))
	st, _ = c.do("POST", g+"/claim", invite, false, map[string]any{"memberKey": pubB64(member), "proof": "AAAA"})
	expect("claim with bad proof", st, 400)
	st, _ = c.do("POST", g+"/claim", invite, false, map[string]any{"memberKey": pubB64(member), "proof": protocol.B64.EncodeToString(proof)})
	expect("claim", st, 200)
	st, _ = c.do("POST", g+"/claim", invite, false, map[string]any{"memberKey": pubB64(newKey()), "proof": protocol.B64.EncodeToString(proof)})
	expect("claim twice", st, 403)
	st, _ = c.do("POST", g+"/events", member, false, map[string]any{"events": []any{
		map[string]any{"id": uuid.Must(uuid.NewV7()), "blob": blob(3)},
		map[string]any{"id": uuid.Must(uuid.NewV7()), "blob": blob(4)},
	}})
	expect("member appends", st, 200)

	st, out = c.do("GET", g+"/events?after=1", member, false, nil)
	expect("read", st, 200)
	events := out["events"].([]any)
	if len(events) != 2 || out["head"].(float64) != 3 {
		t.Fatalf("read after 1: %d events, head %v", len(events), out["head"])
	}
	if events[0].(map[string]any)["authorKey"] != pubB64(member) {
		t.Fatal("authorKey not recorded")
	}

	// Quota: MaxGroupEvents is 5.
	st, _ = c.do("POST", g+"/events", member, false, map[string]any{"events": []any{
		map[string]any{"id": uuid.Must(uuid.NewV7()), "blob": blob(5)},
		map[string]any{"id": uuid.Must(uuid.NewV7()), "blob": blob(6)},
		map[string]any{"id": uuid.Must(uuid.NewV7()), "blob": blob(7)},
	}})
	expect("over quota", st, 429)

	// Tampered request: signature over another path.
	req, _ := http.NewRequest("GET", c.srv.URL+g+"/events?after=0", nil)
	req.Header.Set("Authorization", protocol.AuthHeader(member, "GET", g+"/events?after=1", time.Now().Unix(), nil))
	res, _ := http.DefaultClient.Do(req)
	res.Body.Close()
	expect("signature for another path", res.StatusCode, 401)

	st, _ = c.do("DELETE", "/v1/admin/groups/"+group.String(), nil, true, nil)
	expect("owner deletes", st, 204)
	st, _ = c.do("GET", g+"/events", member, false, nil)
	expect("read deleted group", st, 403)
}

// Members invite further devices of their own (§5.2, §5.4 step 5).
func TestDeviceInvites(t *testing.T) {
	c := client{t, testServer(t)}
	group := uuid.Must(uuid.NewV7())
	g := "/v1/groups/" + group.String()
	admin := newKey()

	expect := func(what string, got, want int) {
		t.Helper()
		if got != want {
			t.Fatalf("%s: status %d, want %d", what, got, want)
		}
	}
	invite := func(by ed25519.PrivateKey, role string) (ed25519.PrivateKey, int) {
		t.Helper()
		k := newKey()
		body := map[string]any{"inviteKey": pubB64(k)}
		if role != "" {
			body["role"] = role
		}
		st, _ := c.do("POST", g+"/invites", by, false, body)
		return k, st
	}
	claim := func(inv ed25519.PrivateKey) ed25519.PrivateKey {
		t.Helper()
		dev := newKey()
		proof := ed25519.Sign(dev, protocol.ClaimInput(group, inv.Public().(ed25519.PublicKey)))
		st, _ := c.do("POST", g+"/claim", inv, false, map[string]any{"memberKey": pubB64(dev), "proof": protocol.B64.EncodeToString(proof)})
		expect("claim", st, 200)
		return dev
	}
	revoke := func(by, inv ed25519.PrivateKey) int {
		t.Helper()
		st, _ := c.do("DELETE", g+"/invites/"+pubB64(inv), by, false, nil)
		return st
	}
	appendOK := func(what string, by ed25519.PrivateKey) {
		t.Helper()
		st, _ := c.do("POST", g+"/events", by, false, map[string]any{"events": []any{map[string]any{"id": uuid.Must(uuid.NewV7()), "blob": blob(1)}}})
		expect(what, st, 200)
	}

	st, _ := c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": group, "adminKey": pubB64(admin)})
	expect("create", st, 201)
	inv, st := invite(admin, "")
	expect("admin invites", st, 201)
	memberKey := claim(inv)

	// A member invites its second device; the device can write.
	_, st = invite(memberKey, "admin")
	expect("member grants admin", st, 403)
	_, st = invite(memberKey, "owner")
	expect("unknown role", st, 400)
	devInv, st := invite(memberKey, "member")
	expect("member invites a device", st, 201)
	device2 := claim(devInv)
	appendOK("second device appends", device2)

	// Revoking: the creator and the admin may, other members may not.
	pending, _ := invite(memberKey, "")
	expect("other device revokes", revoke(device2, pending), 404)
	expect("admin revokes", revoke(admin, pending), 204)
	own, _ := invite(memberKey, "")
	expect("creator revokes", revoke(memberKey, own), 204)
	expect("revoke twice", revoke(memberKey, own), 404)

	// The admin's own second device is admin on the server too.
	adminInv, st := invite(admin, "admin")
	expect("admin grants admin", st, 201)
	adminDevice2 := claim(adminInv)
	other, _ := invite(memberKey, "")
	expect("admin's second device revokes", revoke(adminDevice2, other), 204)
	appendOK("admin's second device appends", adminDevice2)
}

func TestStreamWakesOnAppend(t *testing.T) {
	srv := testServer(t)
	c := client{t, srv}
	group := uuid.Must(uuid.NewV7())
	admin := newKey()
	if st, _ := c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": group, "adminKey": pubB64(admin)}); st != 201 {
		t.Fatalf("create: %d", st)
	}
	path := "/v1/groups/" + group.String() + "/stream"
	req, _ := http.NewRequest("GET", srv.URL+path, nil)
	req.Header.Set("Authorization", protocol.AuthHeader(admin, "GET", path, time.Now().Unix(), nil))
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()

	lines := make(chan string, 16)
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := res.Body.Read(buf)
			for _, l := range strings.Split(string(buf[:n]), "\n") {
				if strings.HasPrefix(l, "data:") {
					lines <- l
				}
			}
			if err != nil {
				close(lines)
				return
			}
		}
	}()
	wait := func(want string) {
		t.Helper()
		select {
		case l := <-lines:
			if !strings.Contains(l, want) {
				t.Fatalf("got %q, want %q", l, want)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("no %q within 5s", want)
		}
	}
	wait(`"seq": 0`)
	c.do("POST", "/v1/groups/"+group.String()+"/events", admin, false, map[string]any{"events": []any{map[string]any{"id": uuid.Must(uuid.NewV7()), "blob": blob(1)}}})
	wait(`"seq": 1`)
}
