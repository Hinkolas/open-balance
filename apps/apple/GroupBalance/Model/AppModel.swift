import Foundation
import LedgerCore
import LedgerSync
import Observation

/// App-wide state: the groups on this device, which one is active, the
/// servers this device may create groups on, and pending invite links.
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
    /// An invite opened from a link or scanned, waiting for the join sheet.
    var pendingInvite: InviteLink?
    var toast: String?
    private var foreground = false

    init() {
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
        if let link = InviteLink(url) {
            pendingInvite = link
        } else {
            toast = String(localized: "This link is not a valid Group Balance invite.")
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

    func create(on server: ServerOwnership, name: String, currency: String, myName: String) async throws {
        let session = try await GroupSession.create(server: server.server, ownerToken: server.token, name: name, currency: currency, myName: myName)
        sessions.append(session)
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

    func removeServer(_ s: ServerOwnership) {
        KeychainStore.servers.delete(account: s.server.absoluteString)
        servers.removeAll { $0.server == s.server }
    }
}
