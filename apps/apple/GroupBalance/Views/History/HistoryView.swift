import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The ledger itself, newest first. Events every client ignored stay visible,
/// marked with the reason, so everyone sees the same thing.
struct HistoryView: View {
    let session: GroupSession

    var body: some View {
        let items = Array(session.state.history.reversed())
        let days = Dictionary(grouping: items) { day($0) }
        let order = days.keys.sorted(by: >)
        GBPage {
            GBPageHeader(eyebrow: session.state.name, title: String(localized: "History"))
                .padding(.top, 8)
            if items.isEmpty {
                Text("Nothing has happened yet.").font(GBFont.secondary).foregroundStyle(GB.ink3).padding(.top, 20)
            }
            ForEach(order, id: \.self) { d in
                GBSectionLabel(d)
                ForEach(days[d] ?? []) { item in
                    row(item)
                }
            }
        }
        .refreshable { try? await session.syncNow() }
        .navigationDestination(for: PaymentRoute.self) { PaymentDetailView(session: session, paymentID: $0.id) }
    }

    private func day(_ item: HistoryItem) -> String {
        guard let date = Dates.timestamp(item.at) else { return String(localized: "Unknown date") }
        return date.formatted(date: .complete, time: .omitted)
    }

    @ViewBuilder private func row(_ item: HistoryItem) -> some View {
        let content = HStack(alignment: .top, spacing: 12) {
            Text(Dates.timestamp(item.at)?.formatted(date: .omitted, time: .shortened) ?? "–")
                .font(GBFont.mono(12)).foregroundStyle(GB.ink3).frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(sentence(item)).font(GBFont.body).foregroundStyle(item.rejection == nil ? GB.ink : GB.ink3)
                    .strikethrough(item.rejection != nil)
                if let r = item.rejection {
                    Text(String(localized: "Ignored: \(reason(r))")).font(GBFont.secondary).foregroundStyle(GB.red)
                }
                if item.pending {
                    GBTag(String(localized: "not synced yet"), color: GB.ink3, tilted: false)
                }
            }
            Spacer(minLength: 8)
            if let amount = amount(item) {
                GBAmount(session.money(amount)).foregroundStyle(item.rejection == nil ? GB.ink : GB.ink3)
            }
        }
        .padding(.vertical, 10)

        VStack(spacing: 0) {
            if let pid = paymentID(item), item.rejection == nil, session.state.payments[pid] != nil {
                NavigationLink(value: PaymentRoute(id: pid)) { content.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                content
            }
            GBHairline()
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
        let who = session.name(item.author)
        switch item.data {
        case .groupCreated(let d): return String(localized: "\(d.admin.name) created the group")
        case .groupUpdated(let d): return String(localized: "\(who) renamed the group to \(d.name)")
        case .memberAdded(let d): return String(localized: "\(who) added \(d.name)")
        case .memberInviteRenewed(let d): return String(localized: "\(who) renewed the invite of \(session.name(d.id))")
        case .memberClaimed(let d): return String(localized: "\(session.name(d.id)) joined")
        case .memberUpdated(let d): return String(localized: "\(who) renamed a member to \(d.name)")
        case .paymentCreated(let p): return String(localized: "\(who) added “\(p.title)”")
        case .paymentUpdated(let p): return String(localized: "\(who) edited “\(p.title)”")
        case .paymentDeleted(let d): return String(localized: "\(who) deleted “\(title(d.id))”")
        case .arrivalRecorded(let a): return String(localized: "\(who) confirmed money arrived at \(session.name(a.member)) for “\(title(a.payment))”")
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
