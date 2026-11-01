import Foundation

/// Ids inside events are lowercase UUID strings (PROTOCOL.md §2). Kept as
/// strings so ordering is plain byte order and encoding never changes case.
public typealias MemberID = String
public typealias PaymentID = String
public typealias ArrivalID = String

/// The JSON body inside an event blob (§6.2), without `data`.
public struct EventHeader: Codable, Sendable, Equatable {
    public var v: Int
    public var type: String
    public var author: MemberID
    public var at: String
    public var seen: Seen

    public struct Seen: Codable, Sendable, Equatable {
        public var seq: UInt64
        public var chain: String
        public init(seq: UInt64, chain: String) {
            self.seq = seq
            self.chain = chain
        }
    }
}

/// Typed event content. One case per event type of §7.
public enum EventData: Sendable, Equatable {
    case groupCreated(GroupCreated)
    case groupUpdated(GroupUpdated)
    case memberAdded(MemberAdded)
    case memberInviteRenewed(MemberInviteRenewed)
    case memberClaimed(MemberClaimed)
    case memberUpdated(MemberUpdated)
    case memberDeviceInvited(MemberDeviceInvite)
    case memberDeviceClaimed(MemberDeviceClaimed)
    case memberDeviceInviteRevoked(MemberDeviceInvite)
    case paymentCreated(Payment)
    case paymentUpdated(Payment)
    case paymentDeleted(PaymentDeleted)
    case arrivalRecorded(ArrivalRecorded)
    case arrivalRemoved(ArrivalRemoved)
    case unsupported(String)

    public var type: String {
        switch self {
        case .groupCreated: "group.created"
        case .groupUpdated: "group.updated"
        case .memberAdded: "member.added"
        case .memberInviteRenewed: "member.invite_renewed"
        case .memberClaimed: "member.claimed"
        case .memberUpdated: "member.updated"
        case .memberDeviceInvited: "member.device_invited"
        case .memberDeviceClaimed: "member.device_claimed"
        case .memberDeviceInviteRevoked: "member.device_invite_revoked"
        case .paymentCreated: "payment.created"
        case .paymentUpdated: "payment.updated"
        case .paymentDeleted: "payment.deleted"
        case .arrivalRecorded: "arrival.recorded"
        case .arrivalRemoved: "arrival.removed"
        case .unsupported(let t): t
        }
    }
}

public struct GroupCreated: Codable, Sendable, Equatable {
    public var name: String
    public var currency: String
    public var admin: Admin
    public struct Admin: Codable, Sendable, Equatable {
        public var id: MemberID
        public var name: String
        public var key: String
        public init(id: MemberID, name: String, key: String) {
            self.id = id
            self.name = name
            self.key = key
        }
    }
    public init(name: String, currency: String, admin: Admin) {
        self.name = name
        self.currency = currency
        self.admin = admin
    }
}

public struct GroupUpdated: Codable, Sendable, Equatable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct MemberAdded: Codable, Sendable, Equatable {
    public var id: MemberID
    public var name: String
    public var inviteKey: String
    public init(id: MemberID, name: String, inviteKey: String) {
        self.id = id
        self.name = name
        self.inviteKey = inviteKey
    }
}

public struct MemberInviteRenewed: Codable, Sendable, Equatable {
    public var id: MemberID
    public var inviteKey: String
    public init(id: MemberID, inviteKey: String) {
        self.id = id
        self.inviteKey = inviteKey
    }
}

public struct MemberClaimed: Codable, Sendable, Equatable {
    public var id: MemberID
    public var key: String
    public var inviteSig: String
    public init(id: MemberID, key: String, inviteSig: String) {
        self.id = id
        self.key = key
        self.inviteSig = inviteSig
    }
}

public struct MemberUpdated: Codable, Sendable, Equatable {
    public var id: MemberID
    public var name: String
    public init(id: MemberID, name: String) {
        self.id = id
        self.name = name
    }
}

/// `member.device_invited` and `member.device_invite_revoked` (§7.3).
public struct MemberDeviceInvite: Codable, Sendable, Equatable {
    public var id: MemberID
    public var inviteKey: String
    public init(id: MemberID, inviteKey: String) {
        self.id = id
        self.inviteKey = inviteKey
    }
}

/// `member.device_claimed` (§7.3): one more key for a claimed member.
public struct MemberDeviceClaimed: Codable, Sendable, Equatable {
    public var id: MemberID
    public var key: String
    public var inviteKey: String
    public var inviteSig: String
    public init(id: MemberID, key: String, inviteKey: String, inviteSig: String) {
        self.id = id
        self.key = key
        self.inviteKey = inviteKey
        self.inviteSig = inviteSig
    }
}

/// A payment (§7.4). `in` is who received the money, `out` whom it belongs to.
public struct Payment: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case income, expense, settlement }

    public var id: PaymentID
    public var kind: String
    public var title: String
    public var note: String?
    public var date: String
    public var amount: Int
    public var track: Bool
    public var `in`: Side
    public var out: Side
    /// Only on payment.updated: the event id this edit is based on.
    public var base: String?

    public struct Side: Codable, Sendable, Equatable {
        public var mode: String
        public var lines: [Line]
        public init(mode: String, lines: [Line]) {
            self.mode = mode
            self.lines = lines
        }
        public func amount(of member: MemberID) -> Int {
            lines.first { $0.member == member }?.amount ?? 0
        }
    }

    public struct Line: Codable, Sendable, Equatable {
        public var member: MemberID
        public var amount: Int
        public var value: Int?
        public var rest: Bool?
        public init(member: MemberID, amount: Int, value: Int? = nil, rest: Bool? = nil) {
            self.member = member
            self.amount = amount
            self.value = value
            self.rest = rest
        }
    }

    public init(id: PaymentID, kind: Kind, title: String, note: String? = nil, date: String, amount: Int, track: Bool, in: Side, out: Side, base: String? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.title = title
        self.note = note
        self.date = date
        self.amount = amount
        self.track = track
        self.in = `in`
        self.out = out
        self.base = base
    }

    /// Unknown kinds display as income (§7.4).
    public var displayKind: Kind { Kind(rawValue: kind) ?? .income }
}

public struct PaymentDeleted: Codable, Sendable, Equatable {
    public var id: PaymentID
    public init(id: PaymentID) { self.id = id }
}

public struct ArrivalRecorded: Codable, Sendable, Equatable {
    public var id: ArrivalID
    public var payment: PaymentID
    public var member: MemberID
    public var amount: Int
    public init(id: ArrivalID, payment: PaymentID, member: MemberID, amount: Int) {
        self.id = id
        self.payment = payment
        self.member = member
        self.amount = amount
    }
}

public struct ArrivalRemoved: Codable, Sendable, Equatable {
    public var id: ArrivalID
    public init(id: ArrivalID) { self.id = id }
}

// MARK: - Coding

public enum EventCoding {
    public struct Malformed: Error {}

    private struct Wrapper<T: Codable>: Codable {
        var v: Int
        var type: String
        var author: MemberID
        var at: String
        var seen: EventHeader.Seen
        var data: T
    }

    private struct Unknown: Codable {}

    /// Encode a body. Key order is irrelevant: signatures cover the bytes as written.
    public static func encode(header: EventHeader, data: EventData) throws -> Data {
        func enc<T: Codable>(_ d: T) throws -> Data {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try e.encode(Wrapper(v: header.v, type: header.type, author: header.author, at: header.at, seen: header.seen, data: d))
        }
        switch data {
        case .groupCreated(let d): return try enc(d)
        case .groupUpdated(let d): return try enc(d)
        case .memberAdded(let d): return try enc(d)
        case .memberInviteRenewed(let d): return try enc(d)
        case .memberClaimed(let d): return try enc(d)
        case .memberUpdated(let d): return try enc(d)
        case .memberDeviceInvited(let d), .memberDeviceInviteRevoked(let d): return try enc(d)
        case .memberDeviceClaimed(let d): return try enc(d)
        case .paymentCreated(let d), .paymentUpdated(let d): return try enc(d)
        case .paymentDeleted(let d): return try enc(d)
        case .arrivalRecorded(let d): return try enc(d)
        case .arrivalRemoved(let d): return try enc(d)
        case .unsupported: throw Malformed()
        }
    }

    /// Decode a body into header and typed data. Unknown types decode as `.unsupported`.
    public static func decode(_ body: Data) throws(Malformed) -> (EventHeader, EventData) {
        let d = JSONDecoder()
        guard let h = try? d.decode(EventHeader.self, from: body), h.v == 1 else { throw Malformed() }
        func dec<T: Codable>(_: T.Type) throws(Malformed) -> T {
            guard let w = try? d.decode(Wrapper<T>.self, from: body) else { throw Malformed() }
            return w.data
        }
        let data: EventData = switch h.type {
        case "group.created": .groupCreated(try dec(GroupCreated.self))
        case "group.updated": .groupUpdated(try dec(GroupUpdated.self))
        case "member.added": .memberAdded(try dec(MemberAdded.self))
        case "member.invite_renewed": .memberInviteRenewed(try dec(MemberInviteRenewed.self))
        case "member.claimed": .memberClaimed(try dec(MemberClaimed.self))
        case "member.updated": .memberUpdated(try dec(MemberUpdated.self))
        case "member.device_invited": .memberDeviceInvited(try dec(MemberDeviceInvite.self))
        case "member.device_claimed": .memberDeviceClaimed(try dec(MemberDeviceClaimed.self))
        case "member.device_invite_revoked": .memberDeviceInviteRevoked(try dec(MemberDeviceInvite.self))
        case "payment.created": .paymentCreated(try dec(Payment.self))
        case "payment.updated": .paymentUpdated(try dec(Payment.self))
        case "payment.deleted": .paymentDeleted(try dec(PaymentDeleted.self))
        case "arrival.recorded": .arrivalRecorded(try dec(ArrivalRecorded.self))
        case "arrival.removed": .arrivalRemoved(try dec(ArrivalRemoved.self))
        default: .unsupported(h.type)
        }
        return (h, data)
    }
}
