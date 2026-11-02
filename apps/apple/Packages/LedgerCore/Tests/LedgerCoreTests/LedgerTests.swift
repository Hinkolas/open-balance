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
    let box: Curve25519.KeyAgreement.PrivateKey
    init(_ group: UUID, _ secret: Data, id: MemberID = UUID.v7().lower, key: Curve25519.Signing.PrivateKey = .init()) throws {
        self.id = id
        self.key = key
        self.box = try LedgerCrypto.boxKey(seed: key.rawRepresentation)
        self.writer = try EventWriter(groupID: group, secret: secret, author: id, signer: key)
    }
    var boxKey: String { box.publicKey.rawRepresentation.base64URL }
}

/// The box key (base64url) of an invite or other seed key.
func boxKey(_ k: Curve25519.Signing.PrivateKey) -> String {
    try! LedgerCrypto.boxKey(seed: k.rawRepresentation).publicKey.rawRepresentation.base64URL
}

struct Fixture {
    let group = UUID.v7()
    let secret = Data.random(32)
    var server = FakeServer()
    var ledger: Ledger
    let admin: Actor
    let recovery = Curve25519.Signing.PrivateKey()

    init() throws {
        admin = try Actor(group, secret)
        ledger = try Ledger(groupID: group, secrets: [secret], boxes: [admin.box])
        try write(admin, .groupCreated(.init(name: "Italien", currency: "EUR",
                                             admin: .init(id: admin.id, name: "Jonas", key: admin.key.publicKey.rawRepresentation.base64URL, boxKey: admin.boxKey),
                                             recoveryKey: recovery.publicKey.rawRepresentation.base64URL, recoveryBoxKey: boxKey(recovery))))
    }

    /// Write as `who`, append, reduce; returns the rejection of that event.
    @discardableResult
    mutating func write(_ who: Actor, _ data: EventData) throws -> Rejection? {
        server.append(try writer(who).write(data, seen: ledger.state.head))
        ledger.apply(Array(server.events.suffix(1)))
        return ledger.state.history.last?.rejection
    }

    /// A writer for the ledger's current epoch.
    func writer(_ who: Actor) throws -> EventWriter {
        try EventWriter(groupID: group, secret: ledger.currentSecret ?? secret, epoch: ledger.state.epoch, author: who.id, signer: who.key)
    }

    /// Admin adds a member; the member claims with a fresh key.
    mutating func join(_ name: String) throws -> Actor {
        let invite = Curve25519.Signing.PrivateKey()
        let member = try Actor(group, secret)
        try write(admin, .memberAdded(.init(id: member.id, name: name, inviteKey: invite.publicKey.rawRepresentation.base64URL, inviteBoxKey: boxKey(invite))))
        let pub = member.key.publicKey.rawRepresentation
        let sig = try invite.signature(for: LedgerCrypto.claimInput(groupID: group, key: pub))
        let r = try write(member, .memberClaimed(.init(id: member.id, key: pub.base64URL, boxKey: member.boxKey, inviteSig: sig.base64URL)))
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
    let x = Curve25519.Signing.PrivateKey()
    #expect(try f.write(cem, .memberAdded(.init(id: "x", name: "X", inviteKey: x.publicKey.rawRepresentation.base64URL, inviteBoxKey: boxKey(x)))) == .forbidden)
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
    try f.write(f.admin, .memberAdded(.init(id: oma, name: "Oma", inviteKey: invite.publicKey.rawRepresentation.base64URL, inviteBoxKey: boxKey(invite))))
    let ben = try f.join("Ben")

    // Anyone may record arrivals for an unclaimed seat.
    let p = f.payment(amount: 500, track: true, in: [(oma, 500)], out: [(ben.id, 500)])
    #expect(try f.write(ben, .paymentCreated(p)) == nil)
    #expect(try f.write(ben, .arrivalRecorded(.init(id: "r", payment: p.id, member: oma, amount: 500))) == nil)
    #expect(f.ledger.state.summary.balances[oma] == -500)

    // A claim needs the invite's signature.
    let impostor = try Actor(f.group, f.secret, id: oma)
    let wrongSig = try Curve25519.Signing.PrivateKey().signature(for: LedgerCrypto.claimInput(groupID: f.group, key: impostor.key.publicKey.rawRepresentation))
    #expect(try f.write(impostor, .memberClaimed(.init(id: oma, key: impostor.key.publicKey.rawRepresentation.base64URL, boxKey: impostor.boxKey, inviteSig: wrongSig.base64URL))) == .badInviteSig)

    let real = try Actor(f.group, f.secret, id: oma)
    let sig = try invite.signature(for: LedgerCrypto.claimInput(groupID: f.group, key: real.key.publicKey.rawRepresentation))
    #expect(try f.write(real, .memberClaimed(.init(id: oma, key: real.key.publicKey.rawRepresentation.base64URL, boxKey: real.boxKey, inviteSig: sig.base64URL))) == nil)
    #expect(try f.write(real, .memberClaimed(.init(id: oma, key: real.key.publicKey.rawRepresentation.base64URL, boxKey: real.boxKey, inviteSig: sig.base64URL))) == .alreadyClaimed)
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
    var fresh = try Ledger(groupID: f.group, secrets: [f.secret], boxes: [f.admin.box])
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
        return try f.write(device, .memberDeviceClaimed(.init(id: globex.id, key: pub(device.key).base64URL, boxKey: device.boxKey,
                                                              inviteKey: pub(invite).base64URL, inviteSig: sig.base64URL)))
    }

    // Only the member itself invites its devices, not the admin or others.
    let invite = Curve25519.Signing.PrivateKey()
    let deviceInvite = EventData.memberDeviceInvited(.init(id: globex.id, inviteKey: pub(invite).base64URL, inviteBoxKey: boxKey(invite)))
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
    #expect(try f.write(second, .memberDeviceInvited(.init(id: globex.id, inviteKey: pub(spare).base64URL, inviteBoxKey: boxKey(spare)))) == nil)
    let revoke = EventData.memberDeviceInviteRevoked(.init(id: globex.id, inviteKey: pub(spare).base64URL))
    #expect(try f.write(ben, revoke) == .forbidden)
    #expect(try f.write(f.admin, revoke) == nil)
    #expect(try f.write(f.admin, revoke) == .unknownTarget)
    #expect(try claim(third, invite: spare) == .badInviteSig)

    // Replaying from scratch gives the same state.
    var fresh = try Ledger(groupID: f.group, secrets: [f.secret], boxes: [f.admin.box])
    fresh.apply(f.server.events)
    #expect(fresh.state == f.ledger.state)
}

private func pub(_ k: Curve25519.Signing.PrivateKey) -> Data { k.publicKey.rawRepresentation }

/// Removing devices and resetting a member (§7.3 member.device_removed).
@Test func deviceRemoval() throws {
    var f = try Fixture()
    let anna = try f.join("Anna")
    let ben = try f.join("Ben")
    let invite = Curve25519.Signing.PrivateKey()
    #expect(try f.write(anna, .memberDeviceInvited(.init(id: anna.id, inviteKey: pub(invite).base64URL, inviteBoxKey: boxKey(invite)))) == nil)
    let phone = try Actor(f.group, f.secret, id: anna.id)
    let sig = try invite.signature(for: LedgerCrypto.claimInput(groupID: f.group, key: pub(phone.key)))
    #expect(try f.write(phone, .memberDeviceClaimed(.init(id: anna.id, key: pub(phone.key).base64URL, boxKey: phone.boxKey, inviteKey: pub(invite).base64URL, inviteSig: sig.base64URL))) == nil)

    // Only Anna herself or the admin removes Anna's devices.
    let removePhone = EventData.memberDeviceRemoved(.init(id: anna.id, key: pub(phone.key).base64URL))
    #expect(try f.write(ben, removePhone) == .forbidden)
    #expect(try f.write(anna, .memberDeviceRemoved(.init(id: anna.id, key: pub(ben.key).base64URL))) == .unknownTarget)
    #expect(try f.write(anna, removePhone) == nil)
    #expect(f.ledger.state.members[anna.id]?.keys == [pub(anna.key)])
    #expect(f.ledger.state.removedKeys.contains(pub(phone.key)))
    #expect(try f.write(anna, removePhone) == .unknownTarget)

    // The removed device can't write any more, and its key can't come back.
    #expect(try f.write(phone, .memberUpdated(.init(id: anna.id, name: "Thief"))) == .badSignature)
    let again = Curve25519.Signing.PrivateKey()
    #expect(try f.write(anna, .memberDeviceInvited(.init(id: anna.id, inviteKey: pub(again).base64URL, inviteBoxKey: boxKey(again)))) == nil)
    let sig2 = try again.signature(for: LedgerCrypto.claimInput(groupID: f.group, key: pub(phone.key)))
    #expect(try f.write(phone, .memberDeviceClaimed(.init(id: anna.id, key: pub(phone.key).base64URL, boxKey: phone.boxKey, inviteKey: pub(again).base64URL, inviteSig: sig2.base64URL))) == .invalidData)

    // Reset: the admin removes Anna's last key; she is a seat again, keeps her
    // payments, and her pending device invites are gone.
    let p = f.payment(amount: 1000, track: true, in: [(anna.id, 1000)], out: [(ben.id, 1000)])
    #expect(try f.write(anna, .paymentCreated(p)) == nil)
    #expect(try f.write(f.admin, .memberDeviceRemoved(.init(id: anna.id, key: pub(anna.key).base64URL))) == nil)
    let seat = try #require(f.ledger.state.members[anna.id])
    #expect(!seat.isClaimed && seat.inviteKey == nil && seat.deviceInvites.isEmpty)
    #expect(try f.write(ben, .arrivalRecorded(.init(id: "a1", payment: p.id, member: anna.id, amount: 500))) == nil)

    let fresh = Curve25519.Signing.PrivateKey()
    #expect(try f.write(f.admin, .memberInviteRenewed(.init(id: anna.id, inviteKey: pub(fresh).base64URL, inviteBoxKey: boxKey(fresh)))) == nil)
    let newPhone = try Actor(f.group, f.secret, id: anna.id)
    let claimSig = try fresh.signature(for: LedgerCrypto.claimInput(groupID: f.group, key: pub(newPhone.key)))
    #expect(try f.write(newPhone, .memberClaimed(.init(id: anna.id, key: pub(newPhone.key).base64URL, boxKey: newPhone.boxKey, inviteSig: claimSig.base64URL))) == nil)
    #expect(f.ledger.state.members[anna.id]?.keys == [pub(newPhone.key)])
    #expect(f.ledger.state.payments[p.id]?.creator == anna.id)
    #expect(try f.write(newPhone, .paymentDeleted(.init(id: p.id))) == nil)

    var replay = try Ledger(groupID: f.group, secrets: [f.secret], boxes: [f.admin.box])
    replay.apply(f.server.events)
    #expect(replay.state == f.ledger.state)
}

/// The recovery key replaces the admin's devices (§7.3 member.recovered, §7.2).
@Test func adminRecovery() throws {
    var f = try Fixture()
    let anna = try f.join("Anna")
    let deviceInvite = Curve25519.Signing.PrivateKey()
    #expect(try f.write(f.admin, .memberDeviceInvited(.init(id: f.admin.id, inviteKey: pub(deviceInvite).base64URL, inviteBoxKey: boxKey(deviceInvite)))) == nil)

    func recover(_ device: Actor, with key: Curve25519.Signing.PrivateKey, id: MemberID? = nil) throws -> Rejection? {
        let sig = try key.signature(for: LedgerCrypto.recoverInput(groupID: f.group, key: pub(device.key)))
        return try f.write(device, .memberRecovered(.init(id: id ?? device.id, key: pub(device.key).base64URL, boxKey: device.boxKey, recoverySig: sig.base64URL)))
    }

    // Only the admin's seat, only with the recovery key, and not with a claim signature.
    let annaNew = try Actor(f.group, f.secret, id: anna.id)
    #expect(try recover(annaNew, with: f.recovery) == .forbidden)
    let restored = try Actor(f.group, f.secret, id: f.admin.id)
    #expect(try recover(restored, with: Curve25519.Signing.PrivateKey()) == .badRecoverySig)
    let claimSig = try f.recovery.signature(for: LedgerCrypto.claimInput(groupID: f.group, key: pub(restored.key)))
    #expect(try f.write(restored, .memberRecovered(.init(id: f.admin.id, key: pub(restored.key).base64URL, boxKey: restored.boxKey, recoverySig: claimSig.base64URL))) == .badRecoverySig)
    #expect(try recover(restored, with: f.recovery) == nil)

    let admin = try #require(f.ledger.state.members[f.admin.id])
    #expect(admin.keys == [pub(restored.key)] && admin.deviceInvites.isEmpty)
    #expect(f.ledger.state.removedKeys.contains(pub(f.admin.key)))
    #expect(try f.write(f.admin, .groupUpdated(.init(name: "Lost phone"))) == .badSignature)
    #expect(try f.write(restored, .groupUpdated(.init(name: "Italien 2026"))) == nil)
    #expect(try recover(restored, with: f.recovery) == .invalidData) // key reuse

    // A new recovery key: admin only, new key, the old one stops working.
    let next = Curve25519.Signing.PrivateKey()
    let change = EventData.groupRecoveryChanged(.init(recoveryKey: pub(next).base64URL, recoveryBoxKey: boxKey(next)))
    #expect(try f.write(anna, change) == .forbidden)
    #expect(try f.write(restored, .groupRecoveryChanged(.init(recoveryKey: pub(f.admin.key).base64URL, recoveryBoxKey: boxKey(Curve25519.Signing.PrivateKey())))) == .invalidData)
    #expect(try f.write(restored, change) == nil)
    #expect(f.ledger.state.recoveryKey == pub(next))
    let second = try Actor(f.group, f.secret, id: f.admin.id)
    #expect(try recover(second, with: f.recovery) == .badRecoverySig)
    #expect(try recover(second, with: next) == nil)
    #expect(f.ledger.state.members[f.admin.id]?.keys == [pub(second.key)])
}

/// group.created needs a recovery key different from the admin key.
@Test func genesisNeedsRecoveryKey() throws {
    let group = UUID.v7()
    let secret = Data.random(32)
    let admin = try Actor(group, secret)
    let k = pub(admin.key).base64URL
    let e = try admin.writer.write(.groupCreated(.init(name: "G", currency: "EUR", admin: .init(id: admin.id, name: "A", key: k, boxKey: admin.boxKey),
                                                       recoveryKey: k, recoveryBoxKey: boxKey(Curve25519.Signing.PrivateKey()))),
                                   seen: LedgerState(groupID: group).head)
    var l = try Ledger(groupID: group, secret: secret)
    l.apply([RawEvent(seq: 1, id: e.id, blob: e.blob)])
    #expect(l.state.history.first?.rejection == .invalidData)
    #expect(l.state.inconsistency != nil)
}

/// Key epochs (§7.2): a removed device can't read what follows the next epoch,
/// stale writes are invalid, the reader set must match, and a member who joins
/// later reads all of it from its keyring and the entries sealed to its invite.
@Test func keyEpochs() throws {
    var f = try Fixture()
    let anna = try f.join("Anna")
    let ben = try f.join("Ben")
    let invite = Curve25519.Signing.PrivateKey()
    #expect(try f.write(anna, .memberDeviceInvited(.init(id: anna.id, inviteKey: pub(invite).base64URL, inviteBoxKey: boxKey(invite)))) == nil)
    let phone = try Actor(f.group, f.secret, id: anna.id)
    let sig = try invite.signature(for: LedgerCrypto.claimInput(groupID: f.group, key: pub(phone.key)))
    #expect(try f.write(phone, .memberDeviceClaimed(.init(id: anna.id, key: pub(phone.key).base64URL, boxKey: phone.boxKey,
                                                         inviteKey: pub(invite).base64URL, inviteSig: sig.base64URL))) == nil)
    #expect(f.ledger.state.readers.count == 5) // admin, Anna, her phone, Ben, recovery
    #expect(!f.ledger.state.epochDue)

    // Anna removes her phone: a new epoch is due, by her.
    #expect(try f.write(anna, .memberDeviceRemoved(.init(id: anna.id, key: pub(phone.key).base64URL))) == nil)
    #expect(f.ledger.state.epochDue && f.ledger.state.epochDueBy == anna.id)
    let readers = f.ledger.state.readers
    #expect(readers.count == 4 && !readers.contains(phone.box.publicKey.rawRepresentation))

    // The reader set must match exactly, and the epoch must be the next one.
    let withPhone = try Epochs.start(epoch: 1, readers: readers.union([phone.box.publicKey.rawRepresentation]), groupID: f.group).0
    #expect(try f.write(anna, .groupEpochStarted(withPhone)) == .invalidData)
    let withoutRecovery = try Epochs.start(epoch: 1, readers: readers.subtracting([f.ledger.state.recoveryBoxKey!]), groupID: f.group).0
    #expect(try f.write(anna, .groupEpochStarted(withoutRecovery)) == .invalidData)
    #expect(try f.write(anna, .groupEpochStarted(try Epochs.start(epoch: 2, readers: readers, groupID: f.group).0)) == .invalidData)

    // Two devices start epoch 1 at the same time: the first wins, the second is stale.
    let (first, s1) = try Epochs.start(epoch: 1, readers: readers, groupID: f.group)
    let (second, _) = try Epochs.start(epoch: 1, readers: readers, groupID: f.group)
    #expect(try f.write(anna, .groupEpochStarted(first)) == nil)
    #expect(f.ledger.state.epoch == 1 && !f.ledger.state.epochDue)
    #expect(f.ledger.currentSecret == s1) // the admin found its entry
    let epoch0 = try EventWriter(groupID: f.group, secret: f.secret, epoch: 0, author: f.admin.id, signer: f.admin.key)
    f.server.append(try epoch0.write(.groupEpochStarted(second), seen: f.ledger.state.head))
    f.ledger.apply(Array(f.server.events.suffix(1)))
    #expect(f.ledger.state.history.last?.rejection == .staleEpoch)
    #expect(f.ledger.state.epoch == 1)

    // Writes in the old epoch are stale; in the new one they count.
    f.server.append(try epoch0.write(.groupUpdated(.init(name: "Old key")), seen: f.ledger.state.head))
    f.ledger.apply(Array(f.server.events.suffix(1)))
    #expect(f.ledger.state.history.last?.rejection == .staleEpoch)
    let p = f.payment(amount: 5000, track: false, in: [(anna.id, 5000)], out: [(ben.id, 5000)])
    #expect(try f.write(ben, .paymentCreated(p)) == nil)

    // The removed phone reads up to the new epoch and nothing after.
    var phoneView = try Ledger(groupID: f.group, secrets: [f.secret], boxes: [phone.box])
    phoneView.apply(f.server.events)
    #expect(phoneView.secrets.count == 1)
    #expect(phoneView.state.payments[p.id] == nil)
    #expect(phoneView.state.history.last?.rejection == .decrypt)

    // Cem is invited in epoch 1; epoch 2 starts before he joins, sealed to his invite too.
    let cemInvite = Curve25519.Signing.PrivateKey()
    let cem = try Actor(f.group, f.secret)
    #expect(try f.write(f.admin, .memberAdded(.init(id: cem.id, name: "Cem", inviteKey: pub(cemInvite).base64URL, inviteBoxKey: boxKey(cemInvite)))) == nil)
    let inviteBox = try LedgerCrypto.boxKey(seed: cemInvite.rawRepresentation)
    let keyring = try Epochs.sealKeyring(f.ledger.secrets, to: inviteBox.publicKey.rawRepresentation, groupID: f.group)
    #expect(f.ledger.state.readers.contains(inviteBox.publicKey.rawRepresentation))
    #expect(try f.write(f.admin, .groupEpochStarted(try Epochs.start(epoch: 2, readers: f.ledger.state.readers, groupID: f.group).0)) == nil)

    var cemView = try Ledger(groupID: f.group, secrets: try Epochs.openKeyring(keyring, box: inviteBox, groupID: f.group), boxes: [cem.box, inviteBox])
    cemView.apply(f.server.events)
    #expect(cemView.secrets == f.ledger.secrets)
    #expect(cemView.state == f.ledger.state)
    let claimSig = try cemInvite.signature(for: LedgerCrypto.claimInput(groupID: f.group, key: pub(cem.key)))
    #expect(try f.write(cem, .memberClaimed(.init(id: cem.id, key: pub(cem.key).base64URL, boxKey: cem.boxKey, inviteSig: claimSig.base64URL))) == nil)
    #expect(!f.ledger.state.readers.contains(inviteBox.publicKey.rawRepresentation))

    // A recovery and a new recovery key make an epoch due too.
    let next = Curve25519.Signing.PrivateKey()
    #expect(try f.write(f.admin, .groupRecoveryChanged(.init(recoveryKey: pub(next).base64URL, recoveryBoxKey: boxKey(next)))) == nil)
    #expect(f.ledger.state.epochDue && f.ledger.state.epochDueBy == f.admin.id)

    var replay = try Ledger(groupID: f.group, secrets: [f.secret], boxes: [f.admin.box])
    replay.apply(f.server.events)
    #expect(replay.state == f.ledger.state)
    #expect(replay.secrets == f.ledger.secrets)
}
