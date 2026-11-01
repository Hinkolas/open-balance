import Foundation

/// Balance math (PROTOCOL.md §9). Exact integers, 128-bit intermediates.
public enum Balances {
    /// Largest remainder (§9.1): split `total` over integer weights.
    /// Ties go to the smaller member id.
    public static func distribute(_ total: Int, weights: [MemberID: Int]) -> [MemberID: Int] {
        let w = weights.values.reduce(0, +)
        precondition(total >= 0 && w > 0, "distribute needs total >= 0 and positive weight sum")
        var result: [MemberID: Int] = [:]
        var rows: [(id: MemberID, rem: Int)] = []
        var assigned = 0
        for (id, weight) in weights {
            let (q, r) = w.dividingFullWidth(total.multipliedFullWidth(by: weight))
            result[id] = q
            assigned += q
            rows.append((id, r))
        }
        rows.sort { $0.rem != $1.rem ? $0.rem > $1.rem : $0.id < $1.id }
        for row in rows.prefix(total - assigned) { result[row.id]! += 1 }
        return result
    }

    /// What one payment contributes (§9.2).
    public struct PaymentEffect: Sendable, Equatable {
        /// What has arrived at each receiver (in side).
        public var held: [MemberID: Int] = [:]
        /// What counts as owned so far (out side).
        public var owned: [MemberID: Int] = [:]
        public var arrived: Int { held.values.reduce(0, +) }
    }

    public static func effect(of p: Payment, arrivals: [Arrival]) -> PaymentEffect {
        var e = PaymentEffect()
        for line in p.in.lines {
            if p.track {
                let recorded = arrivals.filter { $0.member == line.member }.reduce(0) { $0 + $1.amount }
                e.held[line.member] = min(line.amount, recorded)
            } else {
                e.held[line.member] = line.amount
            }
        }
        let weights = Dictionary(uniqueKeysWithValues: p.out.lines.map { ($0.member, $0.amount) })
        e.owned = distribute(e.arrived, weights: weights)
        return e
    }

    public struct Summary: Sendable, Equatable {
        /// > 0: the group owes this member. < 0: the member owes the group.
        public var balances: [MemberID: Int] = [:]
        /// Money a member is still expecting to own once it arrives.
        public var pendingOwned: [MemberID: Int] = [:]
        /// Money still expected to arrive at a member.
        public var pendingHeld: [MemberID: Int] = [:]
        public var transfers: [Transfer] = []
    }

    public struct Transfer: Sendable, Equatable, Hashable {
        public var from: MemberID
        public var to: MemberID
        public var amount: Int
        public init(from: MemberID, to: MemberID, amount: Int) {
            self.from = from
            self.to = to
            self.amount = amount
        }
    }

    /// Payments must already be valid; `arrivals` are the live arrivals per payment.
    public static func summarize(members: [MemberID], payments: [Payment], arrivals: [PaymentID: [Arrival]]) -> Summary {
        var s = Summary()
        for m in members {
            s.balances[m] = 0
            s.pendingOwned[m] = 0
            s.pendingHeld[m] = 0
        }
        for p in payments {
            let e = effect(of: p, arrivals: arrivals[p.id] ?? [])
            for line in p.out.lines {
                let owned = e.owned[line.member] ?? 0
                s.balances[line.member, default: 0] += owned
                s.pendingOwned[line.member, default: 0] += line.amount - owned
            }
            for line in p.in.lines {
                let held = e.held[line.member] ?? 0
                s.balances[line.member, default: 0] -= held
                s.pendingHeld[line.member, default: 0] += line.amount - held
            }
        }
        s.transfers = transfers(s.balances)
        return s
    }

    /// Who pays whom (§9.3): largest debtor pays largest creditor, ties by id.
    public static func transfers(_ balances: [MemberID: Int]) -> [Transfer] {
        var debtors = balances.filter { $0.value < 0 }.map { (id: $0.key, amount: -$0.value) }
        var creditors = balances.filter { $0.value > 0 }.map { (id: $0.key, amount: $0.value) }
        let order: ((id: MemberID, amount: Int), (id: MemberID, amount: Int)) -> Bool = {
            $0.amount != $1.amount ? $0.amount > $1.amount : $0.id < $1.id
        }
        var out: [Transfer] = []
        while !debtors.isEmpty, !creditors.isEmpty {
            debtors.sort(by: order)
            creditors.sort(by: order)
            let amount = min(debtors[0].amount, creditors[0].amount)
            out.append(Transfer(from: debtors[0].id, to: creditors[0].id, amount: amount))
            debtors[0].amount -= amount
            creditors[0].amount -= amount
            debtors.removeAll { $0.amount == 0 }
            creditors.removeAll { $0.amount == 0 }
        }
        return out
    }
}

public extension LedgerState {
    var summary: Balances.Summary {
        let live = livePayments
        var byPayment: [PaymentID: [Arrival]] = [:]
        for a in arrivals.values where !a.removed { byPayment[a.payment, default: []].append(a) }
        return Balances.summarize(members: memberOrder, payments: live.map(\.payment), arrivals: byPayment)
    }
}
