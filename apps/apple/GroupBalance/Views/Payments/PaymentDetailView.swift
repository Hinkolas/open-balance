import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// One payment: both sides, what has arrived, arrivals, edit and delete.
struct PaymentDetailView: View {
    let session: GroupSession
    let paymentID: PaymentID
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PaymentDraft?
    @State private var confirmDelete = false
    @State private var arrivalFor: ArrivalTarget?

    var body: some View {
        Group {
            if let r = session.state.payments[paymentID] {
                content(r)
            } else {
                ContentUnavailableView("Payment not found", systemImage: "questionmark.circle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let r = session.state.payments[paymentID], !r.deleted, session.canEdit(r) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit", systemImage: "pencil") { editing = .edit(r, session: session) }
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        .sheet(item: $editing) { PaymentFlow(session: session, draft: $0) }
        .sheet(item: $arrivalFor) { ArrivalSheet(session: session, target: $0) }
        .confirmationDialog("Delete this payment?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                _ = try? session.submit(.paymentDeleted(.init(id: paymentID)))
                dismiss()
            }
        } message: {
            Text("Everyone in the group will see that you deleted it.")
        }
    }

    private func content(_ r: PaymentRecord) -> some View {
        let p = r.payment
        let arrivals = session.state.arrivals(of: p.id)
        let effect = Balances.effect(of: p, arrivals: arrivals)
        return List {
            Section {
                VStack(spacing: 6) {
                    Amount(session.money(p.amount), font: .amount(.largeTitle, weight: .semibold))
                    Text(p.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text(Dates.display(p.date)).font(.subheadline).foregroundStyle(.secondary)
                    if r.deleted {
                        StatusBadge(String(localized: "Deleted"), color: Theme.negative)
                    } else if p.track {
                        if effect.arrived == p.amount {
                            StatusBadge(String(localized: "Arrived"), color: Theme.positive)
                        } else {
                            StatusBadge(String(localized: "\(session.money(effect.arrived)) of \(session.money(p.amount)) arrived"))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            if let note = p.note {
                Section("Note") { Text(note) }
            }

            Section {
                ForEach(p.in.lines, id: \.member) { line in
                    inRow(p, line, held: effect.held[line.member] ?? 0, deleted: r.deleted)
                }
            } header: {
                Text(p.displayKind == .expense ? String(localized: "For") : String(localized: "Received by"))
            } footer: {
                if p.track, !r.deleted { Text("Only money confirmed as arrived counts in the balances.") }
            }

            Section(p.displayKind == .expense ? String(localized: "Paid by") : String(localized: "Belongs to")) {
                ForEach(p.out.lines, id: \.member) { line in
                    LabeledContent {
                        Amount(session.money(line.amount))
                    } label: {
                        memberLabel(line.member)
                    }
                }
            }

            if !arrivals.isEmpty {
                Section("Arrivals") {
                    ForEach(arrivals) { a in
                        LabeledContent {
                            Amount(session.money(a.amount))
                        } label: {
                            Text(session.name(a.member))
                            Text("\(session.name(a.author)) · \(Dates.timestamp(a.at)?.formatted(date: .abbreviated, time: .shortened) ?? a.at)")
                        }
                        .swipeActions {
                            if a.author == session.me || session.isAdmin {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    _ = try? session.submit(.arrivalRemoved(.init(id: a.id)))
                                }
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Added by", value: session.name(r.creator))
                if let editor = r.lastEditor { LabeledContent("Last edited by", value: session.name(editor)) }
            } footer: {
                if r.editedConcurrently {
                    Text("Two people edited this at the same time. The later edit won.").foregroundStyle(Theme.negative)
                }
            }
        }
        .navigationTitle(p.displayKind.label)
    }

    private func inRow(_ p: Payment, _ line: Payment.Line, held: Int, deleted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                if p.track {
                    Amount("\(session.money(held)) / \(session.money(line.amount))", tone: held == line.amount ? .positive : .pending)
                } else {
                    Amount(session.money(line.amount))
                }
            } label: {
                memberLabel(line.member)
            }
            if p.track, line.amount > 0 {
                ProgressView(value: Double(held), total: Double(line.amount))
                    .tint(held == line.amount ? Theme.positive : Theme.tint)
                if !deleted, held < line.amount, session.canRecordArrival(for: line.member) {
                    Button(line.member == session.me ? String(localized: "Confirm what arrived") : String(localized: "Confirm for \(session.name(line.member))"),
                           systemImage: "checkmark.circle") {
                        arrivalFor = ArrivalTarget(payment: p.id, member: line.member, remaining: line.amount - held)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func memberLabel(_ m: MemberID) -> some View {
        HStack(spacing: 10) {
            MemberAvatar(session.state.members[m]?.initial ?? "?", isMe: m == session.me)
            Text(session.name(m))
        }
    }
}

struct ArrivalTarget: Identifiable {
    let payment: PaymentID
    let member: MemberID
    let remaining: Int
    var id: String { payment + member }
}

/// "How much arrived?" Defaults to everything still open.
struct ArrivalSheet: View {
    let session: GroupSession
    let target: ArrivalTarget
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TextField("0", text: $amount)
                            .font(.amount(.largeTitle, weight: .semibold))
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                            .keyboardType(.decimalPad)
                            .focused($focused)
                            .fixedSize()
                        Text(session.state.currencySymbol).font(.amount(.title2, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } footer: {
                    Text("Still expected: \(session.money(target.remaining)). Confirm instalments one by one as they come in.")
                }
            }
            .navigationTitle(target.member == session.me ? String(localized: "What arrived?") : String(localized: "Arrived at \(session.name(target.member))"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { save() }.disabled(parsed == nil)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
            .onAppear {
                amount = Money.bare(target.remaining, currency: session.state.currency)
                focused = true
            }
        }
        .presentationDetents([.medium])
        .tint(Theme.tint)
    }

    private var parsed: Int? {
        guard let v = Money.parse(amount, currency: session.state.currency), v > 0 else { return nil }
        return v
    }

    private func save() {
        guard let v = parsed else { return }
        _ = try? session.submit(.arrivalRecorded(.init(id: UUID.v7().lower, payment: target.payment, member: target.member, amount: v)))
        dismiss()
    }
}
