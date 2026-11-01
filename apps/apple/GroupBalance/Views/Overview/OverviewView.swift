import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The active group at a glance: your balance, who pays whom, money waiting
/// to be confirmed, everyone's balance line, latest payments.
struct OverviewView: View {
    let session: GroupSession
    @State private var draft: PaymentDraft?
    @State private var arrivalFor: ArrivalTarget?

    var body: some View {
        let state = session.state
        let summary = state.summary
        List {
            hero(summary)
            if let problem = state.inconsistency {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("History can't be verified").font(.headline)
                            Text(problem).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.negative)
                    }
                }
            }
            transfers(summary)
            waiting(state)
            balances(state, summary)
            recent(state)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(state.name)
        .groupSwitcher(current: session)
        .toolbar { AddPaymentMenu(session: session, draft: $draft) }
        .refreshable { try? await session.syncNow() }
        .navigationDestination(for: PaymentRoute.self) { PaymentDetailView(session: session, paymentID: $0.id) }
        .sheet(item: $draft) { PaymentFlow(session: session, draft: $0) }
        .sheet(item: $arrivalFor) { ArrivalSheet(session: session, target: $0) }
    }

    private func hero(_ summary: Balances.Summary) -> some View {
        let mine = summary.balances[session.me] ?? 0
        let expected = summary.pendingOwned[session.me] ?? 0
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your balance").font(.subheadline).foregroundStyle(.secondary)
                Amount(session.money(mine, signed: true), tone: mine > 0 ? .positive : mine < 0 ? .negative : .neutral,
                       font: .amount(.largeTitle, weight: .bold))
                Text(mine > 0 ? String(localized: "The group owes you money.") : mine < 0 ? String(localized: "You owe the group money.") : String(localized: "You're settled."))
                    .font(.subheadline)
                if expected > 0 {
                    Text("\(session.money(expected)) more once it arrives.").font(.subheadline).foregroundStyle(.secondary)
                }
                SyncStatus(session: session).padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    private func transfers(_ summary: Balances.Summary) -> some View {
        Section {
            if summary.transfers.isEmpty {
                Label("Everyone is settled.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.positive)
            }
            ForEach(summary.transfers, id: \.self) { t in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(session.name(t.from)).fontWeight(t.from == session.me ? .semibold : .regular)
                            Image(systemName: "arrow.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            Text(session.name(t.to)).fontWeight(t.to == session.me ? .semibold : .regular)
                        }
                        .lineLimit(1)
                        if t.from == session.me {
                            Button("Settle up", systemImage: "arrow.left.arrow.right") { draft = .settle(t, session: session) }
                                .buttonStyle(.borderless)
                                .font(.subheadline)
                        }
                    }
                    Spacer(minLength: 8)
                    Amount(session.money(t.amount), tone: t.from == session.me ? .negative : t.to == session.me ? .positive : .neutral)
                }
            }
        } header: {
            Text("Who pays whom")
        } footer: {
            Text("The fewest transfers that settle everyone, netted through the group.")
        }
    }

    @ViewBuilder private func waiting(_ state: LedgerState) -> some View {
        let items: [Waiting] = state.livePayments.filter(\.payment.track).flatMap { r in
            let effect = Balances.effect(of: r.payment, arrivals: state.arrivals(of: r.id))
            return r.payment.in.lines.compactMap { line -> Waiting? in
                let open = line.amount - (effect.held[line.member] ?? 0)
                guard open > 0, line.member == session.me || state.members[line.member]?.isClaimed == false else { return nil }
                return Waiting(record: r, line: line, open: open)
            }
        }
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    NavigationLink(value: PaymentRoute(id: item.record.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.record.payment.title)
                                Text(item.line.member == session.me ? String(localized: "to you") : String(localized: "to \(session.name(item.line.member))"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Amount(session.money(item.open), tone: .pending)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Arrived", systemImage: "checkmark") {
                            arrivalFor = ArrivalTarget(payment: item.record.id, member: item.line.member, remaining: item.open)
                        }
                        .tint(Theme.positive)
                    }
                    .contextMenu {
                        Button("Confirm what arrived", systemImage: "checkmark.circle") {
                            arrivalFor = ArrivalTarget(payment: item.record.id, member: item.line.member, remaining: item.open)
                        }
                    }
                }
            } header: {
                Text("Waiting for arrival")
            } footer: {
                Text("Swipe right when money arrived. It counts once it's confirmed.")
            }
        }
    }

    private func balances(_ state: LedgerState, _ summary: Balances.Summary) -> some View {
        let scale = summary.balances.values.map(abs).max() ?? 0
        return Section("Balances") {
            ForEach(state.orderedMembers) { m in
                let b = summary.balances[m.id] ?? 0
                HStack(spacing: 12) {
                    MemberAvatar(m.initial, isMe: m.id == session.me)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(session.name(m.id))
                            if !m.isClaimed { StatusBadge(String(localized: "Invited")) }
                            Spacer()
                            Amount(session.money(b, signed: true), tone: b > 0 ? .positive : b < 0 ? .negative : .pending)
                        }
                        BalanceBar(value: b, scale: scale)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func recent(_ state: LedgerState) -> some View {
        let payments = state.livePayments.sorted { ($0.payment.date, $0.createdAt) > ($1.payment.date, $1.createdAt) }
        Section("Payments") {
            if payments.isEmpty {
                Text("Nothing yet. Tap + to add the first payment.").foregroundStyle(.secondary)
            }
            ForEach(payments.prefix(10)) { r in
                NavigationLink(value: PaymentRoute(id: r.id)) { PaymentRow(session: session, record: r) }
            }
        }
    }
}

struct PaymentRoute: Hashable { let id: PaymentID }

private struct Waiting: Identifiable {
    let record: PaymentRecord
    let line: Payment.Line
    let open: Int
    var id: String { record.id + line.member }
}

/// "Syncing…" / "Offline" under the balance, only when it matters.
struct SyncStatus: View {
    let session: GroupSession

    var body: some View {
        if session.lastError != nil {
            Label(String(localized: "Offline – \(session.pendingCount) change(s) waiting"), systemImage: "icloud.slash")
                .font(.footnote).foregroundStyle(.secondary)
        } else if session.pendingCount > 0 {
            Label(String(localized: "Syncing \(session.pendingCount) change(s)…"), systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct PaymentRow: View {
    let session: GroupSession
    let record: PaymentRecord

    var body: some View {
        let p = record.payment
        let effect = Balances.effect(of: p, arrivals: session.state.arrivals(of: p.id))
        HStack(spacing: 12) {
            Image(systemName: p.displayKind.symbol)
                .font(.body)
                .foregroundStyle(Theme.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).lineLimit(1)
                Text(subtitle(p)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Amount(session.money(p.amount))
                if p.track, effect.arrived < p.amount {
                    Text(effect.arrived == 0 ? String(localized: "expected") : String(localized: "\(session.money(effect.arrived)) arrived"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ p: Payment) -> String {
        let date = Dates.display(p.date)
        switch p.displayKind {
        case .income: return String(localized: "\(date) · at \(names(p.in))")
        case .expense: return String(localized: "\(date) · paid by \(names(p.out))")
        case .settlement: return String(localized: "\(date) · \(names(p.out)) → \(names(p.in))")
        }
    }

    private func names(_ side: Payment.Side) -> String {
        side.lines.filter { $0.amount > 0 }.map { session.name($0.member) }.formatted(.list(type: .and))
    }
}

extension View {
    /// The navigation title menu: switch group, join, create.
    func groupSwitcher(current: GroupSession) -> some View {
        modifier(GroupSwitcher(current: current))
    }
}

private struct GroupSwitcher: ViewModifier {
    let current: GroupSession
    @Environment(AppModel.self) private var model
    @State private var joining = false
    @State private var creating = false

    func body(content: Content) -> some View {
        content
            .toolbarTitleMenu {
                ForEach(model.sessions) { s in
                    Button { model.activate(s.id) } label: {
                        if s.id == current.id {
                            Label(s.state.name, systemImage: "checkmark")
                        } else {
                            Text(s.state.name)
                        }
                    }
                }
                Divider()
                Button("Join with an invite", systemImage: "qrcode.viewfinder") { joining = true }
                Button("Create a group", systemImage: "plus") { creating = true }
            }
            .sheet(isPresented: $joining) { JoinSheet(link: nil) }
            .sheet(isPresented: $creating) { CreateGroupSheet() }
    }
}
