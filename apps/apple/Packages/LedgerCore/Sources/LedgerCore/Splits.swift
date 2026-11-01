import Foundation

/// Form helpers that turn what the user entered into line amounts. Only the
/// resulting amounts are authoritative (PROTOCOL.md §7.4), so these may differ
/// between platforms without affecting balances.
public enum Splits {
    public enum Mode: String, CaseIterable, Sendable { case equal, shares, exact, percent }

    /// Equal split among `members`.
    public static func equal(_ amount: Int, among members: [MemberID]) -> [MemberID: Int] {
        guard !members.isEmpty else { return [:] }
        return Balances.distribute(amount, weights: Dictionary(uniqueKeysWithValues: members.map { ($0, 1) }))
    }

    /// Proportional to integer weights. Nil if all weights are zero.
    public static func shares(_ amount: Int, weights: [MemberID: Int]) -> [MemberID: Int]? {
        guard weights.values.allSatisfy({ $0 >= 0 }), weights.values.reduce(0, +) > 0 else { return nil }
        return Balances.distribute(amount, weights: weights)
    }

    /// Percent in basis points. With `rest`, fixed lines get floor(amount·bp/10000)
    /// and the rest line absorbs what is left. Without, percents must sum to 100 %.
    public static func percent(_ amount: Int, basisPoints: [MemberID: Int], rest: MemberID?) -> [MemberID: Int]? {
        let total = basisPoints.values.reduce(0, +)
        guard basisPoints.values.allSatisfy({ $0 >= 0 }) else { return nil }
        if let rest {
            guard total <= 10_000 else { return nil }
            var out: [MemberID: Int] = [:]
            var assigned = 0
            for (id, bp) in basisPoints where id != rest {
                let v = amount.multipliedFullWidth(by: bp)
                let (q, _) = 10_000.dividingFullWidth(v)
                out[id] = q
                assigned += q
            }
            out[rest] = amount - assigned
            return out
        }
        guard total == 10_000 else { return nil }
        return Balances.distribute(amount, weights: basisPoints)
    }
}
