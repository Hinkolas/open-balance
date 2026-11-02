package io.github.hinkolas.openbalance.core

import java.math.BigInteger

/** floor(a·b / c) and (a·b) mod c without overflow: the 128-bit intermediate of §9. a, b ≥ 0, c > 0. */
internal fun mulDiv(a: Long, b: Long, c: Long): Pair<Long, Long> {
    val qr = BigInteger.valueOf(a).multiply(BigInteger.valueOf(b)).divideAndRemainder(BigInteger.valueOf(c))
    return qr[0].longValueExact() to qr[1].longValueExact()
}

/** Balance math (PROTOCOL.md §9). Exact integers, 128-bit intermediates. */
object Balances {
    /**
     * Largest remainder (§9.1): split [total] over integer weights.
     * Ties go to the smaller member id.
     */
    fun distribute(total: Long, weights: Map<MemberId, Long>): Map<MemberId, Long> {
        val w = weights.values.sum()
        require(total >= 0 && w > 0) { "distribute needs total >= 0 and positive weight sum" }
        val result = LinkedHashMap<MemberId, Long>()
        val rows = ArrayList<Pair<MemberId, Long>>()
        var assigned = 0L
        for ((id, weight) in weights) {
            val (q, r) = mulDiv(total, weight, w)
            result[id] = q
            assigned += q
            rows.add(id to r)
        }
        rows.sortWith(compareByDescending<Pair<MemberId, Long>> { it.second }.thenComparing({ it.first }, memberIdOrder))
        for (row in rows.take((total - assigned).toInt())) result[row.first] = result.getValue(row.first) + 1
        return result
    }

    /** What one payment contributes (§9.2). */
    data class PaymentEffect(
        /** What has arrived at each receiver (in side). */
        val held: Map<MemberId, Long>,
        /** What counts as owned so far (out side). */
        val owned: Map<MemberId, Long>,
    ) {
        val arrived: Long get() = held.values.sum()
    }

    fun effect(p: Payment, arrivals: List<Arrival>): PaymentEffect {
        val held = LinkedHashMap<MemberId, Long>()
        for (line in p.inSide.lines) {
            held[line.member] = if (p.track) {
                minOf(line.amount, arrivals.filter { it.member == line.member }.sumOf { it.amount })
            } else {
                line.amount
            }
        }
        val weights = LinkedHashMap<MemberId, Long>()
        for (l in p.outSide.lines) weights[l.member] = l.amount
        return PaymentEffect(held, distribute(held.values.sum(), weights))
    }

    data class Transfer(val from: MemberId, val to: MemberId, val amount: Long)

    data class Summary(
        /** > 0: the group owes this member. < 0: the member owes the group. */
        val balances: Map<MemberId, Long>,
        /** Money a member is still expecting to own once it arrives. */
        val pendingOwned: Map<MemberId, Long>,
        /** Money still expected to arrive at a member. */
        val pendingHeld: Map<MemberId, Long>,
        val transfers: List<Transfer>,
        /** §9.4: the balance once every tracked payment has fully arrived. */
        val expected: Map<MemberId, Long>,
        /** §9.4: who pays whom once everything has arrived. The plan to settle by. */
        val expectedTransfers: List<Transfer>,
        /** §9.5: the part of each expected transfer that can be paid today. */
        val payNow: List<Transfer>,
    ) {
        /** What [from] can pay [to] today out of their expected transfer. */
        fun payableNow(from: MemberId, to: MemberId): Long = payNow.firstOrNull { it.from == from && it.to == to }?.amount ?: 0
    }

    /** Payments must already be valid; [arrivals] are the live arrivals per payment. */
    fun summarize(members: List<MemberId>, payments: List<Payment>, arrivals: Map<PaymentId, List<Arrival>>): Summary {
        val balances = LinkedHashMap<MemberId, Long>()
        val pendingOwned = LinkedHashMap<MemberId, Long>()
        val pendingHeld = LinkedHashMap<MemberId, Long>()
        // §9.5: per member, the sum of each payment's pending effect that
        // raises (up) or lowers (down) their balance once it arrives.
        val up = HashMap<MemberId, Long>()
        val down = HashMap<MemberId, Long>()
        for (m in members) {
            balances[m] = 0
            pendingOwned[m] = 0
            pendingHeld[m] = 0
        }
        fun MutableMap<MemberId, Long>.add(m: MemberId, v: Long) {
            this[m] = (this[m] ?: 0) + v
        }
        for (p in payments) {
            val e = effect(p, arrivals[p.id] ?: emptyList())
            val pending = LinkedHashMap<MemberId, Long>()
            for (line in p.outSide.lines) {
                val owned = e.owned[line.member] ?: 0
                balances.add(line.member, owned)
                pendingOwned.add(line.member, line.amount - owned)
                pending.add(line.member, line.amount - owned)
            }
            for (line in p.inSide.lines) {
                val held = e.held[line.member] ?: 0
                balances.add(line.member, -held)
                pendingHeld.add(line.member, line.amount - held)
                pending.add(line.member, -(line.amount - held))
            }
            for ((m, d) in pending) {
                if (d > 0) up.add(m, d) else down.add(m, d)
            }
        }
        val expected = LinkedHashMap<MemberId, Long>()
        for ((m, b) in balances) expected[m] = b + (pendingOwned[m] ?: 0) - (pendingHeld[m] ?: 0)
        val expectedTransfers = transfers(expected)
        val owes = HashMap<MemberId, Long>()
        val owed = HashMap<MemberId, Long>()
        for ((m, b) in balances) {
            owes[m] = maxOf(0, -(b + (up[m] ?: 0)))
            owed[m] = maxOf(0, b + (down[m] ?: 0))
        }
        return Summary(
            balances = balances,
            pendingOwned = pendingOwned,
            pendingHeld = pendingHeld,
            transfers = transfers(balances),
            expected = expected,
            expectedTransfers = expectedTransfers,
            payNow = payNow(owes, owed, expectedTransfers),
        )
    }

    /**
     * Pay now (§9.5): each planned transfer, capped by the least the payer
     * can end up owing and the receiver can end up being owed.
     */
    internal fun payNow(owesIn: Map<MemberId, Long>, owedIn: Map<MemberId, Long>, plan: List<Transfer>): List<Transfer> {
        val owes = HashMap(owesIn)
        val owed = HashMap(owedIn)
        val out = ArrayList<Transfer>()
        for (t in plan) {
            val now = minOf(t.amount, owes[t.from] ?: 0, owed[t.to] ?: 0)
            if (now <= 0) continue
            owes[t.from] = owes.getValue(t.from) - now
            owed[t.to] = owed.getValue(t.to) - now
            out.add(Transfer(t.from, t.to, now))
        }
        return out
    }

    /** Who pays whom (§9.3): largest debtor pays largest creditor, ties by id. */
    fun transfers(balances: Map<MemberId, Long>): List<Transfer> {
        class Entry(val id: MemberId, var amount: Long)
        val debtors = balances.filter { it.value < 0 }.map { Entry(it.key, -it.value) }.toMutableList()
        val creditors = balances.filter { it.value > 0 }.map { Entry(it.key, it.value) }.toMutableList()
        val order = compareByDescending<Entry> { it.amount }.thenComparing({ it.id }, memberIdOrder)
        val out = ArrayList<Transfer>()
        while (debtors.isNotEmpty() && creditors.isNotEmpty()) {
            debtors.sortWith(order)
            creditors.sortWith(order)
            val amount = minOf(debtors[0].amount, creditors[0].amount)
            out.add(Transfer(debtors[0].id, creditors[0].id, amount))
            debtors[0].amount -= amount
            creditors[0].amount -= amount
            debtors.removeAll { it.amount == 0L }
            creditors.removeAll { it.amount == 0L }
        }
        return out
    }
}

/** Balances, pending money and the settle-up plan of the current state. */
fun LedgerState.summary(): Balances.Summary {
    val byPayment = HashMap<PaymentId, MutableList<Arrival>>()
    for (a in arrivals.values) if (!a.removed) byPayment.getOrPut(a.payment) { ArrayList() }.add(a)
    return Balances.summarize(memberOrder, livePayments.map { it.payment }, byPayment)
}
