import CryptoKit
import Foundation
import Testing
@testable import LedgerCore

struct CryptoFile: Decodable {
    struct KeyPair: Decodable { var seed: String; var publicKey: String; var boxPrivate: String; var boxPublic: String }
    struct Keys: Decodable { var epochSecrets: [String]; var groupId: String; var encKeys: [String]; var admin: KeyPair; var member: KeyPair; var invite: KeyPair; var recovery: KeyPair }
    struct Event: Decodable { var seq: UInt64; var epoch: UInt32; var id: String; var nonce: String; var body: String; var authorPublicKey: String; var signature: String; var blob: String; var chain: String }
    struct Seal: Decodable { var to: String; var label: String; var plaintext: String; var ephemeralPrivate: String; var sealed: String }
    struct Req: Decodable { var method: String; var pathAndQuery: String; var ts: Int64; var body: String; var signingInput: String; var authorization: String }
    struct Claim: Decodable { var proof: String; var inviteSig: String }
    struct Recover: Decodable { var signingInputHex: String; var proof: String; var recoverySig: String }
    var keys: Keys; var events: [Event]; var requests: [Req]; var claim: Claim; var recover: Recover; var seals: [Seal]
}

private func b(_ s: String) -> Data { Data(base64URL: s)! }

@Test func cryptoVectors() throws {
    let v = try JSONDecoder().decode(CryptoFile.self, from: vectors("crypto.json"))
    let group = UUID(uuidString: v.keys.groupId)!
    let keys = try v.keys.epochSecrets.enumerated().map { try LedgerCrypto.encKey(secret: b($1), groupID: group, epoch: UInt32($0)) }
    #expect(keys.map { $0.withUnsafeBytes { Data($0) } } == v.keys.encKeys.map(b))

    let pairs = ["admin": v.keys.admin, "member": v.keys.member, "invite": v.keys.invite, "recovery": v.keys.recovery]
    for (_, p) in pairs {
        let box = try LedgerCrypto.boxKey(seed: b(p.seed))
        #expect(box.rawRepresentation == b(p.boxPrivate))
        #expect(box.publicKey.rawRepresentation == b(p.boxPublic))
    }
    for c in v.seals {
        let to = try #require(pairs[c.to])
        let e = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: b(c.ephemeralPrivate))
        #expect(try LedgerCrypto.seal(b(c.plaintext), to: b(to.boxPublic), label: c.label, groupID: group, ephemeral: e) == b(c.sealed))
        let box = try LedgerCrypto.boxKey(seed: b(to.seed))
        #expect(try LedgerCrypto.open(sealed: b(c.sealed), box: box, label: c.label, groupID: group) == b(c.plaintext))
        #expect(throws: (any Error).self) { try LedgerCrypto.open(sealed: b(c.sealed), box: box, label: "other", groupID: group) }
    }
    let ring = try #require(v.seals.first { $0.label == LedgerCrypto.labelKeyring })
    #expect(try Epochs.openKeyring(b(ring.sealed), box: LedgerCrypto.boxKey(seed: b(v.keys.invite.seed)), groupID: group) == v.keys.epochSecrets.map(b))

    let admin = try Curve25519.Signing.PrivateKey(rawRepresentation: b(v.keys.admin.seed))
    #expect(admin.publicKey.rawRepresentation == b(v.keys.admin.publicKey))

    var chain = LedgerCrypto.chainZero
    for e in v.events {
        let id = UUID(uuidString: e.id)!
        let key = keys[Int(e.epoch)]
        #expect(LedgerCrypto.blobEpoch(b(e.blob)) == e.epoch)
        let (body, sig) = try LedgerCrypto.open(blob: b(e.blob), groupID: group, eventID: id, key: key)
        #expect(String(decoding: body, as: UTF8.self) == e.body)
        #expect(sig == b(e.signature))
        #expect(LedgerCrypto.verify(signature: sig, body: body, groupID: group, eventID: id, publicKey: b(e.authorPublicKey)))
        // Same nonce → same blob: our envelope matches byte for byte. (CryptoKit
        // signatures are randomized, so seal with the vector's signature.)
        #expect(try LedgerCrypto.seal(body: body, signature: sig, groupID: group, eventID: id, epoch: e.epoch, key: key,
                                      nonce: ChaChaPoly.Nonce(data: b(e.nonce))) == b(e.blob))
        #expect(throws: (any Error).self) {
            try LedgerCrypto.open(blob: b(e.blob), groupID: group, eventID: id, key: keys[1 - Int(e.epoch)])
        }
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
