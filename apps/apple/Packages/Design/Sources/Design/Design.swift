import SwiftUI

/// Native iOS with a light brand layer (docs/DESIGN.md): system colors, one
/// tint, money set in rounded monospaced digits, and the balance line.
nonisolated public enum Theme {
    public static let tint = Color.indigo
    public static let positive = Color.green
    public static let negative = Color.red
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
