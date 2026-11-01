// Package protocol is the Go reference for the cryptographic parts of
// docs/PROTOCOL.md: key derivation, the event envelope, signatures, the hash
// chain and request signing. The server only needs request signing; the rest
// exists so spec/vectors/crypto.json can be generated and checked from Go.
package protocol

import (
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/google/uuid"
	"golang.org/x/crypto/chacha20poly1305"
)

const (
	// BlobVersion is the first byte of every event blob (§6.1).
	BlobVersion = 0x01
	// PadBlock is the plaintext padding granularity (§6.1).
	PadBlock = 256
	// MaxClockSkew is how far a request timestamp may be from the server clock (§5.1).
	MaxClockSkewSeconds = 300

	labelEnc   = "group-balance/v1/enc"
	labelEvent = "group-balance/v1/event"
	labelSig   = "group-balance/v1/sig"
	labelChain = "group-balance/v1/chain"
	labelReq   = "group-balance/v1/req\n"
	labelClaim = "group-balance/v1/claim"
)

// B64 is base64url without padding, the encoding for keys, blobs and signatures.
var B64 = base64.RawURLEncoding

// DeriveEncKey returns K_enc for a group (§3.1).
func DeriveEncKey(secret []byte, groupID uuid.UUID) ([]byte, error) {
	if len(secret) != 32 {
		return nil, errors.New("group secret must be 32 bytes")
	}
	return hkdf.Key(sha256.New, secret, groupID[:], labelEnc, 32)
}

func eventAAD(groupID, eventID uuid.UUID) []byte {
	aad := make([]byte, 0, len(labelEvent)+32)
	aad = append(aad, labelEvent...)
	aad = append(aad, groupID[:]...)
	return append(aad, eventID[:]...)
}

// EventSigningInput is the message an event signature covers (§6.1).
func EventSigningInput(groupID, eventID uuid.UUID, body []byte) []byte {
	m := make([]byte, 0, len(labelSig)+32+len(body))
	m = append(m, labelSig...)
	m = append(m, groupID[:]...)
	m = append(m, eventID[:]...)
	return append(m, body...)
}

// Plaintext frames a body and its signature and pads it (§6.1).
func Plaintext(body, sig []byte) []byte {
	n := 4 + len(body) + ed25519.SignatureSize
	padded := (n + PadBlock - 1) / PadBlock * PadBlock
	p := make([]byte, padded)
	binary.BigEndian.PutUint32(p, uint32(len(body)))
	copy(p[4:], body)
	copy(p[4+len(body):], sig)
	return p
}

// SealEvent signs body with the author's key and encrypts it into a blob.
func SealEvent(encKey []byte, groupID, eventID uuid.UUID, body []byte, author ed25519.PrivateKey) ([]byte, error) {
	nonce := make([]byte, chacha20poly1305.NonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return SealEventWithNonce(encKey, groupID, eventID, body, author, nonce)
}

// SealEventWithNonce is SealEvent with a caller-chosen nonce, for test vectors only.
func SealEventWithNonce(encKey []byte, groupID, eventID uuid.UUID, body []byte, author ed25519.PrivateKey, nonce []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(encKey)
	if err != nil {
		return nil, err
	}
	sig := ed25519.Sign(author, EventSigningInput(groupID, eventID, body))
	out := append([]byte{BlobVersion}, nonce...)
	return aead.Seal(out, nonce, Plaintext(body, sig), eventAAD(groupID, eventID)), nil
}

// OpenEvent decrypts a blob and returns the body and its signature. It does
// not verify the signature: the reader has to look up the author's key first.
func OpenEvent(encKey []byte, groupID, eventID uuid.UUID, blob []byte) (body, sig []byte, err error) {
	aead, err := chacha20poly1305.New(encKey)
	if err != nil {
		return nil, nil, err
	}
	if len(blob) < 1+aead.NonceSize()+aead.Overhead() || blob[0] != BlobVersion {
		return nil, nil, errors.New("not a v1 blob")
	}
	nonce := blob[1 : 1+aead.NonceSize()]
	p, err := aead.Open(nil, nonce, blob[1+aead.NonceSize():], eventAAD(groupID, eventID))
	if err != nil {
		return nil, nil, err
	}
	if len(p) < 4 {
		return nil, nil, errors.New("plaintext too short")
	}
	n := int(binary.BigEndian.Uint32(p))
	if 4+n+ed25519.SignatureSize > len(p) {
		return nil, nil, errors.New("body length out of range")
	}
	return p[4 : 4+n], p[4+n : 4+n+ed25519.SignatureSize], nil
}

// VerifyEvent checks an event signature.
func VerifyEvent(pub ed25519.PublicKey, groupID, eventID uuid.UUID, body, sig []byte) bool {
	return len(pub) == ed25519.PublicKeySize && ed25519.Verify(pub, EventSigningInput(groupID, eventID, body), sig)
}

// ChainNext computes chain_n from chain_{n-1} (§6.4).
func ChainNext(prev [32]byte, seq uint64, eventID uuid.UUID, blob []byte) [32]byte {
	blobHash := sha256.Sum256(blob)
	h := sha256.New()
	h.Write([]byte(labelChain))
	h.Write(prev[:])
	var s [8]byte
	binary.BigEndian.PutUint64(s[:], seq)
	h.Write(s[:])
	h.Write(eventID[:])
	h.Write(blobHash[:])
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}

// ClaimInput is signed twice during a join (§5.3, §7.3): by the member key over
// the invite key (server proof) and by the invite key over the member key
// (ledger inviteSig).
func ClaimInput(groupID uuid.UUID, key []byte) []byte {
	m := make([]byte, 0, len(labelClaim)+16+len(key))
	m = append(m, labelClaim...)
	m = append(m, groupID[:]...)
	return append(m, key...)
}

// RequestSigningInput is the message a request signature covers (§5.1).
func RequestSigningInput(method, pathAndQuery string, ts int64, body []byte) []byte {
	sum := sha256.Sum256(body)
	return []byte(labelReq + method + "\n" + pathAndQuery + "\n" + strconv.FormatInt(ts, 10) + "\n" + hex.EncodeToString(sum[:]))
}

// AuthHeader builds the Authorization header value for a signed request.
func AuthHeader(priv ed25519.PrivateKey, method, pathAndQuery string, ts int64, body []byte) string {
	sig := ed25519.Sign(priv, RequestSigningInput(method, pathAndQuery, ts, body))
	pub := priv.Public().(ed25519.PublicKey)
	return fmt.Sprintf("GB1 key=%s, ts=%d, sig=%s", B64.EncodeToString(pub), ts, B64.EncodeToString(sig))
}

// SignedRequest is a parsed GB1 Authorization header.
type SignedRequest struct {
	Key ed25519.PublicKey
	TS  int64
	Sig []byte
}

// ParseAuthHeader parses `GB1 key=…, ts=…, sig=…`.
func ParseAuthHeader(h string) (SignedRequest, error) {
	var r SignedRequest
	rest, ok := strings.CutPrefix(h, "GB1 ")
	if !ok {
		return r, errors.New("not a GB1 authorization")
	}
	for part := range strings.SplitSeq(rest, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			return r, errors.New("malformed authorization")
		}
		var err error
		switch k {
		case "key":
			var b []byte
			b, err = B64.DecodeString(v)
			if err == nil && len(b) != ed25519.PublicKeySize {
				err = errors.New("key must be 32 bytes")
			}
			r.Key = b
		case "ts":
			r.TS, err = strconv.ParseInt(v, 10, 64)
		case "sig":
			r.Sig, err = B64.DecodeString(v)
		}
		if err != nil {
			return r, fmt.Errorf("authorization %s: %w", k, err)
		}
	}
	if r.Key == nil || r.TS == 0 || r.Sig == nil {
		return r, errors.New("authorization needs key, ts and sig")
	}
	return r, nil
}

// Verify checks the signature against the request.
func (r SignedRequest) Verify(method, pathAndQuery string, body []byte) bool {
	return ed25519.Verify(r.Key, RequestSigningInput(method, pathAndQuery, r.TS, body), r.Sig)
}
