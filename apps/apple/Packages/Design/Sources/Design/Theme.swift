import SwiftUI

/// Design tokens. Light is the primary theme, dark is derived. Never hardcode
/// a color in a view; add a token here. Values from docs/DESIGN.md.
///
/// `nonisolated`: the package defaults to MainActor isolation, but dynamic
/// colors are resolved by CoreAnimation on its render thread. An isolated
/// provider closure would trap there (dispatch_assert_queue).
nonisolated public enum GB {
    // Surfaces
    public static let paper = adaptive(light: 0xF4F1EA, dark: 0x141311)
    public static let paperRaised = adaptive(light: 0xFAF8F3, dark: 0x1B1A17)
    public static let track = adaptive(light: 0xE3DFD4, dark: 0x2A2824)

    // Ink
    public static let ink = adaptive(light: 0x141414, dark: 0xF3F0E8)
    public static let ink2 = adaptive(light: 0x5C5A55, dark: 0xB5B0A6)
    public static let ink3 = adaptive(light: 0x8A877F, dark: 0x817D74)
    public static let onInk = adaptive(light: 0xF4F1EA, dark: 0x141311)

    // Lines
    public static let hairline = adaptive(light: 0xD9D4C8, dark: 0x2E2C28)
    public static let hairlineStrong = ink

    // Accents
    public static let red = adaptive(light: 0xC8371F, dark: 0xE0523A)
    public static let green = adaptive(light: 0x2E6B3A, dark: 0x4C9A5C)
    public static var redSoft: Color { red.opacity(0.10) }
    public static var greenSoft: Color { green.opacity(0.10) }

    // Metrics
    public static let gutter: CGFloat = 20
    public static let ctaHeight: CGFloat = 56
    public static let chip: CGFloat = 36

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
        #else
        return Color(hex: light)
        #endif
    }
}

#if canImport(UIKit)
import UIKit
nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

nonisolated extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Type roles. System fonts with serif / monospaced designs stand in until
/// Instrument Serif, IBM Plex Mono and Inter are bundled (docs/DESIGN.md).
nonisolated public enum GBFont {
    public static func display(_ size: CGFloat = 34) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
    public static func mono(_ size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    public static let heroAmount: Font = mono(40, weight: .semibold)
    public static let amount: Font = mono(15)
    public static let body: Font = .system(size: 15)
    public static let secondary: Font = .system(size: 13)
    public static let sectionLabel: Font = .system(size: 11, weight: .semibold)
    public static let button: Font = .system(size: 16, weight: .semibold)
}
