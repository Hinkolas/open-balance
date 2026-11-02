import CryptoKit
import Foundation

/// Key derivation, event envelope, signatures, hash chain and request signing
/// (PROTOCOL.md §3, §5.1, §6). Mirrors internal/protocol in Go.
public enum LedgerCrypto {
    public static let blobVersion: UInt8 = 0x01
    public static let padBlock = 256

    private static let labelEnc = "open-balance/v1/enc"
    private static let labelEvent = "open-balance/v1/event"
    private static let labelSig = "open-balance/v1/sig"
    private static let labelChain = "open-balance/v1/chain"
    private static let labelReq = "open-balance/v1/req\n"
    private static let labelClaim = "open-balance/v1/claim"
    private static let labelRecover = "open-balance/v1/recover"

    public enum Failure: Error { case badSecret, notABlob, badPlaintext }

    /// K_enc for a group (§3.1).
    public static func encKey(secret: Data, groupID: UUID) throws(Failure) -> SymmetricKey {
        guard secret.count == 32 else { throw .badSecret }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: groupID.bytes,
            info: Data(labelEnc.utf8),
            outputByteCount: 32
        )
    }

    static func aad(groupID: UUID, eventID: UUID) -> Data {
        Data(labelEvent.utf8) + groupID.bytes + eventID.bytes
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

    /// Sign the body with the author's key and encrypt it into a blob.
    public static func seal(
        body: Data, groupID: UUID, eventID: UUID, key: SymmetricKey,
        signer: Curve25519.Signing.PrivateKey, nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> Data {
        let signature = try signer.signature(for: eventSigningInput(groupID: groupID, eventID: eventID, body: body))
        let box = try ChaChaPoly.seal(
            plaintext(body: body, signature: signature), using: key, nonce: nonce,
            authenticating: aad(groupID: groupID, eventID: eventID)
        )
        return Data([blobVersion]) + box.combined
    }

    /// Decrypt a blob. Does not verify the signature (the author's key comes from the ledger).
    public static func open(blob: Data, groupID: UUID, eventID: UUID, key: SymmetricKey) throws -> (body: Data, signature: Data) {
        guard blob.count >= 1 + 12 + 16, blob.first == blobVersion else { throw Failure.notABlob }
        let box = try ChaChaPoly.SealedBox(combined: blob.dropFirst())
        let p = try ChaChaPoly.open(box, using: key, authenticating: aad(groupID: groupID, eventID: eventID))
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
