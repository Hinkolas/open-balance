import CryptoKit
import Foundation
import Testing
@testable import LedgerCore

struct CryptoFile: Decodable {
    struct KeyPair: Decodable { var seed: String; var publicKey: String }
    struct Keys: Decodable { var groupSecret: String; var groupId: String; var encKey: String; var admin: KeyPair; var member: KeyPair; var invite: KeyPair; var recovery: KeyPair }
    struct Event: Decodable { var seq: UInt64; var id: String; var nonce: String; var body: String; var authorPublicKey: String; var signature: String; var blob: String; var chain: String }
    struct Req: Decodable { var method: String; var pathAndQuery: String; var ts: Int64; var body: String; var signingInput: String; var authorization: String }
    struct Claim: Decodable { var proof: String; var inviteSig: String }
    struct Recover: Decodable { var signingInputHex: String; var proof: String; var recoverySig: String }
    var keys: Keys; var events: [Event]; var requests: [Req]; var claim: Claim; var recover: Recover
}

private func b(_ s: String) -> Data { Data(base64URL: s)! }

@Test func cryptoVectors() throws {
    let v = try JSONDecoder().decode(CryptoFile.self, from: vectors("crypto.json"))
    let group = UUID(uuidString: v.keys.groupId)!
    let key = try LedgerCrypto.encKey(secret: b(v.keys.groupSecret), groupID: group)
    #expect(key.withUnsafeBytes { Data($0) } == b(v.keys.encKey))

    let admin = try Curve25519.Signing.PrivateKey(rawRepresentation: b(v.keys.admin.seed))
    #expect(admin.publicKey.rawRepresentation == b(v.keys.admin.publicKey))

    var chain = LedgerCrypto.chainZero
    for e in v.events {
        let id = UUID(uuidString: e.id)!
        let (body, sig) = try LedgerCrypto.open(blob: b(e.blob), groupID: group, eventID: id, key: key)
        #expect(String(decoding: body, as: UTF8.self) == e.body)
        #expect(sig == b(e.signature))
        #expect(LedgerCrypto.verify(signature: sig, body: body, groupID: group, eventID: id, publicKey: b(e.authorPublicKey)))
        // Same nonce → same blob: our envelope matches byte for byte. (CryptoKit
        // signatures are randomized, so seal with the vector's signature.)
        let box = try ChaChaPoly.seal(LedgerCrypto.plaintext(body: body, signature: sig), using: key,
                                      nonce: ChaChaPoly.Nonce(data: b(e.nonce)), authenticating: LedgerCrypto.aad(groupID: group, eventID: id))
        #expect(Data([1]) + box.combined == b(e.blob))
        chain = LedgerCrypto.chainNext(chain, seq: e.seq, eventID: id, blob: b(e.blob))
        #expect(chain == b(e.chain))
        #expect(throws: (any Error).self) {
            try LedgerCrypto.open(blob: b(e.blob), groupID: UUID(), eventID: id, key: key)
        }
    }

    for r in v.requests {
        let input = LedgerCrypto.requestSigningInput(method: r.method, pathAndQuery: r.pathAndQuery, ts: r.ts, body: Data(r.body.utf8))
        #expect(String(decoding: input, as: UTF8.self) == r.signingInput)
    }

    let member = try Curve25519.Signing.PublicKey(rawRepresentation: b(v.keys.member.publicKey))
    let invite = try Curve25519.Signing.PublicKey(rawRepresentation: b(v.keys.invite.publicKey))
    #expect(member.isValidSignature(b(v.claim.proof), for: LedgerCrypto.claimInput(groupID: group, key: b(v.keys.invite.publicKey))))
    #expect(invite.isValidSignature(b(v.claim.inviteSig), for: LedgerCrypto.claimInput(groupID: group, key: b(v.keys.member.publicKey))))

    let recovery = try Curve25519.Signing.PrivateKey(rawRepresentation: b(v.keys.recovery.seed))
    #expect(recovery.publicKey.rawRepresentation == b(v.keys.recovery.publicKey))
    let recoverInput = LedgerCrypto.recoverInput(groupID: group, key: b(v.keys.member.publicKey))
    #expect(recoverInput.hex == v.recover.signingInputHex)
    #expect(recovery.publicKey.isValidSignature(b(v.recover.recoverySig), for: recoverInput))
    #expect(member.isValidSignature(b(v.recover.proof), for: LedgerCrypto.claimInput(groupID: group, key: b(v.keys.recovery.publicKey))))
    #expect(!recovery.publicKey.isValidSignature(b(v.recover.recoverySig), for: LedgerCrypto.claimInput(groupID: group, key: b(v.keys.member.publicKey))))
}
