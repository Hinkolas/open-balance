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
            Form {
                Section {
                    if model.servers.isEmpty {
                        Button("Add server", systemImage: "server.rack") { showAddServer = true }
                    } else {
                        Picker("Server", selection: $server) {
                            ForEach(model.servers) { Text($0.name).tag(Optional($0.server)) }
                        }
                        Button("Add another server", systemImage: "plus") { showAddServer = true }
                    }
                } header: {
                    Text("Server")
                } footer: {
                    if model.servers.isEmpty {
                        Text("Groups live on a server you run. Add it with its admin token to create groups there.")
                    }
                }
                Section {
                    TextField("Group name", text: $name).textInputAutocapitalization(.words)
                    TextField("Your name in the group", text: $myName).textInputAutocapitalization(.words)
                }
                Section {
                    Picker("Currency", selection: $currency) {
                        ForEach(Array(Set(Self.currencies + [currency])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                } footer: {
                    Text("Every amount in the group is in this currency. It can't be changed later.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.negative) }
                }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Create") { create() }.disabled(!canCreate)
                    }
                }
            }
            .sheet(isPresented: $showAddServer) { AddServerSheet { server = $0 } }
            .onAppear { if server == nil { server = model.servers.first?.server } }
        }
        .tint(Theme.tint)
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
            Form {
                Section {
                    TextField("https://group-balance.example.com", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Admin token", text: $token)
                } footer: {
                    Text("The admin token is the server's ADMIN_TOKEN. It lets this device create groups there; it never gives access to any group's contents.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.negative) }
                }
            }
            .navigationTitle("Add server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Add") { add() }.disabled(url.isEmpty || token.isEmpty)
                    }
                }
            }
        }
        .tint(Theme.tint)
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
