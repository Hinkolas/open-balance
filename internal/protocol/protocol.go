// Package protocol is the Go reference for the cryptographic parts of
// docs/PROTOCOL.md: key derivation, the event envelope, signatures, the hash
// chain and request signing. The server only needs request signing; the rest
// exists so spec/vectors/crypto.json can be generated and checked from Go.
package protocol

import (
	"crypto/ecdh"
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
	BlobVersion = 0x02
	// BlobHeader is version, epoch and nonce (§6.1).
	BlobHeader = 1 + 4 + chacha20poly1305.NonceSize
	// PadBlock is the plaintext padding granularity (§6.1).
	PadBlock = 256
	// MaxClockSkew is how far a request timestamp may be from the server clock (§5.1).
	MaxClockSkewSeconds = 300

	labelEnc     = "open-balance/v1/enc"
	labelEvent   = "open-balance/v1/event"
	labelSig     = "open-balance/v1/sig"
	labelChain   = "open-balance/v1/chain"
	labelReq     = "open-balance/v1/req\n"
	labelClaim   = "open-balance/v1/claim"
	labelRecover = "open-balance/v1/recover"
	labelBox     = "open-balance/v1/box"

	// LabelEpoch and LabelKeyring are the seal labels of §3.5.
	LabelEpoch   = "open-balance/v1/epoch"
	LabelKeyring = "open-balance/v1/keyring"
)

// B64 is base64url without padding, the encoding for keys, blobs and signatures.
var B64 = base64.RawURLEncoding

// DeriveEncKey returns K_e, the key of epoch e of a group (§3.1).
func DeriveEncKey(secret []byte, groupID uuid.UUID, epoch uint32) ([]byte, error) {
	if len(secret) != 32 {
		return nil, errors.New("epoch secret must be 32 bytes")
	}
	return hkdf.Key(sha256.New, secret, groupID[:], labelEnc+string(u32(epoch)), 32)
}

func u32(v uint32) []byte { return binary.BigEndian.AppendUint32(nil, v) }

func eventAAD(groupID, eventID uuid.UUID, epoch uint32) []byte {
	aad := make([]byte, 0, len(labelEvent)+36)
	aad = append(aad, labelEvent...)
	aad = append(aad, groupID[:]...)
	aad = append(aad, eventID[:]...)
	return append(aad, u32(epoch)...)
}

// BlobEpoch reads the epoch a blob was sealed with (§6.1).
func BlobEpoch(blob []byte) (uint32, error) {
	if len(blob) < BlobHeader+chacha20poly1305.Overhead || blob[0] != BlobVersion {
		return 0, errors.New("not a version 2 blob")
	}
	return binary.BigEndian.Uint32(blob[1:5]), nil
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

// SealEvent signs body with the author's key and encrypts it into a blob of
// the given epoch; encKey is that epoch's K_e.
func SealEvent(encKey []byte, groupID, eventID uuid.UUID, epoch uint32, body []byte, author ed25519.PrivateKey) ([]byte, error) {
	nonce := make([]byte, chacha20poly1305.NonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return SealEventWithNonce(encKey, groupID, eventID, epoch, body, author, nonce)
}

// SealEventWithNonce is SealEvent with a caller-chosen nonce, for test vectors only.
func SealEventWithNonce(encKey []byte, groupID, eventID uuid.UUID, epoch uint32, body []byte, author ed25519.PrivateKey, nonce []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(encKey)
	if err != nil {
		return nil, err
	}
	sig := ed25519.Sign(author, EventSigningInput(groupID, eventID, body))
	out := append([]byte{BlobVersion}, u32(epoch)...)
	out = append(out, nonce...)
	return aead.Seal(out, nonce, Plaintext(body, sig), eventAAD(groupID, eventID, epoch)), nil
}

// OpenEvent decrypts a blob with the key of its epoch (see BlobEpoch) and
// returns the body and its signature. It does not verify the signature: the
// reader has to look up the author's key first.
func OpenEvent(encKey []byte, groupID, eventID uuid.UUID, blob []byte) (body, sig []byte, err error) {
	aead, err := chacha20poly1305.New(encKey)
	if err != nil {
		return nil, nil, err
	}
	epoch, err := BlobEpoch(blob)
	if err != nil {
		return nil, nil, err
	}
	nonce := blob[5:BlobHeader]
	p, err := aead.Open(nil, nonce, blob[BlobHeader:], eventAAD(groupID, eventID, epoch))
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

// RecoverInput is what the recovery key signs to vouch for the admin's new
// device key (§3.4, §7.3 member.recovered).
func RecoverInput(groupID uuid.UUID, key []byte) []byte {
	m := make([]byte, 0, len(labelRecover)+16+len(key))
	m = append(m, labelRecover...)
	m = append(m, groupID[:]...)
	return append(m, key...)
}

// BoxKey derives the X25519 box key of a seed: a member key seed, an invite
// seed or the recovery seed (§3.5).
func BoxKey(seed []byte) (*ecdh.PrivateKey, error) {
	if len(seed) != 32 {
		return nil, errors.New("seed must be 32 bytes")
	}
	k, err := hkdf.Key(sha256.New, seed, nil, labelBox, 32)
	if err != nil {
		return nil, err
	}
	return ecdh.X25519().NewPrivateKey(k)
}

// Seal seals m to the box key to under label (§3.5).
func Seal(groupID uuid.UUID, to []byte, label string, m []byte) ([]byte, error) {
	e, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return SealWithEphemeral(groupID, to, label, m, e)
}

// SealWithEphemeral is Seal with a caller-chosen ephemeral key, for test vectors only.
func SealWithEphemeral(groupID uuid.UUID, to []byte, label string, m []byte, e *ecdh.PrivateKey) ([]byte, error) {
	k, err := sealKey(groupID, e, to, e.PublicKey().Bytes(), to, label)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.New(k)
	if err != nil {
		return nil, err
	}
	return aead.Seal(e.PublicKey().Bytes(), make([]byte, chacha20poly1305.NonceSize), m, nil), nil
}

// Open opens what Seal sealed to box's public key.
func Open(groupID uuid.UUID, box *ecdh.PrivateKey, label string, sealed []byte) ([]byte, error) {
	if len(sealed) < 32+chacha20poly1305.Overhead {
		return nil, errors.New("sealed data too short")
	}
	k, err := sealKey(groupID, box, sealed[:32], sealed[:32], box.PublicKey().Bytes(), label)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.New(k)
	if err != nil {
		return nil, err
	}
	return aead.Open(nil, make([]byte, chacha20poly1305.NonceSize), sealed[32:], nil)
}

// sealKey is k of §3.5: own is this side's private key and peer the other
// side's public key; ePub and to are the ephemeral and the recipient's keys.
func sealKey(groupID uuid.UUID, own *ecdh.PrivateKey, peer, ePub, to []byte, label string) ([]byte, error) {
	pub, err := ecdh.X25519().NewPublicKey(peer)
	if err != nil {
		return nil, err
	}
	z, err := own.ECDH(pub)
	if err != nil {
		return nil, err // all-zero shared secret
	}
	info := make([]byte, 0, len(label)+64)
	info = append(info, label...)
	info = append(info, ePub...)
	info = append(info, to...)
	return hkdf.Key(sha256.New, z, groupID[:], string(info), 32)
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
	return fmt.Sprintf("OB1 key=%s, ts=%d, sig=%s", B64.EncodeToString(pub), ts, B64.EncodeToString(sig))
}

// SignedRequest is a parsed OB1 Authorization header.
type SignedRequest struct {
	Key ed25519.PublicKey
	TS  int64
	Sig []byte
}

// ParseAuthHeader parses `OB1 key=…, ts=…, sig=…`.
func ParseAuthHeader(h string) (SignedRequest, error) {
	var r SignedRequest
	rest, ok := strings.CutPrefix(h, "OB1 ")
	if !ok {
		return r, errors.New("not a OB1 authorization")
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
