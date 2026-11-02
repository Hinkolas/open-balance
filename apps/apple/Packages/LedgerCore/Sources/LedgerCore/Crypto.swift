import CryptoKit
import Foundation

/// Key derivation, event envelope, signatures, hash chain and request signing
/// (PROTOCOL.md §3, §5.1, §6). Mirrors internal/protocol in Go.
public enum LedgerCrypto {
    public static let blobVersion: UInt8 = 0x02
    /// Version, epoch and nonce (§6.1).
    static let blobHeader = 1 + 4 + 12
    public static let padBlock = 256

    private static let labelEnc = "open-balance/v1/enc"
    private static let labelEvent = "open-balance/v1/event"
    private static let labelSig = "open-balance/v1/sig"
    private static let labelChain = "open-balance/v1/chain"
    private static let labelReq = "open-balance/v1/req\n"
    private static let labelClaim = "open-balance/v1/claim"
    private static let labelRecover = "open-balance/v1/recover"
    private static let labelBox = "open-balance/v1/box"
    public static let labelEpoch = "open-balance/v1/epoch"
    public static let labelKeyring = "open-balance/v1/keyring"

    public enum Failure: Error { case badSecret, notABlob, badPlaintext, badKey }

    /// K_e, the key of epoch e of a group (§3.1).
    public static func encKey(secret: Data, groupID: UUID, epoch: UInt32) throws(Failure) -> SymmetricKey {
        guard secret.count == 32 else { throw .badSecret }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: groupID.bytes,
            info: Data(labelEnc.utf8) + u32(epoch),
            outputByteCount: 32
        )
    }

    static func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    static func aad(groupID: UUID, eventID: UUID, epoch: UInt32) -> Data {
        Data(labelEvent.utf8) + groupID.bytes + eventID.bytes + u32(epoch)
    }

    /// The epoch a blob was sealed with, nil if it isn't a version 2 blob (§6.1).
    public static func blobEpoch(_ blob: Data) -> UInt32? {
        guard blob.count >= blobHeader + 16, blob.first == blobVersion else { return nil }
        return blob.dropFirst().prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    public static func eventSigningInput(groupID: UUID, eventID: UUID, body: Data) -> Data {
        Data(labelSig.utf8) + groupID.bytes + eventID.bytes + body
    }

    /// Frame and pad body + signature (§6.1).
    static func plaintext(body: Data, signature: Data) -> Data {
        let n = 4 + body.count + 64
        let padded = (n + padBlock - 1) / padBlock * padBlock
        var p = Data(capacity: padded)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { p.append(contentsOf: $0) }
        p.append(body)
        p.append(signature)
        p.append(Data(count: padded - n))
        return p
    }

    /// Sign the body with the author's key and encrypt it into a blob of
    /// `epoch`; `key` is that epoch's K_e.
    public static func seal(
        body: Data, groupID: UUID, eventID: UUID, epoch: UInt32, key: SymmetricKey,
        signer: Curve25519.Signing.PrivateKey, nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> Data {
        let signature = try signer.signature(for: eventSigningInput(groupID: groupID, eventID: eventID, body: body))
        return try seal(body: body, signature: signature, groupID: groupID, eventID: eventID, epoch: epoch, key: key, nonce: nonce)
    }

    /// Encrypt an already signed body (§6.1).
    static func seal(body: Data, signature: Data, groupID: UUID, eventID: UUID, epoch: UInt32, key: SymmetricKey,
                     nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext(body: body, signature: signature), using: key, nonce: nonce,
            authenticating: aad(groupID: groupID, eventID: eventID, epoch: epoch)
        )
        return Data([blobVersion]) + u32(epoch) + box.combined
    }

    /// Decrypt a blob with the key of its epoch (see `blobEpoch`). Does not
    /// verify the signature (the author's key comes from the ledger).
    public static func open(blob: Data, groupID: UUID, eventID: UUID, key: SymmetricKey) throws -> (body: Data, signature: Data) {
        guard let epoch = blobEpoch(blob) else { throw Failure.notABlob }
        let box = try ChaChaPoly.SealedBox(combined: blob.dropFirst(5))
        let p = try ChaChaPoly.open(box, using: key, authenticating: aad(groupID: groupID, eventID: eventID, epoch: epoch))
        guard p.count >= 4 else { throw Failure.badPlaintext }
        let n = p.prefix(4).reduce(0) { Int($0) << 8 | Int($1) }
        guard 4 + n + 64 <= p.count else { throw Failure.badPlaintext }
        let start = p.startIndex
        return (Data(p[start + 4 ..< start + 4 + n]), Data(p[start + 4 + n ..< start + 4 + n + 64]))
    }

    public static func verify(signature: Data, body: Data, groupID: UUID, eventID: UUID, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: eventSigningInput(groupID: groupID, eventID: eventID, body: body))
    }

    public static let chainZero = Data(count: 32)

    /// chain_n from chain_{n-1} (§6.4).
    public static func chainNext(_ prev: Data, seq: UInt64, eventID: UUID, blob: Data) -> Data {
        var h = SHA256()
        h.update(data: Data(labelChain.utf8))
        h.update(data: prev)
        withUnsafeBytes(of: seq.bigEndian) { h.update(bufferPointer: $0) }
        h.update(data: eventID.bytes)
        h.update(data: Data(SHA256.hash(data: blob)))
        return Data(h.finalize())
    }

    /// Signed twice during a join: member key over the invite key (server
    /// proof), invite key over the member key (ledger inviteSig).
    public static func claimInput(groupID: UUID, key: Data) -> Data {
        Data(labelClaim.utf8) + groupID.bytes + key
    }

    /// Signed by the recovery key for the admin's new device key (§3.4).
    public static func recoverInput(groupID: UUID, key: Data) -> Data {
        Data(labelRecover.utf8) + groupID.bytes + key
    }

    // MARK: - Box keys and sealing (§3.5)

    /// The X25519 box key of a seed: a member key seed, an invite seed or the recovery seed.
    public static func boxKey(seed: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard seed.count == 32 else { throw Failure.badSecret }
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: seed), salt: Data(), info: Data(labelBox.utf8), outputByteCount: 32)
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: k.withUnsafeBytes { Data($0) })
    }

    /// Seal `message` to the box key `to` (32 raw bytes).
    public static func seal(
        _ message: Data, to: Data, label: String, groupID: UUID,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: to)
        let ePub = ephemeral.publicKey.rawRepresentation
        let key = try sealKey(own: ephemeral, peer: peer, ePub: ePub, to: to, label: label, groupID: groupID)
        let box = try ChaChaPoly.seal(message, using: key, nonce: ChaChaPoly.Nonce(data: Data(count: 12)), authenticating: Data())
        return ePub + box.ciphertext + box.tag
    }

    /// Open what `seal` sealed to `box`'s public key.
    public static func open(sealed: Data, box: Curve25519.KeyAgreement.PrivateKey, label: String, groupID: UUID) throws -> Data {
        guard sealed.count >= 32 + 16 else { throw Failure.badPlaintext }
        let s = Data(sealed)
        let ePub = s.prefix(32)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePub)
        let key = try sealKey(own: box, peer: peer, ePub: ePub, to: box.publicKey.rawRepresentation, label: label, groupID: groupID)
        let body = s.dropFirst(32)
        let sb = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 12)), ciphertext: body.dropLast(16), tag: body.suffix(16))
        return try ChaChaPoly.open(sb, using: key, authenticating: Data())
    }

    private static func sealKey(
        own: Curve25519.KeyAgreement.PrivateKey, peer: Curve25519.KeyAgreement.PublicKey,
        ePub: Data, to: Data, label: String, groupID: UUID
    ) throws -> SymmetricKey {
        let z = try own.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        guard z.contains(where: { $0 != 0 }) else { throw Failure.badKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: z), salt: groupID.bytes,
                                      info: Data(label.utf8) + ePub + to, outputByteCount: 32)
    }

    public static func requestSigningInput(method: String, pathAndQuery: String, ts: Int64, body: Data) -> Data {
        let hash = Data(SHA256.hash(data: body)).hex
        return Data("\(labelReq)\(method)\n\(pathAndQuery)\n\(ts)\n\(hash)".utf8)
    }

    /// `Authorization: OB1 key=…, ts=…, sig=…` (§5.1).
    public static func authorization(
        signer: Curve25519.Signing.PrivateKey, method: String, pathAndQuery: String, ts: Int64, body: Data
    ) throws -> String {
        let sig = try signer.signature(for: requestSigningInput(method: method, pathAndQuery: pathAndQuery, ts: ts, body: body))
        return "OB1 key=\(signer.publicKey.rawRepresentation.base64URL), ts=\(ts), sig=\(sig.base64URL)"
    }
}
