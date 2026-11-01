import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The form state. Income, expense and settle up are presets over the same
/// payment (PROTOCOL.md §7.4): two sides with an exact amount per member.
struct PaymentDraft: Equatable {
    var kind: Payment.Kind = .income
    var amount = ""
    var title = ""
    var note = ""
    var date = Date.now
    /// in: who receives the money (income) / who it was for (expense).
    var received = SplitForm()
    /// out: whom it belongs to (income) / who paid (expense).
    var owned = SplitForm()
    var settleFrom: MemberID?
    var settleTo: MemberID?
    /// Set when editing.
    var existing: PaymentID?
    var base: String?

    static func new(session: GroupSession, kind: Payment.Kind = .income) -> PaymentDraft {
        var d = PaymentDraft(kind: kind)
        d.settleFrom = session.me
        d.settleTo = session.state.memberOrder.first { $0 != session.me }
        return d
    }

    /// "Settle up" for a suggested transfer: `from` pays `to`.
    static func settle(_ t: Balances.Transfer, session: GroupSession) -> PaymentDraft {
        var d = PaymentDraft(kind: .settlement)
        d.amount = Money.bare(t.amount, currency: session.state.currency)
        d.settleFrom = t.from
        d.settleTo = t.to
        return d
    }

    static func edit(_ r: PaymentRecord, session: GroupSession) -> PaymentDraft {
        let p = r.payment
        let currency = session.state.currency
        var d = PaymentDraft(kind: p.displayKind)
        d.amount = Money.bare(p.amount, currency: currency)
        d.title = p.title
        d.note = p.note ?? ""
        d.date = Dates.parse(p.date) ?? .now
        d.received = SplitForm(side: p.in, currency: currency)
        d.owned = SplitForm(side: p.out, currency: currency)
        d.settleFrom = p.out.lines.first?.member
        d.settleTo = p.in.lines.first?.member
        d.existing = p.id
        d.base = r.lastEventID.lower
        return d
    }
}

/// Amount, what for, date, then two lists of all members: who gets the money
/// and whom it belongs to (or, for an expense, who paid and for whom). Every
/// field takes an amount or a percentage; one field can take the rest.
struct PaymentEditor: View {
    let session: GroupSession
    @State var draft: PaymentDraft
    @Environment(\.dismiss) private var dismiss
    @State private var showNote = false
    @State private var confirmDelete = false
    @State private var error: String?

    private var currency: String { session.state.currency }
    private var amountMinor: Int? { Money.parse(draft.amount, currency: currency).flatMap { $0 > 0 ? $0 : nil } }
    /// You first, then everyone else in the order they joined.
    private var members: [MemberID] { [session.me] + session.state.memberOrder.filter { $0 != session.me } }

    var body: some View {
        NavigationStack {
            GBPage {
                if draft.existing == nil {
                    HStack(spacing: 6) {
                        ForEach([Payment.Kind.income, .expense, .settlement], id: \.self) { k in
                            GBChoiceChip(kindLabel(k), selected: draft.kind == k) { draft.kind = k }
                        }
                    }
                    .padding(.top, 8)
                }
                GBAmountField(text: $draft.amount, currency: currency)
                    .padding(.top, 16)
                if draft.kind != .settlement {
                    GBTextField(draft.kind == .income ? String(localized: "What for? e.g. Project Nordlicht") : String(localized: "What for? e.g. Dinner"), text: $draft.title)
                        .padding(.top, 16)
                }
                if showNote || !draft.note.isEmpty {
                    GBTextField(String(localized: "Note, e.g. invoice 2026-031"), text: $draft.note)
                        .padding(.top, 8)
                } else {
                    Button { showNote = true } label: {
                        Label("Note", systemImage: "plus").font(GBFont.secondary).foregroundStyle(GB.ink2)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
                GBCard {
                    GBCardRow(String(localized: "Date")) {
                        DatePicker("", selection: $draft.date, displayedComponents: .date).labelsHidden()
                    }
                }
                .padding(.top, 20)

                switch draft.kind {
                case .income:
                    SplitList(session: session, members: members, title: String(localized: "Who gets the money?"),
                              info: String(localized: "Split the amount over the people it arrives at. It only counts once they confirm it arrived."),
                              form: $draft.received, resolution: receivedResolution, fallbackLabel: String(localized: "all to you"))
                    SplitList(session: session, members: members, title: String(localized: "Whom does it belong to?"),
                              info: String(localized: "Split the amount over whom it belongs to. Empty means: same as above. Whoever gets more than they own passes the difference on."),
                              form: $draft.owned, resolution: ownedResolution, fallbackLabel: String(localized: "same as above"))
                case .expense:
                    SplitList(session: session, members: members, title: String(localized: "Who paid?"), info: nil,
                              form: $draft.owned, resolution: ownedResolution, fallbackLabel: String(localized: "all by you"))
                    SplitList(session: session, members: members, title: String(localized: "For whom?"),
                              info: String(localized: "Empty means: split equally between everyone."),
                              form: $draft.received, resolution: receivedResolution, fallbackLabel: String(localized: "split equally"))
                case .settlement:
                    settleFields
                }

                result

                if draft.existing != nil, let r = session.state.payments[draft.existing!], session.canEdit(r) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash").font(GBFont.secondary).foregroundStyle(GB.red)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                }
                if let error {
                    Text(error).font(GBFont.secondary).foregroundStyle(GB.red).padding(.top, 16)
                }
            }
            .navigationTitle(draft.existing == nil ? String(localized: "New payment") : String(localized: "Edit payment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold).disabled(build() == nil)
                }
            }
            .confirmationDialog("Delete this payment?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = draft.existing { _ = try? session.submit(.paymentDeleted(.init(id: id))) }
                    dismiss()
                }
            }
        }
        .presentationBackground(GB.paper)
    }

    // MARK: Sides

    private var receivedFallback: SplitForm.Fallback {
        draft.kind == .expense ? .equal(members) : .all(session.me)
    }

    private var ownedFallback: SplitForm.Fallback {
        if draft.kind == .expense { return .all(session.me) }
        return receivedResolution.amounts.map { .copy($0) } ?? .none
    }

    private var receivedResolution: SplitForm.Resolution {
        draft.received.resolve(amount: amountMinor ?? 0, members: members, currency: currency, fallback: receivedFallback)
    }

    private var ownedResolution: SplitForm.Resolution {
        draft.owned.resolve(amount: amountMinor ?? 0, members: members, currency: currency, fallback: ownedFallback)
    }

    @ViewBuilder private var settleFields: some View {
        GBSectionLabel(String(localized: "Who pays?"))
        FlowLayout(spacing: 8) {
            ForEach(members, id: \.self) { m in
                GBChoiceChip(session.name(m), selected: draft.settleFrom == m) { draft.settleFrom = m }
            }
        }
        GBSectionLabel(String(localized: "To whom?"), info: String(localized: "Counts once the receiver confirms the money arrived."))
        FlowLayout(spacing: 8) {
            ForEach(members, id: \.self) { m in
                GBChoiceChip(session.name(m), selected: draft.settleTo == m) { draft.settleTo = m }
            }
        }
    }

    // MARK: Result

    /// What this payment does to each balance once it has fully arrived.
    @ViewBuilder private var result: some View {
        if let p = build() {
            let net = Dictionary(grouping: p.out.lines.map { ($0.member, $0.amount) } + p.in.lines.map { ($0.member, -$0.amount) }, by: \.0)
                .mapValues { $0.reduce(0) { $0 + $1.1 } }
            let mine = net[session.me] ?? 0
            let owned = p.out.amount(of: session.me)
            HStack(spacing: 8) {
                if draft.kind == .income { GBStat(String(localized: "Yours"), amount: session.money(owned)) }
                if mine < 0 { GBStat(String(localized: "You owe"), amount: session.money(-mine), tone: .negative) }
                if mine > 0 { GBStat(String(localized: "You get"), amount: session.money(mine), tone: .positive) }
            }
            .padding(.top, 24)
            let others = members.filter { $0 != session.me && (net[$0] ?? 0) != 0 }
            if !others.isEmpty {
                Text(others.map { "\(session.name($0)) \(session.money(net[$0] ?? 0, signed: true))" }.joined(separator: " · "))
                    .font(GBFont.secondary).foregroundStyle(GB.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
            if p.track {
                Text("Counts as the money arrives.").font(GBFont.secondary).foregroundStyle(GB.ink3).padding(.top, 6)
            }
        }
    }

    // MARK: Save

    private func kindLabel(_ k: Payment.Kind) -> String {
        switch k {
        case .income: String(localized: "Income")
        case .expense: String(localized: "Expense")
        case .settlement: String(localized: "Settle up")
        }
    }

    private func build() -> Payment? {
        guard let amount = amountMinor else { return nil }
        let order = session.state.memberOrder
        let inSide: Payment.Side
        let outSide: Payment.Side
        var title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.kind == .settlement {
            guard let from = draft.settleFrom, let to = draft.settleTo, from != to else { return nil }
            inSide = .init(mode: "exact", lines: [.init(member: to, amount: amount)])
            outSide = .init(mode: "exact", lines: [.init(member: from, amount: amount)])
            if title.isEmpty { title = String(localized: "Settle up") }
        } else {
            let r = receivedResolution, o = ownedResolution
            guard let ra = r.amounts, let oa = o.amounts else { return nil }
            inSide = .init(mode: "mixed", lines: SplitForm.lines(ra, order: order, form: draft.received, resolution: r, currency: currency))
            outSide = .init(mode: "mixed", lines: SplitForm.lines(oa, order: order, form: draft.owned, resolution: o, currency: currency))
        }
        guard !title.isEmpty, !inSide.lines.isEmpty, !outSide.lines.isEmpty else { return nil }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return Payment(
            id: draft.existing ?? UUID.v7().lower, kind: draft.kind, title: String(title.prefix(200)),
            note: note.isEmpty ? nil : String(note.prefix(2000)), date: Dates.string(draft.date), amount: amount,
            track: draft.kind != .expense, in: inSide, out: outSide, base: draft.existing == nil ? nil : draft.base
        )
    }

    private func save() {
        guard let p = build() else { return }
        do {
            try session.submit(draft.existing == nil ? .paymentCreated(p) : .paymentUpdated(p))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One side: every member with a field for an amount or a percentage.
struct SplitList: View {
    let session: GroupSession
    let members: [MemberID]
    let title: String
    let info: String?
    @Binding var form: SplitForm
    let resolution: SplitForm.Resolution
    let fallbackLabel: String

    private var currency: String { session.state.currency }

    var body: some View {
        VStack(spacing: 0) {
            GBSectionLabel(title, info: info)
            GBCard {
                ForEach(Array(members.enumerated()), id: \.element) { i, m in
                    if i > 0 { GBHairline() }
                    row(m)
                }
            }
            HStack {
                if let status { Text(status.text).font(GBFont.secondary).foregroundStyle(status.ok ? GB.green : GB.red) }
                Spacer()
                Menu {
                    ForEach(members, id: \.self) { m in
                        Button(session.name(m)) {
                            form.text[m] = nil
                            form.rest = m
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Rest to …")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .medium))
                    }
                    .font(GBFont.secondary)
                    .foregroundStyle(GB.ink2)
                }
            }
            .padding(.top, 10)
        }
    }

    private func row(_ m: MemberID) -> some View {
        let member = session.state.members[m]
        let field = form.field(m, currency: currency)
        let preview = resolution.preview[m]
        return HStack(spacing: 12) {
            GBAvatar(member?.initial ?? "?", filled: m == session.me, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name(m)).font(GBFont.body).foregroundStyle(GB.ink).lineLimit(1)
                if resolution.restMember == m {
                    Text("rest").font(GBFont.mono(11)).foregroundStyle(GB.ink3)
                } else if case .percent = field, let preview {
                    Text("= \(Money.bare(preview, currency: currency))").font(GBFont.mono(11)).foregroundStyle(GB.ink3)
                }
            }
            Spacer(minLength: 8)
            GBTextField(placeholder(m, preview), text: binding(m), keyboard: .numbers, mono: true)
                .frame(width: 140)
                .overlay(alignment: .trailing) {
                    if field == .invalid {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(GB.red).padding(.trailing, 10)
                    }
                }
        }
        .padding(.vertical, 6)
    }

    private func binding(_ m: MemberID) -> Binding<String> {
        Binding(
            get: { form.text[m] ?? "" },
            set: { v in
                form.text[m] = v
                if form.rest == m, !v.trimmingCharacters(in: .whitespaces).isEmpty { form.rest = nil }
            }
        )
    }

    private func placeholder(_ m: MemberID, _ preview: Int?) -> String {
        if (resolution.usedFallback || resolution.restMember == m), let preview, preview > 0 {
            return Money.bare(preview, currency: currency)
        }
        return "0"
    }

    private var status: (text: String, ok: Bool)? {
        if !resolution.invalid.isEmpty {
            return (String(localized: "Check the value for \(resolution.invalid.map { session.name($0) }.formatted(.list(type: .and))). Use an amount or a percentage like 15%."), false)
        }
        if resolution.usedFallback { return (fallbackLabel, true) }
        if resolution.amounts != nil { return (String(localized: "adds up"), true) }
        if resolution.leftover > 0 { return (String(localized: "\(Money.format(resolution.leftover, currency: currency)) left to distribute"), false) }
        if resolution.leftover < 0 { return (String(localized: "\(Money.format(-resolution.leftover, currency: currency)) too much"), false) }
        return nil
    }
}
