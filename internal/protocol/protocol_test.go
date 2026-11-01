package protocol

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"os"
	"testing"

	"github.com/google/uuid"
)

func TestEventRoundTrip(t *testing.T) {
	secret := make([]byte, 32)
	rand.Read(secret)
	group, event := uuid.Must(uuid.NewV7()), uuid.Must(uuid.NewV7())
	_, priv, _ := ed25519.GenerateKey(nil)
	key, err := DeriveEncKey(secret, group)
	if err != nil {
		t.Fatal(err)
	}
	body := []byte(`{"v":1,"type":"group.updated"}`)
	blob, err := SealEvent(key, group, event, body, priv)
	if err != nil {
		t.Fatal(err)
	}
	if (len(blob)-1-12-16)%PadBlock != 0 {
		t.Fatalf("plaintext not padded: blob %d bytes", len(blob))
	}
	got, sig, err := OpenEvent(key, group, event, blob)
	if err != nil || !bytes.Equal(got, body) {
		t.Fatalf("open: %v %q", err, got)
	}
	if !VerifyEvent(priv.Public().(ed25519.PublicKey), group, event, got, sig) {
		t.Fatal("signature does not verify")
	}
	if _, _, err := OpenEvent(key, uuid.Must(uuid.NewV7()), event, blob); err == nil {
		t.Fatal("blob opened under another group id")
	}
}

func TestRequestAuth(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(nil)
	h := AuthHeader(priv, "POST", "/v1/groups/x/events?a=1", 1700000000, []byte("{}"))
	r, err := ParseAuthHeader(h)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Verify("POST", "/v1/groups/x/events?a=1", []byte("{}")) {
		t.Fatal("does not verify")
	}
	if r.Verify("POST", "/v1/groups/x/events?a=2", []byte("{}")) || r.Verify("POST", "/v1/groups/x/events?a=1", []byte("{ }")) {
		t.Fatal("verifies a different request")
	}
}

// TestCryptoVectors checks the committed spec/vectors/crypto.json against this
// implementation, so a protocol change without regenerating fails.
func TestCryptoVectors(t *testing.T) {
	raw, err := os.ReadFile("../../spec/vectors/crypto.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Keys struct {
			GroupSecret, GroupID, EncKey string
		}
		Events []struct {
			ID, Nonce, Body, AuthorPublicKey, Signature, Blob, Chain string
			Seq                                                     uint64
		}
		Requests []struct {
			Method, PathAndQuery, Body, SigningInput, Authorization string
			TS                                                      int64
		}
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	d := func(s string) []byte { b, _ := B64.DecodeString(s); return b }
	group := uuid.MustParse(v.Keys.GroupID)
	key, _ := DeriveEncKey(d(v.Keys.GroupSecret), group)
	if !bytes.Equal(key, d(v.Keys.EncKey)) {
		t.Fatal("encKey differs")
	}
	var chain [32]byte
	for _, e := range v.Events {
		id := uuid.MustParse(e.ID)
		body, sig, err := OpenEvent(key, group, id, d(e.Blob))
		if err != nil || string(body) != e.Body || !bytes.Equal(sig, d(e.Signature)) {
			t.Fatalf("event %d: open %v", e.Seq, err)
		}
		if !VerifyEvent(d(e.AuthorPublicKey), group, id, body, sig) {
			t.Fatalf("event %d: signature", e.Seq)
		}
		chain = ChainNext(chain, e.Seq, id, d(e.Blob))
		if !bytes.Equal(chain[:], d(e.Chain)) {
			t.Fatalf("event %d: chain", e.Seq)
		}
	}
	for _, r := range v.Requests {
		if got := string(RequestSigningInput(r.Method, r.PathAndQuery, r.TS, []byte(r.Body))); got != r.SigningInput {
			t.Fatalf("signing input %q", got)
		}
		p, err := ParseAuthHeader(r.Authorization)
		if err != nil || !p.Verify(r.Method, r.PathAndQuery, []byte(r.Body)) {
			t.Fatalf("authorization: %v", err)
		}
	}
}
