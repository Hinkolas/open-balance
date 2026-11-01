import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// What the user entered for one side of a payment (in: who received it,
/// out: whom it belongs to), before it becomes line amounts.
struct SideDraft: Equatable {
    var mode: Splits.Mode = .equal
    var selected: [MemberID] = []
    /// Text per member: weight (shares), percent (percent), amount (exact).
    var values: [MemberID: String] = [:]

    static func single(_ m: MemberID) -> SideDraft { SideDraft(mode: .equal, selected: [m]) }

    /// Rebuild the form from a stored side.
    init(mode: Splits.Mode = .equal, selected: [MemberID] = [], values: [MemberID: String] = [:]) {
        self.mode = mode
        self.selected = selected
        self.values = values
    }

    init(side: Payment.Side, currency: String) {
        mode = Splits.Mode(rawValue: side.mode) ?? .exact
        selected = side.lines.map(\.member)
        for l in side.lines {
            switch mode {
            case .equal: break
            case .shares: values[l.member] = String(l.value ?? 1)
            case .percent: values[l.member] = l.rest == true && l.value == nil ? "" : Money.inputString(l.value ?? 0, currency: "EUR")
            case .exact: values[l.member] = Money.inputString(l.amount, currency: currency)
            }
        }
    }

    enum Issue: Error, Equatable {
        case noMembers
        case badValue(MemberID)
        case percentSum(Int)
        case twoRests
        case exactSum(Int)
    }

    /// Lines in member order, or what is wrong.
    func lines(amount: Int, currency: String, order: [MemberID]) -> Result<[Payment.Line], Issue> {
        let members = order.filter(selected.contains)
        guard !members.isEmpty else { return .failure(.noMembers) }
        switch mode {
        case .equal:
            let split = Splits.equal(amount, among: members)
            return .success(members.map { .init(member: $0, amount: split[$0] ?? 0) })
        case .shares:
            var weights: [MemberID: Int] = [:]
            for m in members {
                let t = values[m, default: ""].trimmingCharacters(in: .whitespaces)
                guard let w = t.isEmpty ? 1 : Int(t), w >= 0 else { return .failure(.badValue(m)) }
                weights[m] = w
            }
            guard let split = Splits.shares(amount, weights: weights) else { return .failure(.badValue(members[0])) }
            return .success(members.map { .init(member: $0, amount: split[$0] ?? 0, value: weights[$0]) })
        case .percent:
            var bp: [MemberID: Int] = [:]
            var rest: MemberID?
            for m in members {
                let t = values[m, default: ""].trimmingCharacters(in: .whitespaces)
                if t.isEmpty {
                    guard rest == nil else { return .failure(.twoRests) }
                    rest = m
                } else {
                    guard let v = parseBasisPoints(t), v <= 10_000 else { return .failure(.badValue(m)) }
                    bp[m] = v
                }
            }
            let total = bp.values.reduce(0, +)
            if rest != nil ? total > 10_000 : total != 10_000 { return .failure(.percentSum(total)) }
            var all = bp
            if let rest { all[rest] = 0 }
            guard let split = Splits.percent(amount, basisPoints: all, rest: rest) else { return .failure(.percentSum(total)) }
            return .success(members.map { .init(member: $0, amount: split[$0] ?? 0, value: bp[$0], rest: $0 == rest ? true : nil) })
        case .exact:
            var sum = 0
            var lines: [Payment.Line] = []
            for m in members {
                let t = values[m, default: ""]
                guard let v = t.isEmpty ? 0 : Money.parse(t, currency: currency) else { return .failure(.badValue(m)) }
                sum += v
                lines.append(.init(member: m, amount: v))
            }
            guard sum == amount else { return .failure(.exactSum(sum)) }
            return .success(lines)
        }
    }
}

/// Edits one side: pick members, pick how to split, enter values.
struct SideEditor: View {
    let session: GroupSession
    @Binding var draft: SideDraft
    let amount: Int?
    /// Only one member, no split modes.
    var single = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 8) {
                ForEach(session.state.orderedMembers) { m in
                    GBChoiceChip(session.name(m.id), selected: draft.selected.contains(m.id)) { toggle(m.id) }
                }
            }
            if !single, draft.selected.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Splits.Mode.allCases, id: \.self) { mode in
                        GBChoiceChip(label(mode), selected: draft.mode == mode) { draft.mode = mode }
                    }
                }
                if draft.mode != .equal {
                    VStack(spacing: 0) {
                        ForEach(session.state.memberOrder.filter(draft.selected.contains), id: \.self) { m in
                            valueRow(m)
                        }
                    }
                    if draft.mode == .percent {
                        Text("Leave one member empty to give them the rest.").font(GBFont.secondary).foregroundStyle(GB.ink3)
                    }
                }
                if let amount, let issue = issue(amount) {
                    Text(issue).font(GBFont.secondary).foregroundStyle(GB.red)
                } else if let amount, draft.mode != .exact, case .success(let lines) = draft.lines(amount: amount, currency: session.state.currency, order: session.state.memberOrder) {
                    Text(lines.map { "\(session.name($0.member)) \(session.money($0.amount))" }.joined(separator: " · "))
                        .font(GBFont.mono(12)).foregroundStyle(GB.ink3)
                }
            }
        }
    }

    private func toggle(_ m: MemberID) {
        if single {
            draft.selected = [m]
        } else if let i = draft.selected.firstIndex(of: m) {
            draft.selected.remove(at: i)
        } else {
            draft.selected.append(m)
        }
    }

    private func valueRow(_ m: MemberID) -> some View {
        HStack {
            Text(session.name(m)).font(GBFont.body).foregroundStyle(GB.ink)
            Spacer()
            TextField(placeholder, text: Binding(get: { draft.values[m, default: ""] }, set: { draft.values[m] = $0 }))
                .font(GBFont.mono(15))
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                #if os(iOS)
                .keyboardType(draft.mode == .shares ? .numberPad : .decimalPad)
                #endif
            Text(unit).font(GBFont.mono(13)).foregroundStyle(GB.ink3).frame(width: 34, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { GBHairline() }
    }

    private var placeholder: String {
        switch draft.mode {
        case .shares: "1"
        case .percent: String(localized: "rest")
        default: "0"
        }
    }

    private var unit: String {
        switch draft.mode {
        case .shares: "×"
        case .percent: "%"
        default: session.state.currency
        }
    }

    private func label(_ m: Splits.Mode) -> String {
        switch m {
        case .equal: String(localized: "Equal")
        case .shares: String(localized: "Shares")
        case .percent: String(localized: "Percent")
        case .exact: String(localized: "Exact")
        }
    }

    private func issue(_ amount: Int) -> String? {
        guard case .failure(let i) = draft.lines(amount: amount, currency: session.state.currency, order: session.state.memberOrder) else { return nil }
        switch i {
        case .noMembers: return String(localized: "Pick at least one member.")
        case .badValue(let m): return String(localized: "Check the value for \(session.name(m)).")
        case .twoRests: return String(localized: "Only one member can take the rest.")
        case .percentSum(let bp): return String(localized: "Percentages add up to \(Money.inputString(bp, currency: "EUR")) %.")
        case .exactSum(let s): return String(localized: "Amounts add up to \(session.money(s)), not \(session.money(amount)).")
        }
    }
}
