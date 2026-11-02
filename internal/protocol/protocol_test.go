package protocol

import (
	"bytes"
	"crypto/ecdh"
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
	key, err := DeriveEncKey(secret, group, 3)
	if err != nil {
		t.Fatal(err)
	}
	body := []byte(`{"v":1,"type":"group.updated"}`)
	blob, err := SealEvent(key, group, event, 3, body, priv)
	if err != nil {
		t.Fatal(err)
	}
	if e, _ := BlobEpoch(blob); e != 3 {
		t.Fatalf("epoch %d", e)
	}
	if (len(blob)-BlobHeader-16)%PadBlock != 0 {
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
	tampered := append([]byte{}, blob...)
	tampered[4] = 4 // claims epoch 4: the AAD differs
	if _, _, err := OpenEvent(key, group, event, tampered); err == nil {
		t.Fatal("blob opened with a changed epoch")
	}
}

func TestSealRoundTrip(t *testing.T) {
	group := uuid.Must(uuid.NewV7())
	seed := make([]byte, 32)
	rand.Read(seed)
	box, err := BoxKey(seed)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := Seal(group, box.PublicKey().Bytes(), LabelKeyring, []byte("secret"))
	if err != nil {
		t.Fatal(err)
	}
	if m, err := Open(group, box, LabelKeyring, sealed); err != nil || string(m) != "secret" {
		t.Fatalf("open: %v %q", err, m)
	}
	if _, err := Open(group, box, LabelEpoch, sealed); err == nil {
		t.Fatal("opened under another label")
	}
	if _, err := Open(uuid.Must(uuid.NewV7()), box, LabelKeyring, sealed); err == nil {
		t.Fatal("opened under another group")
	}
	if _, err := Seal(group, make([]byte, 32), LabelKeyring, []byte("x")); err == nil {
		t.Fatal("sealed to a low-order key")
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
			EpochSecrets, EncKeys []string
			GroupID               string
			Admin, Member, Invite map[string]string
			Recovery              map[string]string
		}
		Events []struct {
			ID, Nonce, Body, AuthorPublicKey, Signature, Blob, Chain string
			Seq                                                     uint64
			Epoch                                                   uint32
		}
		Seals []struct {
			To, Label, Plaintext, EphemeralPrivate, Sealed string
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
	keys := make([][]byte, len(v.Keys.EpochSecrets))
	for i, s := range v.Keys.EpochSecrets {
		keys[i], _ = DeriveEncKey(d(s), group, uint32(i))
		if !bytes.Equal(keys[i], d(v.Keys.EncKeys[i])) {
			t.Fatalf("encKey %d differs", i)
		}
	}
	pairs := map[string]map[string]string{"admin": v.Keys.Admin, "member": v.Keys.Member, "invite": v.Keys.Invite, "recovery": v.Keys.Recovery}
	for name, p := range pairs {
		box, err := BoxKey(d(p["seed"]))
		if err != nil || !bytes.Equal(box.Bytes(), d(p["boxPrivate"])) || !bytes.Equal(box.PublicKey().Bytes(), d(p["boxPublic"])) {
			t.Fatalf("%s box key differs", name)
		}
	}
	for _, c := range v.Seals {
		e, _ := ecdh.X25519().NewPrivateKey(d(c.EphemeralPrivate))
		sealed, err := SealWithEphemeral(group, d(pairs[c.To]["boxPublic"]), c.Label, d(c.Plaintext), e)
		if err != nil || !bytes.Equal(sealed, d(c.Sealed)) {
			t.Fatalf("seal to %s differs: %v", c.To, err)
		}
		box, _ := BoxKey(d(pairs[c.To]["seed"]))
		if m, err := Open(group, box, c.Label, d(c.Sealed)); err != nil || !bytes.Equal(m, d(c.Plaintext)) {
			t.Fatalf("open seal to %s: %v", c.To, err)
		}
	}
	var chain [32]byte
	for _, e := range v.Events {
		id := uuid.MustParse(e.ID)
		if epoch, err := BlobEpoch(d(e.Blob)); err != nil || epoch != e.Epoch {
			t.Fatalf("event %d: epoch %d %v", e.Seq, epoch, err)
		}
		body, sig, err := OpenEvent(keys[e.Epoch], group, id, d(e.Blob))
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
