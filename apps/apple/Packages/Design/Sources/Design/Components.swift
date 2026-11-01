import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Structure

/// 11pt uppercase tracked label, optionally with a trailing value.
public struct GBSectionLabel: View {
    let title: String
    let trailing: String?
    let info: String?

    public init(_ title: String, trailing: String? = nil, info: String? = nil) {
        self.title = title
        self.trailing = trailing
        self.info = info
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(GBFont.sectionLabel)
                .tracking(1.2)
                .foregroundStyle(GB.ink3)
            if let info { GBInfoButton(info) }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(GBFont.secondary)
                    .foregroundStyle(GB.ink2)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

public struct GBHairline: View {
    let strong: Bool
    public init(strong: Bool = false) { self.strong = strong }
    public var body: some View {
        Rectangle()
            .fill(strong ? GB.hairlineStrong : GB.hairline)
            .frame(height: strong ? 1.5 : 1)
    }
}

/// Eyebrow + serif title + heavy rule. `emphasis` renders in the secondary ink. No italics anywhere.
public struct GBPageHeader: View {
    let eyebrow: String
    let title: String
    let emphasis: String?

    public init(eyebrow: String, title: String, emphasis: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.emphasis = emphasis
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased())
                .font(GBFont.sectionLabel)
                .tracking(1.2)
                .foregroundStyle(GB.ink3)
            (Text(title).foregroundStyle(GB.ink) + Text(emphasis.map { " " + $0 } ?? "").foregroundStyle(GB.ink2))
                .font(GBFont.display())
                .fixedSize(horizontal: false, vertical: true)
            GBHairline(strong: true)
                .padding(.top, 6)
        }
    }
}

// MARK: - Money

public enum GBTone { case neutral, positive, negative }

/// Monospaced amount text, colored by tone.
public struct GBAmount: View {
    let text: String
    let tone: GBTone
    let font: Font

    public init(_ text: String, tone: GBTone = .neutral, font: Font = GBFont.amount) {
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
        case .neutral: GB.ink
        case .positive: GB.green
        case .negative: GB.red
        }
    }
}

/// Label left, amount right, hairline below.
public struct GBSummaryRow: View {
    let label: String
    let amount: String
    let tone: GBTone

    public init(_ label: String, amount: String, tone: GBTone = .neutral) {
        self.label = label
        self.amount = amount
        self.tone = tone
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(GBFont.body).foregroundStyle(GB.ink2)
                Spacer()
                GBAmount(amount, tone: tone)
            }
            .padding(.vertical, 12)
            GBHairline()
        }
    }
}

// MARK: - Progress

public struct GBProgressBar: View {
    let fraction: Double
    let tint: Color

    public init(fraction: Double, tint: Color = GB.ink) {
        self.fraction = min(max(fraction, 0), 1)
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(GB.track)
                Capsule().fill(tint).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Buttons

/// Full-width dark pill, the one primary action on a screen.
public struct GBPrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(GBFont.button)
            .foregroundStyle(GB.onInk)
            .frame(maxWidth: .infinity)
            .frame(height: GB.ctaHeight)
            .background(GB.ink, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Stamp-like tag: green "QUITT", red "OFFEN", gray "ERWARTET".
public struct GBTag: View {
    let text: String
    let color: Color
    let tilted: Bool

    public init(_ text: String, color: Color = GB.green, tilted: Bool = true) {
        self.text = text
        self.color = color
        self.tilted = tilted
    }

    public var body: some View {
        Text(text.uppercased())
            .font(GBFont.mono(11, weight: .semibold))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
            .rotationEffect(.degrees(tilted ? -3 : 0))
    }
}

/// Small inline action, e.g. "Bestätigen" next to a row.
public struct GBInlineButton: View {
    let title: String
    let tone: Color
    let action: () -> Void

    public init(_ title: String, tone: Color = GB.ink, action: @escaping () -> Void) {
        self.title = title
        self.tone = tone
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(tone, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Avatar initial, filled for the current user.
public struct GBAvatar: View {
    let initial: String
    let filled: Bool
    let size: CGFloat

    public init(_ initial: String, filled: Bool = false, size: CGFloat = 34) {
        self.initial = initial
        self.filled = filled
        self.size = size
    }

    public var body: some View {
        Text(initial.isEmpty ? "·" : initial)
            .font(.system(size: size * 0.41, weight: .semibold))
            .foregroundStyle(filled ? GB.onInk : GB.ink)
            .frame(width: size, height: size)
            .background(filled ? GB.ink : .clear, in: Circle())
            .overlay(Circle().stroke(GB.ink, lineWidth: filled ? 0 : 1))
    }
}

// MARK: - Page

/// Paper background + horizontal gutter. Wrap every screen's content in it.
public struct GBPage<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, GB.gutter)
                .padding(.bottom, 40)
        }
        .background(GB.paper.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .gbKeyboardDoneButton()
    }
}

/// Hide the keyboard from anywhere (number pads have no return key).
@MainActor public func gbHideKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

public extension View {
    /// "Done" above the keyboard.
    func gbKeyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { gbHideKeyboard() }.fontWeight(.semibold)
            }
        }
    }
}

// MARK: - Info

/// Small "i" that explains something on tap instead of a caption on screen.
public struct GBInfoButton: View {
    let text: String
    @State private var shown = false

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(GB.ink3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Info")
        .popover(isPresented: $shown) {
            Text(text)
                .font(GBFont.secondary)
                .foregroundStyle(GB.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)
                .padding(14)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(GB.paperRaised)
        }
    }
}

// MARK: - Stats

/// Compact tile: label on top, amount below. Used in a row of two or three.
public struct GBStat: View {
    let label: String
    let amount: String
    let tone: GBTone
    let info: String?

    public init(_ label: String, amount: String, tone: GBTone = .neutral, info: String? = nil) {
        self.label = label
        self.amount = amount
        self.tone = tone
        self.info = info
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(label).font(GBFont.secondary).foregroundStyle(GB.ink2).lineLimit(1)
                if let info { GBInfoButton(info) }
            }
            .frame(height: 18)
            GBAmount(amount, tone: tone, font: GBFont.mono(16, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GB.paperRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GB.hairline, lineWidth: 1))
    }
}

/// Round icon-only action, e.g. a checkmark to confirm a row.
public struct GBIconButton: View {
    let systemName: String
    let tone: Color
    let label: String
    let action: () -> Void

    public init(_ systemName: String, tone: Color = GB.ink, label: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.tone = tone
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone)
                .frame(width: 34, height: 34)
                .background(tone.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Cards

/// Raised rounded container for settings-style rows.
public struct GBCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 14)
            .background(GB.paperRaised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(GB.hairline, lineWidth: 1))
    }
}

/// One row in a GBCard: optional icon, title, trailing content.
public struct GBCardRow<Trailing: View>: View {
    let icon: String?
    let title: String
    let tone: Color
    let trailing: Trailing

    public init(_ title: String, icon: String? = nil, tone: Color = GB.ink, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.icon = icon
        self.tone = tone
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(tone).frame(width: 22)
            }
            Text(title).font(GBFont.body).foregroundStyle(tone)
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// Chevron for rows that open something.
public struct GBChevron: View {
    public init() {}
    public var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(GB.ink3)
    }
}

// MARK: - Amount input

/// Large amount entry used at the top of money sheets.
public struct GBAmountField: View {
    @Binding var text: String
    let currency: String

    public init(text: Binding<String>, currency: String) {
        self._text = text
        self.currency = currency
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("0", text: $text)
                .font(GBFont.mono(40, weight: .semibold))
                .foregroundStyle(GB.ink)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: true, vertical: false)
            Text(currencySymbol).font(GBFont.mono(28, weight: .semibold)).foregroundStyle(GB.ink3)
            Spacer(minLength: 0)
        }
    }

    private var currencySymbol: String {
        var l = Locale.Components(locale: .current)
        l.currency = Locale.Currency(currency)
        return Locale(components: l).currencySymbol ?? currency
    }
}
