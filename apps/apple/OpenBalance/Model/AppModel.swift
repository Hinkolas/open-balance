import Foundation
import LedgerCore
import LedgerSync
import Observation

/// App-wide state: the groups on this device, which one is active, the
/// servers this device may create groups on, and links opened from outside.
@MainActor @Observable
final class AppModel {
    private(set) var sessions: [GroupSession] = []
    private(set) var servers: [ServerOwnership] = []
    var activeID: UUID? {
        didSet {
            UserDefaults.standard.set(activeID?.uuidString, forKey: "activeGroup")
            updateLive()
        }
    }
    /// An invite, recovery or creation link opened from outside, waiting for its sheet.
    var pendingLink: AppLink?
    var toast: String?
    private var foreground = false

    init() {
        // Earlier builds kept keys in iCloud Keychain; keys now stay on the device.
        KeychainStore.groups.deleteSynced()
        KeychainStore.servers.deleteSynced()
        load()
    }

    var active: GroupSession? { sessions.first { $0.id == activeID } ?? sessions.first }

    func load() {
        let creds = KeychainCredentialStore().all().filter(\.registered).sorted { $0.addedAt < $1.addedAt }
        sessions = creds.compactMap { c in sessions.first { $0.id == c.groupID } ?? (try? GroupSession(credentials: c)) }
        servers = KeychainStore.servers.all(ServerOwnership.self).sorted { $0.name < $1.name }
        if let raw = UserDefaults.standard.string(forKey: "activeGroup"), let id = UUID(uuidString: raw), sessions.contains(where: { $0.id == id }) {
            activeID = id
        } else {
            activeID = sessions.first?.id
        }
    }

    func activate(_ id: UUID) { activeID = id }

    func setForeground(_ on: Bool) {
        foreground = on
        updateLive()
    }

    private func updateLive() {
        for s in sessions where s.id != active?.id || !foreground { s.stopLive() }
        if foreground { active?.startLive() }
    }

    // MARK: - Links

    func handle(url: URL) {
        if let link = AppLink(url) {
            pendingLink = link
        } else {
            toast = String(localized: "This link is not a valid Open Balance invite.")
        }
    }

    // MARK: - Groups

    func join(_ link: InviteLink) async throws {
        if let existing = sessions.first(where: { $0.id == link.groupID }) {
            activeID = existing.id
            return
        }
        let interrupted = KeychainCredentialStore().all().first { $0.groupID == link.groupID && $0.memberID == link.memberID }
        let session = try await GroupSession.join(link, existing: interrupted)
        sessions.append(session)
        activeID = session.id
    }

    /// Take over the admin's seat with a recovery kit. A group this device
    /// still has is just shown; one it was removed from is forgotten first.
    func recover(_ link: RecoveryLink) async throws {
        if let existing = sessions.first(where: { $0.id == link.groupID }) {
            if !existing.isRemoved {
                activeID = existing.id
                return
            }
            forget(existing)
        }
        let interrupted = KeychainCredentialStore().all().first { $0.groupID == link.groupID && $0.memberID == link.adminID }
        let session = try await GroupSession.recover(link, existing: interrupted)
        sessions.append(session)
        activeID = session.id
    }

    /// Create a group with the owner token or a creation code. The caller
    /// shows the recovery kit, then `add`s the session: showing the group
    /// right away would close the sheet before the kit is saved.
    func create(server: URL, token: String, name: String, currency: String, myName: String) async throws -> (GroupSession, RecoveryLink) {
        try await GroupSession.create(server: server, token: token, name: name, currency: currency, myName: myName)
    }

    func add(_ session: GroupSession) {
        if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
        activeID = session.id
    }

    /// Remove a group from this device. The ledger stays on the server.
    func forget(_ session: GroupSession) {
        session.forget()
        sessions.removeAll { $0.id == session.id }
        if activeID == session.id { activeID = sessions.first?.id }
    }

    // MARK: - Servers

    func addServer(url: URL, token: String) async throws {
        let info = try await ServerClient(base: url).info()
        let ownership = ServerOwnership(server: url, token: token, name: info.name)
        try KeychainStore.servers.save(ownership, account: url.absoluteString)
        servers.removeAll { $0.server == url }
        servers.append(ownership)
    }

    /// A one-time link (7 days) that lets someone else create a group here.
    func creationLink(for s: ServerOwnership) async throws -> CreationLink {
        let (code, _) = try await ServerClient(base: s.server).createCreationCode(ownerToken: s.token)
        return CreationLink(server: s.server, code: code)
    }

    func removeServer(_ s: ServerOwnership) {
        KeychainStore.servers.delete(account: s.server.absoluteString)
        servers.removeAll { $0.server == s.server }
    }
}
