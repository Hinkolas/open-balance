import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The + toolbar button: a native menu with the three kinds.
struct AddPaymentMenu: ToolbarContent {
    let session: GroupSession
    @Binding var draft: PaymentDraft?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach([Payment.Kind.income, .expense, .settlement], id: \.self) { kind in
                    Button(kind.label, systemImage: kind.symbol) { draft = .new(kind, session: session) }
                }
            } label: {
                Label("Add payment", systemImage: "plus")
            }
            .tint(.primary)
        }
    }
}

/// New or edited payment, one question per step:
/// amount & name → who gets the money → whom it belongs to (income),
/// amount & name → who paid → for whom (expense),
/// amount → who pays whom (settle up).
struct PaymentFlow: View {
    let session: GroupSession
    @State var draft: PaymentDraft
    @State private var path: [Step] = []
    @Environment(\.dismiss) private var dismiss

    enum Step: Hashable { case first, second }

    var body: some View {
        NavigationStack(path: $path) {
            AmountStep(session: session, draft: $draft, next: { path.append(.first) }, cancel: { dismiss() })
                .navigationDestination(for: Step.self) { step in
                    switch (draft.kind, step) {
                    case (.settlement, _):
                        PartiesStep(session: session, draft: $draft, save: save)
                    case (.income, .first):
                        SideStep(session: session, draft: $draft, side: .received, isLast: false, next: { path.append(.second) }, save: save)
                    case (.income, .second):
                        SideStep(session: session, draft: $draft, side: .owned, isLast: true, next: {}, save: save)
                    case (.expense, .first):
                        SideStep(session: session, draft: $draft, side: .owned, isLast: false, next: { path.append(.second) }, save: save)
                    case (.expense, .second):
                        SideStep(session: session, draft: $draft, side: .received, isLast: true, next: {}, save: save)
                    }
                }
        }
        .tint(Theme.tint)
    }

    private func save() {
        guard let p = draft.build(session) else { return }
        _ = try? session.submit(draft.existing == nil ? .paymentCreated(p) : .paymentUpdated(p))
        dismiss()
    }
}

// MARK: - Step 1: amount and name

private struct AmountStep: View {
    let session: GroupSession
    @Binding var draft: PaymentDraft
    let next: () -> Void
    let cancel: () -> Void
    @FocusState private var amountFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 52

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TextField("0", text: $draft.amount)
                            .font(.system(size: amountSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                            .keyboardType(.decimalPad)
                            .focused($amountFocused)
                            .fixedSize()
                        Text(session.state.currencySymbol)
                            .font(.system(size: amountSize * 0.55, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text(prompt).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture { amountFocused = true }
            }
            .listRowBackground(Color.clear)

            Section {
                if draft.kind != .settlement {
                    TextField(draft.kind == .income ? String(localized: "What for? e.g. Project Nordlicht") : String(localized: "What for? e.g. Dinner"), text: $draft.title)
                }
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                TextField("Note", text: $draft.note, axis: .vertical)
                    .lineLimit(1...4)
            }
        }
        .navigationTitle(draft.existing == nil ? draft.kind.label : String(localized: "Edit payment"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Next", action: next).disabled(draft.amountMinor(session) == nil || !draft.hasTitle)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFocused = false; dismissKeyboard() }
            }
        }
        .onChange(of: amountFocused) { _, focused in
            if !focused, let v = draft.amountMinor(session) { draft.amount = Money.bare(v, currency: session.state.currency) }
        }
        .onAppear { if draft.amount.isEmpty { amountFocused = true } }
    }

    private var prompt: String {
        switch draft.kind {
        case .income: String(localized: "How much came in?")
        case .expense: String(localized: "How much was paid?")
        case .settlement: String(localized: "How much is paid back?")
        }
    }
}

// MARK: - Steps 2 and 3: one side

enum PaymentSide { case received, owned }

private struct SideStep: View {
    let session: GroupSession
    @Binding var draft: PaymentDraft
    let side: PaymentSide
    let isLast: Bool
    let next: () -> Void
    let save: () -> Void

    @FocusState private var focused: MemberID?
    private var members: [MemberID] { PaymentDraft.members(session) }
    private var currency: String { session.state.currency }
    private var form: Binding<SplitForm> { side == .received ? $draft.received : $draft.owned }
    private var resolution: SplitForm.Resolution {
        side == .received ? draft.receivedResolution(session) : draft.ownedResolution(session)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(question).font(.title2.bold())
                    Text(explanation).font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            }
            .listRowBackground(Color.clear)

            Section {
                ForEach(members, id: \.self) { m in row(m) }
                Menu {
                    ForEach(members, id: \.self) { m in
                        Button(session.name(m)) {
                            form.wrappedValue.text[m] = nil
                            form.wrappedValue.rest = m
                        }
                    }
                } label: {
                    Label("Give the rest to …", systemImage: "arrow.turn.down.right")
                }
            } header: {
                HStack {
                    Text("Total")
                    Spacer()
                    Text(draft.amountMinor(session).map { session.money($0) } ?? "–").monospacedDigit()
                }
            } footer: {
                if let status {
                    Text(status.text).foregroundStyle(status.ok ? Theme.positive : Theme.negative)
                }
            }

            if isLast, let p = draft.build(session) {
                ResultSection(session: session, payment: p)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
            }
        }
        .onChange(of: focused) { old, _ in
            // Tidy an amount once you leave its field: 90000 → 90.000,00.
            guard let old, case .amount(let v) = form.wrappedValue.field(old, currency: currency) else { return }
            form.wrappedValue.text[old] = Money.bare(v, currency: currency)
        }
        .navigationTitle(shortTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isLast {
                    Button("Save", action: save).disabled(draft.build(session) == nil)
                } else {
                    Button("Next", action: next).disabled(resolution.amounts == nil)
                }
            }
        }
    }

    private func row(_ m: MemberID) -> some View {
        let field = form.wrappedValue.field(m, currency: currency)
        let preview = resolution.preview[m]
        return HStack(spacing: 12) {
            MemberAvatar(session.state.members[m]?.initial ?? "?", isMe: m == session.me)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name(m)).lineLimit(1)
                if resolution.restMember == m, (preview ?? 0) > 0 || form.wrappedValue.rest == m {
                    Text("gets the rest").font(.caption).foregroundStyle(.secondary)
                } else if case .percent = field, let preview {
                    Text("= \(session.money(preview))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if field == .invalid {
                    Text("Amount or %").font(.caption).foregroundStyle(Theme.negative)
                }
            }
            Spacer(minLength: 8)
            TextField(placeholder(m, preview), text: binding(m))
                .font(.amount())
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .focused($focused, equals: m)
                .submitLabel(m == members.last ? .done : .next)
                .onSubmit {
                    if let i = members.firstIndex(of: m), i + 1 < members.count { focused = members[i + 1] } else { focused = nil }
                }
                .frame(maxWidth: 150)
        }
        .accessibilityElement(children: .combine)
    }

    private func binding(_ m: MemberID) -> Binding<String> {
        Binding(
            get: { form.wrappedValue.text[m] ?? "" },
            set: { v in
                form.wrappedValue.text[m] = v
                if form.wrappedValue.rest == m, !v.trimmingCharacters(in: .whitespaces).isEmpty { form.wrappedValue.rest = nil }
            }
        )
    }

    private func placeholder(_ m: MemberID, _ preview: Int?) -> String {
        if resolution.usedFallback || resolution.restMember == m, let preview, preview > 0 {
            return Money.bare(preview, currency: currency)
        }
        return "0"
    }

    private var status: (text: String, ok: Bool)? {
        if !resolution.invalid.isEmpty {
            return (String(localized: "Use an amount or a percentage like 15%."), false)
        }
        if resolution.usedFallback { return (fallbackLabel, true) }
        if resolution.amounts != nil { return (String(localized: "Adds up."), true) }
        if resolution.leftover > 0 { return (String(localized: "\(session.money(resolution.leftover)) left to distribute."), false) }
        if resolution.leftover < 0 { return (String(localized: "\(session.money(-resolution.leftover)) too much."), false) }
        return nil
    }

    private var question: String {
        switch (draft.kind, side) {
        case (.expense, .owned): String(localized: "Who paid?")
        case (.expense, .received): String(localized: "For whom?")
        case (_, .received): String(localized: "Who gets the money?")
        case (_, .owned): String(localized: "Whom does it belong to?")
        }
    }

    private var shortTitle: String {
        switch (draft.kind, side) {
        case (.expense, .owned): String(localized: "Paid by")
        case (.expense, .received): String(localized: "For")
        case (_, .received): String(localized: "Received by")
        case (_, .owned): String(localized: "Belongs to")
        }
    }

    private var explanation: String {
        switch (draft.kind, side) {
        case (.expense, .owned): String(localized: "Leave everything empty if you paid it all.")
        case (.expense, .received): String(localized: "Leave everything empty to split it equally.")
        case (_, .received): String(localized: "Type an amount or a percentage per person. It counts once they confirm it arrived.")
        case (_, .owned): String(localized: "Type an amount or a percentage per person. Leave everything empty if it belongs to whoever received it.")
        }
    }

    private var fallbackLabel: String {
        switch (draft.kind, side) {
        case (.expense, .owned): String(localized: "You paid it all.")
        case (.expense, .received): String(localized: "Split equally.")
        case (_, .received): String(localized: "All of it goes to you.")
        case (_, .owned): String(localized: "Same as received.")
        }
    }
}

// MARK: - Settle up: who pays whom

private struct PartiesStep: View {
    let session: GroupSession
    @Binding var draft: PaymentDraft
    let save: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("From", selection: $draft.settleFrom) {
                    ForEach(PaymentDraft.members(session), id: \.self) { Text(session.name($0)).tag(Optional($0)) }
                }
                Picker("To", selection: $draft.settleTo) {
                    ForEach(PaymentDraft.members(session), id: \.self) { Text(session.name($0)).tag(Optional($0)) }
                }
            } footer: {
                if draft.settleFrom == draft.settleTo {
                    Text("Pick two different people.").foregroundStyle(Theme.negative)
                } else {
                    Text("Counts once the receiver confirms the money arrived.")
                }
            }
            if let p = draft.build(session) {
                ResultSection(session: session, payment: p)
            }
        }
        .navigationTitle(String(localized: "Who pays whom"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(draft.build(session) == nil)
            }
        }
    }
}

/// What the payment does to each balance once it has fully arrived.
private struct ResultSection: View {
    let session: GroupSession
    let payment: Payment

    var body: some View {
        let net = Dictionary(grouping: payment.out.lines.map { ($0.member, $0.amount) } + payment.in.lines.map { ($0.member, -$0.amount) }, by: \.0)
            .mapValues { $0.reduce(0) { $0 + $1.1 } }
        let changed = PaymentDraft.members(session).filter { (net[$0] ?? 0) != 0 }
        Section {
            if payment.displayKind == .income {
                LabeledContent("Yours") { Amount(session.money(payment.out.amount(of: session.me))) }
            }
            if changed.isEmpty {
                Text("Nobody owes anybody anything from this.").foregroundStyle(.secondary)
            }
            ForEach(changed, id: \.self) { m in
                let v = net[m] ?? 0
                LabeledContent {
                    Amount(session.money(v, signed: true), tone: v > 0 ? .positive : .negative)
                } label: {
                    if m == session.me {
                        Text(v > 0 ? String(localized: "You get") : String(localized: "You pass on"))
                    } else {
                        Text(v > 0 ? String(localized: "\(session.name(m)) gets") : String(localized: "\(session.name(m)) passes on"))
                    }
                }
            }
        } header: {
            Text("Result")
        } footer: {
            if payment.track { Text("Counts as the money arrives.") }
        }
    }
}

extension LedgerState {
    var currencySymbol: String {
        var c = Locale.Components(locale: .current)
        c.currency = Locale.Currency(currency)
        return Locale(components: c).currencySymbol ?? currency
    }
}

@MainActor func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
