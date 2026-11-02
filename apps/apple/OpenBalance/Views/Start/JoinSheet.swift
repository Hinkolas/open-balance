import Design
import LedgerSync
import SwiftUI
#if canImport(VisionKit)
import Vision
import VisionKit
#endif

/// Join a group with an invite, or restore one as its admin with a recovery
/// kit: scan the QR code or paste the link. A creation link turns the sheet
/// into "New group".
struct JoinSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var link: AppLink?
    @State private var pasted = ""
    @State private var joining = false
    @State private var error: String?

    var body: some View {
        if case .creation(let c) = link {
            CreateGroupSheet(creation: c)
        } else {
            NavigationStack { form }.tint(Theme.tint)
        }
    }

    private var isRecovery: Bool { if case .recovery = link { true } else { false } }

    private var form: some View {
        Form {
            switch link {
            case .invite(let l):
                Section {
                    LabeledContent("Server", value: l.server.host() ?? l.server.absoluteString)
                } footer: {
                    Text("You join as the member this invite is for. Your key stays on this device.")
                }
            case .recovery(let l):
                Section {
                    LabeledContent("Server", value: l.server.host() ?? l.server.absoluteString)
                } footer: {
                    Text("You become the admin on this device. The admin's other devices are removed from the group.")
                }
            case .creation, nil:
                #if canImport(VisionKit) && os(iOS)
                if DataScannerViewController.isSupported {
                    Section("Scan the QR code") {
                        QRScanner { scanned in
                            if let l = AppLink(text: scanned) { link = l } else { error = String(localized: "That QR code is not a Open Balance invite.") }
                        }
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                    }
                }
                #endif
                Section {
                    TextField("openbalance://…", text: $pasted, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: pasted) { _, v in
                            if let l = AppLink(text: v) { link = l; error = nil }
                        }
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { pasted = s }
                    }
                } header: {
                    Text("Or paste the invite or recovery link")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.negative) }
            }
        }
        .navigationTitle(isRecovery ? String(localized: "Restore group") : String(localized: "Join a group"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if joining {
                    ProgressView()
                } else {
                    Button(isRecovery ? String(localized: "Restore") : String(localized: "Join")) { if let link { join(link) } }
                        .disabled(link == nil)
                }
            }
        }
    }

    private func join(_ link: AppLink) {
        joining = true
        error = nil
        Task {
            defer { joining = false }
            do {
                switch link {
                case .invite(let l): try await model.join(l)
                case .recovery(let l): try await model.recover(l)
                case .creation: return
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#if canImport(VisionKit) && os(iOS)
/// Live QR scanning with VisionKit. Not available in the simulator.
struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue {
                    scanner.stopScanning()
                    onScan(text)
                    return
                }
            }
        }
    }
}
#endif
