import CryptoKit
import Foundation
import LedgerCore
import Observation

/// One group on this device: the confirmed ledger from the server, the outbox
/// of events written here and not yet appended, and the state both produce.
///
/// Writes are optimistic: `submit` seals the event, shows it immediately and
/// syncs in the background. Appends are idempotent (event ids), so retries
/// after a crash or a lost response are safe.
@MainActor @Observable
public final class GroupSession: Identifiable {
    public private(set) var credentials: GroupCredentials
    /// Confirmed ledger plus pending outbox events.
    public private(set) var state: LedgerState
    public private(set) var isSyncing = false
    public private(set) var lastError: String?
    public private(set) var isLive = false
    /// The server refused this device's key: it was removed, or the group is gone.
    public private(set) var accessLost = false
    public var pendingCount: Int { outbox.count }
    /// This device's public member key.
    public nonisolated let deviceKey: Data

    public nonisolated var id: UUID { groupID }
    nonisolated let groupID: UUID
    @ObservationIgnored private var ledger: Ledger
    @ObservationIgnored private var confirmed: [RawEvent]
    @ObservationIgnored private var outbox: [SealedEvent]
    @ObservationIgnored private let cache: GroupCache
    @ObservationIgnored let store: CredentialStore
    @ObservationIgnored let client: ServerClient
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var tail: Task<Void, Error>?
    @ObservationIgnored private var syncQueued = false

    /// `cacheRoot` defaults to Application Support; tests pass a temporary
    /// directory. `extraBoxes` are box keys this device holds only while it
    /// joins or recovers (the invite's, the recovery key's): epochs started
    /// meanwhile are sealed to them (PROTOCOL.md §5.4 steps 3 and 8).
    public init(credentials: GroupCredentials, store: CredentialStore = KeychainCredentialStore(), cacheRoot: URL? = nil,
                extraBoxes: [Curve25519.KeyAgreement.PrivateKey] = []) throws {
        self.credentials = credentials
        self.groupID = credentials.groupID
        self.store = store
        self.cache = GroupCache(groupID: credentials.groupID, root: cacheRoot)
        self.client = ServerClient(base: credentials.server)
        self.deviceKey = try credentials.signer.publicKey.rawRepresentation
        self.confirmed = cache.loadEvents()
        self.outbox = cache.loadOutbox()
        var ledger = try Ledger(groupID: credentials.groupID, secrets: credentials.secrets, boxes: [try credentials.box] + extraBoxes)
        ledger.apply(confirmed)
        self.ledger = ledger
        self.state = ledger.state
        recompute()
        try keepSecrets()
    }

    /// Every epoch secret this device has, by epoch.
    public var secrets: [Data] { ledger.secrets }

    public var me: MemberID { credentials.memberID }
    public var isAdmin: Bool { state.adminID == me && !isRemoved }
    /// This device no longer belongs to the group: removed in the ledger, or
    /// refused by the server. It can only forget the group.
    public var isRemoved: Bool { accessLost || state.removedKeys.contains(deviceKey) }

    // MARK: - Writing

    /// Seal an event as this member, show it, and sync.
    @discardableResult
    public func submit(_ data: EventData) throws -> SealedEvent {
        let event = try writer().write(data, seen: ledger.state.head)
        outbox.append(event)
        cache.saveOutbox(outbox)
        recompute()
        requestSync()
        return event
    }

    /// A writer for the current confirmed epoch.
    private func writer() throws -> EventWriter {
        guard let secret = ledger.currentSecret else { throw FlowError.noEpochSecret }
        return try EventWriter(groupID: groupID, secret: secret, epoch: ledger.state.epoch, author: me, signer: credentials.signer)
    }

    /// Store epoch secrets found in the ledger, so a restart doesn't need the
    /// box keys they were sealed to.
    private func keepSecrets() throws {
        guard ledger.secrets.count > credentials.secrets.count else { return }
        try updateCredentials { $0.secrets = ledger.secrets }
    }

    public func updateCredentials(_ change: (inout GroupCredentials) -> Void) throws {
        change(&credentials)
        try store.save(credentials)
    }

    // MARK: - Sync

    /// Push the outbox, then pull new events, in the background. Requests
    /// while one is queued coalesce.
    public func requestSync() {
        guard !syncQueued else { return }
        syncQueued = true
        Task {
            try? await serialized {
                self.syncQueued = false
                await self.syncOnce()
            }
        }
    }

    /// Sync and wait for it, throwing the first error.
    public func syncNow() async throws {
        try await serialized {
            try await self.noteAccess {
                try await self.push()
                try await self.pull()
                try await self.startEpochIfDue()
            }
        }
    }

    /// A 403 for a registered key means the server cut this device off.
    private func noteAccess(_ op: () async throws -> Void) async throws {
        do {
            try await op()
        } catch let e as ServerError where e.status == 403 && credentials.registered {
            accessLost = true
            stopLive()
            throw e
        }
    }

    /// Runs syncs one after another: two concurrent pulls would apply the same events twice.
    private func serialized(_ op: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.result
            try await op()
        }
        tail = task
        try await task.value
    }

    private func syncOnce() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await noteAccess {
                try await push()
                try await pull()
                try await startEpochIfDue()
            }
            lastError = nil
        } catch let e as ServerError where accessLost && e.status == 403 {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Append outbox events not yet sent in this run. They stay in the outbox
    /// (and on screen as pending) until a pull returns them. Each is sealed
    /// with the current epoch first; after an epoch start the rest waits for
    /// a pull, so it is sealed with the new epoch (§5.4 step 10).
    private func push() async throws {
        guard credentials.registered else { return }
        let signer = try credentials.signer
        while true {
            let unsent = outbox.filter { !pushed.contains($0.id) }
            guard !unsent.isEmpty else { return }
            let w = try writer()
            var batch: [SealedEvent] = []
            for e in unsent {
                let sealed = e.epoch == w.epoch ? e : try w.reseal(e)
                if sealed != e, let i = outbox.firstIndex(where: { $0.id == e.id }) { outbox[i] = sealed }
                batch.append(sealed)
                if batch.count == 100 || Self.startsEpoch(sealed) { break }
            }
            cache.saveOutbox(outbox)
            _ = try await client.append(signer: signer, groupID: groupID, events: batch)
            pushed.formUnion(batch.map(\.id))
            if batch.contains(where: Self.startsEpoch) { try await pull() }
        }
    }

    private static func startsEpoch(_ e: SealedEvent) -> Bool {
        if case .groupEpochStarted? = try? EventCoding.decode(e.body).1 { true } else { false }
    }

    /// Start the epoch the ledger says is due, if it's ours to start: we made
    /// it due, or we are the admin (§5.4 step 10). Once per sync.
    private func startEpochIfDue() async throws {
        let s = ledger.state
        guard s.epochDue, !isRemoved, s.epochDueBy == me || s.adminID == me, ledger.currentSecret != nil,
              !outbox.contains(where: Self.startsEpoch)
        else { return }
        let (data, _) = try Epochs.start(epoch: s.epoch + 1, readers: s.readers, groupID: groupID)
        try submit(.groupEpochStarted(data))
        try await push()
        try await pull()
    }

    @ObservationIgnored private var pushed: Set<UUID> = []

    private func pull() async throws {
        guard credentials.registered else { return }
        let signer = try credentials.signer
        while true {
            let (page, head) = try await client.read(signer: signer, groupID: groupID, after: ledger.state.lastSeq)
            let events = page.filter { $0.seq > ledger.state.lastSeq }
            if !events.isEmpty {
                confirmed.append(contentsOf: events)
                ledger.apply(events)
                cache.saveEvents(confirmed)
                try keepSecrets()
                let done = outbox.filter { ledger.state.seenIDs.contains($0.id) }
                outbox.removeAll { ledger.state.seenIDs.contains($0.id) }
                cache.saveOutbox(outbox)
                // Ours, but sealed with an epoch that had ended: write them again.
                let stale = Set(ledger.state.history.suffix(events.count).filter { $0.rejection == .staleEpoch }.map(\.eventID))
                for e in done where stale.contains(e.id) && !Self.startsEpoch(e) {
                    if let data = try? EventCoding.decode(e.body).1 { _ = try? submit(data) }
                }
                recompute()
            }
            if page.isEmpty || ledger.state.lastSeq >= head || ledger.state.inconsistency != nil { break }
        }
        recompute()
    }

    private func recompute() {
        var l = ledger
        let confirmedIDs = l.state.seenIDs
        for e in outbox where !confirmedIDs.contains(e.id) {
            l.applyPending(id: e.id, body: e.body)
        }
        state = l.state
    }

    // MARK: - Live updates

    /// Keep a stream open while the app is in the foreground; pull on every new head.
    public func startLive() {
        guard liveTask == nil, !isRemoved else { return }
        liveTask = Task { [weak self] in
            var delay: Duration = .seconds(1)
            while !Task.isCancelled {
                guard let self else { return }
                self.requestSync()
                do {
                    let signer = try self.credentials.signer
                    for try await head in self.client.heads(signer: signer, groupID: self.groupID) {
                        self.isLive = true
                        delay = .seconds(1)
                        if head > self.ledger.state.lastSeq { self.requestSync() }
                    }
                } catch {}
                self.isLive = false
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
        }
    }

    public func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        isLive = false
    }

    /// Remove all local data of this group (Keychain item and cache).
    public func forget() {
        stopLive()
        cache.deleteAll()
        store.delete(groupID)
    }
}

/// Files under Application Support/groups/<id>/. Blobs are ciphertext; the
/// key lives in the Keychain.
struct GroupCache {
    let dir: URL

    init(groupID: UUID, root: URL?) {
        let base = (root ?? URL.applicationSupportDirectory).appending(path: "groups/\(groupID.lower)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
    }

    func loadEvents() -> [RawEvent] { load("events.json") ?? [] }
    func saveEvents(_ e: [RawEvent]) { save(e, "events.json") }
    func loadOutbox() -> [SealedEvent] { load("outbox.json") ?? [] }
    func saveOutbox(_ e: [SealedEvent]) { save(e, "outbox.json") }
    func deleteAll() { try? FileManager.default.removeItem(at: dir) }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private func save<T: Encodable>(_ v: T, _ name: String) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        try? d.write(to: dir.appending(path: name), options: [.atomic])
    }
}
