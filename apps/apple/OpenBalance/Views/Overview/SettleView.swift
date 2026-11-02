import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The Settle up tab: one plan, who pays whom once everything has arrived
/// (PROTOCOL.md §9.4), and for each transfer how much of it can be paid today
/// (§9.5). Nobody pays money they don't owe yet, and no money moves one way
/// that a pending payment would send back.
struct SettleView: View {
    let session: GroupSession
    @State private var draft: PaymentDraft?

    private enum Group { case pay, get, others }

    var body: some View {
        let state = session.state
        let summary = state.summary
        let plan = summary.expectedTransfers
        let waiting = Waiting.items(in: state)
        let stillExpected = waiting.reduce(0) { $0 + $1.open }
        let sent = settlementsOnTheWay(waiting, from: true)
        let incoming = settlementsOnTheWay(waiting, from: false)
        let youPay = rows(plan.filter { $0.from == session.me }.map(\.to), extra: sent.keys)
        let youGet = rows(plan.filter { $0.to == session.me }.map(\.from), extra: incoming.keys)
        let others = plan.filter { $0.from != session.me && $0.to != session.me }
        let waitsForMoney = summary.payNow != plan
        // The plan's closing note goes under whichever plan section comes last.
        let last: Group? = !others.isEmpty ? .others : !youGet.isEmpty ? .get : !youPay.isEmpty ? .pay : nil

        List {
            if waitsForMoney, stillExpected > 0 {
                Section { notice(stillExpected) }
            }
            if plan.isEmpty, sent.isEmpty, incoming.isEmpty {
                Section {
                    Label(summary.transfers.isEmpty
                          ? String(localized: "Everyone is settled.")
                          : String(localized: "Everyone is settled once the money on its way arrives."),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                }
            }
            if !youPay.isEmpty {
                Section {
                    ForEach(youPay, id: \.self) { to in
                        planRow(with: to, total: amount(plan, from: session.me, to: to),
                                now: summary.payableNow(from: session.me, to: to),
                                onTheWay: sent[to] ?? 0, paying: true)
                    }
                } header: {
                    Text("You pay")
                } footer: {
                    planFooter(String(localized: "Settling records a payment. It counts once the receiver confirms it arrived."), last: last == .pay)
                }
            }
            if !youGet.isEmpty {
                Section {
                    ForEach(youGet, id: \.self) { from in
                        planRow(with: from, total: amount(plan, from: from, to: session.me),
                                now: summary.payableNow(from: from, to: session.me),
                                onTheWay: incoming[from] ?? 0, paying: false)
                    }
                } header: {
                    Text("You receive")
                } footer: {
                    planFooter(String(localized: "When the money is in your account, confirm it under Still expected."), last: last == .get)
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.self) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            TransferRow(session: session, transfer: t, tone: .neutral)
                            timing(total: t.amount, now: summary.payableNow(from: t.from, to: t.to))
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(youPay.isEmpty && youGet.isEmpty ? String(localized: "Who pays whom") : String(localized: "Between others"))
                } footer: {
                    planFooter(nil, last: true)
                }
            }
            if !waiting.isEmpty {
                Section("Still expected") {
                    ForEach(waiting) { item in
                        NavigationLink(value: PaymentRoute(id: item.record.id)) {
                            WaitingRow(session: session, item: item)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settle up")
        .toolbar { AddPaymentMenu(session: session, draft: $draft) }
        .refreshable { try? await session.syncNow() }
        .navigationDestination(for: PaymentRoute.self) { PaymentDetailView(session: session, paymentID: $0.id) }
        .sheet(item: $draft) { PaymentFlow(session: session, draft: $0) }
    }

    // MARK: Rows

    /// One person you pay or get money from: the planned amount, the settle
    /// button for what you can pay now, and below it when the rest is due.
    private func planRow(with member: MemberID, total: Int, now: Int, onTheWay: Int, paying: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                MemberAvatar(session.state.members[member]?.initial ?? "?")
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name(member)).lineLimit(1)
                    Amount(session.money(total > 0 ? total : onTheWay),
                           tone: total == 0 ? .pending : paying ? .negative : .positive,
                           font: .amount(.body, weight: .semibold))
                }
                Spacer(minLength: 8)
                if paying, now > 0 {
                    Button(String(localized: "Pay \(session.money(now))")) {
                        draft = .settle(.init(from: session.me, to: member, amount: now), session: session)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .fontWeight(.semibold)
                    .fixedSize()
                    .accessibilityLabel(Text("Pay \(session.money(now)) to \(session.name(member))"))
                }
            }
            if total > 0 { timing(total: total, now: now) }
            if onTheWay > 0 {
                caption(paying
                        ? String(localized: "\(session.money(onTheWay)) sent, waiting for confirmation")
                        : String(localized: "\(session.money(onTheWay)) on the way to you"),
                        symbol: "paperplane")
            }
        }
        .padding(.vertical, 2)
    }

    /// When a planned transfer can happen: nothing when all of it can be paid
    /// today, otherwise what is due now and what waits for money on its way.
    @ViewBuilder private func timing(total: Int, now: Int) -> some View {
        if now == 0 {
            caption(String(localized: "Once the money on its way arrives"), symbol: "clock")
        } else if now < total {
            caption(String(localized: "\(session.money(now)) now, \(session.money(total - now)) once the money arrives"), symbol: "clock")
        }
    }

    private func caption(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: Sections

    private func notice(_ stillExpected: Int) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Planned with money on its way").font(.headline)
                Text("It includes the \(session.money(stillExpected)) still expected. Pay what is due now and the rest once it arrives.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "hourglass").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func planFooter(_ note: String?, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note { Text(note) }
            if last { Text("The fewest transfers that settle everyone once all money has arrived.") }
        }
    }

    // MARK: Data

    private func amount(_ plan: [Balances.Transfer], from: MemberID, to: MemberID) -> Int {
        plan.first { $0.from == from && $0.to == to }?.amount ?? 0
    }

    /// Members from the plan in plan order, then anyone with a settlement on
    /// the way who is no longer in the plan.
    private func rows(_ planned: [MemberID], extra: Dictionary<MemberID, Int>.Keys) -> [MemberID] {
        planned + session.state.memberOrder.filter { extra.contains($0) && !planned.contains($0) }
    }

    /// Settle-up payments not confirmed yet, per counterpart: yours to others
    /// (`from: true`) or others' to you. They already count in the plan, so
    /// the same debt isn't paid twice.
    private func settlementsOnTheWay(_ waiting: [Waiting], from: Bool) -> [MemberID: Int] {
        var out: [MemberID: Int] = [:]
        for item in waiting where item.record.payment.displayKind == .settlement {
            let payer = item.record.payment.out.lines.first { $0.amount > 0 }?.member
            if from, payer == session.me {
                out[item.line.member, default: 0] += item.open
            } else if !from, item.line.member == session.me, let payer {
                out[payer, default: 0] += item.open
            }
        }
        return out
    }
}
