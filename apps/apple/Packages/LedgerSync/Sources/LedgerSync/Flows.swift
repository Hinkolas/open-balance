import CryptoKit
import Foundation
import LedgerCore

public enum FlowError: Error, LocalizedError, Equatable {
    case notAdmin
    case inviteUsed
    case seatMissing
    case seatTaken
    case unsupportedServer
    case creationCodeUsed
    case recoveryReplaced
    case notRecoverable
    case noEpochSecret

    public var errorDescription: String? {
        switch self {
        case .notAdmin: String(localized: "Only the group admin can do this.")
        case .inviteUsed: String(localized: "This invite has already been used or was revoked. Ask for a new one.")
        case .seatMissing: String(localized: "This invite doesn't match a member of the group.")
        case .seatTaken: String(localized: "Someone already joined as this member.")
        case .unsupportedServer: String(localized: "This server doesn't speak protocol version 1.")
        case .creationCodeUsed: String(localized: "This link to create a group has been used, withdrawn or has expired. Ask the server owner for a new one.")
        case .recoveryReplaced: String(localized: "This recovery kit no longer works. A newer one replaced it, or the group was deleted.")
        case .notRecoverable: String(localized: "This recovery kit doesn't match the group's admin.")
        case .noEpochSecret: String(localized: "This device doesn't have the group's current key. Ask the admin or one of your other devices for a new invite.")
        }
    }
}

/// Create, invite, add and remove devices, join and recover (PROTOCOL.md §5.4).
@MainActor
public extension GroupSession {
    /// Create a group as its admin. `token` is the server's ADMIN_TOKEN or a
    /// creation code from the server owner. Returns the recovery kit, which
    /// this device doesn't keep: show it once.
    static func create(
        server: URL, token: String, name: String, currency: String, myName: String,
        store: CredentialStore = KeychainCredentialStore(), cacheRoot: URL? = nil
    ) async throws -> (GroupSession, RecoveryLink) {
        let client = ServerClient(base: server)
        guard try await client.info().protocols.contains(1) else { throw FlowError.unsupportedServer }
        let groupID = UUID.v7()
        let key = Curve25519.Signing.PrivateKey()
        let secret = Data.random(32)
        let recoverySeed = Data.random(32)
        let recovery = try Curve25519.Signing.PrivateKey(rawRepresentation: recoverySeed)
        let recoveryBox = try LedgerCrypto.boxKey(seed: recoverySeed).publicKey.rawRepresentation
        do {
            try await client.createGroup(token: token, groupID: groupID, adminKey: key.publicKey.rawRepresentation,
                                         recoveryKey: recovery.publicKey.rawRepresentation,
                                         recoveryKeyring: Epochs.sealKeyring([secret], to: recoveryBox, groupID: groupID))
        } catch let e as ServerError where e.status == 401 {
            throw FlowError.creationCodeUsed
        }
        let creds = GroupCredentials(server: server, groupID: groupID, secrets: [secret], memberID: UUID.v7().lower,
                                     memberSeed: key.rawRepresentation, registered: true)
        try store.save(creds)
        let session = try GroupSession(credentials: creds, store: store, cacheRoot: cacheRoot)
        let admin = GroupCreated.Admin(id: creds.memberID, name: myName, key: key.publicKey.rawRepresentation.base64URL,
                                       boxKey: try creds.box.publicKey.rawRepresentation.base64URL)
        try session.submit(.groupCreated(.init(name: name, currency: currency, admin: admin,
                                               recoveryKey: recovery.publicKey.rawRepresentation.base64URL, recoveryBoxKey: recoveryBox.base64URL)))
        try await session.syncNow()
        return (session, RecoveryLink(server: server, groupID: groupID, adminID: creds.memberID, recoverySeed: recoverySeed))
    }

    /// A new invite key pair, its box key, and the keyring for it: every epoch
    /// secret so far, sealed to the box key (PROTOCOL.md §5.4 steps 2 and 5).
    private func newInvite() throws -> (seed: Data, key: Data, box: Data, keyring: Data) {
        let seed = Data.random(32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let box = try LedgerCrypto.boxKey(seed: seed).publicKey.rawRepresentation
        return (seed, key, box, try Epochs.sealKeyring(secrets, to: box, groupID: id))
    }

    /// Replace the recovery kit: the old one stops working. Returns the new
    /// one, which this device doesn't keep.
    func newRecoveryKit() async throws -> RecoveryLink {
        guard isAdmin else { throw FlowError.notAdmin }
        let seed = Data.random(32)
        let recovery = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let box = try LedgerCrypto.boxKey(seed: seed).publicKey.rawRepresentation
        try await client.replaceRecovery(signer: credentials.signer, groupID: id, recoveryKey: recovery,
                                         keyring: Epochs.sealKeyring(secrets, to: box, groupID: id))
        // Starts a new epoch too, so the old kit can't read what follows.
        try submit(.groupRecoveryChanged(.init(recoveryKey: recovery.base64URL, recoveryBoxKey: box.base64URL)))
        try await syncNow()
        return RecoveryLink(server: credentials.server, groupID: id, adminID: me, recoverySeed: seed)
    }

    /// Remove a device of a member: one of my own other devices, or (admin)
    /// any member's. The ledger first, then the server cuts the key off.
    func removeDevice(of member: MemberID, key: Data) async throws {
        guard member == me || isAdmin else { throw FlowError.notAdmin }
        if state.members[member]?.keys.contains(key) == true {
            try submit(.memberDeviceRemoved(.init(id: member, key: key.base64URL)))
            try await syncNow()
        }
        do {
            try await client.removeKey(signer: credentials.signer, groupID: id, key: key)
        } catch let e as ServerError where e.status == 404 {}
    }

    /// Reset a member who lost every device (admin): remove all its devices
    /// and return a new invite for its new first device. The member keeps
    /// its payments and balance.
    func resetMember(_ member: MemberID) async throws -> InviteLink {
        guard isAdmin, member != me else { throw FlowError.notAdmin }
        let keys = state.members[member]?.keys ?? []
        for key in keys { try submit(.memberDeviceRemoved(.init(id: member, key: key.base64URL))) }
        if !keys.isEmpty { try await syncNow() }
        for key in keys {
            do {
                try await client.removeKey(signer: credentials.signer, groupID: id, key: key)
            } catch let e as ServerError where e.status == 404 {}
        }
        return try await renewInvite(for: member)
    }

    /// Add a member seat and return the invite to show as QR. The seat is on
    /// the server before this returns, so the invite works right away.
    func addMember(name: String) async throws -> InviteLink {
        guard isAdmin else { throw FlowError.notAdmin }
        let memberID = UUID.v7().lower
        let invite = try newInvite()
        try await client.createInvite(signer: credentials.signer, groupID: id, inviteKey: invite.key, keyring: invite.keyring)
        try updateCredentials { $0.invites[memberID] = invite.seed }
        try submit(.memberAdded(.init(id: memberID, name: name, inviteKey: invite.key.base64URL, inviteBoxKey: invite.box.base64URL)))
        try await syncNow()
        return InviteLink(server: credentials.server, groupID: id, memberID: memberID, inviteSeed: invite.seed)
    }

    /// The invite of an unclaimed member, if this device created it.
    func inviteLink(for member: MemberID) -> InviteLink? {
        guard let m = state.members[member], !m.isClaimed, let seed = credentials.invites[member],
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              key.publicKey.rawRepresentation == m.inviteKey
        else { return nil }
        return InviteLink(server: credentials.server, groupID: id, memberID: member, inviteSeed: seed)
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
        let invite = try newInvite()
        try await client.createInvite(signer: credentials.signer, groupID: id, inviteKey: invite.key, keyring: invite.keyring)
        try updateCredentials { $0.invites[member] = invite.seed }
        try submit(.memberInviteRenewed(.init(id: member, inviteKey: invite.key.base64URL, inviteBoxKey: invite.box.base64URL)))
        try await syncNow()
        return InviteLink(server: credentials.server, groupID: id, memberID: member, inviteSeed: invite.seed)
    }

    /// The pending invite for a further device of my own member, if this
    /// device made it and it hasn't been used or revoked.
    func deviceInviteLink() -> InviteLink? {
        guard let seed = credentials.deviceInvite, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              state.members[me]?.deviceInvites.contains(key.publicKey.rawRepresentation) == true
        else { return nil }
        return InviteLink(server: credentials.server, groupID: id, memberID: me, inviteSeed: seed)
    }

    /// Invite a further device of my own member, e.g. the second person of a
    /// company. Shows this device's pending invite again if there is one.
    func addDevice() async throws -> InviteLink {
        if let link = deviceInviteLink() { return link }
        let invite = try newInvite()
        try await client.createInvite(signer: credentials.signer, groupID: id, inviteKey: invite.key, keyring: invite.keyring,
                                      role: isAdmin ? "admin" : "member")
        try updateCredentials { $0.deviceInvite = invite.seed }
        try submit(.memberDeviceInvited(.init(id: me, inviteKey: invite.key.base64URL, inviteBoxKey: invite.box.base64URL)))
        try await syncNow()
        return InviteLink(server: credentials.server, groupID: id, memberID: me, inviteSeed: invite.seed)
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
        let inviteBox = try LedgerCrypto.boxKey(seed: link.inviteSeed)
        var creds = existing ?? GroupCredentials(server: link.server, groupID: link.groupID, secrets: [], memberID: link.memberID,
                                                 memberSeed: Curve25519.Signing.PrivateKey().rawRepresentation, registered: false)
        if !creds.registered || creds.secrets.isEmpty {
            // Save the key before the server learns it, so a crash can't strand the seat.
            try store.save(creds)
            let member = try creds.signer
            let keyring: Data
            do {
                keyring = try await client.claim(invite: invite, member: member, groupID: link.groupID)
            } catch let e as ServerError where e.status == 403 || e.status == 409 {
                // Used already: by us in an earlier attempt, or by someone else.
                do {
                    keyring = try await client.keyring(signer: member, groupID: link.groupID)
                } catch {
                    store.delete(link.groupID)
                    throw FlowError.inviteUsed
                }
            }
            creds.secrets = try Epochs.openKeyring(keyring, box: inviteBox, groupID: link.groupID)
            creds.registered = true
            try store.save(creds)
        }
        let session = try GroupSession(credentials: creds, store: store, cacheRoot: cacheRoot, extraBoxes: [inviteBox])
        try await session.syncNow()
        guard let seat = session.state.members[creds.memberID] else { throw FlowError.seatMissing }
        let memberKey = try creds.signer.publicKey.rawRepresentation
        let boxKey = try creds.box.publicKey.rawRepresentation.base64URL
        let inviteKey = invite.publicKey.rawRepresentation
        let sig = try invite.signature(for: LedgerCrypto.claimInput(groupID: link.groupID, key: memberKey))
        if seat.keys.contains(memberKey) {
            return session
        } else if !seat.isClaimed {
            try session.submit(.memberClaimed(.init(id: creds.memberID, key: memberKey.base64URL, boxKey: boxKey, inviteSig: sig.base64URL)))
        } else if seat.deviceInvites.contains(inviteKey) {
            try session.submit(.memberDeviceClaimed(.init(id: creds.memberID, key: memberKey.base64URL, boxKey: boxKey,
                                                         inviteKey: inviteKey.base64URL, inviteSig: sig.base64URL)))
        } else {
            throw FlowError.seatTaken
        }
        try await session.syncNow()
        return session
    }

    /// Take over the admin's seat with the recovery kit: the server swaps all
    /// of the admin's devices for this one, then the ledger records it. Safe
    /// to retry with the same kit and `existing` credentials.
    static func recover(
        _ link: RecoveryLink, existing: GroupCredentials? = nil,
        store: CredentialStore = KeychainCredentialStore(), cacheRoot: URL? = nil
    ) async throws -> GroupSession {
        let client = ServerClient(base: link.server)
        let recovery = try Curve25519.Signing.PrivateKey(rawRepresentation: link.recoverySeed)
        let recoveryBox = try LedgerCrypto.boxKey(seed: link.recoverySeed)
        var creds = existing ?? GroupCredentials(server: link.server, groupID: link.groupID, secrets: [], memberID: link.adminID,
                                                 memberSeed: Curve25519.Signing.PrivateKey().rawRepresentation, registered: false)
        if !creds.registered || creds.secrets.isEmpty {
            try store.save(creds)
            let member = try creds.signer
            let keyring: Data
            do {
                keyring = try await client.recover(recovery: recovery, member: member, groupID: link.groupID)
            } catch let e as ServerError where e.status == 403 || e.status == 409 {
                // Registered by an earlier attempt, or the kit was replaced.
                do {
                    keyring = try await client.keyring(signer: member, groupID: link.groupID)
                } catch {
                    store.delete(link.groupID)
                    throw e.status == 403 ? FlowError.recoveryReplaced : error
                }
            }
            creds.secrets = try Epochs.openKeyring(keyring, box: recoveryBox, groupID: link.groupID)
            creds.registered = true
            try store.save(creds)
        }
        let session = try GroupSession(credentials: creds, store: store, cacheRoot: cacheRoot, extraBoxes: [recoveryBox])
        try await session.syncNow()
        guard session.state.adminID == link.adminID else { throw FlowError.notRecoverable }
        let memberKey = try creds.signer.publicKey.rawRepresentation
        if session.state.members[link.adminID]?.keys.contains(memberKey) != true {
            let sig = try recovery.signature(for: LedgerCrypto.recoverInput(groupID: link.groupID, key: memberKey))
            try session.submit(.memberRecovered(.init(id: link.adminID, key: memberKey.base64URL,
                                                      boxKey: try creds.box.publicKey.rawRepresentation.base64URL, recoverySig: sig.base64URL)))
            // Starts a new epoch too: the old admin devices can't read what follows.
            try await session.syncNow()
        }
        return session
    }
}
