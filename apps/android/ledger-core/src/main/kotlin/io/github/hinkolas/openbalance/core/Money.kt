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
