import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The whole form state. Income, expense and settle up are presets over the
/// same payment (PROTOCOL.md §7.4).
struct PaymentDraft: Equatable {
    var kind: Payment.Kind = .expense
    var amount = ""
    var title = ""
    var note = ""
    var date = Date.now
    var inSide = SideDraft()
    var outSide = SideDraft()
    var advanced = false
    /// Set when editing.
    var existing: PaymentID?
    var base: String?

    static func new(session: GroupSession, kind: Payment.Kind = .expense) -> PaymentDraft {
        var d = PaymentDraft(kind: kind)
        d.apply(kind: kind, session: session)
        return d
    }

    /// "Settle up" for a suggested transfer: `from` pays `to`.
    static func settle(_ t: Balances.Transfer, session: GroupSession) -> PaymentDraft {
        var d = PaymentDraft(kind: .settlement)
        d.amount = Money.inputString(t.amount, currency: session.state.currency)
        d.outSide = .single(t.from)
        d.inSide = .single(t.to)
        return d
    }

    static func edit(_ r: PaymentRecord, session: GroupSession) -> PaymentDraft {
        let p = r.payment
        var d = PaymentDraft(kind: p.displayKind)
        d.amount = Money.inputString(p.amount, currency: session.state.currency)
        d.title = p.title
        d.note = p.note ?? ""
        d.date = Dates.parse(p.date) ?? .now
        d.inSide = SideDraft(side: p.in, currency: session.state.currency)
        d.outSide = SideDraft(side: p.out, currency: session.state.currency)
        d.advanced = d.kind != .settlement && !d.simpleFits
        d.existing = p.id
        d.base = r.lastEventID.lower
        return d
    }

    /// Defaults when switching the form.
    mutating func apply(kind: Payment.Kind, session: GroupSession) {
        self.kind = kind
        let everyone = session.state.memberOrder
        let me = session.me
        switch kind {
        case .income:
            inSide = .single(me)
            outSide = SideDraft(mode: .equal, selected: everyone)
        case .expense:
            inSide = SideDraft(mode: .equal, selected: everyone)
            outSide = .single(me)
        case .settlement:
            outSide = .single(me)
            inSide = .single(everyone.first { $0 != me } ?? me)
            advanced = false
        }
    }

    /// Whether the simple form (one receiver for income, one payer for expense) shows this payment.
    var simpleFits: Bool {
        switch kind {
        case .income: inSide.selected.count == 1
        case .expense: outSide.selected.count == 1
        case .settlement: true
        }
    }

    var track: Bool { kind != .expense }
}

struct PaymentEditor: View {
    let session: GroupSession
    @State var draft: PaymentDraft
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            GBPage {
                if draft.existing == nil {
                    HStack(spacing: 6) {
                        ForEach([Payment.Kind.income, .expense, .settlement], id: \.self) { k in
                            GBChoiceChip(kindLabel(k), selected: draft.kind == k) { draft.apply(kind: k, session: session) }
                        }
                    }
                    .padding(.top, 8)
                }
                Text(explanation).font(GBFont.secondary).foregroundStyle(GB.ink2).padding(.top, 12)

                GBSectionLabel(String(localized: "Amount"))
                GBAmountField(text: $draft.amount, currency: session.state.currency)

                if draft.kind != .settlement {
                    GBSectionLabel(String(localized: "What for"))
                    GBTextField(draft.kind == .income ? String(localized: "Invoice 42, first instalment") : String(localized: "Dinner"), text: $draft.title)
                }

                sides

                GBSectionLabel(String(localized: "Date"))
                DatePicker("", selection: $draft.date, displayedComponents: .date).labelsHidden().tint(GB.ink)

                if draft.kind != .settlement {
                    Toggle(isOn: $draft.advanced.animation(.snappy(duration: 0.2))) {
                        Text("Split both sides freely").font(GBFont.body).foregroundStyle(GB.ink)
                    }
                    .tint(GB.ink)
                    .padding(.top, 24)
                }

                GBSectionLabel(String(localized: "Note"))
                GBTextField(String(localized: "Optional"), text: $draft.note)

                if let error {
                    Text(error).font(GBFont.secondary).foregroundStyle(GB.red).padding(.top, 16)
                }
                GBPrimaryButton(draft.existing == nil ? String(localized: "Add") : String(localized: "Save")) { save() }
                    .disabled(build() == nil)
                    .opacity(build() == nil ? 0.4 : 1)
                    .padding(.top, 28)
            }
            .navigationTitle(draft.existing == nil ? String(localized: "New payment") : String(localized: "Edit payment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    @ViewBuilder private var sides: some View {
        let amount = Money.parse(draft.amount, currency: session.state.currency)
        switch draft.kind {
        case .income:
            GBSectionLabel(String(localized: "Arrived at"), info: String(localized: "Who receives the money. Only what they confirm as arrived counts."))
            SideEditor(session: session, draft: $draft.inSide, amount: amount, single: !draft.advanced)
            GBSectionLabel(String(localized: "Belongs to"))
            SideEditor(session: session, draft: $draft.outSide, amount: amount)
        case .expense:
            GBSectionLabel(String(localized: "Paid by"))
            SideEditor(session: session, draft: $draft.outSide, amount: amount, single: !draft.advanced)
            GBSectionLabel(String(localized: "For"))
            SideEditor(session: session, draft: $draft.inSide, amount: amount)
        case .settlement:
            GBSectionLabel(String(localized: "From"))
            SideEditor(session: session, draft: $draft.outSide, amount: amount, single: true)
            GBSectionLabel(String(localized: "To"), info: String(localized: "Counts once the receiver confirms the money arrived."))
            SideEditor(session: session, draft: $draft.inSide, amount: amount, single: true)
        }
    }

    private var explanation: String {
        switch draft.kind {
        case .income: String(localized: "Money that came in for the group: who received it, and whom it belongs to.")
        case .expense: String(localized: "Someone paid for others.")
        case .settlement: String(localized: "Paying back what you owe.")
        }
    }

    private func kindLabel(_ k: Payment.Kind) -> String {
        switch k {
        case .income: String(localized: "Income")
        case .expense: String(localized: "Expense")
        case .settlement: String(localized: "Settle up")
        }
    }

    private func build() -> Payment? {
        let currency = session.state.currency
        let order = session.state.memberOrder
        guard let amount = Money.parse(draft.amount, currency: currency), amount > 0,
              case .success(let i) = draft.inSide.lines(amount: amount, currency: currency, order: order),
              case .success(let o) = draft.outSide.lines(amount: amount, currency: currency, order: order)
        else { return nil }
        var title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.kind == .settlement {
            guard draft.inSide.selected != draft.outSide.selected else { return nil }
            if title.isEmpty { title = String(localized: "Settle up") }
        }
        guard !title.isEmpty else { return nil }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return Payment(
            id: draft.existing ?? UUID.v7().lower, kind: draft.kind, title: String(title.prefix(200)),
            note: note.isEmpty ? nil : String(note.prefix(2000)), date: Dates.string(draft.date), amount: amount, track: draft.track,
            in: .init(mode: draft.inSide.mode.rawValue, lines: i), out: .init(mode: draft.outSide.mode.rawValue, lines: o),
            base: draft.existing == nil ? nil : draft.base
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
