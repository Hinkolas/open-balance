import Foundation

/// The per-member inputs of one payment side ("arrived at" or "belongs to")
/// and how they resolve to exact amounts. Only the resolved amounts are
/// stored as authoritative line amounts (PROTOCOL.md §7.4); the inputs come
/// back as editing hints (`value` = basis points, `rest`).
///
/// Every field takes an amount ("20.000"), a percentage ("15%") or nothing.
/// The rest member gets what is left: the explicitly chosen one, otherwise
/// the only empty field. Other empty fields are zero. With every field
/// empty, `fallback` decides.
public struct SplitForm: Equatable, Sendable {
    public var text: [MemberID: String] = [:]
    /// Chosen explicitly ("rest to …"); cleared when its field is typed into.
    public var rest: MemberID?

    public init(text: [MemberID: String] = [:], rest: MemberID? = nil) {
        self.text = text
        self.rest = rest
    }

    public enum Fallback: Equatable, Sendable {
        /// Everything to one member.
        case all(MemberID)
        /// The same amounts as another side ("as received").
        case copy([MemberID: Int])
        /// Equal split among these members.
        case equal([MemberID])
        case none
    }

    public enum Field: Equatable, Sendable {
        case empty
        case amount(Int)
        case percent(Int)
        case invalid
    }

    public struct Resolution: Equatable, Sendable {
        /// Exact amount per member, nil while the inputs don't add up.
        public var amounts: [MemberID: Int]?
        /// What each member's field resolves to, for placeholders and captions.
        public var preview: [MemberID: Int] = [:]
        public var restMember: MemberID?
        /// amount − assigned when there is no rest member: > 0 still to distribute, < 0 too much.
        public var leftover = 0
        public var usedFallback = false
        public var invalid: [MemberID] = []
    }

    public static func parse(_ raw: String, currency: String) -> Field {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .empty }
        if t.hasSuffix("%") {
            t.removeLast()
            guard let bp = Money.parse(t, currency: "EUR"), bp <= 10_000 else { return .invalid }
            return .percent(bp)
        }
        guard let v = Money.parse(t, currency: currency) else { return .invalid }
        return .amount(v)
    }

    public func field(_ m: MemberID, currency: String) -> Field { Self.parse(text[m] ?? "", currency: currency) }

    public func resolve(amount: Int, members: [MemberID], currency: String, fallback: Fallback) -> Resolution {
        var r = Resolution()
        let fields = Dictionary(uniqueKeysWithValues: members.map { ($0, field($0, currency: currency)) })
        r.invalid = members.filter { fields[$0] == .invalid }
        guard amount > 0, r.invalid.isEmpty else { return r }

        if members.allSatisfy({ fields[$0] == .empty }), rest == nil {
            let all: [MemberID: Int]? = switch fallback {
            case .all(let m): members.contains(m) ? [m: amount] : nil
            case .copy(let other): other.values.reduce(0, +) == amount ? other : nil
            case .equal(let ms): ms.isEmpty ? nil : Splits.equal(amount, among: ms.filter(members.contains))
            case .none: nil
            }
            guard let all else { return r }
            r.usedFallback = true
            r.preview = all
            r.amounts = Dictionary(uniqueKeysWithValues: members.map { ($0, all[$0] ?? 0) })
            return r
        }

        var out: [MemberID: Int] = [:]
        var percentRows: [(id: MemberID, rem: Int)] = []
        for m in members {
            switch fields[m] {
            case .amount(let v): out[m] = v
            case .percent(let bp):
                let (q, rem) = 10_000.dividingFullWidth(amount.multipliedFullWidth(by: bp))
                out[m] = q
                percentRows.append((m, rem))
            default: out[m] = 0
            }
        }
        let empties = members.filter { fields[$0] == .empty }
        let restMember = rest.flatMap { members.contains($0) && fields[$0] == .empty ? $0 : nil } ?? (empties.count == 1 ? empties[0] : nil)
        let assigned = out.values.reduce(0, +)
        r.preview = out
        if let restMember {
            r.restMember = restMember
            let left = amount - assigned
            r.preview[restMember] = max(left, 0)
            r.leftover = min(left, 0)
            guard left >= 0 else { return r }
            out[restMember] = left
            r.amounts = out
            return r
        }
        var left = amount - assigned
        // Percentages that add up to 100 % lose cents to rounding: hand those
        // out by largest remainder instead of asking for them.
        let exactSum = members.reduce(0) { if case .amount(let v) = fields[$1] { $0 + v } else { $0 } }
        let percentSum = members.reduce(0) { if case .percent(let bp) = fields[$1] { $0 + bp } else { $0 } }
        // Exactly: Σ amount·bp/10000 == amount − exact amounts.
        let exact = (amount - exactSum).multipliedFullWidth(by: 10_000) == amount.multipliedFullWidth(by: percentSum)
        if left > 0, left < percentRows.count, exact {
            for row in percentRows.sorted(by: { $0.rem != $1.rem ? $0.rem > $1.rem : $0.id < $1.id }).prefix(left) {
                out[row.id]! += 1
            }
            left = 0
            r.preview = out
        }
        r.leftover = left
        if left == 0 { r.amounts = out }
        return r
    }

    /// Lines for a payment side: members with an amount, with editing hints.
    public static func lines(_ amounts: [MemberID: Int], order: [MemberID], form: SplitForm, resolution: Resolution, currency: String) -> [Payment.Line] {
        order.compactMap { m in
            let a = amounts[m] ?? 0
            let isRest = resolution.restMember == m
            guard a > 0 else { return nil }
            if resolution.usedFallback { return Payment.Line(member: m, amount: a) }
            var line = Payment.Line(member: m, amount: a)
            if case .percent(let bp) = form.field(m, currency: currency) { line.value = bp }
            if isRest { line.rest = true }
            return line
        }
    }

    /// Rebuild the inputs from a stored side.
    public init(side: Payment.Side, currency: String) {
        for l in side.lines {
            if l.rest == true {
                rest = l.member
            } else if let bp = l.value, side.mode == "mixed" || side.mode == "percent" {
                text[l.member] = (bp % 100 == 0 ? "\(bp / 100)" : Money.bare(bp, currency: "EUR")) + "%"
            } else if l.amount > 0 {
                text[l.member] = Money.bare(l.amount, currency: currency)
            }
        }
    }
}
