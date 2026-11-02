import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Native iOS with a light brand layer (docs/DESIGN.md): system colors, one
/// tint, money set in rounded monospaced digits, and the balance line.
nonisolated public enum Theme {
    /// Brand emerald, matching the app icon. Also the positive color, so the
    /// app has one green.
    public static let tint = emerald
    public static let positive = emerald
    public static let negative = Color.red

    private static let emerald = Color.adaptive(
        light: 0x1E9E62, dark: 0x3CCB82,
        lightHighContrast: 0x148A54, darkHighContrast: 0x6EDCA2
    )
}

nonisolated extension Color {
    /// An sRGB color that follows light/dark mode and Increase Contrast.
    static func adaptive(light: UInt32, dark: UInt32, lightHighContrast: UInt32, darkHighContrast: UInt32) -> Color {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        func pick(isDark: Bool, highContrast: Bool) -> (CGFloat, CGFloat, CGFloat) {
            switch (isDark, highContrast) {
            case (false, false): rgb(light)
            case (true, false): rgb(dark)
            case (false, true): rgb(lightHighContrast)
            case (true, true): rgb(darkHighContrast)
            }
        }
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = pick(isDark: traits.userInterfaceStyle == .dark, highContrast: traits.accessibilityContrast == .high)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let (r, g, b) = pick(
                isDark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
                highContrast: match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            )
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

public enum AmountTone: Sendable { case neutral, positive, negative, pending }

public extension Font {
    /// Money: rounded design. Pair with `.monospacedDigit()`.
    static func amount(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

/// A formatted amount. Color follows tone; the text itself carries the sign.
public struct Amount: View {
    let text: String
    let tone: AmountTone
    let font: Font

    public init(_ text: String, tone: AmountTone = .neutral, font: Font = .amount()) {
        self.text = text
        self.tone = tone
        self.font = font
    }

    public var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tone {
        case .neutral: .primary
        case .positive: Theme.positive
        case .negative: Theme.negative
        case .pending: .secondary
        }
    }
}

/// A member's initial in a circle. Filled with the tint for you.
public struct MemberAvatar: View {
    let initial: String
    let isMe: Bool
    @ScaledMetric private var size: CGFloat = 32

    public init(_ initial: String, isMe: Bool = false) {
        self.initial = initial
        self.isMe = isMe
    }

    public var body: some View {
        Text(initial)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(isMe ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .background(isMe ? AnyShapeStyle(Theme.tint) : AnyShapeStyle(.quaternary), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The balance line: a bar diverging from a center axis, right and green for
/// money the group owes this member, left and red for money they owe. An
/// optional faint bar behind it marks where the member lands once expected
/// money has arrived.
public struct BalanceBar: View {
    let value: Int
    let expected: Int?
    let scale: Int

    public init(value: Int, expected: Int? = nil, scale: Int) {
        self.value = value
        self.expected = expected == value ? nil : expected
        self.scale = max(scale, 1)
    }

    public var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                if let expected, expected != 0 {
                    bar(expected, half: half)
                        .opacity(0.3)
                }
                Rectangle().fill(.tertiary).frame(width: 1.5, height: 14).offset(x: half - 0.75)
                if value != 0 {
                    bar(value, half: half)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private func bar(_ v: Int, half: CGFloat) -> some View {
        let length = max(3, half * min(1, CGFloat(abs(v)) / CGFloat(scale)))
        return Capsule()
            .fill(v > 0 ? Theme.positive : Theme.negative)
            .frame(width: length, height: 6)
            .offset(x: v > 0 ? half : half - length)
    }
}

/// Small capsule for a state word: invited, expected, arrived, settled.
public struct StatusBadge: View {
    let text: String
    let color: Color

    public init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// The leading icon of a history row: what the entry is about (a payment
/// kind's symbol or a member's initial, both grey) with a small badge for
/// what happened to it (added, edited, deleted, arrived …).
public struct EventIcon: View {
    public enum Subject: Sendable, Equatable {
        case symbol(String)
        case initial(String)
    }

    let subject: Subject
    let badge: String?
    let badgeColor: Color
    let muted: Bool
    @ScaledMetric private var size: CGFloat = 36

    public init(_ subject: Subject, badge: String? = nil, badgeColor: Color = Theme.tint, muted: Bool = false) {
        self.subject = subject
        self.badge = badge
        self.badgeColor = badgeColor
        self.muted = muted
    }

    public var body: some View {
        main
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.caption2.weight(.bold))
                        .imageScale(.small)
                        .foregroundStyle(.white)
                        .frame(width: size * 0.48, height: size * 0.48)
                        .background(muted ? AnyShapeStyle(.gray) : AnyShapeStyle(badgeColor), in: Circle())
                        .overlay(Circle().strokeBorder(Self.cellBackground, lineWidth: 2).padding(-2))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var main: some View {
        switch subject {
        case .symbol(let name):
            Image(systemName: name)
                .font(.body.weight(.medium))
                .foregroundStyle(muted ? .tertiary : .secondary)
                .frame(width: size, height: size)
                .background(.quaternary, in: Circle())
        case .initial(let initial):
            Text(initial)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(muted ? .secondary : .primary)
                .frame(width: size, height: size)
                .background(.quaternary, in: Circle())
        }
    }

    /// The badge's ring matches the list row behind it.
    private static var cellBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}
