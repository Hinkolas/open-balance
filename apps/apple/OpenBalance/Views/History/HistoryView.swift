import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The ledger itself, newest first. Events every client ignored stay visible,
/// marked with the reason, so everyone sees the same thing.
struct HistoryView: View {
    let session: GroupSession
    @Binding var filter: HistoryFilter
    @State private var draft: PaymentDraft?
    @State private var query = ""

    var body: some View {
        let all = session.state.history
        let shown = all.reversed().filter { filter.includes($0) && matches($0) }
        let days = Dictionary(grouping: shown) { Dates.timestamp($0.at).map { Calendar.current.startOfDay(for: $0) } ?? .distantPast }
        List {
            if all.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "clock", description: Text("Everything that happens in the group shows up here."))
            } else if shown.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView(filter.emptyTitle, systemImage: filter.symbol)
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section(dayTitle(day)) {
                    ForEach(days[day] ?? []) { row($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
        .navigationSubtitle(filter == .all ? "" : filter.label)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(HistoryFilter.allCases, id: \.self) { f in
                            Label(f.label, systemImage: f.symbol).tag(f)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: filter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                // Plain like the other toolbar buttons; tinted while filtering.
                .tint(filter == .all ? Color.primary : Theme.tint)
            }
            AddPaymentMenu(session: session, draft: $draft)
        }
        .refreshable { try? await session.syncNow() }
        .navigationDestination(for: PaymentRoute.self) { PaymentDetailView(session: session, paymentID: $0.id) }
        .sheet(item: $draft) { PaymentFlow(session: session, draft: $0) }
    }

    /// Search over what a row shows: title, detail and who did it.
    private func matches(_ item: HistoryItem) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let e = entry(item)
        return [e.title, e.detail].contains { $0.localizedStandardContains(q) }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if day == .distantPast { return String(localized: "Unknown date") }
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.weekday(.wide).day().month(.wide).year())
    }

    @ViewBuilder private func row(_ item: HistoryItem) -> some View {
        let entry = entry(item)
        let row = HistoryRow(entry: entry, time: Dates.timestamp(item.at)?.formatted(date: .omitted, time: .shortened) ?? "–",
                             rejection: item.rejection.map(reason), pending: item.pending, money: { session.money($0) })
        if let pid = entry.payment, item.rejection == nil, session.state.payments[pid] != nil {
            NavigationLink(value: PaymentRoute(id: pid)) { row }
        } else {
            row
        }
    }

    // MARK: Entries

    /// Who did it, for "… by %@" / "… from %@": "you" for yourself.
    private func by(_ item: HistoryItem) -> String {
        guard let author = item.author else { return String(localized: "someone") }
        if author == session.me { return String(localized: "you", comment: "After “by”, “from” or “at”. German: dir") }
        return session.state.members[author]?.name ?? String(localized: "someone")
    }

    private func memberName(_ id: MemberID) -> String {
        session.state.members[id]?.name ?? String(localized: "Unknown member")
    }

    private func member(_ id: MemberID) -> EventIcon.Subject {
        .initial(session.state.members[id]?.initial ?? "?")
    }

    private func payment(_ id: PaymentID) -> Payment? { session.state.payments[id]?.payment }

    /// A settle up is about who paid whom; its title is just the form's name.
    private func title(_ p: Payment) -> String {
        guard p.displayKind == .settlement else { return p.title }
        let from = p.out.lines.first { $0.amount > 0 }?.member
        let to = p.in.lines.first { $0.amount > 0 }?.member
        return "\(session.name(from)) → \(session.name(to))"
    }

    private func entry(_ item: HistoryItem) -> HistoryEntry {
        let by = by(item)
        switch item.data {
        case .groupCreated(let d):
            return .init(subject: .symbol("person.3"), title: d.name,
                         detail: String(localized: "Group created by \(item.author == session.me ? by : d.admin.name)"))
        case .groupUpdated(let d):
            return .init(subject: .symbol("person.3"), badge: "pencil", badgeColor: .gray, title: d.name,
                         detail: String(localized: "Group renamed by \(by)"))
        case .groupRecoveryChanged:
            return .init(subject: .symbol("person.3"), badge: "key.horizontal", badgeColor: .gray, title: session.state.name,
                         detail: String(localized: "Recovery kit replaced by \(by)"))
        case .memberAdded(let d):
            return .init(subject: member(d.id), title: memberName(d.id),
                         detail: String(localized: "Added by \(by)"))
        case .memberInviteRenewed(let d):
            return .init(subject: member(d.id), badge: "qrcode", badgeColor: .gray, title: memberName(d.id),
                         detail: String(localized: "New invite from \(by)"))
        case .memberClaimed(let d):
            return .init(subject: member(d.id), badge: "checkmark", badgeColor: Theme.positive, title: memberName(d.id),
                         detail: String(localized: "Joined"))
        case .memberUpdated(let d):
            return .init(subject: member(d.id), badge: "pencil", badgeColor: .gray, title: d.name,
                         detail: String(localized: "Renamed by \(by)"))
        case .memberDeviceInvited(let d):
            return .init(subject: member(d.id), badge: "qrcode", badgeColor: .gray, title: memberName(d.id),
                         detail: String(localized: "QR code for another device"))
        case .memberDeviceClaimed(let d):
            return .init(subject: member(d.id), badge: "iphone", badgeColor: Theme.positive, title: memberName(d.id),
                         detail: String(localized: "Added another device"))
        case .memberDeviceInviteRevoked(let d):
            return .init(subject: member(d.id), badge: "xmark", badgeColor: Theme.negative, title: memberName(d.id),
                         detail: String(localized: "Device QR code revoked by \(by)"))
        case .memberDeviceRemoved(let d):
            return .init(subject: member(d.id), badge: "minus", badgeColor: Theme.negative, title: memberName(d.id),
                         detail: String(localized: "Device removed by \(by)"))
        case .memberRecovered(let d):
            return .init(subject: member(d.id), badge: "key.horizontal", badgeColor: Theme.positive, title: memberName(d.id),
                         detail: String(localized: "Restored on a new device"))
        case .paymentCreated(let p):
            return .init(subject: .symbol(p.displayKind.symbol), title: title(p),
                         detail: String(localized: "\(p.displayKind.label) · by \(by)"), amount: p.amount, payment: p.id)
        case .paymentUpdated(let p):
            return .init(subject: .symbol(p.displayKind.symbol), badge: "pencil", badgeColor: .gray, title: title(p),
                         detail: String(localized: "Edited by \(by)"), amount: p.amount, payment: p.id)
        case .paymentDeleted(let d):
            let p = payment(d.id)
            return .init(subject: .symbol(p?.displayKind.symbol ?? "doc"), badge: "trash", badgeColor: Theme.negative,
                         title: p.map(title) ?? String(localized: "A payment"),
                         detail: String(localized: "Deleted by \(by)"), amount: p?.amount, tone: .pending, payment: d.id)
        case .arrivalRecorded(let a):
            let p = payment(a.payment)
            let at = a.member == session.me ? String(localized: "you", comment: "After “by”, “from” or “at”. German: dir") : memberName(a.member)
            let detail = item.author == a.member
                ? String(localized: "Arrived at \(at)")
                : String(localized: "Arrived at \(at) · confirmed by \(by)")
            return .init(subject: .symbol(p?.displayKind.symbol ?? "doc"), badge: "checkmark", badgeColor: Theme.positive,
                         title: p.map(title) ?? String(localized: "A payment"), detail: detail, amount: a.amount, tone: .positive, payment: a.payment)
        case .arrivalRemoved(let d):
            let arrival = session.state.arrivals[d.id]
            let p = arrival.flatMap { payment($0.payment) }
            return .init(subject: .symbol(p?.displayKind.symbol ?? "doc"), badge: "minus", badgeColor: Theme.negative,
                         title: p.map(title) ?? String(localized: "A payment"),
                         detail: String(localized: "Arrival removed by \(by)"), amount: arrival?.amount, tone: .pending, payment: arrival?.payment)
        case .unsupported(let t):
            return .init(subject: .symbol("questionmark"), title: String(localized: "Unknown event"), detail: t)
        case nil:
            return .init(subject: .symbol("lock"), title: String(localized: "Unreadable event"), detail: String(localized: "Encrypted with a key this device doesn't have"))
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
        case .badRecoverySig: String(localized: "recovery kit doesn't match")
        }
    }
}

/// What a history row shows; built from one ledger event.
struct HistoryEntry {
    var subject: EventIcon.Subject
    var badge: String?
    var badgeColor: Color = Theme.tint
    var title: String
    var detail: String
    var amount: Int?
    var tone: AmountTone = .neutral
    var payment: PaymentID?
}

/// One ledger event: icon, what it is about, what happened and by whom, and
/// the amount and time on the trailing side. One line each so long titles
/// truncate instead of wrapping, more at accessibility text sizes.
struct HistoryRow: View {
    let entry: HistoryEntry
    let time: String
    let rejection: String?
    let pending: Bool
    let money: (Int) -> String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ignored = rejection != nil
        let lines = typeSize.isAccessibilitySize ? 3 : 1
        HStack(spacing: 14) {
            EventIcon(entry.subject, badge: ignored ? "exclamationmark" : entry.badge,
                      badgeColor: ignored ? Theme.negative : entry.badgeColor, muted: ignored)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title)
                        .lineLimit(lines)
                        .strikethrough(ignored)
                        .foregroundStyle(ignored ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if let amount = entry.amount {
                        Amount(money(amount), tone: ignored ? .pending : entry.tone)
                            .fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(rejection.map { String(localized: "Ignored: \($0)") } ?? entry.detail)
                        .font(.subheadline)
                        .foregroundStyle(ignored ? AnyShapeStyle(Theme.negative) : AnyShapeStyle(.secondary))
                        .lineLimit(lines)
                    Spacer(minLength: 0)
                    Group {
                        if pending {
                            Label("Not synced yet", systemImage: "arrow.triangle.2.circlepath")
                                .labelStyle(.iconOnly)
                        } else {
                            Text(time)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What History shows. Overview's "Show all" opens it on `.payments`.
enum HistoryFilter: CaseIterable, Hashable {
    case all, payments, arrivals, members

    var label: String {
        switch self {
        case .all: String(localized: "Everything")
        case .payments: String(localized: "Payments")
        case .arrivals: String(localized: "Arrivals")
        case .members: String(localized: "Members & devices")
        }
    }

    var symbol: String {
        switch self {
        case .all: "list.bullet"
        case .payments: "eurosign.circle"
        case .arrivals: "checkmark.circle"
        case .members: "person.2"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: String(localized: "Nothing yet")
        case .payments: String(localized: "No payments yet")
        case .arrivals: String(localized: "No arrivals yet")
        case .members: String(localized: "No member changes yet")
        }
    }

    func includes(_ item: HistoryItem) -> Bool {
        switch (self, item.data) {
        case (.all, _): true
        case (.payments, .paymentCreated?), (.payments, .paymentUpdated?), (.payments, .paymentDeleted?): true
        case (.arrivals, .arrivalRecorded?), (.arrivals, .arrivalRemoved?): true
        case (.members, .groupCreated?), (.members, .groupUpdated?), (.members, .memberAdded?),
             (.members, .memberInviteRenewed?), (.members, .memberClaimed?), (.members, .memberUpdated?),
             (.members, .memberDeviceInvited?), (.members, .memberDeviceClaimed?), (.members, .memberDeviceInviteRevoked?),
             (.members, .groupRecoveryChanged?), (.members, .memberDeviceRemoved?), (.members, .memberRecovered?): true
        default: false
        }
    }
}
