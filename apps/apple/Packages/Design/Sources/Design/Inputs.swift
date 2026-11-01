import SwiftUI

/// Bordered text field on raised paper. `keyboard` is ignored on macOS.
public struct GBTextField: View {
    let placeholder: String
    @Binding var text: String
    let keyboard: GBKeyboard
    let mono: Bool

    public enum GBKeyboard { case `default`, decimalPad, email, name, numbers }

    public init(_ placeholder: String, text: Binding<String>, keyboard: GBKeyboard = .default, mono: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.keyboard = keyboard
        self.mono = mono
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .font(mono ? GBFont.mono(16) : GBFont.body)
            .foregroundStyle(GB.ink)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(GB.paperRaised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(GB.hairline, lineWidth: 1))
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(keyboard == .email ? .never : (keyboard == .name ? .words : .sentences))
            #endif
    }

    #if os(iOS)
    private var keyboardType: UIKeyboardType {
        switch keyboard {
        case .default, .name: .default
        case .decimalPad: .decimalPad
        case .email: .emailAddress
        case .numbers: .numbersAndPunctuation
        }
    }
    #endif
}

/// Square member chip ("A", "L", "J") that toggles. Matches the receipt chips in the design.
public struct GBMemberChip: View {
    let initial: String
    let selected: Bool
    let action: () -> Void

    public init(_ initial: String, selected: Bool, action: @escaping () -> Void) {
        self.initial = initial
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(initial)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? GB.onInk : GB.ink2)
                .frame(width: GB.chip, height: GB.chip)
                .background(selected ? GB.ink : GB.paperRaised, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? GB.ink : GB.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: selected)
    }
}

/// Pill-shaped selectable label (payer, mode).
public struct GBChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    public init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? GB.onInk : GB.ink)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(selected ? GB.ink : GB.paperRaised, in: Capsule())
                .overlay(Capsule().stroke(selected ? GB.ink : GB.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Outlined secondary button.
public struct GBSecondaryButton: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GB.ink)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(GB.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
