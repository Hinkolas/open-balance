import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The Settle up tab: who pays whom with the money that has arrived, or with
/// everything that is still expected (PROTOCOL.md §9.4), so nobody settles
/// just before a pending payment turns the plan around.
struct SettleView: View {
    let session: GroupSession
    @State private var basis: Basis = .arrived
    @State private var draft: PaymentDraft?

    enum Basis: Hashable { case arrived, expected }
    private enum Group { case pay, get, others }

    var body: some View {
        let state = session.state
        let summary = state.summary
        let expecting = basis == .expected
        let plan = expecting ? summary.expectedTransfers : summary.transfers
        let youPay = plan.filter { $0.from == session.me }
        let youGet = plan.filter { $0.to == session.me }
        let others = plan.filter { $0.from != session.me && $0.to != session.me }
        let waiting = Waiting.items(in: state)
        let stillExpected = waiting.reduce(0) { $0 + $1.open }
        let recorded = recordedSettlements(waiting)
        // The plan's closing note goes under whichever plan section comes last.
        let last: Group? = !others.isEmpty ? .others : !youGet.isEmpty ? .get : !youPay.isEmpty ? .pay : nil

        List {
            notice(expecting: expecting, differs: summary.expectedDiffers, stillExpected: stillExpected)

            if plan.isEmpty {
                Section {
                    Label(expecting ? String(localized: "Everyone will be settled.") : String(localized: "Everyone is settled."),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                }
            }
            if !youPay.isEmpty {
                Section {
                    ForEach(youPay, id: \.self) { t in
                        payRow(t, recorded: expecting ? 0 : recorded[t.to] ?? 0, expecting: expecting)
                    }
                } header: {
                    Text("You pay")
                } footer: {
                    planFooter(expecting ? nil : String(localized: "Settling records a payment. It counts once the receiver confirms it arrived."), last: last == .pay)
                }
            }
            if !youGet.isEmpty {
                Section {
                    ForEach(youGet, id: \.self) { t in
                        memberRow(t.from, amount: t.amount, tone: expecting ? .pending : .positive)
                    }
                } header: {
                    Text("You receive")
                } footer: {
                    planFooter(expecting ? nil : String(localized: "When the money is in your account, confirm it under Waiting for arrival."), last: last == .get)
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.self) { t in
                        TransferRow(session: session, transfer: t, tone: expecting ? .pending : .neutral)
                    }
                } header: {
                    Text(youPay.isEmpty && youGet.isEmpty ? String(localized: "Who pays whom") : String(localized: "Between others"))
                } footer: {
                    planFooter(nil, last: true)
                }
            }
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { item in
                        NavigationLink(value: PaymentRoute(id: item.record.id)) {
                            WaitingRow(session: session, item: item)
                        }
                    }
                } header: {
                    Text("Still expected")
                } footer: {
                    Text("Who pays whom changes as this money arrives.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settle up")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Plan", selection: $basis) {
                    Text("Arrived").tag(Basis.arrived)
                    Text("Expected").tag(Basis.expected)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            AddPaymentMenu(session: session, draft: $draft)
        }
        .refreshable { try? await session.syncNow() }
        .navigationDestination(for: PaymentRoute.self) { PaymentDetailView(session: session, paymentID: $0.id) }
        .sheet(item: $draft) { PaymentFlow(session: session, draft: $0) }
    }

    @ViewBuilder private func planFooter(_ note: String?, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note { Text(note) }
            if last { Text("The fewest transfers that settle everyone, netted through the group.") }
        }
    }

    /// Why this plan may not be the one to act on.
    @ViewBuilder private func notice(expecting: Bool, differs: Bool, stillExpected: Int) -> some View {
        if expecting {
            Section {
                noticeLabel(
                    title: String(localized: "Not owed yet"),
                    detail: stillExpected > 0
                        ? String(localized: "This plan assumes the \(session.money(stillExpected)) still expected arrives. Settle once it has.")
                        : String(localized: "Nothing is on its way, so this is the same as what is owed now."),
                    symbol: "clock")
            }
        } else if differs {
            Section {
                noticeLabel(
                    title: String(localized: "Money is still on its way"),
                    detail: String(localized: "Once the \(session.money(stillExpected)) still expected arrives, who pays whom changes. Check Expected before you settle."),
                    symbol: "hourglass")
            }
        }
    }

    private func noticeLabel(title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.tint)
        }
        .accessibilityElement(children: .combine)
    }

    /// One person you pay: who, how much, and the settle button while
    /// something is still left to pay.
    private func payRow(_ t: Balances.Transfer, recorded: Int, expecting: Bool) -> some View {
        let left = t.amount - recorded
        return HStack(spacing: 12) {
            MemberAvatar(session.state.members[t.to]?.initial ?? "?")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name(t.to)).lineLimit(1)
                Amount(session.money(t.amount), tone: expecting ? .pending : .negative, font: .amount(.body, weight: .semibold))
                if recorded > 0 {
                    Text("\(session.money(recorded)) recorded, waiting for confirmation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !expecting, left > 0 {
                Button("Settle up") {
                    draft = .settle(.init(from: t.from, to: t.to, amount: left), session: session)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .fontWeight(.semibold)
                .accessibilityLabel(Text("Settle up with \(session.name(t.to))"))
            }
        }
        .padding(.vertical, 2)
    }

    private func memberRow(_ member: MemberID, amount: Int, tone: AmountTone) -> some View {
        HStack(spacing: 12) {
            MemberAvatar(session.state.members[member]?.initial ?? "?")
            Text(session.name(member)).lineLimit(1)
            Spacer(minLength: 8)
            Amount(session.money(amount), tone: tone)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Settle-up payments from you that the receiver hasn't confirmed yet,
    /// per receiver, so the same debt isn't paid twice.
    private func recordedSettlements(_ waiting: [Waiting]) -> [MemberID: Int] {
        var out: [MemberID: Int] = [:]
        for item in waiting where item.record.payment.displayKind == .settlement
            && item.record.payment.out.lines.contains(where: { $0.member == session.me && $0.amount > 0 }) {
            out[item.line.member, default: 0] += item.open
        }
        return out
    }
}
