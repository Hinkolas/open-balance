// swift-tools-version: 6.2
import PackageDescription

// Talks to a Group Balance server: signed requests, invite links, Keychain
// credentials, the local ledger cache, outbox and live updates.
let package = Package(
    name: "LedgerSync",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "LedgerSync", targets: ["LedgerSync"])],
    dependencies: [.package(path: "../LedgerCore")],
    targets: [
        .target(name: "LedgerSync", dependencies: ["LedgerCore"]),
        .testTarget(name: "LedgerSyncTests", dependencies: ["LedgerSync"]),
    ],
    swiftLanguageModes: [.v6]
)
