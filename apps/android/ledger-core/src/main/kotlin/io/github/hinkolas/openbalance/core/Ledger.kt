package io.github.hinkolas.openbalance.core

import java.text.BreakIterator
import java.util.Locale
import java.util.UUID

/** An event as the server returns it. */
class RawEvent(val seq: Long, val id: UUID, val blob: ByteArray, val receivedAt: String? = null)

/**
 * Why an event changed nothing (PROTOCOL.md §8.1). Every client reports the
 * same reason for the same event.
 */
enum class Rejection(val code: String) {
    Decrypt("decrypt"),
    Malformed("malformed"),
    UnknownAuthor("unknown_author"),
    BadSignature("bad_signature"),
    Forbidden("forbidden"),
    InvalidData("invalid_data"),
    UnknownTarget("unknown_target"),
    DuplicateId("duplicate_id"),
    Misplaced("misplaced"),
    AlreadyClaimed("already_claimed"),
    BadInviteSig("bad_invite_sig"),
    BadRecoverySig("bad_recovery_sig"),
}

/** Why the server's history can't be trusted (§6.4, §7.1). The app words it. */
sealed interface Inconsistency {
    /** The server skipped events. */
    data class Gap(val expected: Long, val got: Long) : Inconsistency

    /** A member saw a different history at [seq]: the server may be forking. */
    data class Fork(val memberName: String?, val seq: Long) : Inconsistency

    /** Event 1 is not a valid `group.created`. */
    data object BadGenesis : Inconsistency
}

data class Member(
    val id: MemberId,
    val name: String,
    /**
     * Public keys of the member's devices, in the order they joined. Empty
     * while unclaimed. Every key writes as the member (§3.2); removed keys
     * are gone from here.
     */
    val keys: List<Bytes> = emptyList(),
    /** Current invite public key while unclaimed. */
    val inviteKey: Bytes? = null,
    /** Pending invites for further devices (§7.3). */
    val deviceInvites: List<Bytes> = emptyList(),
    val isAdmin: Boolean,
) {
    val isClaimed: Boolean get() = keys.isNotEmpty()

    /** The first user-perceived character, uppercased. */
    val initial: String
        get() {
            if (name.isEmpty()) return "·"
            val it = BreakIterator.getCharacterInstance()
            it.setText(name)
            val end = it.next().takeIf { e -> e != BreakIterator.DONE } ?: name.length
            return name.substring(0, end).uppercase(Locale.getDefault())
        }
}

data class PaymentRecord(
    val payment: Payment,
    val creator: MemberId,
    val createdAt: String,
    val lastEditor: MemberId? = null,
    val lastEventId: UUID,
    val editedConcurrently: Boolean = false,
    val deleted: Boolean = false,
) {
    val id: PaymentId get() = payment.id
}

data class Arrival(
    val id: ArrivalId,
    val payment: PaymentId,
    val member: MemberId,
    val amount: Long,
    val author: MemberId,
    val at: String,
    val removed: Boolean = false,
)

/** One line of the history: every event, valid or not, in ledger order. */
data class HistoryItem(
    val seq: Long?,
    val eventId: UUID,
    val author: MemberId? = null,
    val at: String? = null,
    val data: EventData? = null,
    val rejection: Rejection? = null,
    /** Not yet confirmed by the server (optimistic). */
    val pending: Boolean = false,
)

/**
 * The state of a group, rebuilt by replaying its ledger. Only [Ledger]
 * mutates it; everything published to the UI is a [snapshot].
 */
class LedgerState(val groupId: UUID) {
    var name: String = ""
        internal set
    var currency: String = "EUR"
        internal set
    var adminId: MemberId? = null
        internal set
    /** The current public recovery key (§3.4). */
    var recoveryKey: Bytes? = null
        internal set
    /** Set when the server's history can't be trusted (§6.4) or seq 1 is not a valid group.created. */
    var inconsistency: Inconsistency? = null
        internal set

    internal val membersMut = LinkedHashMap<MemberId, Member>()
    internal val memberOrderMut = ArrayList<MemberId>()
    internal val paymentsMut = LinkedHashMap<PaymentId, PaymentRecord>()
    internal val paymentOrderMut = ArrayList<PaymentId>()
    internal val arrivalsMut = LinkedHashMap<ArrivalId, Arrival>()
    internal val historyMut = ArrayList<HistoryItem>()
    /** chains[n] = chain_n; chains[0] is zero. */
    internal val chainsMut = arrayListOf(Bytes(LedgerCrypto.chainZero))
    internal val seenIdsMut = HashSet<UUID>()
    /** Every key any valid event introduced; none may appear again (§7.3). */
    internal val usedKeysMut = HashSet<Bytes>()
    /** Member keys removed by `member.device_removed` or `member.recovered`. */
    internal val removedKeysMut = HashSet<Bytes>()
    /** When each member key joined, as the writer's `at` (display only). */
    internal val keyAddedAtMut = HashMap<Bytes, String>()

    val members: Map<MemberId, Member> get() = membersMut
    val memberOrder: List<MemberId> get() = memberOrderMut
    val payments: Map<PaymentId, PaymentRecord> get() = paymentsMut
    val paymentOrder: List<PaymentId> get() = paymentOrderMut
    val arrivals: Map<ArrivalId, Arrival> get() = arrivalsMut
    val history: List<HistoryItem> get() = historyMut
    val chains: List<Bytes> get() = chainsMut
    val seenIds: Set<UUID> get() = seenIdsMut
    val usedKeys: Set<Bytes> get() = usedKeysMut
    val removedKeys: Set<Bytes> get() = removedKeysMut
    val keyAddedAt: Map<Bytes, String> get() = keyAddedAtMut

    val lastSeq: Long get() = (chainsMut.size - 1).toLong()
    val head: EventHeader.Seen get() = EventHeader.Seen(lastSeq, chainsMut.last().base64Url)
    val isCreated: Boolean get() = adminId != null
    val orderedMembers: List<Member> get() = memberOrderMut.mapNotNull { membersMut[it] }
    val livePayments: List<PaymentRecord> get() = paymentOrderMut.mapNotNull { paymentsMut[it] }.filter { !it.deleted }

    fun arrivalsOf(payment: PaymentId): List<Arrival> =
        arrivalsMut.values.filter { it.payment == payment && !it.removed }.sortedBy { it.at }

    internal fun keysOf(member: MemberId): List<Bytes> = membersMut[member]?.keys ?: emptyList()

    /** A deep copy that later reductions don't touch. */
    fun snapshot(): LedgerState {
        val s = LedgerState(groupId)
        s.name = name
        s.currency = currency
        s.adminId = adminId
        s.recoveryKey = recoveryKey
        s.inconsistency = inconsistency
        s.membersMut.putAll(membersMut)
        s.memberOrderMut.addAll(memberOrderMut)
        s.paymentsMut.putAll(paymentsMut)
        s.paymentOrderMut.addAll(paymentOrderMut)
        s.arrivalsMut.putAll(arrivalsMut)
        s.historyMut.addAll(historyMut)
        s.chainsMut.clear()
        s.chainsMut.addAll(chainsMut)
        s.seenIdsMut.addAll(seenIdsMut)
        s.usedKeysMut.addAll(usedKeysMut)
        s.removedKeysMut.addAll(removedKeysMut)
        s.keyAddedAtMut.putAll(keyAddedAtMut)
        return s
    }

    private fun fields(): List<Any?> = listOf(
        groupId, name, currency, adminId, recoveryKey, inconsistency, membersMut, memberOrderMut, paymentsMut,
        paymentOrderMut, arrivalsMut, historyMut, chainsMut, seenIdsMut, usedKeysMut, removedKeysMut, keyAddedAtMut,
    )

    override fun equals(other: Any?): Boolean = other is LedgerState && fields() == other.fields()
    override fun hashCode(): Int = fields().hashCode()
}

/** Replays events into a [LedgerState] (§8). */
class Ledger private constructor(val groupId: UUID, private val encKey: ByteArray, state: LedgerState) {
    constructor(groupId: UUID, secret: ByteArray) : this(groupId, LedgerCrypto.encKey(secret, groupId), LedgerState(groupId))

    var state: LedgerState = state
        private set

    /** An independent copy, e.g. to layer unconfirmed events on top. */
    fun copy(): Ledger = Ledger(groupId, encKey, state.snapshot())

    /** Apply server events in order. Stops at the first inconsistency. */
    fun apply(events: List<RawEvent>) {
        for (e in events) {
            if (state.inconsistency != null) return
            apply(e)
        }
    }

    private fun apply(e: RawEvent) {
        val s = state
        // §6.4: contiguous seq and chain.
        if (e.seq != s.lastSeq + 1) {
            s.inconsistency = Inconsistency.Gap(s.lastSeq + 1, e.seq)
            return
        }
        s.chainsMut.add(Bytes(LedgerCrypto.chainNext(s.chainsMut.last().toByteArray(), e.seq, e.id, e.blob)))
        var item = HistoryItem(seq = e.seq, eventId = e.id)
        try {
            if (!s.seenIdsMut.add(e.id)) {
                item = item.copy(rejection = Rejection.DuplicateId)
                return
            }
            val opened = try {
                LedgerCrypto.open(e.blob, groupId, e.id, encKey)
            } catch (_: Exception) {
                item = item.copy(rejection = Rejection.Decrypt)
                return genesisCheck(e.seq, valid = false)
            }
            val (header, data) = try {
                EventCoding.decode(opened.body)
            } catch (_: EventCoding.Malformed) {
                item = item.copy(rejection = Rejection.Malformed)
                return genesisCheck(e.seq, valid = false)
            }
            item = item.copy(author = header.author, at = header.at, data = data)

            if (header.seen.seq >= e.seq) {
                item = item.copy(rejection = Rejection.Malformed)
                return genesisCheck(e.seq, valid = false)
            }
            if (s.chainsMut[header.seen.seq.toInt()].base64Url != header.seen.chain) {
                s.inconsistency = Inconsistency.Fork(s.membersMut[header.author]?.name, header.seen.seq)
                return
            }

            val keys = authorKeys(header, data)
            if (keys.isEmpty()) {
                item = item.copy(rejection = Rejection.UnknownAuthor)
                return genesisCheck(e.seq, valid = false)
            }
            if (keys.none { LedgerCrypto.verify(opened.signature, opened.body, groupId, e.id, it.toByteArray()) }) {
                item = item.copy(rejection = Rejection.BadSignature)
                return genesisCheck(e.seq, valid = false)
            }
            val rejection = validateAndApply(header, data, e.id, e.seq)
            item = item.copy(rejection = rejection)
            genesisCheck(e.seq, valid = rejection == null)
        } finally {
            // Every event past the seq check gets a history line, valid or not.
            s.historyMut.add(item)
        }
    }

    private fun genesisCheck(seq: Long, valid: Boolean) {
        if (seq == 1L && (!valid || !state.isCreated)) state.inconsistency = Inconsistency.BadGenesis
    }

    /** §8.2: the keys the signature may verify with. */
    private fun authorKeys(header: EventHeader, data: EventData): List<Bytes> = when (data) {
        is EventData.GroupCreated -> listOfNotNull(Bytes.ofBase64Url(data.data.admin.key))
        is EventData.MemberClaimed -> listOfNotNull(Bytes.ofBase64Url(data.data.key))
        is EventData.MemberDeviceClaimed -> listOfNotNull(Bytes.ofBase64Url(data.data.key))
        is EventData.MemberRecovered -> listOfNotNull(Bytes.ofBase64Url(data.data.key))
        else -> state.keysOf(header.author)
    }

    /**
     * Apply an event written locally but not yet confirmed by the server.
     * Runs the same validation; signatures and chain are ours.
     */
    fun applyPending(id: UUID, body: ByteArray) {
        val (header, data) = try {
            EventCoding.decode(body)
        } catch (_: EventCoding.Malformed) {
            state.historyMut.add(HistoryItem(seq = null, eventId = id, pending = true, rejection = Rejection.Malformed))
            return
        }
        val rejection = validateAndApply(header, data, id, null)
        state.historyMut.add(HistoryItem(seq = null, eventId = id, author = header.author, at = header.at, data = data, rejection = rejection, pending = true))
    }

    // MARK: - Validation and permissions (§7)

    private fun validateAndApply(h: EventHeader, data: EventData, eventId: UUID, seq: Long?): Rejection? {
        val s = state
        val isAdmin = h.author == s.adminId
        when (data) {
            is EventData.GroupCreated -> {
                val d = data.data
                if (!(seq == 1L || (seq == null && !s.isCreated))) return Rejection.Misplaced
                val key = Bytes.ofBase64Url(d.admin.key)
                val recovery = Bytes.ofBase64Url(d.recoveryKey)
                if (h.author != d.admin.id || !validName(d.name) || !validName(d.admin.name) ||
                    !Currency.isValidCode(d.currency) || key == null || key.size != 32 ||
                    recovery == null || recovery.size != 32 || recovery == key
                ) return Rejection.InvalidData
                s.name = d.name
                s.currency = d.currency
                s.adminId = d.admin.id
                s.recoveryKey = recovery
                use(recovery)
                addMember(Member(id = d.admin.id, name = d.admin.name, isAdmin = true))
                addKey(key, d.admin.id, h.at)
            }

            is EventData.GroupUpdated -> {
                if (!isAdmin) return Rejection.Forbidden
                if (!validName(data.data.name)) return Rejection.InvalidData
                s.name = data.data.name
            }

            is EventData.GroupRecoveryChanged -> {
                if (!isAdmin) return Rejection.Forbidden
                val key = Bytes.ofBase64Url(data.data.recoveryKey)
                if (key == null || key.size != 32 || keyInUse(key)) return Rejection.InvalidData
                s.recoveryKey = key
                use(key)
            }

            is EventData.MemberAdded -> {
                val d = data.data
                if (!isAdmin) return Rejection.Forbidden
                if (s.membersMut[d.id] != null) return Rejection.DuplicateId
                val key = Bytes.ofBase64Url(d.inviteKey)
                if (!validName(d.name) || key == null || key.size != 32 || keyInUse(key)) return Rejection.InvalidData
                addMember(Member(id = d.id, name = d.name, inviteKey = key, isAdmin = false))
                use(key)
            }

            is EventData.MemberInviteRenewed -> {
                val d = data.data
                if (!isAdmin) return Rejection.Forbidden
                val m = s.membersMut[d.id] ?: return Rejection.UnknownTarget
                if (m.isClaimed) return Rejection.AlreadyClaimed
                val key = Bytes.ofBase64Url(d.inviteKey)
                if (key == null || key.size != 32 || keyInUse(key)) return Rejection.InvalidData
                s.membersMut[d.id] = m.copy(inviteKey = key)
                use(key)
            }

            is EventData.MemberClaimed -> {
                val d = data.data
                val m = s.membersMut[d.id] ?: return Rejection.UnknownTarget
                if (h.author != d.id) return Rejection.Forbidden
                if (m.isClaimed) return Rejection.AlreadyClaimed
                val key = Bytes.ofBase64Url(d.key)
                if (key == null || key.size != 32 || keyInUse(key)) return Rejection.InvalidData
                val invite = m.inviteKey
                if (invite == null || !inviteSigned(d.inviteSig, invite, key)) return Rejection.BadInviteSig
                s.membersMut[d.id] = m.copy(inviteKey = null)
                addKey(key, d.id, h.at)
            }

            is EventData.MemberUpdated -> {
                val d = data.data
                val m = s.membersMut[d.id] ?: return Rejection.UnknownTarget
                if (!(isAdmin || h.author == d.id)) return Rejection.Forbidden
                if (!validName(d.name)) return Rejection.InvalidData
                s.membersMut[d.id] = m.copy(name = d.name)
            }

            is EventData.MemberDeviceInvited -> {
                // Only the member itself; the admin adds a first device through member.added.
                val d = data.data
                val m = s.membersMut[d.id] ?: return Rejection.UnknownTarget
                if (h.author != d.id) return Rejection.Forbidden
                val key = Bytes.ofBase64Url(d.inviteKey)
                if (key == null || key.size != 32 || keyInUse(key)) return Rejection.InvalidData
                s.membersMut[d.id] = m.copy(deviceInvites = m.deviceInvites + key)
                use(key)
            }

            is EventData.MemberDeviceClaimed -> {
                val d = data.data
                val m = s.membersMut[d.id] ?: return Rejection.UnknownTarget
                if (h.author != d.id) return Rejection.Forbidden
                val key = Bytes.ofBase64Url(d.key)
                if (key == null || key.size != 32 || keyInUse(key)) return Rejection.InvalidData
                val invite = Bytes.ofBase64Url(d.inviteKey)
                if (invite == null || invite !in m.deviceInvites || !inviteSigned(d.inviteSig, invite, key)) return Rejection.BadInviteSig
                s.membersMut[d.id] = m.copy(deviceInvites = m.deviceInvites.filter { it != invite })
                addKey(key, d.id, h.at)
            }

            is EventData.MemberDeviceInviteRevoked -> {
                val d = data.data
                val m = s.membersMut[d.id] ?: return Rejection.UnknownTarget
                if (!(isAdmin || h.author == d.id)) return Rejection.Forbidden
                val invite = Bytes.ofBase64Url(d.inviteKey)
                if (invite == null || invite !in m.deviceInvites) return Rejection.UnknownTarget
                s.membersMut[d.id] = m.copy(deviceInvites = m.deviceInvites.filter { it != invite })
            }

            is EventData.MemberDeviceRemoved -> {
                val d = data.data
                val m = s.membersMut[d.id] ?: return Rejection.UnknownTarget
                if (!(isAdmin || h.author == d.id)) return Rejection.Forbidden
                val key = Bytes.ofBase64Url(d.key)
                if (key == null || key !in m.keys) return Rejection.UnknownTarget
                val keys = m.keys.filter { it != key }
                s.removedKeysMut.add(key)
                // Unclaimed again: the admin renews its invite for a new first device.
                s.membersMut[d.id] = if (keys.isEmpty()) m.copy(keys = keys, inviteKey = null, deviceInvites = emptyList()) else m.copy(keys = keys)
            }

            is EventData.MemberRecovered -> {
                val d = data.data
                if (d.id != s.adminId || h.author != d.id) return Rejection.Forbidden
                val key = Bytes.ofBase64Url(d.key)
                if (key == null || key.size != 32 || keyInUse(key)) return Rejection.InvalidData
                val recovery = s.recoveryKey
                if (recovery == null || !signed(d.recoverySig, recovery, LedgerCrypto.recoverInput(groupId, key.toByteArray()))) return Rejection.BadRecoverySig
                val m = s.membersMut.getValue(d.id)
                s.removedKeysMut.addAll(m.keys)
                s.membersMut[d.id] = m.copy(keys = emptyList(), deviceInvites = emptyList())
                addKey(key, d.id, h.at)
            }

            is EventData.PaymentCreated -> {
                val p = data.payment
                if (s.paymentsMut[p.id] != null) return Rejection.DuplicateId
                if (!validPayment(p)) return Rejection.InvalidData
                s.paymentsMut[p.id] = PaymentRecord(payment = p, creator = h.author, createdAt = h.at, lastEventId = eventId)
                s.paymentOrderMut.add(p.id)
            }

            is EventData.PaymentUpdated -> {
                val p = data.payment
                val r = s.paymentsMut[p.id]?.takeIf { !it.deleted } ?: return Rejection.UnknownTarget
                if (!(isAdmin || h.author == r.creator)) return Rejection.Forbidden
                if (!validPayment(p)) return Rejection.InvalidData
                s.paymentsMut[p.id] = r.copy(
                    payment = p,
                    editedConcurrently = p.base != r.lastEventId.lower,
                    lastEditor = h.author,
                    lastEventId = eventId,
                )
            }

            is EventData.PaymentDeleted -> {
                val r = s.paymentsMut[data.data.id]?.takeIf { !it.deleted } ?: return Rejection.UnknownTarget
                if (!(isAdmin || h.author == r.creator)) return Rejection.Forbidden
                s.paymentsMut[r.id] = r.copy(deleted = true)
            }

            is EventData.ArrivalRecorded -> {
                val a = data.data
                if (s.arrivalsMut[a.id] != null) return Rejection.DuplicateId
                val r = s.paymentsMut[a.payment]
                if (r == null || r.deleted || !r.payment.track || r.payment.inSide.lines.none { it.member == a.member }) return Rejection.UnknownTarget
                val m = s.membersMut[a.member] ?: return Rejection.UnknownTarget
                if (!(isAdmin || h.author == a.member || !m.isClaimed)) return Rejection.Forbidden
                if (a.amount !in 1..MAX_AMOUNT) return Rejection.InvalidData
                s.arrivalsMut[a.id] = Arrival(a.id, a.payment, a.member, a.amount, author = h.author, at = h.at)
            }

            is EventData.ArrivalRemoved -> {
                val a = s.arrivalsMut[data.data.id]?.takeIf { !it.removed } ?: return Rejection.UnknownTarget
                if (!(isAdmin || h.author == a.author)) return Rejection.Forbidden
                s.arrivalsMut[a.id] = a.copy(removed = true)
            }

            is EventData.Unsupported -> return null
        }
        return null
    }

    private fun addMember(m: Member) {
        state.membersMut[m.id] = m
        state.memberOrderMut.add(m.id)
    }

    /** Keys are never reused within a group (§7.3). */
    private fun keyInUse(key: Bytes): Boolean = key in state.usedKeysMut

    private fun use(key: Bytes) {
        state.usedKeysMut.add(key)
    }

    private fun addKey(key: Bytes, member: MemberId, at: String) {
        val m = state.membersMut[member] ?: return
        state.membersMut[member] = m.copy(keys = m.keys + key)
        state.keyAddedAtMut[key] = at
        use(key)
    }

    /** `inviteSig` (§7.3): the invite key vouches for `key` in this group. */
    private fun inviteSigned(sig: String, invite: Bytes, key: Bytes): Boolean =
        signed(sig, invite, LedgerCrypto.claimInput(groupId, key.toByteArray()))

    private fun signed(sig: String, publicKey: Bytes, input: ByteArray): Boolean {
        val s = Base64Url.decode(sig) ?: return false
        return Ed25519.verify(publicKey.toByteArray(), s, input)
    }

    private fun validPayment(p: Payment): Boolean {
        if (p.title.scalarCount() !in 1..200 || (p.note?.scalarCount() ?: 0) > 2000 ||
            p.amount !in 1..MAX_AMOUNT || !validDate(p.date)
        ) return false
        for (side in listOf(p.inSide, p.outSide)) {
            if (side.lines.isEmpty()) return false
            if (side.lines.map { it.member }.toSet().size != side.lines.size) return false
            if (side.lines.any { it.amount < 0 || state.membersMut[it.member] == null }) return false
            // Overflow-safe: a sum that wraps around must not match.
            var sum = 0L
            for (l in side.lines) {
                sum = try {
                    Math.addExact(sum, l.amount)
                } catch (_: ArithmeticException) {
                    return false
                }
            }
            if (sum != p.amount) return false
        }
        return true
    }

    companion object {
        const val MAX_AMOUNT = 1_000_000_000_000_000L

        fun validName(s: String): Boolean = s.scalarCount() in 1..100

        /**
         * YYYY-MM-DD. Each part parses like Swift's `Int(String)` (an optional
         * leading "+"), so this client accepts exactly the dates iOS accepts.
         */
        fun validDate(s: String): Boolean {
            val parts = s.split("-")
            if (parts.size != 3 || parts[0].length != 4 || parts[1].length != 2 || parts[2].length != 2) return false
            val numbers = parts.map { p -> if (swiftInt.matches(p)) p.removePrefix("+").toInt() else return false }
            return numbers[1] in 1..12 && numbers[2] in 1..31
        }

        private val swiftInt = Regex("^\\+?[0-9]+$")
    }
}

/** Unicode scalar values, the length unit of §2. */
internal fun String.scalarCount(): Int = codePointCount(0, length)

object Currency {
    fun isValidCode(code: String): Boolean = code.length == 3 && code.all { it in 'A'..'Z' }

    /** ISO 4217 minor-unit exponent (EUR 2, JPY 0). */
    fun exponent(code: String): Int = try {
        java.util.Currency.getInstance(code).defaultFractionDigits.takeIf { it >= 0 } ?: 2
    } catch (_: Exception) {
        2
    }
}
