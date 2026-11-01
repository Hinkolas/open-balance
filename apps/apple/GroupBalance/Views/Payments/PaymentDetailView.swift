import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// One payment: both sides, what has arrived, arrivals, edit and delete.
struct PaymentDetailView: View {
    let session: GroupSession
    let paymentID: PaymentID
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var arrivalFor: ArrivalTarget?

    var body: some View {
        GBPage {
            if let r = session.state.payments[paymentID] {
                content(r)
            } else {
                Text("This payment no longer exists.").font(GBFont.secondary).foregroundStyle(GB.ink3).padding(.top, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let r = session.state.payments[paymentID], !r.deleted, session.canEdit(r) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(GB.ink)
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let r = session.state.payments[paymentID] { PaymentEditor(session: session, draft: .edit(r, session: session)) }
        }
        .sheet(item: $arrivalFor) { t in ArrivalSheet(session: session, target: t) }
        .confirmationDialog("Delete this payment?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                _ = try? session.submit(.paymentDeleted(.init(id: paymentID)))
                dismiss()
            }
        }
    }

    @ViewBuilder private func content(_ r: PaymentRecord) -> some View {
        let p = r.payment
        let arrivals = session.state.arrivals(of: p.id)
        let effect = Balances.effect(of: p, arrivals: arrivals)
        GBPageHeader(eyebrow: "\(kindLabel(p.displayKind)) · \(Dates.display(p.date))", title: p.title)
            .padding(.top, 8)
        HStack(alignment: .firstTextBaseline) {
            GBAmount(session.money(p.amount), font: GBFont.heroAmount)
            Spacer()
            if r.deleted {
                GBTag(String(localized: "deleted"), color: GB.red)
            } else if p.track {
                if effect.arrived == p.amount {
                    GBTag(String(localized: "arrived"), color: GB.green)
                } else {
                    GBTag(String(localized: "expected"), color: GB.ink3)
                }
            }
        }
        .padding(.top, 16)
        if let note = p.note {
            Text(note).font(GBFont.body).foregroundStyle(GB.ink2).padding(.top, 8)
        }
        if r.editedConcurrently {
            Text("This was edited by two people at the same time. The later edit won.")
                .font(GBFont.secondary).foregroundStyle(GB.red).padding(.top, 8)
        }

        GBSectionLabel(p.displayKind == .expense ? String(localized: "For") : String(localized: "Arrived at"))
        ForEach(p.in.lines, id: \.member) { line in
            let held = effect.held[line.member] ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.name(line.member)).font(GBFont.body).foregroundStyle(GB.ink)
                    Spacer()
                    if p.track {
                        GBAmount("\(session.money(held)) / \(session.money(line.amount))", tone: held == line.amount ? .positive : .neutral)
                    } else {
                        GBAmount(session.money(line.amount))
                    }
                }
                if p.track {
                    GBProgressBar(fraction: line.amount == 0 ? 1 : Double(held) / Double(line.amount), tint: held == line.amount ? GB.green : GB.ink)
                    if !r.deleted, held < line.amount, session.canRecordArrival(for: line.member) {
                        GBInlineButton(String(localized: "Record arrival")) {
                            arrivalFor = ArrivalTarget(payment: p.id, member: line.member, remaining: line.amount - held)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, 10)
            GBHairline()
        }

        GBSectionLabel(p.displayKind == .expense ? String(localized: "Paid by") : String(localized: "Belongs to"))
        ForEach(p.out.lines, id: \.member) { line in
            let owned = effect.owned[line.member] ?? 0
            GBSummaryRow(session.name(line.member),
                         amount: p.track && owned != line.amount ? "\(session.money(owned)) / \(session.money(line.amount))" : session.money(line.amount))
        }

        if !arrivals.isEmpty {
            GBSectionLabel(String(localized: "Arrivals"))
            ForEach(arrivals) { a in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(session.name(a.member)): \(session.money(a.amount))").font(GBFont.body).foregroundStyle(GB.ink)
                        Text("by \(session.name(a.author)) · \(Dates.timestamp(a.at)?.formatted(date: .abbreviated, time: .shortened) ?? a.at)")
                            .font(GBFont.secondary).foregroundStyle(GB.ink3)
                    }
                    Spacer()
                    if a.author == session.me || session.isAdmin {
                        GBIconButton("xmark", tone: GB.red, label: String(localized: "Remove arrival")) {
                            _ = try? session.submit(.arrivalRemoved(.init(id: a.id)))
                        }
                    }
                }
                .padding(.vertical, 8)
                GBHairline()
            }
        }

        Text(String(localized: "Added by \(session.name(r.creator))") + (r.lastEditor.map { " · " + String(localized: "edited by \(session.name($0))") } ?? ""))
            .font(GBFont.secondary).foregroundStyle(GB.ink3).padding(.top, 20)
    }

    private func kindLabel(_ k: Payment.Kind) -> String {
        switch k {
        case .income: String(localized: "Income")
        case .expense: String(localized: "Expense")
        case .settlement: String(localized: "Settle up")
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

    var body: some View {
        NavigationStack {
            GBPage {
                GBPageHeader(eyebrow: session.state.payments[target.payment]?.payment.title ?? "",
                             title: target.member == session.me ? String(localized: "What arrived?") : String(localized: "What arrived at \(session.name(target.member))?"))
                    .padding(.top, 8)
                Text("Still expected: \(session.money(target.remaining)). Record instalments one by one as they come in.")
                    .font(GBFont.secondary).foregroundStyle(GB.ink2).padding(.top, 12)
                GBSectionLabel(String(localized: "Amount"))
                GBAmountField(text: $amount, currency: session.state.currency)
                GBPrimaryButton(String(localized: "Record arrival")) { save() }
                    .disabled(parsed == nil)
                    .opacity(parsed == nil ? 0.4 : 1)
                    .padding(.top, 28)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { amount = Money.inputString(target.remaining, currency: session.state.currency) }
        }
        .presentationDetents([.medium, .large])
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
