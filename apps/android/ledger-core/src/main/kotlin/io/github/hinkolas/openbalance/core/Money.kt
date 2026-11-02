package io.github.hinkolas.openbalance.core

import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Locale

/** Display and input of amounts in minor units of a group's currency. */
object Money {
    /** "12,40 €" / "€12.40" in the user's locale. */
    fun format(minor: Long, currency: String, signed: Boolean = false, locale: Locale = Locale.getDefault()): String {
        val exp = Currency.exponent(currency)
        val f = NumberFormat.getCurrencyInstance(locale)
        try {
            f.currency = java.util.Currency.getInstance(currency)
        } catch (_: IllegalArgumentException) {
            return bare(minor, currency, locale) + " " + currency
        }
        f.minimumFractionDigits = exp
        f.maximumFractionDigits = exp
        val text = f.format(BigDecimal.valueOf(minor, exp))
        return if (signed && minor > 0) "+$text" else text
    }

    /**
     * Parse user input like "12,40", "12.4", "1.240,00", "1,240.00", "12" into
     * minor units. The last separator is decimal when at most `exponent`
     * digits follow it; other separators must group thousands. Null for
     * anything else, including negative values.
     */
    fun parse(input: String, currency: String): Long? {
        val exp = Currency.exponent(currency)
        var text = input.trim()
        for (junk in listOf(" ", " ", " ", "'", "€", "$", "£", "¥", currency)) text = text.replace(junk, "")
        if (text.isEmpty() || !text.all { it in '0'..'9' || it == ',' || it == '.' }) return null

        val groups = arrayListOf(StringBuilder())
        val separators = ArrayList<Char>()
        for (ch in text) {
            if (ch == ',' || ch == '.') {
                separators.add(ch)
                groups.add(StringBuilder())
            } else {
                groups.last().append(ch)
            }
        }
        val integerGroups = groups.map { it.toString() }.toMutableList()
        var fraction = ""
        val decimal = separators.lastOrNull()
        val last = integerGroups.last()
        if (separators.isNotEmpty() && exp > 0 && (last.length in 1..exp || (last.isEmpty() && separators.size == 1))) {
            fraction = last
            integerGroups.removeAt(integerGroups.size - 1)
            separators.removeAt(separators.size - 1)
            if (separators.any { it == decimal }) return null
        }
        if (separators.toSet().size > 1) return null
        for (i in 1 until integerGroups.size) if (integerGroups[i].length != 3) return null
        if (integerGroups.size > 1 && (integerGroups[0].isEmpty() || integerGroups[0].length > 3)) return null
        val integerText = integerGroups.joinToString("")
        if ((integerText.isEmpty() && fraction.isEmpty()) || integerText.length > 15) return null
        val whole = if (integerText.isEmpty()) 0L else integerText.toLong()
        val frac = if (fraction.isEmpty()) 0L else fraction.padEnd(exp, '0').toLong()
        var scale = 1L
        repeat(exp) { scale *= 10 }
        val r = try {
            Math.multiplyExact(whole, scale)
        } catch (_: ArithmeticException) {
            return null
        }
        if (r + frac > Ledger.MAX_AMOUNT) return null
        return r + frac
    }

    /** "130.000,00" in the user's locale, without the currency symbol. */
    fun bare(minor: Long, currency: String, locale: Locale = Locale.getDefault()): String = number(minor, currency, locale, grouping = true)

    /** Minor units back to an input string ("12,40" in the user's locale). */
    fun inputString(minor: Long, currency: String, locale: Locale = Locale.getDefault()): String = number(minor, currency, locale, grouping = false)

    private fun number(minor: Long, currency: String, locale: Locale, grouping: Boolean): String {
        val exp = Currency.exponent(currency)
        val f = NumberFormat.getNumberInstance(locale)
        f.isGroupingUsed = grouping
        f.minimumFractionDigits = exp
        f.maximumFractionDigits = exp
        return f.format(BigDecimal.valueOf(minor, exp))
    }

    /** The currency's symbol in the user's locale ("€", "CHF"). */
    fun symbol(currency: String, locale: Locale = Locale.getDefault()): String = try {
        java.util.Currency.getInstance(currency).getSymbol(locale)
    } catch (_: IllegalArgumentException) {
        currency
    }
}

/**
 * Formats an amount while it is typed, so it never jumps when the field is
 * left: "130000" shows as "130.000" (German) or "130,000" (English) as the
 * digits come in. Either "." or "," typed by the user starts the decimals,
 * since grouping is never typed by hand. Display only; [Money.parse] reads
 * the result.
 */
object AmountTyping {
    class Result(val text: String, val cursor: Int)

    /**
     * The field went from [old] to [new] with the cursor at [cursor]. Returns
     * the formatted text and where the cursor goes, or null to keep [new] as
     * typed (anything that isn't a plain amount, e.g. "15%").
     */
    fun next(old: String, new: String, cursor: Int, currency: String, locale: java.util.Locale = java.util.Locale.getDefault()): Result? {
        val symbols = java.text.DecimalFormatSymbols.getInstance(locale)
        val dec = symbols.decimalSeparator
        val grp = symbols.groupingSeparator
        val spaces = setOf(' ', ' ', ' ', '\'')
        if (new.any { !(it in '0'..'9' || it == '.' || it == ',' || it == dec || it == grp || it in spaces) }) return null
        val exp = Currency.exponent(currency)

        // A pasted amount: let the full parser decide.
        if (kotlin.math.abs(new.length - old.length) > 1) {
            val minor = Money.parse(new, currency) ?: return null
            val text = Money.bare(minor, currency, locale).let { if (exp > 0 && it.endsWith(dec + "0".repeat(exp))) it.dropLast(exp + 1) else it }
            return Result(text, text.length)
        }

        var src = new
        var at = cursor.coerceIn(0, new.length)
        // Deleting a grouping separator deletes the digit before it.
        if (new.length == old.length - 1 && at < old.length && old[at] == grp && old.removeRange(at, at + 1) == new && at > 0) {
            src = new.removeRange(at - 1, at)
            at -= 1
        }
        // A typed "." or "," is the decimal separator.
        var decimalAt: Int? = null
        if (new.length == old.length + 1 && at in 1..new.length) {
            val c = new[at - 1]
            if ((c == '.' || c == ',') && new.removeRange(at - 1, at) == old) {
                if (old.contains(dec) || exp == 0) return Result(old, (at - 1).coerceAtMost(old.length))
                decimalAt = at - 1
            }
        }
        if (decimalAt == null && src.contains(dec)) decimalAt = src.indexOf(dec)

        // Digits right of the cursor stay right of it.
        val digitsAfter = src.substring(at.coerceAtMost(src.length)).count { it in '0'..'9' }
        val decAfter = decimalAt != null && decimalAt >= at
        val whole = (if (decimalAt != null) src.substring(0, decimalAt) else src).filter { it in '0'..'9' }
        val frac = if (decimalAt != null) src.substring(decimalAt + 1).filter { it in '0'..'9' }.take(exp) else ""
        val wholeDigits = whole.trimStart('0').ifEmpty { if (whole.isNotEmpty() || decimalAt != null) "0" else "" }.take(15 - exp)
        val grouped = wholeDigits.reversed().chunked(3).joinToString(grp.toString()).reversed()
        val text = grouped + if (decimalAt != null) dec + frac else ""

        // Walk back from the end past the digits that were right of the cursor;
        // if the decimal separator was right of it too, stay left of that.
        var pos = text.length
        var seen = 0
        while (pos > 0 && seen < digitsAfter) {
            pos -= 1
            if (text[pos] in '0'..'9') seen += 1
        }
        if (decAfter) pos = minOf(pos, text.indexOf(dec).takeIf { it >= 0 } ?: pos)
        return Result(text, pos)
    }
}
