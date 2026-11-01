import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The active group at a glance: your balance, who pays whom, money waiting
/// to be confirmed, everyone's balance, latest payments.
struct OverviewView: View {
    let session: GroupSession
    @State private var editor: PaymentDraft?
    @State private var arrivalFor: ArrivalTarget?

    var body: some View {
        let state = session.state
        let summary = state.summary
        GBPage {
            header(state)
            status
            hero(summary)
            transfers(summary)
            waiting(state)
            balances(state, summary)
            recent(state)
        }
        .refreshable { try? await session.syncNow() }
        .navigationDestination(for: PaymentRoute.self) { PaymentDetailView(session: session, paymentID: $0.id) }
        .sheet(item: Binding(get: { editor.map(EditorItem.init) }, set: { editor = $0?.draft })) { item in
            PaymentEditor(session: session, draft: item.draft)
        }
        .sheet(item: $arrivalFor) { ArrivalSheet(session: session, target: $0) }
    }

    private func header(_ state: LedgerState) -> some View {
        GBPageHeader(
            eyebrow: String(localized: "\(state.memberOrder.count) members · \(state.currency)"),
            title: state.name.isEmpty ? String(localized: "Loading…") : state.name
        )
        .padding(.top, 8)
    }

    @ViewBuilder private var status: some View {
        if let problem = session.state.inconsistency {
            VStack(alignment: .leading, spacing: 6) {
                Text("History can't be verified").font(GBFont.body.weight(.semibold)).foregroundStyle(GB.red)
                Text(problem).font(GBFont.secondary).foregroundStyle(GB.ink2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GB.redSoft, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 16)
        }
        if session.pendingCount > 0 || session.lastError != nil {
            HStack(spacing: 6) {
                Image(systemName: session.lastError == nil ? "arrow.triangle.2.circlepath" : "wifi.slash")
                Text(session.lastError == nil
                     ? String(localized: "Syncing \(session.pendingCount) change(s)…")
                     : String(localized: "Offline. \(session.pendingCount) change(s) waiting."))
            }
            .font(GBFont.secondary)
            .foregroundStyle(GB.ink3)
            .padding(.top, 12)
        }
    }

    private func hero(_ summary: Balances.Summary) -> some View {
        let mine = summary.balances[session.me] ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            GBSectionLabel(String(localized: "Your balance"), info: String(localized: "What the group owes you (+) or what you owe the group (−), counting only money that has arrived."))
            GBAmount(session.money(mine, signed: true), tone: mine > 0 ? .positive : mine < 0 ? .negative : .neutral, font: GBFont.heroAmount)
            Text(mine > 0 ? String(localized: "You get money back.") : mine < 0 ? String(localized: "You owe money.") : String(localized: "You're settled."))
                .font(GBFont.secondary).foregroundStyle(GB.ink2)
            if let expected = summary.pendingOwned[session.me], expected > 0 {
                Text("Plus \(session.money(expected)) expected once it arrives.").font(GBFont.secondary).foregroundStyle(GB.ink3)
            }
        }
    }

    @ViewBuilder private func transfers(_ summary: Balances.Summary) -> some View {
        GBSectionLabel(String(localized: "Who pays whom"), info: String(localized: "The fewest transfers that settle everyone. Debts are netted through the group: if A owes B and B owes C, A pays C."))
        if summary.transfers.isEmpty {
            HStack {
                Text("Everyone is settled.").font(GBFont.body).foregroundStyle(GB.ink2)
                Spacer()
                GBTag(String(localized: "settled"), color: GB.green)
            }
            .padding(.vertical, 8)
        }
        ForEach(summary.transfers, id: \.self) { t in
            let involved = t.from == session.me || t.to == session.me
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(session.name(t.from)).fontWeight(t.from == session.me ? .semibold : .regular)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(GB.ink3)
                    Text(session.name(t.to)).fontWeight(t.to == session.me ? .semibold : .regular)
                    Spacer()
                    GBAmount(session.money(t.amount), tone: t.from == session.me ? .negative : t.to == session.me ? .positive : .neutral)
                }
                .font(GBFont.body)
                .foregroundStyle(involved ? GB.ink : GB.ink2)
                .padding(.vertical, 12)
                if t.from == session.me {
                    HStack {
                        Spacer()
                        GBInlineButton(String(localized: "Settle up")) { editor = .settle(t, session: session) }
                    }
                    .padding(.bottom, 10)
                }
                GBHairline()
            }
        }
    }

    /// Money that should arrive at someone this device may confirm for.
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
            GBSectionLabel(String(localized: "Waiting for arrival"), info: String(localized: "Money that should arrive. It counts once it's confirmed here."))
            ForEach(items) { item in
                let (r, line, open) = (item.record, item.line, item.open)
                VStack(spacing: 0) {
                    HStack {
                        NavigationLink(value: PaymentRoute(id: r.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.payment.title).font(GBFont.body).foregroundStyle(GB.ink)
                                Text(line.member == session.me ? String(localized: "to you") : String(localized: "to \(session.name(line.member))"))
                                    .font(GBFont.secondary).foregroundStyle(GB.ink3)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        GBAmount(session.money(open))
                        GBIconButton("checkmark", tone: GB.green, label: String(localized: "Record arrival")) {
                            arrivalFor = ArrivalTarget(payment: r.id, member: line.member, remaining: open)
                        }
                    }
                    .padding(.vertical, 10)
                    GBHairline()
                }
            }
        }
    }

    @ViewBuilder private func balances(_ state: LedgerState, _ summary: Balances.Summary) -> some View {
        GBSectionLabel(String(localized: "Balances"))
        ForEach(state.orderedMembers) { m in
            let b = summary.balances[m.id] ?? 0
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    GBAvatar(m.initial, filled: m.id == session.me, size: 28)
                    Text(session.name(m.id)).font(GBFont.body).foregroundStyle(GB.ink)
                    if !m.isClaimed {
                        GBTag(String(localized: "invited"), color: GB.ink3, tilted: false)
                    }
                    Spacer()
                    GBAmount(session.money(b, signed: true), tone: b > 0 ? .positive : b < 0 ? .negative : .neutral)
                }
                .padding(.vertical, 10)
                GBHairline()
            }
        }
    }

    @ViewBuilder private func recent(_ state: LedgerState) -> some View {
        let payments = state.livePayments.sorted { ($0.payment.date, $0.createdAt) > ($1.payment.date, $1.createdAt) }.prefix(8)
        GBSectionLabel(String(localized: "Payments"))
        if payments.isEmpty {
            Text("Nothing yet. Tap + to add the first payment.").font(GBFont.secondary).foregroundStyle(GB.ink3).padding(.vertical, 8)
        }
        ForEach(Array(payments)) { r in
            NavigationLink(value: PaymentRoute(id: r.id)) {
                PaymentRow(session: session, record: r)
            }
            .buttonStyle(.plain)
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

private struct EditorItem: Identifiable {
    let draft: PaymentDraft
    let id = UUID()
}

struct PaymentRow: View {
    let session: GroupSession
    let record: PaymentRecord

    var body: some View {
        let p = record.payment
        let effect = Balances.effect(of: p, arrivals: session.state.arrivals(of: p.id))
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(GBFont.body).foregroundStyle(GB.ink).lineLimit(1)
                    Text(subtitle(p)).font(GBFont.secondary).foregroundStyle(GB.ink3).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    GBAmount(session.money(p.amount))
                    if p.track, effect.arrived < p.amount {
                        Text(effect.arrived == 0 ? String(localized: "expected") : String(localized: "\(session.money(effect.arrived)) arrived"))
                            .font(GBFont.mono(11)).foregroundStyle(GB.ink3)
                    }
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            GBHairline()
        }
    }

    private func subtitle(_ p: Payment) -> String {
        let date = Dates.display(p.date)
        switch p.displayKind {
        case .income: return String(localized: "\(date) · income at \(names(p.in))")
        case .expense: return String(localized: "\(date) · paid by \(names(p.out))")
        case .settlement: return String(localized: "\(date) · \(names(p.out)) → \(names(p.in))")
        }
    }

    private func names(_ side: Payment.Side) -> String {
        side.lines.filter { $0.amount > 0 }.map { session.name($0.member) }.formatted(.list(type: .and))
    }
}
