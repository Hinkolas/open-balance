import Foundation

/// Display and input of amounts in minor units of a group's currency.
public enum Money {
    /// "12,40 €" / "€12.40" in the user's locale.
    public static func format(_ minor: Int, currency: String, signed: Bool = false, locale: Locale = .current) -> String {
        let exp = Currency.exponent(currency)
        let value = Decimal(minor) / pow(Decimal(10), exp)
        var text = value.formatted(.currency(code: currency).locale(locale).precision(.fractionLength(exp)))
        if signed, minor > 0 { text = "+" + text }
        return text
    }

    /// Parse user input like "12,40", "12.4", "1.240,00", "1,240.00", "12" into
    /// minor units. The last separator is decimal when at most `exponent`
    /// digits follow it; other separators must group thousands. Nil for
    /// anything else, including negative values.
    public static func parse(_ input: String, currency: String) -> Int? {
        let exp = Currency.exponent(currency)
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for junk in [" ", "\u{00A0}", "\u{202F}", "'", "€", "$", "£", "¥", currency] { text = text.replacingOccurrences(of: junk, with: "") }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") }) else { return nil }

        var groups: [String] = [""]
        var separators: [Character] = []
        for ch in text {
            if ch == "," || ch == "." {
                separators.append(ch)
                groups.append("")
            } else {
                groups[groups.count - 1].append(ch)
            }
        }
        var integerGroups = groups
        var fraction = ""
        let decimal = separators.last
        if let last = groups.last, !separators.isEmpty, exp > 0, (1...exp).contains(last.count) || (last.isEmpty && separators.count == 1) {
            fraction = last
            integerGroups.removeLast()
            separators.removeLast()
            if separators.contains(where: { $0 == decimal }) { return nil }
        }
        guard Set(separators).count <= 1 else { return nil }
        for (i, g) in integerGroups.enumerated() where i > 0 {
            guard g.count == 3 else { return nil }
        }
        if integerGroups.count > 1, integerGroups[0].isEmpty || integerGroups[0].count > 3 { return nil }
        let integerText = integerGroups.joined()
        guard !(integerText.isEmpty && fraction.isEmpty), integerText.count <= 15 else { return nil }
        let whole = Int(integerText.isEmpty ? "0" : integerText) ?? 0
        let frac = Int(fraction.isEmpty ? "0" : fraction.padding(toLength: exp, withPad: "0", startingAt: 0)) ?? 0
        var scale = 1
        for _ in 0..<exp { scale *= 10 }
        let (r, overflow) = whole.multipliedReportingOverflow(by: scale)
        guard !overflow, r + frac <= Ledger.maxAmount else { return nil }
        return r + frac
    }

    /// "130.000,00" in the user's locale, without the currency symbol.
    public static func bare(_ minor: Int, currency: String, locale: Locale = .current) -> String {
        let exp = Currency.exponent(currency)
        let value = Decimal(minor) / pow(Decimal(10), exp)
        return value.formatted(.number.precision(.fractionLength(exp)).locale(locale))
    }

    /// Minor units back to an input string ("12,40" in the user's locale).
    public static func inputString(_ minor: Int, currency: String, locale: Locale = .current) -> String {
        let exp = Currency.exponent(currency)
        let value = Decimal(minor) / pow(Decimal(10), exp)
        return value.formatted(.number.precision(.fractionLength(exp)).grouping(.never).locale(locale))
    }
}
