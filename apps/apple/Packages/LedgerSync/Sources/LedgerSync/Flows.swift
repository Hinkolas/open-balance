import CryptoKit
import Foundation
import LedgerCore

public enum FlowError: Error, LocalizedError, Equatable {
    case notAdmin
    case inviteUsed
    case seatMissing
    case seatTaken
    case unsupportedServer

    public var errorDescription: String? {
        switch self {
        case .notAdmin: String(localized: "Only the group admin can do this.")
        case .inviteUsed: String(localized: "This invite has already been used or was revoked. Ask for a new one.")
        case .seatMissing: String(localized: "This invite doesn't match a member of the group.")
        case .seatTaken: String(localized: "Someone already joined as this member.")
        case .unsupportedServer: String(localized: "This server doesn't speak protocol version 1.")
        }
    }
}

/// Create, invite, add devices and join (PROTOCOL.md §5.4).
@MainActor
public extension GroupSession {
    /// Create a group on a server this device owns, as its admin.
    static func create(
        server: URL, ownerToken: String, name: String, currency: String, myName: String,
        store: CredentialStore = KeychainCredentialStore(), cacheRoot: URL? = nil
    ) async throws -> GroupSession {
        let client = ServerClient(base: server)
        guard try await client.info().protocols.contains(1) else { throw FlowError.unsupportedServer }
        let groupID = UUID.v7()
        let key = Curve25519.Signing.PrivateKey()
        try await client.createGroup(ownerToken: ownerToken, groupID: groupID, adminKey: key.publicKey.rawRepresentation)
        let creds = GroupCredentials(server: server, groupID: groupID, secret: .random(32), memberID: UUID.v7().lower,
                                     memberSeed: key.rawRepresentation, registered: true)
        try store.save(creds)
        let session = try GroupSession(credentials: creds, store: store, cacheRoot: cacheRoot)
        try session.submit(.groupCreated(.init(name: name, currency: currency,
                                               admin: .init(id: creds.memberID, name: myName, key: key.publicKey.rawRepresentation.base64URL))))
        try await session.syncNow()
        return session
    }

    /// Add a member seat and return the invite to show as QR. The seat is on
    /// the server before this returns, so the invite works right away.
    func addMember(name: String) async throws -> InviteLink {
        guard isAdmin else { throw FlowError.notAdmin }
        let memberID = UUID.v7().lower
        let seed = Data.random(32)
        let invite = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        try await client.createInvite(signer: credentials.signer, groupID: id, inviteKey: invite.publicKey.rawRepresentation)
        try updateCredentials { $0.invites[memberID] = seed }
        try submit(.memberAdded(.init(id: memberID, name: name, inviteKey: invite.publicKey.rawRepresentation.base64URL)))
        try await syncNow()
        return InviteLink(server: credentials.server, groupID: id, memberID: memberID, secret: credentials.secret, inviteSeed: seed)
    }

    /// The invite of an unclaimed member, if this device created it.
    func inviteLink(for member: MemberID) -> InviteLink? {
        guard let m = state.members[member], !m.isClaimed, let seed = credentials.invites[member],
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              key.publicKey.rawRepresentation == m.inviteKey
        else { return nil }
        return InviteLink(server: credentials.server, groupID: id, memberID: member, secret: credentials.secret, inviteSeed: seed)
    }

    /// Replace a lost or leaked invite: the old QR stops working.
    func renewInvite(for member: MemberID) async throws -> InviteLink {
        guard isAdmin else { throw FlowError.notAdmin }
        guard let m = state.members[member], !m.isClaimed else { throw FlowError.seatTaken }
        if let old = m.inviteKey {
            do {
                try await client.revokeInvite(signer: credentials.signer, groupID: id, inviteKey: old)
            } catch let e as ServerError where e.status == 404 {}
        }
        let seed = Data.random(32)
        let invite = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        try await client.createInvite(signer: credentials.signer, groupID: id, inviteKey: invite.publicKey.rawRepresentation)
        try updateCredentials { $0.invites[member] = seed }
        try submit(.memberInviteRenewed(.init(id: member, inviteKey: invite.publicKey.rawRepresentation.base64URL)))
        try await syncNow()
        return InviteLink(server: credentials.server, groupID: id, memberID: member, secret: credentials.secret, inviteSeed: seed)
    }

    /// The pending invite for a further device of my own member, if this
    /// device made it and it hasn't been used or revoked.
    func deviceInviteLink() -> InviteLink? {
        guard let seed = credentials.deviceInvite, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              state.members[me]?.deviceInvites.contains(key.publicKey.rawRepresentation) == true
        else { return nil }
        return InviteLink(server: credentials.server, groupID: id, memberID: me, secret: credentials.secret, inviteSeed: seed)
    }

    /// Invite a further device of my own member, e.g. the second person of a
    /// company. Shows this device's pending invite again if there is one.
    func addDevice() async throws -> InviteLink {
        if let link = deviceInviteLink() { return link }
        let seed = Data.random(32)
        let invite = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        try await client.createInvite(signer: credentials.signer, groupID: id, inviteKey: invite.publicKey.rawRepresentation,
                                      role: isAdmin ? "admin" : "member")
        try updateCredentials { $0.deviceInvite = seed }
        try submit(.memberDeviceInvited(.init(id: me, inviteKey: invite.publicKey.rawRepresentation.base64URL)))
        try await syncNow()
        return InviteLink(server: credentials.server, groupID: id, memberID: me, secret: credentials.secret, inviteSeed: seed)
    }

    /// Withdraw this device's pending device invite: its QR stops working.
    func revokeDeviceInvite() async throws {
        guard let seed = credentials.deviceInvite, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return }
        let pub = key.publicKey.rawRepresentation
        do {
            try await client.revokeInvite(signer: credentials.signer, groupID: id, inviteKey: pub)
        } catch let e as ServerError where e.status == 404 {}
        if state.members[me]?.deviceInvites.contains(pub) == true {
            try submit(.memberDeviceInviteRevoked(.init(id: me, inviteKey: pub.base64URL)))
        }
        try updateCredentials { $0.deviceInvite = nil }
        try await syncNow()
    }

    /// Join with an invite: register a new member key with the server, then
    /// announce it in the ledger, as the member's first device or a further
    /// one. Safe to retry with the same link.
    static func join(
        _ link: InviteLink, existing: GroupCredentials? = nil,
        store: CredentialStore = KeychainCredentialStore(), cacheRoot: URL? = nil
    ) async throws -> GroupSession {
        let client = ServerClient(base: link.server)
        let invite = try Curve25519.Signing.PrivateKey(rawRepresentation: link.inviteSeed)
        var creds = existing ?? GroupCredentials(server: link.server, groupID: link.groupID, secret: link.secret, memberID: link.memberID,
                                                 memberSeed: Curve25519.Signing.PrivateKey().rawRepresentation, registered: false)
        if !creds.registered {
            // Save the key before the server learns it, so a crash can't strand the seat.
            try store.save(creds)
            let member = try creds.signer
            do {
                try await client.claim(invite: invite, member: member, groupID: link.groupID)
            } catch let e as ServerError where e.status == 403 || e.status == 409 {
                // Used already: by us in an earlier attempt, or by someone else.
                do {
                    _ = try await client.read(signer: member, groupID: link.groupID, after: 0, limit: 1)
                } catch {
                    store.delete(link.groupID)
                    throw FlowError.inviteUsed
                }
            }
            creds.registered = true
            try store.save(creds)
        }
        let session = try GroupSession(credentials: creds, store: store, cacheRoot: cacheRoot)
        try await session.syncNow()
        guard let seat = session.state.members[creds.memberID] else { throw FlowError.seatMissing }
        let memberKey = try creds.signer.publicKey.rawRepresentation
        let inviteKey = invite.publicKey.rawRepresentation
        let sig = try invite.signature(for: LedgerCrypto.claimInput(groupID: link.groupID, key: memberKey))
        if seat.keys.contains(memberKey) {
            return session
        } else if !seat.isClaimed {
            try session.submit(.memberClaimed(.init(id: creds.memberID, key: memberKey.base64URL, inviteSig: sig.base64URL)))
        } else if seat.deviceInvites.contains(inviteKey) {
            try session.submit(.memberDeviceClaimed(.init(id: creds.memberID, key: memberKey.base64URL,
                                                         inviteKey: inviteKey.base64URL, inviteSig: sig.base64URL)))
        } else {
            throw FlowError.seatTaken
        }
        try await session.syncNow()
        return session
    }
}
