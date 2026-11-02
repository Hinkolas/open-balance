import CoreImage.CIFilterBuiltins
import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// Members, invites and devices, this group's settings, your groups, your servers.
struct GroupView: View {
    let session: GroupSession
    @Environment(AppModel.self) private var model
    @State private var addingMember = false
    @State private var invite: InviteLink?
    @State private var deviceInvite: InviteLink?
    @State private var renaming: RenameTarget?
    @State private var joining = false
    @State private var creating = false
    @State private var addingServer = false
    @State private var confirmLeave = false
    @State private var error: String?

    var body: some View {
        List {
            members
            Section("This group") {
                LabeledContent("Currency", value: session.state.currency)
                LabeledContent("Server", value: session.credentials.server.host() ?? session.credentials.server.absoluteString)
                if session.isAdmin {
                    Button("Rename group", systemImage: "pencil") { renaming = .group(session.state.name) }
                }
            }
            Section("Your groups") {
                ForEach(model.sessions) { s in
                    Button { model.activate(s.id) } label: {
                        HStack {
                            Text(s.state.name).foregroundStyle(.primary)
                            Spacer()
                            if s.id == session.id { Image(systemName: "checkmark").foregroundStyle(Theme.tint) }
                        }
                    }
                }
                Button("Join with an invite", systemImage: "qrcode.viewfinder") { joining = true }
                Button("Create a group", systemImage: "plus") { creating = true }
            }
            Section {
                ForEach(model.servers) { s in
                    LabeledContent(s.name, value: s.server.host() ?? "")
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { model.removeServer(s) }
                        }
                }
                Button("Add server", systemImage: "server.rack") { addingServer = true }
            } header: {
                Text("Servers you own")
            } footer: {
                Text("With a server's admin token this device can create groups there. The token never gives access to any group's contents.")
            }
            Section {
                Button("Remove from this device", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
            } footer: {
                Text("To lock Balance with Face ID, touch and hold its icon on the Home Screen and choose Require Face ID.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Group")
        .sheet(isPresented: $addingMember) { AddMemberSheet(session: session) }
        .sheet(item: $invite) { InviteQRSheet(session: session, link: $0) }
        .sheet(item: $deviceInvite) { DeviceInviteSheet(session: session, link: $0) }
        .sheet(item: $renaming) { RenameSheet(session: session, target: $0) }
        .sheet(isPresented: $joining) { JoinSheet(link: nil) }
        .sheet(isPresented: $creating) { CreateGroupSheet() }
        .sheet(isPresented: $addingServer) { AddServerSheet { _ in } }
        .alert("Couldn't create the invite", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog("Remove this group from this device?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Remove from this device", role: .destructive) { model.forget(session) }
        } message: {
            Text("The group stays on the server and with the other members. You can only come back with a new invite from the admin.")
        }
    }

    private var members: some View {
        Section {
            ForEach(session.state.orderedMembers) { m in
                HStack(spacing: 12) {
                    MemberAvatar(m.initial, isMe: m.id == session.me)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name(m.id))
                        Text(status(m))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if session.isAdmin, !m.isClaimed {
                        Button("Invite", systemImage: "qrcode") { showInvite(m.id) }
                            .labelStyle(.titleAndIcon)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .contextMenu {
                    if session.isAdmin || m.id == session.me {
                        Button("Rename", systemImage: "pencil") { renaming = .member(m.id, m.name) }
                    }
                    if m.id == session.me {
                        Button("Add a device", systemImage: "qrcode") { showDeviceInvite() }
                    }
                }
                .swipeActions {
                    if session.isAdmin || m.id == session.me {
                        Button("Rename", systemImage: "pencil") { renaming = .member(m.id, m.name) }
                    }
                }
            }
            if session.isAdmin {
                Button("Add member", systemImage: "person.badge.plus") { addingMember = true }
            }
            Button("Add a device", systemImage: "qrcode") { showDeviceInvite() }
        } header: {
            Text("Members")
        } footer: {
            Text(session.isAdmin
                 ? String(localized: "Each member joins with their own one-time QR code. Add a device to share your member with someone else, for example a partner in your company.")
                 : String(localized: "Add a device to share your member with someone else, for example a partner in your company."))
        }
    }

    /// "Admin · 2 devices", "Joined", "Invited, not joined yet".
    private func status(_ m: Member) -> String {
        let role = m.isAdmin ? String(localized: "Admin") : m.isClaimed ? String(localized: "Joined") : String(localized: "Invited, not joined yet")
        guard m.keys.count > 1 else { return role }
        return String(localized: "\(role) · \(m.keys.count) devices")
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

    private func showInvite(_ member: MemberID) {
        Task {
            guard await DeviceOwner.confirm(String(localized: "Show an invite that lets someone join this group.")) else { return }
            if let link = session.inviteLink(for: member) {
                invite = link
                return
            }
            // Created on another device: issue a fresh invite.
            do {
                invite = try await session.renewInvite(for: member)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum RenameTarget: Identifiable {
    case group(String)
    case member(MemberID, String)
    var id: String {
        switch self {
        case .group: "group"
        case .member(let id, _): id
        }
    }
}

struct RenameSheet: View {
    let session: GroupSession
    let target: RenameTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).focused($focused).textInputAutocapitalization(.words)
            }
            .navigationTitle(isGroup ? String(localized: "Rename group") : String(localized: "Rename member"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(trimmed.isEmpty) }
            }
            .onAppear {
                switch target {
                case .group(let n), .member(_, let n): name = n
                }
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private var isGroup: Bool { if case .group = target { true } else { false } }
    private var trimmed: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }

    private func save() {
        switch target {
        case .group: _ = try? session.submit(.groupUpdated(.init(name: trimmed)))
        case .member(let id, _): _ = try? session.submit(.memberUpdated(.init(id: id, name: trimmed)))
        }
        dismiss()
    }
}

/// Admin adds a member by name, then shows their invite QR.
struct AddMemberSheet: View {
    let session: GroupSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false
    @State private var link: InviteLink?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let link {
                    InviteQRContent(session: session, link: link)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                } else {
                    Form {
                        Section {
                            TextField("Name", text: $name).focused($focused).textInputAutocapitalization(.words)
                        } footer: {
                            if let error {
                                Text(error).foregroundStyle(Theme.negative)
                            } else {
                                Text("You'll get a QR code that lets only this person join, once.")
                            }
                        }
                    }
                    .navigationTitle("Add member")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            if working {
                                ProgressView()
                            } else {
                                Button("Add") { add() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                    .onAppear { focused = true }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func add() {
        working = true
        error = nil
        Task {
            defer { working = false }
            guard await DeviceOwner.confirm(String(localized: "Show an invite that lets someone join this group.")) else { return }
            do {
                link = try await session.addMember(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct InviteQRSheet: View {
    let session: GroupSession
    let link: InviteLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InviteQRContent(session: session, link: link)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The QR for a further device of your own member, with a way to withdraw it.
struct DeviceInviteSheet: View {
    let session: GroupSession
    let link: InviteLink
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRevoke = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            InviteQRContent(session: session, link: link, isDevice: true) {
                Button("Revoke this QR code", systemImage: "xmark.circle", role: .destructive) { confirmRevoke = true }
                    .disabled(working)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Revoke this QR code?", isPresented: $confirmRevoke, titleVisibility: .visible) {
                Button("Revoke", role: .destructive) { revoke() }
            } message: {
                Text("Nobody can join with it any more. Devices that already joined stay.")
            }
        }
    }

    private func revoke() {
        working = true
        Task {
            defer { working = false }
            try? await session.revokeDeviceInvite()
            dismiss()
        }
    }
}

struct InviteQRContent<Footer: View>: View {
    let session: GroupSession
    let link: InviteLink
    var isDevice = false
    @ViewBuilder var footer: Footer
    @State private var copied = false

    var body: some View {
        let name = session.name(link.memberID)
        let me = session.state.members[session.me]?.name ?? ""
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(isDevice ? String(localized: "Add a device") : String(localized: "Invite \(name)")).font(.title2.bold())
                    Text(isDevice
                         ? String(localized: "Scan this on the other device. It joins as \(me): it sees the group and writes as \(me). It works once, so show it only to the person you mean.")
                         : String(localized: "Let \(name) scan this with the iPhone camera. It works once and contains the group's key, so show it only to them."))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let image = QRCode.image(link.url.absoluteString) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .frame(maxWidth: 320)
                        .accessibilityLabel(String(localized: "Invite QR code"))
                }
                HStack(spacing: 12) {
                    ShareLink(item: link.url) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy link"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = link.url.absoluteString
                        copied = true
                    }
                    .buttonStyle(.bordered)
                }
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }
}

extension InviteQRContent where Footer == EmptyView {
    init(session: GroupSession, link: InviteLink) {
        self.init(session: session, link: link, footer: { EmptyView() })
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
