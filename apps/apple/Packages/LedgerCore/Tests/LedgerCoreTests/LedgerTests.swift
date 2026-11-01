import CryptoKit
import Foundation
import Testing
@testable import LedgerCore

/// A small in-memory server: assigns seq, keeps blobs.
struct FakeServer {
    var events: [RawEvent] = []
    mutating func append(_ e: SealedEvent) { events.append(RawEvent(seq: UInt64(events.count + 1), id: e.id, blob: e.blob)) }
}

struct Actor {
    let id: MemberID
    let key: Curve25519.Signing.PrivateKey
    let writer: EventWriter
    init(_ group: UUID, _ secret: Data, id: MemberID = UUID.v7().lower, key: Curve25519.Signing.PrivateKey = .init()) throws {
        self.id = id
        self.key = key
        self.writer = try EventWriter(groupID: group, secret: secret, author: id, signer: key)
    }
}

struct Fixture {
    let group = UUID.v7()
    let secret = Data.random(32)
    var server = FakeServer()
    var ledger: Ledger
    let admin: Actor

    init() throws {
        ledger = try Ledger(groupID: group, secret: secret)
        admin = try Actor(group, secret)
        try write(admin, .groupCreated(.init(name: "Italien", currency: "EUR", admin: .init(id: admin.id, name: "Jonas", key: admin.key.publicKey.rawRepresentation.base64URL))))
    }

    /// Write as `who`, append, reduce; returns the rejection of that event.
    @discardableResult
    mutating func write(_ who: Actor, _ data: EventData) throws -> Rejection? {
        server.append(try who.writer.write(data, seen: ledger.state.head))
        ledger.apply(Array(server.events.suffix(1)))
        return ledger.state.history.last?.rejection
    }

    /// Admin adds a member; the member claims with a fresh key.
    mutating func join(_ name: String) throws -> Actor {
        let invite = Curve25519.Signing.PrivateKey()
        let member = try Actor(group, secret)
        try write(admin, .memberAdded(.init(id: member.id, name: name, inviteKey: invite.publicKey.rawRepresentation.base64URL)))
        let pub = member.key.publicKey.rawRepresentation
        let sig = try invite.signature(for: LedgerCrypto.claimInput(groupID: group, key: pub))
        let r = try write(member, .memberClaimed(.init(id: member.id, key: pub.base64URL, inviteSig: sig.base64URL)))
        #expect(r == nil)
        return member
    }

    func payment(_ id: PaymentID = UUID.v7().lower, kind: Payment.Kind = .income, amount: Int, track: Bool,
                 in i: [(MemberID, Int)], out o: [(MemberID, Int)]) -> Payment {
        Payment(id: id, kind: kind, title: "Rate 1", date: "2026-10-30", amount: amount, track: track,
                in: .init(mode: "exact", lines: i.map { .init(member: $0.0, amount: $0.1) }),
                out: .init(mode: "exact", lines: o.map { .init(member: $0.0, amount: $0.1) }))
    }
}

@Test func incomeWithArrivalsAndSettleUp() throws {
    var f = try Fixture()
    let ben = try f.join("Ben")
    let a = f.admin.id

    // 1000 arrives at Jonas, belongs 600 Jonas / 400 Ben.
    let p = f.payment(amount: 100_000, track: true, in: [(a, 100_000)], out: [(a, 60_000), (ben.id, 40_000)])
    #expect(try f.write(ben, .paymentCreated(p)) == nil)
    #expect(f.ledger.state.summary.balances == [a: 0, ben.id: 0])

    // Ben can't confirm money that arrived at Jonas; Jonas can.
    #expect(try f.write(ben, .arrivalRecorded(.init(id: "r1", payment: p.id, member: a, amount: 50_000))) == .forbidden)
    #expect(try f.write(f.admin, .arrivalRecorded(.init(id: "r2", payment: p.id, member: a, amount: 50_000))) == nil)
    var s = f.ledger.state.summary
    #expect(s.balances == [a: -20_000, ben.id: 20_000])
    #expect(s.pendingOwned[ben.id] == 20_000)
    #expect(s.transfers == [.init(from: a, to: ben.id, amount: 20_000)])

    // Settle up: Jonas pays Ben, counts once Ben confirms.
    let settle = f.payment(kind: .settlement, amount: 20_000, track: true, in: [(ben.id, 20_000)], out: [(a, 20_000)])
    #expect(try f.write(f.admin, .paymentCreated(settle)) == nil)
    #expect(f.ledger.state.summary.balances == [a: -20_000, ben.id: 20_000])
    #expect(try f.write(ben, .arrivalRecorded(.init(id: "r3", payment: settle.id, member: ben.id, amount: 20_000))) == nil)
    s = f.ledger.state.summary
    #expect(s.balances == [a: 0, ben.id: 0])
    #expect(s.transfers.isEmpty)
}

@Test func permissions() throws {
    var f = try Fixture()
    let ben = try f.join("Ben")
    let cem = try f.join("Cem")
    let p = f.payment(amount: 900, track: false, in: [(ben.id, 300), (cem.id, 300), (f.admin.id, 300)], out: [(ben.id, 900)])
    #expect(try f.write(ben, .paymentCreated(p)) == nil)

    var edit = p
    edit.title = "Dinner"
    edit.base = f.ledger.state.payments[p.id]!.lastEventID.lower
    #expect(try f.write(cem, .paymentUpdated(edit)) == .forbidden)
    #expect(try f.write(f.admin, .paymentUpdated(edit)) == nil)
    #expect(f.ledger.state.payments[p.id]?.payment.title == "Dinner")
    #expect(f.ledger.state.payments[p.id]?.editedConcurrently == false)

    #expect(try f.write(cem, .groupUpdated(.init(name: "Mine"))) == .forbidden)
    #expect(try f.write(cem, .memberAdded(.init(id: "x", name: "X", inviteKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64URL))) == .forbidden)
    #expect(try f.write(cem, .memberUpdated(.init(id: cem.id, name: "Cem K."))) == nil)
    #expect(try f.write(cem, .memberUpdated(.init(id: ben.id, name: "Benny"))) == .forbidden)
    #expect(try f.write(ben, .paymentDeleted(.init(id: p.id))) == nil)
    #expect(try f.write(ben, .paymentDeleted(.init(id: p.id))) == .unknownTarget)

    // Sums must match.
    var bad = f.payment(amount: 1000, track: false, in: [(ben.id, 999)], out: [(ben.id, 1000)])
    #expect(try f.write(ben, .paymentCreated(bad)) == .invalidData)
    bad = f.payment(amount: 1000, track: false, in: [(ben.id, 1000)], out: [("nobody", 1000)])
    #expect(try f.write(ben, .paymentCreated(bad)) == .invalidData)
}

@Test func unclaimedSeatsAndClaims() throws {
    var f = try Fixture()
    let invite = Curve25519.Signing.PrivateKey()
    let oma = UUID.v7().lower
    try f.write(f.admin, .memberAdded(.init(id: oma, name: "Oma", inviteKey: invite.publicKey.rawRepresentation.base64URL)))
    let ben = try f.join("Ben")

    // Anyone may record arrivals for an unclaimed seat.
    let p = f.payment(amount: 500, track: true, in: [(oma, 500)], out: [(ben.id, 500)])
    #expect(try f.write(ben, .paymentCreated(p)) == nil)
    #expect(try f.write(ben, .arrivalRecorded(.init(id: "r", payment: p.id, member: oma, amount: 500))) == nil)
    #expect(f.ledger.state.summary.balances[oma] == -500)

    // A claim needs the invite's signature.
    let impostor = try Actor(f.group, f.secret, id: oma)
    let wrongSig = try Curve25519.Signing.PrivateKey().signature(for: LedgerCrypto.claimInput(groupID: f.group, key: impostor.key.publicKey.rawRepresentation))
    #expect(try f.write(impostor, .memberClaimed(.init(id: oma, key: impostor.key.publicKey.rawRepresentation.base64URL, inviteSig: wrongSig.base64URL))) == .badInviteSig)

    let real = try Actor(f.group, f.secret, id: oma)
    let sig = try invite.signature(for: LedgerCrypto.claimInput(groupID: f.group, key: real.key.publicKey.rawRepresentation))
    #expect(try f.write(real, .memberClaimed(.init(id: oma, key: real.key.publicKey.rawRepresentation.base64URL, inviteSig: sig.base64URL))) == nil)
    #expect(try f.write(real, .memberClaimed(.init(id: oma, key: real.key.publicKey.rawRepresentation.base64URL, inviteSig: sig.base64URL))) == .alreadyClaimed)
}

@Test func forgedAuthorIsRejected() throws {
    var f = try Fixture()
    let ben = try f.join("Ben")
    // Ben signs with his key but claims to be the admin.
    let forger = try EventWriter(groupID: f.group, secret: f.secret, author: f.admin.id, signer: ben.key)
    f.server.append(try forger.write(.groupUpdated(.init(name: "Hacked")), seen: f.ledger.state.head))
    f.ledger.apply(Array(f.server.events.suffix(1)))
    #expect(f.ledger.state.history.last?.rejection == .badSignature)
    #expect(f.ledger.state.name == "Italien")
}

@Test func serverForkIsDetected() throws {
    var f = try Fixture()
    let ben = try f.join("Ben")
    // Ben saw a different event 2 than everyone else.
    var seen = f.ledger.state.head
    seen.seq = 2
    seen.chain = Data.random(32).base64URL
    f.server.append(try ben.writer.write(.groupUpdated(.init(name: "x")), seen: seen))
    f.ledger.apply(Array(f.server.events.suffix(1)))
    #expect(f.ledger.state.inconsistency != nil)
}

@Test func replayFromScratchMatches() throws {
    var f = try Fixture()
    let ben = try f.join("Ben")
    try f.write(ben, .paymentCreated(f.payment(amount: 900, track: false, in: [(ben.id, 900)], out: [(f.admin.id, 900)])))
    var fresh = try Ledger(groupID: f.group, secret: f.secret)
    fresh.apply(f.server.events)
    #expect(fresh.state == f.ledger.state)
}

@Test func wrongSecretCannotRead() throws {
    let f = try Fixture()
    var other = try Ledger(groupID: f.group, secret: Data.random(32))
    other.apply(f.server.events)
    #expect(other.state.inconsistency != nil)
    #expect(other.state.history.first?.rejection == .decrypt)
}

/// Further devices of a member (§7.3): a company member shared by two people.
@Test func memberDevices() throws {
    var f = try Fixture()
    let globex = try f.join("Globex")
    let ben = try f.join("Ben")
    let pub = { (k: Curve25519.Signing.PrivateKey) in k.publicKey.rawRepresentation }
    func claim(_ device: Actor, invite: Curve25519.Signing.PrivateKey, signedBy: Curve25519.Signing.PrivateKey? = nil) throws -> Rejection? {
        let sig = try (signedBy ?? invite).signature(for: LedgerCrypto.claimInput(groupID: f.group, key: pub(device.key)))
        return try f.write(device, .memberDeviceClaimed(.init(id: globex.id, key: pub(device.key).base64URL,
                                                              inviteKey: pub(invite).base64URL, inviteSig: sig.base64URL)))
    }

    // Only the member itself invites its devices, not the admin or others.
    let invite = Curve25519.Signing.PrivateKey()
    let deviceInvite = EventData.memberDeviceInvited(.init(id: globex.id, inviteKey: pub(invite).base64URL))
    #expect(try f.write(f.admin, deviceInvite) == .forbidden)
    #expect(try f.write(ben, deviceInvite) == .forbidden)
    #expect(try f.write(globex, deviceInvite) == nil)
    #expect(try f.write(globex, deviceInvite) == .invalidData) // key reuse
    #expect(f.ledger.state.members[globex.id]?.deviceInvites == [pub(invite)])

    // The second device needs the invite's signature, then writes as Globex.
    let second = try Actor(f.group, f.secret, id: globex.id)
    #expect(try claim(second, invite: invite, signedBy: Curve25519.Signing.PrivateKey()) == .badInviteSig)
    #expect(try claim(second, invite: invite) == nil)
    #expect(f.ledger.state.members[globex.id]?.keys == [pub(globex.key), pub(second.key)])
    #expect(f.ledger.state.members[globex.id]?.deviceInvites.isEmpty == true)
    #expect(try f.write(second, .memberUpdated(.init(id: globex.id, name: "Globex GmbH"))) == nil)
    let p = f.payment(amount: 1000, track: false, in: [(globex.id, 1000)], out: [(ben.id, 1000)])
    #expect(try f.write(second, .paymentCreated(p)) == nil)
    #expect(f.ledger.state.payments[p.id]?.creator == globex.id)
    #expect(try f.write(globex, .paymentDeleted(.init(id: p.id))) == nil) // the first device edits what the second made

    // An invite is good for one device.
    let third = try Actor(f.group, f.secret, id: globex.id)
    #expect(try claim(third, invite: invite) == .badInviteSig)

    // The second device can't speak for Ben.
    let forger = try EventWriter(groupID: f.group, secret: f.secret, author: ben.id, signer: second.key)
    f.server.append(try forger.write(.memberUpdated(.init(id: ben.id, name: "x")), seen: f.ledger.state.head))
    f.ledger.apply(Array(f.server.events.suffix(1)))
    #expect(f.ledger.state.history.last?.rejection == .badSignature)

    // Revoking a pending device invite: the member or the admin.
    let spare = Curve25519.Signing.PrivateKey()
    #expect(try f.write(second, .memberDeviceInvited(.init(id: globex.id, inviteKey: pub(spare).base64URL))) == nil)
    let revoke = EventData.memberDeviceInviteRevoked(.init(id: globex.id, inviteKey: pub(spare).base64URL))
    #expect(try f.write(ben, revoke) == .forbidden)
    #expect(try f.write(f.admin, revoke) == nil)
    #expect(try f.write(f.admin, revoke) == .unknownTarget)
    #expect(try claim(third, invite: spare) == .badInviteSig)

    // Replaying from scratch gives the same state.
    var fresh = try Ledger(groupID: f.group, secret: f.secret)
    fresh.apply(f.server.events)
    #expect(fresh.state == f.ledger.state)
}
