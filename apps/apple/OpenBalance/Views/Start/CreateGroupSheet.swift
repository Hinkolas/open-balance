import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// Create a group on a server this device owns (without one, add it first:
/// URL + the server's ADMIN_TOKEN), or on the server of a creation link.
/// Ends with the recovery kit.
struct CreateGroupSheet: View {
    var creation: CreationLink?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var created: (session: GroupSession, kit: RecoveryLink)?
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
            if let created {
                RecoveryKitView(groupName: created.session.state.name, link: created.kit) {
                    model.add(created.session)
                    dismiss()
                }
            } else {
                form
            }
        }
        .interactiveDismissDisabled(created != nil)
        .tint(Theme.tint)
    }

    private var form: some View {
        Form {
            serverSection
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

    /// The creation link's server, fixed, or a server this device owns.
    @ViewBuilder private var serverSection: some View {
        if let creation {
            Section {
                LabeledContent("Server", value: creation.server.host() ?? creation.server.absoluteString)
            } header: {
                Text("Server")
            } footer: {
                Text("The server owner invited you to create a group. You'll be its admin.")
            }
        } else {
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
        }
    }

    /// Where to create and with which token: the creation link's code, or the owner token.
    private var target: (server: URL, token: String)? {
        if let creation { return (creation.server, creation.code) }
        return model.servers.first { $0.server == server }.map { ($0.server, $0.token) }
    }

    private var canCreate: Bool {
        target != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && !myName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() {
        guard let target else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                created = try await model.create(server: target.server, token: target.token, name: name.trimmingCharacters(in: .whitespaces),
                                                 currency: currency, myName: myName.trimmingCharacters(in: .whitespaces))
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
                    TextField("https://open-balance.example.com", text: $url)
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
