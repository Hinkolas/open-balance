import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The ledger itself, newest first. Events every client ignored stay visible,
/// marked with the reason, so everyone sees the same thing.
struct HistoryView: View {
    let session: GroupSession
    @State private var draft: PaymentDraft?

    var body: some View {
        let items = Array(session.state.history.reversed())
        let days = Dictionary(grouping: items) { Dates.timestamp($0.at).map { Calendar.current.startOfDay(for: $0) } ?? .distantPast }
        List {
            if items.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "clock", description: Text("Everything that happens in the group shows up here."))
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section(day == .distantPast ? String(localized: "Unknown date") : day.formatted(date: .complete, time: .omitted)) {
                    ForEach(days[day] ?? []) { row($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
        .toolbar { AddPaymentMenu(session: session, draft: $draft) }
        .refreshable { try? await session.syncNow() }
        .navigationDestination(for: PaymentRoute.self) { PaymentDetailView(session: session, paymentID: $0.id) }
        .sheet(item: $draft) { PaymentFlow(session: session, draft: $0) }
    }

    @ViewBuilder private func row(_ item: HistoryItem) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sentence(item))
                    .foregroundStyle(item.rejection == nil ? .primary : .secondary)
                    .strikethrough(item.rejection != nil)
                HStack(spacing: 6) {
                    Text(Dates.timestamp(item.at)?.formatted(date: .omitted, time: .shortened) ?? "–")
                    if let r = item.rejection {
                        Text("Ignored: \(reason(r))").foregroundStyle(Theme.negative)
                    }
                    if item.pending { StatusBadge(String(localized: "Not synced yet")) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let amount = amount(item) {
                Amount(session.money(amount), tone: item.rejection == nil ? .neutral : .pending)
            }
        }
        if let pid = paymentID(item), item.rejection == nil, session.state.payments[pid] != nil {
            NavigationLink(value: PaymentRoute(id: pid)) { content }
        } else {
            content
        }
    }

    private func paymentID(_ item: HistoryItem) -> PaymentID? {
        switch item.data {
        case .paymentCreated(let p), .paymentUpdated(let p): p.id
        case .paymentDeleted(let d): d.id
        case .arrivalRecorded(let a): a.payment
        default: nil
        }
    }

    private func amount(_ item: HistoryItem) -> Int? {
        switch item.data {
        case .paymentCreated(let p), .paymentUpdated(let p): p.amount
        case .arrivalRecorded(let a): a.amount
        default: nil
        }
    }

    private func title(_ id: PaymentID) -> String {
        session.state.payments[id]?.payment.title ?? String(localized: "a payment")
    }

    private func sentence(_ item: HistoryItem) -> String {
        // Real names, not "You": the sentences conjugate for a third person.
        let who = item.author.flatMap { session.state.members[$0]?.name } ?? String(localized: "Someone")
        switch item.data {
        case .groupCreated(let d): return String(localized: "\(d.admin.name) created the group")
        case .groupUpdated(let d): return String(localized: "\(who) renamed the group to \(d.name)")
        case .memberAdded(let d): return String(localized: "\(who) added \(d.name)")
        case .memberInviteRenewed(let d): return String(localized: "\(who) renewed the invite of \(session.state.members[d.id]?.name ?? "")")
        case .memberClaimed(let d): return String(localized: "\(session.state.members[d.id]?.name ?? "") joined")
        case .memberUpdated(let d): return String(localized: "\(who) renamed a member to \(d.name)")
        case .paymentCreated(let p): return String(localized: "\(who) added “\(p.title)”")
        case .paymentUpdated(let p): return String(localized: "\(who) edited “\(p.title)”")
        case .paymentDeleted(let d): return String(localized: "\(who) deleted “\(title(d.id))”")
        case .arrivalRecorded(let a): return String(localized: "\(who) confirmed money arrived at \(session.state.members[a.member]?.name ?? "") for “\(title(a.payment))”")
        case .arrivalRemoved: return String(localized: "\(who) removed a confirmed arrival")
        case .unsupported(let t): return String(localized: "\(who) wrote an event this app doesn't know (\(t))")
        case nil: return String(localized: "Unreadable event")
        }
    }

    private func reason(_ r: Rejection) -> String {
        switch r {
        case .decrypt: String(localized: "can't be decrypted")
        case .malformed: String(localized: "malformed")
        case .unknownAuthor: String(localized: "unknown author")
        case .badSignature: String(localized: "signature doesn't match the author")
        case .forbidden: String(localized: "not allowed for this member")
        case .invalidData: String(localized: "invalid content")
        case .unknownTarget: String(localized: "refers to something that doesn't exist")
        case .duplicateID: String(localized: "duplicate")
        case .misplaced: String(localized: "out of place")
        case .alreadyClaimed: String(localized: "member already joined")
        case .badInviteSig: String(localized: "invite doesn't match")
        }
    }
}
