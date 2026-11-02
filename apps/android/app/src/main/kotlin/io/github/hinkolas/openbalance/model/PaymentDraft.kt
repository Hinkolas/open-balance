package io.github.hinkolas.openbalance.model

import io.github.hinkolas.openbalance.core.Balances
import io.github.hinkolas.openbalance.core.LedgerState
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Money
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.core.PaymentId
import io.github.hinkolas.openbalance.core.PaymentRecord
import io.github.hinkolas.openbalance.core.SplitForm
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.lower
import java.time.LocalDate

/**
 * What the payment flow edits. Income, expense and settle up are presets
 * over one payment (PROTOCOL.md §7.4): two sides with an exact amount per
 * member, resolved from amounts, percentages and a rest.
 */
data class PaymentDraft(
    val kind: Payment.Kind = Payment.Kind.Income,
    val amount: String = "",
    val title: String = "",
    val note: String = "",
    val date: LocalDate = LocalDate.now(),
    /** in: who received the money (income) / who it was for (expense). */
    val received: SplitForm = SplitForm(),
    /** out: whom it belongs to (income) / who paid (expense). */
    val owned: SplitForm = SplitForm(),
    val settleFrom: MemberId? = null,
    val settleTo: MemberId? = null,
    /** Set when editing. */
    val existing: PaymentId? = null,
    val base: String? = null,
) {
    fun amountMinor(state: LedgerState): Long? = Money.parse(amount, state.currency)?.takeIf { it > 0 }

    fun receivedResolution(state: LedgerState, me: MemberId): SplitForm.Resolution {
        val members = members(state, me)
        val fallback = if (kind == Payment.Kind.Expense) SplitForm.Fallback.Equal(members) else SplitForm.Fallback.All(me)
        return received.resolve(amountMinor(state) ?: 0, members, state.currency, fallback)
    }

    fun ownedResolution(state: LedgerState, me: MemberId): SplitForm.Resolution {
        val fallback = if (kind == Payment.Kind.Expense) {
            SplitForm.Fallback.All(me)
        } else {
            receivedResolution(state, me).amounts?.let { SplitForm.Fallback.Copy(it) } ?: SplitForm.Fallback.None
        }
        return owned.resolve(amountMinor(state) ?: 0, members(state, me), state.currency, fallback)
    }

    val hasTitle: Boolean get() = kind == Payment.Kind.Settlement || title.isNotBlank()

    /** The payment to store, or null while something doesn't add up. [settleTitle] is "Settle up" in the user's language. */
    fun build(state: LedgerState, me: MemberId, settleTitle: String): Payment? {
        val amount = amountMinor(state) ?: return null
        if (!hasTitle) return null
        val currency = state.currency
        val order = state.memberOrder
        var title = title.trim()
        val inSide: Payment.Side
        val outSide: Payment.Side
        if (kind == Payment.Kind.Settlement) {
            val from = settleFrom ?: return null
            val to = settleTo ?: return null
            if (from == to) return null
            inSide = Payment.Side("exact", listOf(Payment.Line(to, amount)))
            outSide = Payment.Side("exact", listOf(Payment.Line(from, amount)))
            if (title.isEmpty()) title = settleTitle
        } else {
            val r = receivedResolution(state, me)
            val o = ownedResolution(state, me)
            val ra = r.amounts ?: return null
            val oa = o.amounts ?: return null
            inSide = Payment.Side("mixed", SplitForm.lines(ra, order, received, r, currency))
            outSide = Payment.Side("mixed", SplitForm.lines(oa, order, owned, o, currency))
        }
        if (inSide.lines.isEmpty() || outSide.lines.isEmpty()) return null
        val note = note.trim()
        return Payment(
            id = existing ?: Uuids.v7().lower,
            kind = kind,
            title = title.take(200),
            note = note.ifEmpty { null }?.take(2000),
            date = Dates.string(date),
            amount = amount,
            track = kind != Payment.Kind.Expense,
            inSide = inSide,
            outSide = outSide,
            base = if (existing == null) null else base,
        )
    }

    companion object {
        /** You first, then everyone else in the order they joined. */
        fun members(state: LedgerState, me: MemberId): List<MemberId> = listOf(me) + state.memberOrder.filter { it != me }

        fun new(kind: Payment.Kind, state: LedgerState, me: MemberId) =
            PaymentDraft(kind = kind, settleFrom = me, settleTo = state.memberOrder.firstOrNull { it != me })

        /** Settle a suggested transfer: `from` pays `to`. */
        fun settle(t: Balances.Transfer, state: LedgerState) = PaymentDraft(
            kind = Payment.Kind.Settlement,
            amount = Money.bare(t.amount, state.currency),
            settleFrom = t.from,
            settleTo = t.to,
        )

        fun edit(r: PaymentRecord, state: LedgerState): PaymentDraft {
            val p = r.payment
            val currency = state.currency
            return PaymentDraft(
                kind = p.displayKind,
                amount = Money.bare(p.amount, currency),
                title = p.title,
                note = p.note ?: "",
                date = Dates.parse(p.date) ?: LocalDate.now(),
                received = SplitForm.fromSide(p.inSide, currency),
                owned = SplitForm.fromSide(p.outSide, currency),
                settleFrom = p.outSide.lines.firstOrNull()?.member,
                settleTo = p.inSide.lines.firstOrNull()?.member,
                existing = p.id,
                base = r.lastEventId.lower,
            )
        }
    }
}
