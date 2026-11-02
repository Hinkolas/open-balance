package io.github.hinkolas.openbalance.core

import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SplitFormTests {
    private val members = listOf("initech", "globex", "acme")
    private val de = Locale.GERMANY

    @Test
    fun receivedAndOwnedLikeTheExample() {
        // 130.000 arrive: Initech 90.000, Acme 40.000, Globex nothing (only empty field → rest = 0).
        val received = SplitForm(mapOf("initech" to "90.000", "acme" to "40.000"))
        val r = received.resolve(13_000_000, members, "EUR", SplitForm.Fallback.All("initech"))
        assertEquals(mapOf("initech" to 9_000_000L, "acme" to 4_000_000L, "globex" to 0L), r.amounts)
        assertEquals("globex", r.restMember)

        // Belongs: Globex 15 %, Acme 20.000, Initech the rest.
        val owned = SplitForm(mapOf("globex" to "15%", "acme" to "20.000"))
        val o = owned.resolve(13_000_000, members, "EUR", SplitForm.Fallback.Copy(r.amounts!!))
        assertEquals(mapOf("globex" to 1_950_000L, "acme" to 2_000_000L, "initech" to 9_050_000L), o.amounts)
        assertEquals("initech", o.restMember)

        val lines = SplitForm.lines(o.amounts!!, members, owned, o, "EUR")
        assertEquals(
            listOf(Payment.Line("initech", 9_050_000, rest = true), Payment.Line("globex", 1_950_000, value = 1500), Payment.Line("acme", 2_000_000)),
            lines,
        )

        // Reopening gives the same inputs back.
        val back = SplitForm.fromSide(Payment.Side("mixed", lines), "EUR", de)
        assertEquals("initech", back.rest)
        assertEquals(mapOf("globex" to "15%", "acme" to "20.000,00"), back.text)
        assertEquals(o.amounts, back.resolve(13_000_000, members, "EUR", SplitForm.Fallback.None).amounts)
    }

    @Test
    fun fallbacks() {
        val empty = SplitForm()
        assertEquals(mapOf("initech" to 900L, "globex" to 0L, "acme" to 0L), empty.resolve(900, members, "EUR", SplitForm.Fallback.All("initech")).amounts)
        assertEquals(mapOf("initech" to 300L, "globex" to 300L, "acme" to 300L), empty.resolve(900, members, "EUR", SplitForm.Fallback.Equal(members)).amounts)
        assertEquals(mapOf("acme" to 900L, "initech" to 0L, "globex" to 0L), empty.resolve(900, members, "EUR", SplitForm.Fallback.Copy(mapOf("acme" to 900L))).amounts)
    }

    @Test
    fun leftoverAndTooMuch() {
        // Two empty fields and no explicit rest: 500 still to distribute.
        var f = SplitForm(mapOf("initech" to "4"))
        var r = f.resolve(900, members, "EUR", SplitForm.Fallback.None)
        assertNull(r.amounts)
        assertEquals(500L, r.leftover)
        f = f.copy(rest = "acme")
        r = f.resolve(900, members, "EUR", SplitForm.Fallback.None)
        assertEquals(mapOf("initech" to 400L, "globex" to 0L, "acme" to 500L), r.amounts)

        val over = SplitForm(mapOf("initech" to "10", "globex" to "5"))
        val o = over.resolve(900, members, "EUR", SplitForm.Fallback.None)
        assertNull(o.amounts)
        assertEquals(-600L, o.leftover)
    }

    @Test
    fun percentRoundingIsAbsorbed() {
        val f = SplitForm(mapOf("initech" to "50%", "globex" to "50%", "acme" to "0"))
        assertEquals(mapOf("initech" to 50L, "globex" to 51L, "acme" to 0L), f.resolve(101, members, "EUR", SplitForm.Fallback.None).amounts)
        val thirds = SplitForm(mapOf("initech" to "33,34%", "globex" to "33,33%", "acme" to "33,33%"))
        assertEquals(100L, thirds.resolve(100, members, "EUR", SplitForm.Fallback.None).amounts?.values?.sum())
    }

    @Test
    fun invalidInput() {
        val f = SplitForm(mapOf("initech" to "abc"))
        assertEquals(listOf("initech"), f.resolve(100, members, "EUR", SplitForm.Fallback.None).invalid)
        assertEquals(SplitForm.Field.Invalid, SplitForm.parse("120%", "EUR"))
    }
}

class AmountTypingTests {
    private val de = Locale.GERMANY
    private val en = Locale.US

    /** Type [keys] one by one at the end, like a user would. */
    private fun type(keys: String, locale: Locale, currency: String = "EUR"): String {
        var text = ""
        for (k in keys) {
            val r = if (k == '<') {
                AmountTyping.next(text, text.dropLast(1), text.length - 1, currency, locale)
            } else {
                AmountTyping.next(text, text + k, text.length + 1, currency, locale)
            }
            text = r?.text ?: (text + k)
        }
        return text
    }

    @Test
    fun groupsAsYouType() {
        assertEquals("130.000", type("130000", de))
        assertEquals("130,000", type("130000", en))
        assertEquals(13_000_000L, Money.parse(type("130000", de), "EUR"))
        assertEquals(13_000_000L, Money.parse(type("130000", en), "EUR"))
    }

    @Test
    fun eitherSeparatorStartsTheCents() {
        assertEquals("1.234,5", type("1234.5", de))
        assertEquals("1.234,56", type("1234,567", de))
        assertEquals("1,234.56", type("1234,56", en))
        assertEquals(123_456L, Money.parse(type("1234.56", de), "EUR"))
        assertEquals("0,", type(",", de))
        assertEquals("1.500", type("1.500", de, "JPY").let { type("1500", de, "JPY") })
    }

    @Test
    fun deletingWorks() {
        assertEquals("123", type("1234<", de))
        assertEquals("12,3", type("12,34<", de))
        // Backspace over a grouping separator removes the digit before it.
        val r = AmountTyping.next("1.234", "1234", 1, "EUR", de)!!
        assertEquals("234", r.text)
    }

    @Test
    fun cursorStaysBeforeTheSameDigits() {
        // "1.234" with the cursor before "234"; typing 9 there gives "19.234" with the cursor before "234".
        val r = AmountTyping.next("1.234", "19.234", 2, "EUR", de)!!
        assertEquals("19.234", r.text)
        assertEquals(3, r.cursor)
    }

    @Test
    fun percentagesStayAsTyped() {
        assertNull(AmountTyping.next("15", "15%", 3, "EUR", de))
        assertEquals("33,33", type("33,33", de))
    }

    @Test
    fun editingAStoredAmountKeepsIt() {
        assertEquals("130.000,00", AmountTyping.next("130.000,0", "130.000,00", 10, "EUR", de)!!.text)
    }
}
