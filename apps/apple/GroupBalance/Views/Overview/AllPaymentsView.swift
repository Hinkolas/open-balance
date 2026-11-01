import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// Every payment, newest first, by month. Reached from "Show all" on Overview.
struct AllPaymentsView: View {
    let session: GroupSession
    @State private var query = ""

    var body: some View {
        let payments = session.state.livePayments.newestFirst.filter {
            query.isEmpty || $0.payment.title.localizedStandardContains(query)
        }
        let months = Dictionary(grouping: payments) { String($0.payment.date.prefix(7)) }
        List {
            if payments.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            ForEach(months.keys.sorted(by: >), id: \.self) { month in
                Section(title(month)) {
                    ForEach(months[month] ?? []) { r in
                        NavigationLink(value: PaymentRoute(id: r.id)) { PaymentRow(session: session, record: r) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Payments")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search payments"))
    }

    /// "2026-11" → "November 2026".
    private func title(_ month: String) -> String {
        Dates.parse(month + "-01")?.formatted(.dateTime.month(.wide).year()) ?? month
    }
}
