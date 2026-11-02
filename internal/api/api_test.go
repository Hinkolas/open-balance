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
	st, _ := c.do("POST", "/v1/groups", nil, false, map[string]any{"groupId": group, "adminKey": pubB64(admin), "recoveryKey": pubB64(newKey())})
	expect("create without owner token", st, 401)
	st, _ = c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": group, "adminKey": pubB64(admin), "recoveryKey": pubB64(newKey())})
	expect("create", st, 201)
	st, _ = c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": group, "adminKey": pubB64(admin), "recoveryKey": pubB64(newKey())})
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

	st, _ := c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": group, "adminKey": pubB64(admin), "recoveryKey": pubB64(newKey())})
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
	if st, _ := c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": group, "adminKey": pubB64(admin), "recoveryKey": pubB64(newKey())}); st != 201 {
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

func expectStatus(t *testing.T, what string, got, want int) {
	t.Helper()
	if got != want {
		t.Fatalf("%s: status %d, want %d", what, got, want)
	}
}

// groupFixture creates a group and helpers to invite, claim and remove keys.
type groupFixture struct {
	c        client
	group    uuid.UUID
	g        string
	admin    ed25519.PrivateKey
	recovery ed25519.PrivateKey
}

func newGroup(t *testing.T, c client) groupFixture {
	t.Helper()
	f := groupFixture{c: c, group: uuid.Must(uuid.NewV7()), admin: newKey(), recovery: newKey()}
	f.g = "/v1/groups/" + f.group.String()
	st, _ := c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": f.group, "adminKey": pubB64(f.admin), "recoveryKey": pubB64(f.recovery)})
	expectStatus(t, "create", st, 201)
	return f
}

func (f groupFixture) invite(by ed25519.PrivateKey, role string) ed25519.PrivateKey {
	f.c.t.Helper()
	k := newKey()
	body := map[string]any{"inviteKey": pubB64(k)}
	if role != "" {
		body["role"] = role
	}
	st, _ := f.c.do("POST", f.g+"/invites", by, false, body)
	expectStatus(f.c.t, "invite", st, 201)
	return k
}

func (f groupFixture) claim(inv ed25519.PrivateKey) ed25519.PrivateKey {
	f.c.t.Helper()
	dev := newKey()
	proof := ed25519.Sign(dev, protocol.ClaimInput(f.group, inv.Public().(ed25519.PublicKey)))
	st, _ := f.c.do("POST", f.g+"/claim", inv, false, map[string]any{"memberKey": pubB64(dev), "proof": protocol.B64.EncodeToString(proof)})
	expectStatus(f.c.t, "claim", st, 200)
	return dev
}

func (f groupFixture) remove(by, key ed25519.PrivateKey) int {
	f.c.t.Helper()
	st, _ := f.c.do("DELETE", f.g+"/keys/"+pubB64(key), by, false, nil)
	return st
}

func (f groupFixture) reads(by ed25519.PrivateKey) int {
	f.c.t.Helper()
	st, _ := f.c.do("GET", f.g+"/events?after=0", by, false, nil)
	return st
}

// Creating a group needs the owner token or an unused, unexpired creation code (§5.3).
func TestCreationCodes(t *testing.T) {
	c := client{t, testServer(t)}
	create := func(auth string) int {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"groupId": uuid.Must(uuid.NewV7()), "adminKey": pubB64(newKey()), "recoveryKey": pubB64(newKey())})
		req, _ := http.NewRequest("POST", c.srv.URL+"/v1/groups", bytes.NewReader(raw))
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}

	st, _ := c.do("POST", "/v1/admin/creation-codes", nil, false, nil)
	expectStatus(t, "code without owner token", st, 401)
	st, _ = c.do("POST", "/v1/admin/creation-codes", nil, true, map[string]any{"expiresInHours": 0})
	expectStatus(t, "code with zero lifetime", st, 400)
	st, out := c.do("POST", "/v1/admin/creation-codes", nil, true, nil)
	expectStatus(t, "code", st, 201)
	code, id := out["code"].(string), out["id"].(string)

	expectStatus(t, "create with a made-up code", create(protocol.B64.EncodeToString(make([]byte, 32))), 401)
	expectStatus(t, "create with code", create(code), 201)
	expectStatus(t, "create with a used code", create(code), 401)
	st, _ = c.do("DELETE", "/v1/admin/creation-codes/"+id, nil, true, nil)
	expectStatus(t, "withdraw a used code", st, 404)

	_, out = c.do("POST", "/v1/admin/creation-codes", nil, true, map[string]any{"expiresInHours": 1})
	st, _ = c.do("DELETE", "/v1/admin/creation-codes/"+out["id"].(string), nil, true, nil)
	expectStatus(t, "withdraw", st, 204)
	expectStatus(t, "create with a withdrawn code", create(out["code"].(string)), 401)

	st, out = c.do("GET", "/v1/admin/creation-codes", nil, true, nil)
	expectStatus(t, "list", st, 200)
	found := false
	for _, item := range out["codes"].([]any) {
		m := item.(map[string]any)
		if _, leaks := m["code"]; leaks {
			t.Fatal("list returns codes")
		}
		if m["id"] == id && m["usedAt"] != nil && m["groupId"] != nil {
			found = true
		}
	}
	if !found {
		t.Fatal("used code not listed with its group")
	}

	// The same key can't be admin and recovery key.
	k := pubB64(newKey())
	st, _ = c.do("POST", "/v1/groups", nil, true, map[string]any{"groupId": uuid.Must(uuid.NewV7()), "adminKey": k, "recoveryKey": k})
	expectStatus(t, "admin key as recovery key", st, 400)
}

// Members remove keys of their own seat, the admin any key (§5.2, §5.4 steps 6, 7).
func TestRemoveKeys(t *testing.T) {
	f := newGroup(t, client{t, testServer(t)})
	anna := f.claim(f.invite(f.admin, ""))
	annaPhone := f.claim(f.invite(anna, ""))
	annaPending := f.invite(annaPhone, "")
	ben := f.claim(f.invite(f.admin, ""))
	adminPhone := f.claim(f.invite(f.admin, "admin"))

	expectStatus(t, "member removes another member's key", f.remove(ben, anna), 404)
	expectStatus(t, "member removes the admin's key", f.remove(ben, adminPhone), 404)
	expectStatus(t, "admin removes the recovery key", f.remove(f.admin, f.recovery), 404)

	// Anna removes her lost device: it is cut off, the invites it made die with it.
	expectStatus(t, "member removes its own device", f.remove(anna, annaPhone), 204)
	expectStatus(t, "removed device reads", f.reads(annaPhone), 403)
	expectStatus(t, "remove twice", f.remove(anna, annaPhone), 404)
	st, _ := f.c.do("DELETE", f.g+"/invites/"+pubB64(annaPending), f.admin, false, nil)
	expectStatus(t, "pending invite of a removed device", st, 404)

	// The admin resets Ben: removes his key and invites a new first device.
	pending := f.invite(ben, "")
	expectStatus(t, "admin removes a member's key", f.remove(f.admin, ben), 204)
	dev := newKey()
	proof := ed25519.Sign(dev, protocol.ClaimInput(f.group, pending.Public().(ed25519.PublicKey)))
	st, _ = f.c.do("POST", f.g+"/claim", pending, false, map[string]any{"memberKey": pubB64(dev), "proof": protocol.B64.EncodeToString(proof)})
	expectStatus(t, "claim an invite of a removed key", st, 403)
	benNew := f.claim(f.invite(f.admin, ""))
	expectStatus(t, "Ben's new device reads", f.reads(benNew), 200)
	expectStatus(t, "Ben's new device removes Anna", f.remove(benNew, anna), 404)

	// The admin's devices share a seat.
	expectStatus(t, "admin device removes another admin device", f.remove(adminPhone, f.admin), 204)
	expectStatus(t, "removed admin device reads", f.reads(f.admin), 403)
	expectStatus(t, "remaining admin device reads", f.reads(adminPhone), 200)
}

// The recovery key replaces every admin device (§5.4 steps 8, 9).
func TestRecovery(t *testing.T) {
	f := newGroup(t, client{t, testServer(t)})
	adminPhone := f.claim(f.invite(f.admin, "admin"))
	pendingMember := f.invite(f.admin, "")
	anna := f.claim(f.invite(f.admin, ""))

	recoverWith := func(rk ed25519.PrivateKey) (ed25519.PrivateKey, int) {
		t.Helper()
		dev := newKey()
		proof := ed25519.Sign(dev, protocol.ClaimInput(f.group, rk.Public().(ed25519.PublicKey)))
		st, _ := f.c.do("POST", f.g+"/recover", rk, false, map[string]any{"memberKey": pubB64(dev), "proof": protocol.B64.EncodeToString(proof)})
		return dev, st
	}

	expectStatus(t, "recovery key reads", f.reads(f.recovery), 403)
	_, st := recoverWith(anna)
	expectStatus(t, "member recovers", st, 403)
	dev := newKey()
	st, _ = f.c.do("POST", f.g+"/recover", f.recovery, false, map[string]any{"memberKey": pubB64(dev), "proof": "AAAA"})
	expectStatus(t, "recover with a bad proof", st, 400)

	restored, st := recoverWith(f.recovery)
	expectStatus(t, "recover", st, 200)
	expectStatus(t, "old admin device reads", f.reads(f.admin), 403)
	expectStatus(t, "other old admin device reads", f.reads(adminPhone), 403)
	expectStatus(t, "restored device reads", f.reads(restored), 200)
	expectStatus(t, "member still reads", f.reads(anna), 200)
	st, _ = f.c.do("DELETE", f.g+"/invites/"+pubB64(pendingMember), restored, false, nil)
	expectStatus(t, "old admin's pending invite was revoked", st, 404)
	expectStatus(t, "restored device is admin", f.remove(restored, anna), 204)

	// Only the admin replaces the recovery key; the old one stops working.
	next := newKey()
	st, _ = f.c.do("PUT", f.g+"/recovery", anna, false, map[string]any{"recoveryKey": pubB64(next)})
	expectStatus(t, "removed member replaces recovery key", st, 403)
	member := f.claim(f.invite(restored, ""))
	st, _ = f.c.do("PUT", f.g+"/recovery", member, false, map[string]any{"recoveryKey": pubB64(next)})
	expectStatus(t, "member replaces recovery key", st, 403)
	st, _ = f.c.do("PUT", f.g+"/recovery", restored, false, map[string]any{"recoveryKey": pubB64(next)})
	expectStatus(t, "admin replaces recovery key", st, 204)
	st, _ = f.c.do("PUT", f.g+"/recovery", restored, false, map[string]any{"recoveryKey": pubB64(next)})
	expectStatus(t, "reuse a key", st, 409)
	_, st = recoverWith(f.recovery)
	expectStatus(t, "recover with the old key", st, 403)
	again, st := recoverWith(next)
	expectStatus(t, "recover with the new key", st, 200)
	expectStatus(t, "previous restored device reads", f.reads(restored), 403)
	expectStatus(t, "second restored device reads", f.reads(again), 200)
}
