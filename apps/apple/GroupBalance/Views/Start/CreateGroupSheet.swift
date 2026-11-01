import Design
import LedgerSync
import SwiftUI

/// Create a group on a server this device owns. Without a server, add one
/// first (URL + the server's ADMIN_TOKEN).
struct CreateGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server: URL?
    @State private var name = ""
    @State private var myName = ""
    @State private var currency = Locale.current.currency?.identifier ?? "EUR"
    @State private var showAddServer = false
    @State private var working = false
    @State private var error: String?

    static let currencies = ["EUR", "USD", "GBP", "CHF", "SEK", "NOK", "DKK", "PLN", "CZK", "JPY", "CAD", "AUD", "TRY"]

    var body: some View {
        NavigationStack {
            GBPage {
                GBPageHeader(eyebrow: String(localized: "New group"), title: String(localized: "Create a group"))
                    .padding(.top, 8)
                GBSectionLabel(String(localized: "Server"))
                if model.servers.isEmpty {
                    Text("Groups live on a server you run. Add it with its admin token to create groups there.")
                        .font(GBFont.secondary).foregroundStyle(GB.ink2)
                } else {
                    FlowChips(items: model.servers, title: \.name, selected: server.flatMap { s in model.servers.first { $0.server == s } }) { server = $0.server }
                }
                GBSecondaryButton(String(localized: "Add server")) { showAddServer = true }.padding(.top, 10)

                GBSectionLabel(String(localized: "Group name"))
                GBTextField(String(localized: "Italy 2026"), text: $name, keyboard: .name)
                GBSectionLabel(String(localized: "Your name in the group"))
                GBTextField(String(localized: "Your name"), text: $myName, keyboard: .name)
                GBSectionLabel(String(localized: "Currency"), info: String(localized: "Every amount in the group is in this currency. It can't be changed later."))
                Picker("Currency", selection: $currency) {
                    ForEach(Array(Set(Self.currencies + [currency])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(GB.ink)

                GBPrimaryButton(working ? String(localized: "Creating…") : String(localized: "Create group")) { create() }
                    .disabled(!canCreate || working)
                    .opacity(canCreate ? 1 : 0.4)
                    .padding(.top, 32)
                if let error {
                    Text(error).font(GBFont.secondary).foregroundStyle(GB.red).padding(.top, 16)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showAddServer) { AddServerSheet { server = $0 } }
            .onAppear { if server == nil { server = model.servers.first?.server } }
        }
    }

    private var canCreate: Bool {
        server != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && !myName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() {
        guard let s = model.servers.first(where: { $0.server == server }) else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.create(on: s, name: name.trimmingCharacters(in: .whitespaces), currency: currency,
                                       myName: myName.trimmingCharacters(in: .whitespaces))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct AddServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onAdded: (URL) -> Void
    @State private var url = ""
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            GBPage {
                GBPageHeader(eyebrow: String(localized: "Server owner"), title: String(localized: "Add a server"))
                    .padding(.top, 8)
                Text("The admin token is the server's ADMIN_TOKEN. It lets this device create groups on the server; it never gives access to any group's contents.")
                    .font(GBFont.secondary).foregroundStyle(GB.ink2).padding(.top, 12)
                GBSectionLabel(String(localized: "Server URL"))
                GBTextField("https://group-balance.example.com", text: $url, keyboard: .email, mono: true)
                GBSectionLabel(String(localized: "Admin token"))
                SecureField("", text: $token)
                    .font(GBFont.mono(16))
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(GB.paperRaised, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(GB.hairline, lineWidth: 1))
                GBPrimaryButton(working ? String(localized: "Checking…") : String(localized: "Add server")) { add() }
                    .disabled(working || url.isEmpty || token.isEmpty)
                    .padding(.top, 28)
                if let error {
                    Text(error).font(GBFont.secondary).foregroundStyle(GB.red).padding(.top, 16)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func add() {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let u = URL(string: raw), u.host() != nil else {
            error = String(localized: "That is not a valid URL.")
            return
        }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.addServer(url: u, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                onAdded(u)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Wrapping row of choice chips.
struct FlowChips<Item: Identifiable>: View {
    let items: [Item]
    let title: KeyPath<Item, String>
    let selected: Item?
    let onSelect: (Item) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items) { item in
                GBChoiceChip(item[keyPath: title], selected: item.id == selected?.id) { onSelect(item) }
            }
        }
    }
}

/// Lays children out left to right, wrapping lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: maxX, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
