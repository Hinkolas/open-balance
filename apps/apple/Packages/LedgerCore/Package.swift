// swift-tools-version: 6.2
import PackageDescription

// Pure Swift, no UI: crypto, event envelope, reducer, balances.
// Implements docs/PROTOCOL.md, verified against spec/vectors.
let package = Package(
    name: "LedgerCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "LedgerCore", targets: ["LedgerCore"])],
    targets: [
        .target(name: "LedgerCore"),
        .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore"]),
    ],
    swiftLanguageModes: [.v6]
)
