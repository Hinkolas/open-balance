import Foundation
import LedgerCore
import LedgerSync

extension GroupSession {
    func money(_ minor: Int, signed: Bool = false) -> String {
        Money.format(minor, currency: state.currency, signed: signed)
    }

    func name(_ id: MemberID?) -> String {
        guard let id else { return String(localized: "Someone") }
        if id == me { return String(localized: "You") }
        return state.members[id]?.name ?? String(localized: "Unknown member")
    }

    func canEdit(_ r: PaymentRecord) -> Bool { r.creator == me || isAdmin }

    /// §7.5: the receiver, the admin, or anyone for a seat nobody claimed yet.
    func canRecordArrival(for member: MemberID) -> Bool {
        member == me || isAdmin || state.members[member]?.isClaimed == false
    }
}

enum Dates {
    static func parse(_ s: String) -> Date? {
        try? Date(s, strategy: .iso8601.year().month().day())
    }

    static func string(_ d: Date) -> String {
        d.formatted(.iso8601.year().month().day())
    }

    static func display(_ s: String) -> String {
        parse(s)?.formatted(date: .abbreviated, time: .omitted) ?? s
    }

    static func timestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        return try? Date(s, strategy: .iso8601)
    }
}

/// "60" or "33,33" → basis points (hundredths of a percent).
func parseBasisPoints(_ text: String) -> Int? {
    Money.parse(text, currency: "EUR")
}
