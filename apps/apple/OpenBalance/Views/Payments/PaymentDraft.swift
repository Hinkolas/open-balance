import Foundation
import LedgerCore
import LedgerSync

/// What the payment flow edits. Income, expense and settle up are presets
/// over one payment (PROTOCOL.md §7.4): two sides with an exact amount per
/// member, resolved from amounts, percentages and a rest.
struct PaymentDraft: Equatable, Identifiable {
    let id = UUID()
    var kind: Payment.Kind = .income
    var amount = ""
    var title = ""
    var note = ""
    var date = Date.now
    /// in: who received the money (income) / who it was for (expense).
    var received = SplitForm()
    /// out: whom it belongs to (income) / who paid (expense).
    var owned = SplitForm()
    var settleFrom: MemberID?
    var settleTo: MemberID?
    /// Set when editing.
    var existing: PaymentID?
    var base: String?

    static func new(_ kind: Payment.Kind, session: GroupSession) -> PaymentDraft {
        var d = PaymentDraft(kind: kind)
        d.settleFrom = session.me
        d.settleTo = session.state.memberOrder.first { $0 != session.me }
        return d
    }

    /// Settle a suggested transfer: `from` pays `to`.
    static func settle(_ t: Balances.Transfer, session: GroupSession) -> PaymentDraft {
        var d = PaymentDraft(kind: .settlement)
        d.amount = Money.bare(t.amount, currency: session.state.currency)
        d.settleFrom = t.from
        d.settleTo = t.to
        return d
    }

    static func edit(_ r: PaymentRecord, session: GroupSession) -> PaymentDraft {
        let p = r.payment
        let currency = session.state.currency
        var d = PaymentDraft(kind: p.displayKind)
        d.amount = Money.bare(p.amount, currency: currency)
        d.title = p.title
        d.note = p.note ?? ""
        d.date = Dates.parse(p.date) ?? .now
        d.received = SplitForm(side: p.in, currency: currency)
        d.owned = SplitForm(side: p.out, currency: currency)
        d.settleFrom = p.out.lines.first?.member
        d.settleTo = p.in.lines.first?.member
        d.existing = p.id
        d.base = r.lastEventID.lower
        return d
    }

    // MARK: Resolving

    func amountMinor(_ session: GroupSession) -> Int? {
        Money.parse(amount, currency: session.state.currency).flatMap { $0 > 0 ? $0 : nil }
    }

    /// You first, then everyone else in the order they joined.
    static func members(_ session: GroupSession) -> [MemberID] {
        [session.me] + session.state.memberOrder.filter { $0 != session.me }
    }

    func receivedResolution(_ session: GroupSession) -> SplitForm.Resolution {
        let members = Self.members(session)
        let fallback: SplitForm.Fallback = kind == .expense ? .equal(members) : .all(session.me)
        return received.resolve(amount: amountMinor(session) ?? 0, members: members, currency: session.state.currency, fallback: fallback)
    }

    func ownedResolution(_ session: GroupSession) -> SplitForm.Resolution {
        let fallback: SplitForm.Fallback = kind == .expense
            ? .all(session.me)
            : receivedResolution(session).amounts.map { .copy($0) } ?? .none
        return owned.resolve(amount: amountMinor(session) ?? 0, members: Self.members(session), currency: session.state.currency, fallback: fallback)
    }

    var hasTitle: Bool { kind == .settlement || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The payment to store, or nil while something doesn't add up.
    func build(_ session: GroupSession) -> Payment? {
        guard let amount = amountMinor(session), hasTitle else { return nil }
        let currency = session.state.currency
        let order = session.state.memberOrder
        let inSide: Payment.Side
        let outSide: Payment.Side
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .settlement {
            guard let from = settleFrom, let to = settleTo, from != to else { return nil }
            inSide = .init(mode: "exact", lines: [.init(member: to, amount: amount)])
            outSide = .init(mode: "exact", lines: [.init(member: from, amount: amount)])
            if title.isEmpty { title = String(localized: "Settle up") }
        } else {
            let r = receivedResolution(session), o = ownedResolution(session)
            guard let ra = r.amounts, let oa = o.amounts else { return nil }
            inSide = .init(mode: "mixed", lines: SplitForm.lines(ra, order: order, form: received, resolution: r, currency: currency))
            outSide = .init(mode: "mixed", lines: SplitForm.lines(oa, order: order, form: owned, resolution: o, currency: currency))
        }
        guard !inSide.lines.isEmpty, !outSide.lines.isEmpty else { return nil }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return Payment(
            id: existing ?? UUID.v7().lower, kind: kind, title: String(title.prefix(200)),
            note: note.isEmpty ? nil : String(note.prefix(2000)), date: Dates.string(date), amount: amount,
            track: kind != .expense, in: inSide, out: outSide, base: existing == nil ? nil : base
        )
    }
}

extension Payment.Kind {
    var label: String {
        switch self {
        case .income: String(localized: "Income")
        case .expense: String(localized: "Expense")
        case .settlement: String(localized: "Settle up")
        }
    }

    var symbol: String {
        switch self {
        case .income: "arrow.down.circle"
        case .expense: "arrow.up.circle"
        case .settlement: "arrow.left.arrow.right"
        }
    }
}
