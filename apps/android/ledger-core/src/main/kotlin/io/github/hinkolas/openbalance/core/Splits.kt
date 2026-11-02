package io.github.hinkolas.openbalance.core

/**
 * Form helpers that turn what the user entered into line amounts. Only the
 * resulting amounts are authoritative (PROTOCOL.md §7.4), so these may differ
 * between platforms without affecting balances.
 */
object Splits {
    /** Equal split among [members]. */
    fun equal(amount: Long, members: List<MemberId>): Map<MemberId, Long> {
        if (members.isEmpty()) return emptyMap()
        return Balances.distribute(amount, members.associateWith { 1L })
    }

    /** Proportional to integer weights. Null if all weights are zero. */
    fun shares(amount: Long, weights: Map<MemberId, Long>): Map<MemberId, Long>? {
        if (weights.values.any { it < 0 } || weights.values.sum() <= 0) return null
        return Balances.distribute(amount, weights)
    }

    /**
     * Percent in basis points. With [rest], fixed lines get floor(amount·bp/10000)
     * and the rest line absorbs what is left. Without, percents must sum to 100 %.
     */
    fun percent(amount: Long, basisPoints: Map<MemberId, Long>, rest: MemberId?): Map<MemberId, Long>? {
        val total = basisPoints.values.sum()
        if (basisPoints.values.any { it < 0 }) return null
        if (rest != null) {
            if (total > 10_000) return null
            val out = LinkedHashMap<MemberId, Long>()
            var assigned = 0L
            for ((id, bp) in basisPoints) {
                if (id == rest) continue
                val q = mulDiv(amount, bp, 10_000).first
                out[id] = q
                assigned += q
            }
            out[rest] = amount - assigned
            return out
        }
        if (total != 10_000L) return null
        return Balances.distribute(amount, basisPoints)
    }
}
