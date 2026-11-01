import CoreImage.CIFilterBuiltins
import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// Members and invites, renaming, switching groups, servers.
struct GroupView: View {
    let session: GroupSession
    @Environment(AppModel.self) private var model
    @State private var addingMember = false
    @State private var invite: InviteLink?
    @State private var renaming: RenameTarget?
    @State private var joining = false
    @State private var creating = false
    @State private var addingServer = false
    @State private var confirmLeave = false
    @State private var error: String?

    var body: some View {
        GBPage {
            GBPageHeader(eyebrow: String(localized: "Group"), title: session.state.name)
                .padding(.top, 8)
            members
            groupSettings
            otherGroups
            servers
            if let error {
                Text(error).font(GBFont.secondary).foregroundStyle(GB.red).padding(.top, 16)
            }
        }
        .sheet(isPresented: $addingMember) { AddMemberSheet(session: session) }
        .sheet(item: $invite) { InviteQRSheet(session: session, link: $0) }
        .sheet(item: $renaming) { RenameSheet(session: session, target: $0) }
        .sheet(isPresented: $joining) { JoinSheet(link: nil) }
        .sheet(isPresented: $creating) { CreateGroupSheet() }
        .sheet(isPresented: $addingServer) { AddServerSheet { _ in } }
        .confirmationDialog("Remove this group from this device?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Remove from this device", role: .destructive) { model.forget(session) }
        } message: {
            Text("The group stays on the server and with the other members. You can only come back with a new invite from the admin.")
        }
    }

    @ViewBuilder private var members: some View {
        GBSectionLabel(String(localized: "Members"), trailing: "\(session.state.memberOrder.count)")
        ForEach(session.state.orderedMembers) { m in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    GBAvatar(m.initial, filled: m.id == session.me, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name(m.id) + (m.id == session.me ? "" : "")).font(GBFont.body).foregroundStyle(GB.ink)
                        Text(m.isAdmin ? String(localized: "Admin") : m.isClaimed ? String(localized: "Joined") : String(localized: "Invited, not joined yet"))
                            .font(GBFont.secondary).foregroundStyle(GB.ink3)
                    }
                    Spacer()
                    if session.isAdmin, !m.isClaimed {
                        GBInlineButton(String(localized: "Invite")) { showInvite(m.id) }
                    }
                    if session.isAdmin || m.id == session.me {
                        GBIconButton("pencil", label: String(localized: "Rename")) { renaming = .member(m.id, m.name) }
                    }
                }
                .padding(.vertical, 10)
                GBHairline()
            }
        }
        if session.isAdmin {
            GBPrimaryButton(String(localized: "Add member"), systemImage: "person.badge.plus") { addingMember = true }
                .padding(.top, 16)
        }
    }

    @ViewBuilder private var groupSettings: some View {
        GBSectionLabel(String(localized: "This group"))
        GBCard {
            GBCardRow(String(localized: "Currency"), icon: "banknote") {
                Text(session.state.currency).font(GBFont.mono(15)).foregroundStyle(GB.ink2)
            }
            GBHairline()
            GBCardRow(String(localized: "Server"), icon: "server.rack") {
                Text(session.credentials.server.host() ?? "").font(GBFont.mono(13)).foregroundStyle(GB.ink2).lineLimit(1)
            }
            if session.isAdmin {
                GBHairline()
                Button { renaming = .group(session.state.name) } label: {
                    GBCardRow(String(localized: "Rename group"), icon: "pencil") { GBChevron() }
                }
                .buttonStyle(.plain)
            }
            GBHairline()
            Button { confirmLeave = true } label: {
                GBCardRow(String(localized: "Remove from this device"), icon: "rectangle.portrait.and.arrow.right", tone: GB.red)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var otherGroups: some View {
        GBSectionLabel(String(localized: "Your groups"))
        GBCard {
            ForEach(model.sessions) { s in
                Button { model.activate(s.id) } label: {
                    GBCardRow(s.state.name.isEmpty ? String(localized: "Loading…") : s.state.name, icon: "person.3") {
                        if s.id == session.id { Image(systemName: "checkmark").foregroundStyle(GB.ink) }
                    }
                }
                .buttonStyle(.plain)
                GBHairline()
            }
            Button { joining = true } label: { GBCardRow(String(localized: "Join with an invite"), icon: "qrcode.viewfinder") { GBChevron() } }
                .buttonStyle(.plain)
            GBHairline()
            Button { creating = true } label: { GBCardRow(String(localized: "Create a group"), icon: "plus") { GBChevron() } }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var servers: some View {
        GBSectionLabel(String(localized: "Servers you own"), info: String(localized: "With a server's admin token this device can create groups there. The token never gives access to any group's contents."))
        GBCard {
            ForEach(model.servers) { s in
                GBCardRow(s.name, icon: "server.rack") {
                    Text(s.server.host() ?? "").font(GBFont.mono(12)).foregroundStyle(GB.ink3)
                }
                .contextMenu {
                    Button(role: .destructive) { model.removeServer(s) } label: { Label("Remove", systemImage: "trash") }
                }
                GBHairline()
            }
            Button { addingServer = true } label: { GBCardRow(String(localized: "Add server"), icon: "plus") { GBChevron() } }
                .buttonStyle(.plain)
        }
    }

    private func showInvite(_ member: MemberID) {
        if let link = session.inviteLink(for: member) {
            invite = link
            return
        }
        // Created on another device: issue a fresh invite.
        Task {
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

    var body: some View {
        NavigationStack {
            GBPage {
                GBSectionLabel(String(localized: "Name"))
                GBTextField(String(localized: "Name"), text: $name, keyboard: .name)
                GBPrimaryButton(String(localized: "Save")) { save() }
                    .disabled(trimmed.isEmpty)
                    .padding(.top, 24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                switch target {
                case .group(let n), .member(_, let n): name = n
                }
            }
        }
        .presentationDetents([.medium])
    }

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

    var body: some View {
        NavigationStack {
            if let link {
                InviteQRContent(session: session, link: link)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            } else {
                GBPage {
                    GBPageHeader(eyebrow: session.state.name, title: String(localized: "Add member"))
                        .padding(.top, 8)
                    Text("Add the person by name. You'll get a QR code that only lets them join as this member, once.")
                        .font(GBFont.secondary).foregroundStyle(GB.ink2).padding(.top, 12)
                    GBSectionLabel(String(localized: "Name"))
                    GBTextField(String(localized: "Name"), text: $name, keyboard: .name)
                    GBPrimaryButton(working ? String(localized: "Adding…") : String(localized: "Add and show invite")) { add() }
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.top, 24)
                    if let error {
                        Text(error).font(GBFont.secondary).foregroundStyle(GB.red).padding(.top, 16)
                    }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
    }

    private func add() {
        working = true
        error = nil
        Task {
            defer { working = false }
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
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct InviteQRContent: View {
    let session: GroupSession
    let link: InviteLink
    @State private var copied = false

    var body: some View {
        GBPage {
            GBPageHeader(eyebrow: session.state.name, title: String(localized: "Invite for"), emphasis: session.name(link.memberID))
                .padding(.top, 8)
            Text("Let \(session.name(link.memberID)) scan this with their camera. It works once and contains the group's key: show it only to them.")
                .font(GBFont.secondary).foregroundStyle(GB.ink2).padding(.top, 12)
            if let image = QRCode.image(link.url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(GB.hairline, lineWidth: 1))
                    .padding(.top, 20)
                    .accessibilityLabel(String(localized: "Invite QR code"))
            }
            HStack(spacing: 12) {
                ShareLink(item: link.url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .font(GBFont.button).foregroundStyle(GB.ink)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = link.url.absoluteString
                    copied = true
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy link"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(GBFont.button).foregroundStyle(GB.ink)
                }
            }
            .padding(.top, 20)
        }
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
