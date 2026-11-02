package io.github.hinkolas.openbalance.core

import java.math.BigInteger
import java.util.Locale

/**
 * The per-member inputs of one payment side ("arrived at" or "belongs to")
 * and how they resolve to exact amounts. Only the resolved amounts are
 * stored as authoritative line amounts (PROTOCOL.md §7.4); the inputs come
 * back as editing hints (`value` = basis points, `rest`).
 *
 * Every field takes an amount ("20.000"), a percentage ("15%") or nothing.
 * The rest member gets what is left: the explicitly chosen one, otherwise
 * the only empty field. Other empty fields are zero. With every field
 * empty, [Fallback] decides.
 */
data class SplitForm(
    val text: Map<MemberId, String> = emptyMap(),
    /** Chosen explicitly ("rest to …"); cleared when its field is typed into. */
    val rest: MemberId? = null,
) {
    sealed interface Fallback {
        /** Everything to one member. */
        data class All(val member: MemberId) : Fallback

        /** The same amounts as another side ("as received"). */
        data class Copy(val amounts: Map<MemberId, Long>) : Fallback

        /** Equal split among these members. */
        data class Equal(val members: List<MemberId>) : Fallback

        data object None : Fallback
    }

    sealed interface Field {
        data object Empty : Field
        data class Amount(val value: Long) : Field
        data class Percent(val basisPoints: Long) : Field
        data object Invalid : Field
    }

    data class Resolution(
        /** Exact amount per member, null while the inputs don't add up. */
        val amounts: Map<MemberId, Long>? = null,
        /** What each member's field resolves to, for placeholders and captions. */
        val preview: Map<MemberId, Long> = emptyMap(),
        val restMember: MemberId? = null,
        /** amount − assigned when there is no rest member: > 0 still to distribute, < 0 too much. */
        val leftover: Long = 0,
        val usedFallback: Boolean = false,
        val invalid: List<MemberId> = emptyList(),
    )

    fun field(m: MemberId, currency: String): Field = parse(text[m] ?: "", currency)

    fun resolve(amount: Long, members: List<MemberId>, currency: String, fallback: Fallback): Resolution {
        val fields = members.associateWith { field(it, currency) }
        val invalid = members.filter { fields[it] == Field.Invalid }
        val r = Resolution(invalid = invalid)
        if (amount <= 0 || invalid.isNotEmpty()) return r

        if (members.all { fields[it] == Field.Empty } && rest == null) {
            val all: Map<MemberId, Long> = when (fallback) {
                is Fallback.All -> if (fallback.member in members) mapOf(fallback.member to amount) else null
                is Fallback.Copy -> if (fallback.amounts.values.sum() == amount) fallback.amounts else null
                is Fallback.Equal -> if (fallback.members.isEmpty()) null else Splits.equal(amount, fallback.members.filter { it in members })
                Fallback.None -> null
            } ?: return r
            return r.copy(usedFallback = true, preview = all, amounts = members.associateWith { all[it] ?: 0 })
        }

        val out = LinkedHashMap<MemberId, Long>()
        val percentRows = ArrayList<Pair<MemberId, Long>>()
        for (m in members) {
            when (val f = fields.getValue(m)) {
                is Field.Amount -> out[m] = f.value
                is Field.Percent -> {
                    val (q, rem) = mulDiv(amount, f.basisPoints, 10_000)
                    out[m] = q
                    percentRows.add(m to rem)
                }
                else -> out[m] = 0
            }
        }
        val empties = members.filter { fields[it] == Field.Empty }
        val restMember = rest?.takeIf { it in members && fields[it] == Field.Empty } ?: empties.singleOrNull()
        val assigned = out.values.sum()
        val preview = LinkedHashMap(out)
        if (restMember != null) {
            val left = amount - assigned
            preview[restMember] = maxOf(left, 0)
            if (left < 0) return r.copy(preview = preview, restMember = restMember, leftover = left)
            out[restMember] = left
            return r.copy(preview = preview, restMember = restMember, amounts = out)
        }
        var left = amount - assigned
        // Percentages that add up to 100 % lose cents to rounding: hand those
        // out by largest remainder instead of asking for them.
        val exactSum = members.sumOf { (fields[it] as? Field.Amount)?.value ?: 0 }
        val percentSum = members.sumOf { (fields[it] as? Field.Percent)?.basisPoints ?: 0 }
        // Exactly: Σ amount·bp/10000 == amount − exact amounts.
        val exact = BigInteger.valueOf(amount - exactSum).multiply(BigInteger.valueOf(10_000)) ==
            BigInteger.valueOf(amount).multiply(BigInteger.valueOf(percentSum))
        var finalPreview: Map<MemberId, Long> = preview
        if (left > 0 && left < percentRows.size && exact) {
            val sorted = percentRows.sortedWith(compareByDescending<Pair<MemberId, Long>> { it.second }.thenComparing({ it.first }, memberIdOrder))
            for (row in sorted.take(left.toInt())) out[row.first] = out.getValue(row.first) + 1
            left = 0
            finalPreview = LinkedHashMap(out)
        }
        return r.copy(preview = finalPreview, leftover = left, amounts = if (left == 0L) out else null)
    }

    companion object {
        fun parse(raw: String, currency: String): Field {
            var t = raw.trim()
            // A bare "%" is a percentage not typed yet (the Android % toggle).
            if (t.isEmpty() || t == "%") return Field.Empty
            if (t.endsWith("%")) {
                t = t.dropLast(1)
                val bp = Money.parse(t, "EUR") ?: return Field.Invalid
                return if (bp <= 10_000) Field.Percent(bp) else Field.Invalid
            }
            return Money.parse(t, currency)?.let { Field.Amount(it) } ?: Field.Invalid
        }

        /** Lines for a payment side: members with an amount, with editing hints. */
        fun lines(amounts: Map<MemberId, Long>, order: List<MemberId>, form: SplitForm, resolution: Resolution, currency: String): List<Payment.Line> =
            order.mapNotNull { m ->
                val a = amounts[m] ?: 0
                if (a <= 0) return@mapNotNull null
                if (resolution.usedFallback) return@mapNotNull Payment.Line(m, a)
                val f = form.field(m, currency)
                Payment.Line(
                    member = m,
                    amount = a,
                    value = (f as? Field.Percent)?.basisPoints,
                    rest = if (resolution.restMember == m) true else null,
                )
            }

        /** Rebuild the inputs from a stored side. */
        fun fromSide(side: Payment.Side, currency: String, locale: Locale = Locale.getDefault()): SplitForm {
            val text = LinkedHashMap<MemberId, String>()
            var rest: MemberId? = null
            for (l in side.lines) {
                val bp = l.value
                if (l.rest == true) {
                    rest = l.member
                } else if (bp != null && (side.mode == "mixed" || side.mode == "percent")) {
                    text[l.member] = (if (bp % 100 == 0L) "${bp / 100}" else Money.bare(bp, "EUR", locale)) + "%"
                } else if (l.amount > 0) {
                    text[l.member] = Money.bare(l.amount, currency, locale)
                }
            }
            return SplitForm(text, rest)
        }
    }
}
