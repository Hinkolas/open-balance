import CryptoKit
import Foundation

/// An event as the server returns it.
public struct RawEvent: Codable, Sendable, Equatable {
    public var seq: UInt64
    public var id: UUID
    public var blob: Data
    public var receivedAt: Date?

    public init(seq: UInt64, id: UUID, blob: Data, receivedAt: Date? = nil) {
        self.seq = seq
        self.id = id
        self.blob = blob
        self.receivedAt = receivedAt
    }
}

/// Why an event changed nothing (PROTOCOL.md §8.1). Every client reports the
/// same reason for the same event.
public enum Rejection: String, Sendable, Equatable {
    case decrypt, malformed
    case unknownAuthor = "unknown_author"
    case badSignature = "bad_signature"
    case forbidden
    case invalidData = "invalid_data"
    case unknownTarget = "unknown_target"
    case duplicateID = "duplicate_id"
    case misplaced
    case alreadyClaimed = "already_claimed"
    case badInviteSig = "bad_invite_sig"
    case badRecoverySig = "bad_recovery_sig"
}

public struct Member: Sendable, Equatable, Identifiable {
    public var id: MemberID
    public var name: String
    /// Public keys of the member's devices, in the order they joined. Empty
    /// while unclaimed. Every key writes as the member (§3.2); removed keys
    /// are gone from here.
    public var keys: [Data] = []
    /// Current invite public key while unclaimed.
    public var inviteKey: Data?
    /// Pending invites for further devices (§7.3).
    public var deviceInvites: [Data] = []
    public var isAdmin: Bool
    public var isClaimed: Bool { !keys.isEmpty }
    public var initial: String { name.first.map { String($0).uppercased() } ?? "·" }
}

public struct PaymentRecord: Sendable, Equatable, Identifiable {
    public var payment: Payment
    public var creator: MemberID
    public var createdAt: String
    public var lastEditor: MemberID?
    public var lastEventID: UUID
    public var editedConcurrently = false
    public var deleted = false
    public var id: PaymentID { payment.id }
}

public struct Arrival: Sendable, Equatable, Identifiable {
    public var id: ArrivalID
    public var payment: PaymentID
    public var member: MemberID
    public var amount: Int
    public var author: MemberID
    public var at: String
    public var removed = false
}

/// One line of the history: every event, valid or not, in ledger order.
public struct HistoryItem: Sendable, Equatable, Identifiable {
    public var seq: UInt64?
    public var eventID: UUID
    public var author: MemberID?
    public var at: String?
    public var data: EventData?
    public var rejection: Rejection?
    /// Not yet confirmed by the server (optimistic).
    public var pending = false
    public var id: UUID { eventID }
}

/// The state of a group, rebuilt by replaying its ledger.
public struct LedgerState: Sendable, Equatable {
    public let groupID: UUID
    public var name = ""
    public var currency = "EUR"
    public var adminID: MemberID?
    public var members: [MemberID: Member] = [:]
    public var memberOrder: [MemberID] = []
    public var payments: [PaymentID: PaymentRecord] = [:]
    public var paymentOrder: [PaymentID] = []
    public var arrivals: [ArrivalID: Arrival] = [:]
    /// The current public recovery key (§3.4).
    public var recoveryKey: Data?
    /// Every key any valid event introduced; none may appear again (§7.3).
    public var usedKeys: Set<Data> = []
    /// Member keys removed by `member.device_removed` or `member.recovered`.
    public var removedKeys: Set<Data> = []
    /// When each member key joined, as the writer's `at` (display only).
    public var keyAddedAt: [Data: String] = [:]
    public var history: [HistoryItem] = []
    /// chains[n] = chain_n; chains[0] is zero.
    public var chains: [Data] = [LedgerCrypto.chainZero]
    public var seenIDs: Set<UUID> = []
    /// Set when the server's history can't be trusted (§6.4) or seq 1 is not a valid group.created.
    public var inconsistency: String?

    public init(groupID: UUID) { self.groupID = groupID }

    public var lastSeq: UInt64 { UInt64(chains.count - 1) }
    public var head: EventHeader.Seen { .init(seq: lastSeq, chain: chains[chains.count - 1].base64URL) }
    public var isCreated: Bool { adminID != nil }
    public var orderedMembers: [Member] { memberOrder.compactMap { members[$0] } }
    public var livePayments: [PaymentRecord] { paymentOrder.compactMap { payments[$0] }.filter { !$0.deleted } }

    public func arrivals(of payment: PaymentID) -> [Arrival] {
        arrivals.values.filter { $0.payment == payment && !$0.removed }.sorted { $0.at < $1.at }
    }

    func keys(of member: MemberID) -> [Data] { members[member]?.keys ?? [] }
}

/// Replays events into a `LedgerState` (§8).
public struct Ledger: Sendable {
    public let groupID: UUID
    let encKey: SymmetricKey
    public private(set) var state: LedgerState

    public init(groupID: UUID, secret: Data) throws {
        self.groupID = groupID
        self.encKey = try LedgerCrypto.encKey(secret: secret, groupID: groupID)
        self.state = LedgerState(groupID: groupID)
    }

    /// Apply server events in order. Stops at the first inconsistency.
    public mutating func apply(_ events: [RawEvent]) {
        for e in events {
            guard state.inconsistency == nil else { return }
            apply(e)
        }
    }

    mutating func apply(_ e: RawEvent) {
        // §6.4: contiguous seq and chain.
        guard e.seq == state.lastSeq + 1 else {
            state.inconsistency = "Server skipped events (expected \(state.lastSeq + 1), got \(e.seq))."
            return
        }
        state.chains.append(LedgerCrypto.chainNext(state.chains[state.chains.count - 1], seq: e.seq, eventID: e.id, blob: e.blob))
        var item = HistoryItem(seq: e.seq, eventID: e.id)
        defer { state.history.append(item) }

        guard state.seenIDs.insert(e.id).inserted else {
            item.rejection = .duplicateID
            return
        }
        guard let (body, sig) = try? LedgerCrypto.open(blob: e.blob, groupID: groupID, eventID: e.id, key: encKey) else {
            item.rejection = .decrypt
            return genesisCheck(e.seq, valid: false)
        }
        guard let (header, data) = try? EventCoding.decode(body) else {
            item.rejection = .malformed
            return genesisCheck(e.seq, valid: false)
        }
        item.author = header.author
        item.at = header.at
        item.data = data

        if header.seen.seq >= e.seq {
            item.rejection = .malformed
            return genesisCheck(e.seq, valid: false)
        }
        if state.chains[Int(header.seen.seq)].base64URL != header.seen.chain {
            state.inconsistency = "History differs from what \(state.members[header.author]?.name ?? "a member") saw at event \(header.seen.seq). The server may be showing different histories to different members."
            return
        }

        let keys = authorKeys(header: header, data: data)
        guard !keys.isEmpty else {
            item.rejection = .unknownAuthor
            return genesisCheck(e.seq, valid: false)
        }
        guard keys.contains(where: { LedgerCrypto.verify(signature: sig, body: body, groupID: groupID, eventID: e.id, publicKey: $0) }) else {
            item.rejection = .badSignature
            return genesisCheck(e.seq, valid: false)
        }
        item.rejection = validateAndApply(header: header, data: data, eventID: e.id, seq: e.seq)
        genesisCheck(e.seq, valid: item.rejection == nil)
    }

    private mutating func genesisCheck(_ seq: UInt64, valid: Bool) {
        if seq == 1, !valid || !state.isCreated {
            state.inconsistency = "This group's first event is not a valid group creation."
        }
    }

    /// §8.2: the keys the signature may verify with.
    private func authorKeys(header: EventHeader, data: EventData) -> [Data] {
        switch data {
        case .groupCreated(let d): Data(base64URL: d.admin.key).map { [$0] } ?? []
        case .memberClaimed(let d): Data(base64URL: d.key).map { [$0] } ?? []
        case .memberDeviceClaimed(let d): Data(base64URL: d.key).map { [$0] } ?? []
        case .memberRecovered(let d): Data(base64URL: d.key).map { [$0] } ?? []
        default: state.keys(of: header.author)
        }
    }

    /// Apply an event written locally but not yet confirmed by the server. Runs
    /// the same validation; signatures and chain are ours.
    public mutating func applyPending(id: UUID, body: Data) {
        var item = HistoryItem(seq: nil, eventID: id, pending: true)
        defer { state.history.append(item) }
        guard let (header, data) = try? EventCoding.decode(body) else {
            item.rejection = .malformed
            return
        }
        item.author = header.author
        item.at = header.at
        item.data = data
        item.rejection = validateAndApply(header: header, data: data, eventID: id, seq: nil)
    }

    // MARK: - Validation and permissions (§7)

    private mutating func validateAndApply(header h: EventHeader, data: EventData, eventID: UUID, seq: UInt64?) -> Rejection? {
        let isAdmin = h.author == state.adminID
        switch data {
        case .groupCreated(let d):
            guard seq == 1 || (seq == nil && !state.isCreated) else { return .misplaced }
            guard h.author == d.admin.id, Self.validName(d.name), Self.validName(d.admin.name),
                  Currency.isValidCode(d.currency), let key = Data(base64URL: d.admin.key), key.count == 32,
                  let recovery = Data(base64URL: d.recoveryKey), recovery.count == 32, recovery != key
            else { return .invalidData }
            state.name = d.name
            state.currency = d.currency
            state.adminID = d.admin.id
            state.recoveryKey = recovery
            use(recovery)
            addMember(Member(id: d.admin.id, name: d.admin.name, isAdmin: true))
            addKey(key, to: d.admin.id, at: h.at)

        case .groupUpdated(let d):
            guard isAdmin else { return .forbidden }
            guard Self.validName(d.name) else { return .invalidData }
            state.name = d.name

        case .groupRecoveryChanged(let d):
            guard isAdmin else { return .forbidden }
            guard let key = Data(base64URL: d.recoveryKey), key.count == 32, !keyInUse(key) else { return .invalidData }
            state.recoveryKey = key
            use(key)

        case .memberAdded(let d):
            guard isAdmin else { return .forbidden }
            guard state.members[d.id] == nil else { return .duplicateID }
            guard Self.validName(d.name), let key = Data(base64URL: d.inviteKey), key.count == 32, !keyInUse(key) else { return .invalidData }
            addMember(Member(id: d.id, name: d.name, inviteKey: key, isAdmin: false))
            use(key)

        case .memberInviteRenewed(let d):
            guard isAdmin else { return .forbidden }
            guard let m = state.members[d.id] else { return .unknownTarget }
            guard !m.isClaimed else { return .alreadyClaimed }
            guard let key = Data(base64URL: d.inviteKey), key.count == 32, !keyInUse(key) else { return .invalidData }
            state.members[d.id]?.inviteKey = key
            use(key)

        case .memberClaimed(let d):
            guard let m = state.members[d.id] else { return .unknownTarget }
            guard h.author == d.id else { return .forbidden }
            guard !m.isClaimed else { return .alreadyClaimed }
            guard let key = Data(base64URL: d.key), key.count == 32, !keyInUse(key) else { return .invalidData }
            guard let invite = m.inviteKey, inviteSigned(d.inviteSig, by: invite, key: key) else { return .badInviteSig }
            state.members[d.id]?.inviteKey = nil
            addKey(key, to: d.id, at: h.at)

        case .memberUpdated(let d):
            guard state.members[d.id] != nil else { return .unknownTarget }
            guard isAdmin || h.author == d.id else { return .forbidden }
            guard Self.validName(d.name) else { return .invalidData }
            state.members[d.id]?.name = d.name

        case .memberDeviceInvited(let d):
            // Only the member itself; the admin adds a first device through member.added.
            guard state.members[d.id] != nil else { return .unknownTarget }
            guard h.author == d.id else { return .forbidden }
            guard let key = Data(base64URL: d.inviteKey), key.count == 32, !keyInUse(key) else { return .invalidData }
            state.members[d.id]?.deviceInvites.append(key)
            use(key)

        case .memberDeviceClaimed(let d):
            guard let m = state.members[d.id] else { return .unknownTarget }
            guard h.author == d.id else { return .forbidden }
            guard let key = Data(base64URL: d.key), key.count == 32, !keyInUse(key) else { return .invalidData }
            guard let invite = Data(base64URL: d.inviteKey), m.deviceInvites.contains(invite),
                  inviteSigned(d.inviteSig, by: invite, key: key)
            else { return .badInviteSig }
            state.members[d.id]?.deviceInvites.removeAll { $0 == invite }
            addKey(key, to: d.id, at: h.at)

        case .memberDeviceInviteRevoked(let d):
            guard let m = state.members[d.id] else { return .unknownTarget }
            guard isAdmin || h.author == d.id else { return .forbidden }
            guard let invite = Data(base64URL: d.inviteKey), m.deviceInvites.contains(invite) else { return .unknownTarget }
            state.members[d.id]?.deviceInvites.removeAll { $0 == invite }

        case .memberDeviceRemoved(let d):
            guard let m = state.members[d.id] else { return .unknownTarget }
            guard isAdmin || h.author == d.id else { return .forbidden }
            guard let key = Data(base64URL: d.key), m.keys.contains(key) else { return .unknownTarget }
            state.members[d.id]?.keys.removeAll { $0 == key }
            state.removedKeys.insert(key)
            if state.members[d.id]?.keys.isEmpty == true {
                // Unclaimed again: the admin renews its invite for a new first device.
                state.members[d.id]?.inviteKey = nil
                state.members[d.id]?.deviceInvites = []
            }

        case .memberRecovered(let d):
            guard d.id == state.adminID, h.author == d.id else { return .forbidden }
            guard let key = Data(base64URL: d.key), key.count == 32, !keyInUse(key) else { return .invalidData }
            guard let recovery = state.recoveryKey, signed(d.recoverySig, by: recovery, input: LedgerCrypto.recoverInput(groupID: groupID, key: key))
            else { return .badRecoverySig }
            state.removedKeys.formUnion(state.keys(of: d.id))
            state.members[d.id]?.keys = []
            state.members[d.id]?.deviceInvites = []
            addKey(key, to: d.id, at: h.at)

        case .paymentCreated(let p):
            guard state.payments[p.id] == nil else { return .duplicateID }
            guard validPayment(p) else { return .invalidData }
            state.payments[p.id] = PaymentRecord(payment: p, creator: h.author, createdAt: h.at, lastEventID: eventID)
            state.paymentOrder.append(p.id)

        case .paymentUpdated(let p):
            guard let r = state.payments[p.id], !r.deleted else { return .unknownTarget }
            guard isAdmin || h.author == r.creator else { return .forbidden }
            guard validPayment(p) else { return .invalidData }
            state.payments[p.id]?.editedConcurrently = p.base != r.lastEventID.lower
            state.payments[p.id]?.payment = p
            state.payments[p.id]?.lastEditor = h.author
            state.payments[p.id]?.lastEventID = eventID

        case .paymentDeleted(let d):
            guard let r = state.payments[d.id], !r.deleted else { return .unknownTarget }
            guard isAdmin || h.author == r.creator else { return .forbidden }
            state.payments[d.id]?.deleted = true

        case .arrivalRecorded(let a):
            guard state.arrivals[a.id] == nil else { return .duplicateID }
            guard let r = state.payments[a.payment], !r.deleted, r.payment.track,
                  r.payment.in.lines.contains(where: { $0.member == a.member })
            else { return .unknownTarget }
            guard let m = state.members[a.member] else { return .unknownTarget }
            guard isAdmin || h.author == a.member || !m.isClaimed else { return .forbidden }
            guard (1...Self.maxAmount).contains(a.amount) else { return .invalidData }
            state.arrivals[a.id] = Arrival(id: a.id, payment: a.payment, member: a.member, amount: a.amount, author: h.author, at: h.at)

        case .arrivalRemoved(let d):
            guard let a = state.arrivals[d.id], !a.removed else { return .unknownTarget }
            guard isAdmin || h.author == a.author else { return .forbidden }
            state.arrivals[d.id]?.removed = true

        case .unsupported:
            return nil
        }
        return nil
    }

    private mutating func addMember(_ m: Member) {
        state.members[m.id] = m
        state.memberOrder.append(m.id)
    }

    /// Keys are never reused within a group (§7.3).
    private func keyInUse(_ key: Data) -> Bool { state.usedKeys.contains(key) }

    private mutating func use(_ key: Data) { state.usedKeys.insert(key) }

    private mutating func addKey(_ key: Data, to member: MemberID, at: String) {
        state.members[member]?.keys.append(key)
        state.keyAddedAt[key] = at
        use(key)
    }

    /// `inviteSig` (§7.3): the invite key vouches for `key` in this group.
    private func inviteSigned(_ sig: String, by invite: Data, key: Data) -> Bool {
        signed(sig, by: invite, input: LedgerCrypto.claimInput(groupID: groupID, key: key))
    }

    private func signed(_ sig: String, by publicKey: Data, input: Data) -> Bool {
        guard let sig = Data(base64URL: sig), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(sig, for: input)
    }

    public static let maxAmount = 1_000_000_000_000_000

    static func validName(_ s: String) -> Bool { (1...100).contains(s.unicodeScalars.count) }

    func validPayment(_ p: Payment) -> Bool {
        guard (1...200).contains(p.title.unicodeScalars.count), (p.note?.unicodeScalars.count ?? 0) <= 2000,
              (1...Self.maxAmount).contains(p.amount), Self.validDate(p.date)
        else { return false }
        for side in [p.in, p.out] {
            guard !side.lines.isEmpty, Set(side.lines.map(\.member)).count == side.lines.count,
                  side.lines.allSatisfy({ $0.amount >= 0 && state.members[$0.member] != nil }),
                  side.lines.reduce(0, { $0 + $1.amount }) == p.amount
            else { return false }
        }
        return true
    }

    static func validDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let m = Int(parts[1]), let d = Int(parts[2]), Int(parts[0]) != nil
        else { return false }
        return (1...12).contains(m) && (1...31).contains(d)
    }
}

public enum Currency {
    public static func isValidCode(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    /// ISO 4217 minor-unit exponent (EUR 2, JPY 0).
    public static func exponent(_ code: String) -> Int {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        return f.maximumFractionDigits
    }
}
