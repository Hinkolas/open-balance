import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// The devices of my own member: each has its own key. Remove a lost one
/// from here, or add another (PROTOCOL.md §5.4 steps 5 and 6).
struct DevicesView: View {
    let session: GroupSession
    @State private var deviceInvite: InviteLink?
    @State private var removing: Data?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let keys = session.state.members[session.me]?.keys ?? []
        List {
            Section {
                ForEach(keys, id: \.self) { key in
                    row(key)
                        .swipeActions {
                            if key != session.deviceKey {
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = key }
                            }
                        }
                        .contextMenu {
                            if key != session.deviceKey {
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = key }
                            }
                        }
                }
            } footer: {
                Text(session.isAdmin
                     ? String(localized: "Each device has its own key, and the key never leaves it. If you lose a device, remove it here from another one. If you lose all of them, restore the group with your recovery kit.")
                     : String(localized: "Each device has its own key, and the key never leaves it. If you lose a device, remove it here from another one. If you lose all of them, ask the admin to reset your access."))
            }
            Section {
                Button("Add a device", systemImage: "qrcode") { showDeviceInvite() }
                    .disabled(working)
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.negative) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Your devices")
        .sheet(item: $deviceInvite) { DeviceInviteSheet(session: session, link: $0) }
        .confirmationDialog("Remove this device?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { key in
            Button("Remove", role: .destructive) { remove(key) }
        } message: { _ in
            Text("It can no longer read or write in this group. Do this when a device is lost or someone stops sharing your member.")
        }
    }

    private func row(_ key: Data) -> some View {
        let isThis = key == session.deviceKey
        return HStack(spacing: 12) {
            Image(systemName: isThis ? "iphone" : "laptopcomputer.and.iphone")
                .foregroundStyle(isThis ? Theme.tint : .secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(isThis ? String(localized: "This device") : String(localized: "Other device"))
                Text(detail(key)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// "Added 2 Nov 2026 · 3F2A 91C0": when it joined, and the start of its key
    /// to tell devices apart.
    private func detail(_ key: Data) -> String {
        let hex = key.prefix(4).map { String(format: "%02X", $0) }.joined()
        let code = "\(hex.prefix(4)) \(hex.suffix(4))"
        guard let date = Dates.timestamp(session.state.keyAddedAt[key]) else { return code }
        return String(localized: "Added \(date.formatted(date: .abbreviated, time: .omitted)) · \(code)")
    }

    private func showDeviceInvite() {
        Task {
            guard await DeviceOwner.confirm(String(localized: "Show a QR code that lets another device write as you.")) else { return }
            do {
                deviceInvite = try await session.addDevice()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func remove(_ key: Data) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await session.removeDevice(of: session.me, key: key)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
