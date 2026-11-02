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
    let jonas = try await GroupSession.create(server: server, ownerToken: token, name: "Italien 2026", currency: "EUR",
                                              myName: "Jonas", store: MemoryCredentialStore(), cacheRoot: tmp.appending(path: "jonas"))
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
