import Foundation
import LedgerCore
import Testing
@testable import LedgerSync

/// End to end against a running server:
///   ADMIN_TOKEN=… DATABASE_URL=… go run ./cmd/server
///   OB_TEST_SERVER=https://open-balance.localhost OB_TEST_OWNER_TOKEN=… swift test
/// Skipped without OB_TEST_SERVER.
private let env = ProcessInfo.processInfo.environment
private let enabled = env["OB_TEST_SERVER"] != nil

@MainActor
@Test(.enabled(if: enabled))
func twoDevicesShareALedger() async throws {
    let server = URL(string: env["OB_TEST_SERVER"]!)!
    let token = env["OB_TEST_OWNER_TOKEN"] ?? ""
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ob-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Device 1: Jonas creates the group and adds Ben.
    let (jonas, kit) = try await GroupSession.create(server: server, token: token, name: "Italien 2026", currency: "EUR",
                                                     myName: "Jonas", store: MemoryCredentialStore(), cacheRoot: tmp.appending(path: "jonas"))
    #expect(RecoveryLink(kit.url) == kit)
    #expect(jonas.isAdmin)
    #expect(jonas.state.name == "Italien 2026")
    #expect(jonas.pendingCount == 0)
    let invite = try await jonas.addMember(name: "Ben")
    let parsed = try #require(InviteLink(invite.url))
    #expect(parsed == invite)

    // Device 2: Ben joins with the QR.
    let benStore = MemoryCredentialStore()
    let ben = try await GroupSession.join(parsed, store: benStore, cacheRoot: tmp.appending(path: "ben"))
    #expect(ben.state.members[ben.me]?.isClaimed == true)
    #expect(ben.state.name == "Italien 2026")
    #expect(!ben.isAdmin)

    // The invite is single use.
    await #expect(throws: FlowError.inviteUsed) {
        _ = try await GroupSession.join(parsed, store: MemoryCredentialStore(), cacheRoot: tmp.appending(path: "eve"))
    }
    // Retrying with the same device's credentials works.
    _ = try await GroupSession.join(parsed, existing: benStore.all().first, store: benStore, cacheRoot: tmp.appending(path: "ben"))

    // Jonas records an income of 1000 at himself, 600/400.
    let a = jonas.me, b = ben.me
    let p = Payment(id: UUID.v7().lower, kind: .income, title: "Projekt Nordlicht", date: "2026-10-30", amount: 100_000, track: true,
                    in: .init(mode: "exact", lines: [.init(member: a, amount: 100_000)]),
                    out: .init(mode: "percent", lines: [.init(member: a, amount: 60_000, value: 6000, rest: true), .init(member: b, amount: 40_000, value: 4000)]))
    try await jonas.syncNow()
    try jonas.submit(.paymentCreated(p))
    #expect(jonas.state.payments[p.id] != nil) // optimistic
    try jonas.submit(.arrivalRecorded(.init(id: UUID.v7().lower, payment: p.id, member: a, amount: 100_000)))
    try await jonas.syncNow()
    #expect(jonas.pendingCount == 0)

    try await ben.syncNow()
    #expect(ben.state.summary.balances == [a: -40_000, b: 40_000])
    #expect(ben.state.summary.transfers == [.init(from: a, to: b, amount: 40_000)])
    #expect(ben.state == jonas.state)

    // Ben is a company: his partner joins as a second device of the same member.
    let deviceLink = try await ben.addDevice()
    #expect(try await ben.addDevice() == deviceLink) // shown again, not a new invite
    let partner = try await GroupSession.join(try #require(InviteLink(deviceLink.url)), store: MemoryCredentialStore(),
                                              cacheRoot: tmp.appending(path: "partner"))
    #expect(partner.me == b)
    #expect(partner.state.members[b]?.keys.count == 2)
    try partner.submit(.memberUpdated(.init(id: b, name: "Ben & Co")))
    try await partner.syncNow()
    try await jonas.syncNow()
    #expect(jonas.state.members[b]?.name == "Ben & Co")
    #expect(jonas.state.history.allSatisfy { $0.rejection == nil })

    // Used invites aren't shown again; a revoked one stops working.
    try await ben.syncNow()
    #expect(ben.deviceInviteLink() == nil)
    let spare = try await ben.addDevice()
    try await ben.revokeDeviceInvite()
    #expect(ben.deviceInviteLink() == nil)
    await #expect(throws: FlowError.inviteUsed) {
        _ = try await GroupSession.join(spare, store: MemoryCredentialStore(), cacheRoot: tmp.appending(path: "spare"))
    }

    // The admin's second device is admin too: in the ledger, and on the server
    // it may revoke the invite the first device made when it renews it.
    _ = try await jonas.addMember(name: "Cem")
    let cem = try #require(jonas.state.members.values.first { $0.name == "Cem" }?.id)
    let jonasLink = try await jonas.addDevice()
    let jonas2 = try await GroupSession.join(jonasLink, store: MemoryCredentialStore(), cacheRoot: tmp.appending(path: "jonas2"))
    #expect(jonas2.isAdmin)
    _ = try await jonas2.renewInvite(for: cem)
    try await jonas.syncNow()
    #expect(jonas.state.history.allSatisfy { $0.rejection == nil })

    // A third device of nobody can't read.
    let eve = ServerClient(base: server)
    await #expect(throws: ServerError.self) {
        _ = try await eve.read(signer: .init(), groupID: jonas.id, after: 0)
    }
}

/// A creation link from the server owner, lost devices, a reset member and a
/// recovered admin (PROTOCOL.md §5.4 steps 0, 6–9).
@MainActor
@Test(.enabled(if: enabled))
func lostDevicesAndRecovery() async throws {
    let server = URL(string: env["OB_TEST_SERVER"]!)!
    let token = env["OB_TEST_OWNER_TOKEN"] ?? ""
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ob-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    func dir(_ name: String) -> URL { tmp.appending(path: name) }

    // The server owner lets Anna create a group; the code works once.
    let (code, _) = try await ServerClient(base: server).createCreationCode(ownerToken: token, expiresInHours: 1)
    let creation = try #require(CreationLink(CreationLink(server: server, code: code).url))
    let (anna, kit) = try await GroupSession.create(server: server, token: creation.code, name: "WG", currency: "EUR", myName: "Anna",
                                                    store: MemoryCredentialStore(), cacheRoot: dir("anna"))
    await #expect(throws: FlowError.creationCodeUsed) {
        _ = try await GroupSession.create(server: server, token: creation.code, name: "WG 2", currency: "EUR", myName: "Eve",
                                          store: MemoryCredentialStore(), cacheRoot: dir("eve"))
    }

    // Ben joins on his phone and adds his laptop; he loses the phone and
    // removes it from the laptop.
    let ben = try await GroupSession.join(try await anna.addMember(name: "Ben"), store: MemoryCredentialStore(), cacheRoot: dir("ben"))
    let laptop = try await GroupSession.join(try await ben.addDevice(), store: MemoryCredentialStore(), cacheRoot: dir("laptop"))
    try await laptop.removeDevice(of: ben.me, key: ben.deviceKey)
    await #expect(throws: ServerError.self) { try await ben.syncNow() }
    #expect(ben.isRemoved)
    #expect(laptop.state.members[ben.me]?.keys == [laptop.deviceKey])
    // The laptop started epoch 1 right after removing the phone.
    #expect(laptop.state.epoch == 1 && !laptop.state.epochDue)
    try await anna.syncNow()
    #expect(anna.secrets == laptop.secrets)

    // Then the laptop is lost too: Anna resets Ben, who joins again as himself.
    let p = Payment(id: UUID.v7().lower, kind: .expense, title: "Strom", date: "2026-11-02", amount: 9_000, track: false,
                    in: .init(mode: "exact", lines: [.init(member: anna.me, amount: 4_500), .init(member: ben.me, amount: 4_500)]),
                    out: .init(mode: "exact", lines: [.init(member: laptop.me, amount: 9_000)]))
    try laptop.submit(.paymentCreated(p))
    try await laptop.syncNow()
    try await anna.syncNow()

    // Even with every blob from the server, the lost phone can't read the payment.
    let all = try await ServerClient(base: server).read(signer: laptop.credentials.signer, groupID: anna.id, after: 0).events
    var phoneView = try Ledger(groupID: anna.id, secrets: ben.secrets, boxes: [ben.credentials.box])
    phoneView.apply(all)
    #expect(phoneView.secrets.count == 1)
    #expect(phoneView.state.payments[p.id] == nil)
    #expect(anna.state.payments[p.id] != nil)
    let again = try await anna.resetMember(ben.me)
    try? await laptop.syncNow()
    #expect(laptop.isRemoved)
    let benNew = try await GroupSession.join(again, store: MemoryCredentialStore(), cacheRoot: dir("benNew"))
    #expect(benNew.me == ben.me)
    #expect(benNew.secrets == anna.secrets) // from the invite's keyring
    #expect(anna.state.epoch == 2)
    #expect(benNew.state.summary.balances[ben.me] == 4_500)

    // Anna loses her phone and restores the group with her recovery kit.
    let restored = try await GroupSession.recover(try #require(RecoveryLink(kit.url)), store: MemoryCredentialStore(), cacheRoot: dir("restored"))
    #expect(restored.isAdmin)
    #expect(restored.state.members[anna.me]?.keys == [restored.deviceKey])
    try? await anna.syncNow()
    #expect(anna.isRemoved)
    #expect(!anna.isAdmin)
    #expect(restored.state.epoch == 3) // recovering started an epoch

    // A new kit replaces the old one.
    let newKit = try await restored.newRecoveryKit()
    await #expect(throws: FlowError.recoveryReplaced) {
        _ = try await GroupSession.recover(kit, store: MemoryCredentialStore(), cacheRoot: dir("old-kit"))
    }
    let restored2 = try await GroupSession.recover(newKit, store: MemoryCredentialStore(), cacheRoot: dir("restored2"))
    #expect(restored2.isAdmin)
    try await benNew.syncNow()
    #expect(benNew.state.history.filter { $0.rejection != nil }.isEmpty)
    #expect(benNew.state == restored2.state)
    #expect(restored2.state.epoch == 5) // the new kit and the second recovery each started one
    #expect(benNew.secrets.count == 6)
}

/// A device that writes before it has seen a new epoch: its event is stale,
/// and it writes it again under the new epoch (PROTOCOL.md §5.4 step 10).
@MainActor
@Test(.enabled(if: enabled))
func staleWritesAreWrittenAgain() async throws {
    let server = URL(string: env["OB_TEST_SERVER"]!)!
    let token = env["OB_TEST_OWNER_TOKEN"] ?? ""
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ob-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let (anna, _) = try await GroupSession.create(server: server, token: token, name: "Büro", currency: "EUR", myName: "Anna",
                                                  store: MemoryCredentialStore(), cacheRoot: tmp.appending(path: "anna"))
    let ben = try await GroupSession.join(try await anna.addMember(name: "Ben"), store: MemoryCredentialStore(), cacheRoot: tmp.appending(path: "ben"))

    // Anna starts epoch 1 (a new recovery kit); Ben hasn't seen it and writes.
    _ = try await anna.newRecoveryKit()
    #expect(anna.state.epoch == 1)
    let p = Payment(id: UUID.v7().lower, kind: .expense, title: "Kaffee", date: "2026-11-02", amount: 1_200, track: false,
                    in: .init(mode: "exact", lines: [.init(member: anna.me, amount: 600), .init(member: ben.me, amount: 600)]),
                    out: .init(mode: "exact", lines: [.init(member: ben.me, amount: 1_200)]))
    try ben.submit(.paymentCreated(p))
    try await ben.syncNow()
    try await ben.syncNow()
    #expect(ben.pendingCount == 0)
    try await anna.syncNow()
    #expect(anna.state.payments[p.id] != nil)
    #expect(anna.state.history.filter { $0.rejection == .staleEpoch }.count == 1) // the first attempt
    #expect(anna.state == ben.state)
}
