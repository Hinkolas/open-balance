// swift-tools-version: 6.2
import PackageDescription

// Design tokens and components (docs/DESIGN.md), ported from Quitt. SwiftUI only.
let package = Package(
    name: "Design",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Design", targets: ["Design"])],
    targets: [
        .target(
            name: "Design",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
