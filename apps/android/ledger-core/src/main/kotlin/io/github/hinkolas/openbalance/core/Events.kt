package io.github.hinkolas.openbalance.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * Ids inside events are lowercase UUID strings (PROTOCOL.md §2). Kept as
 * strings so ordering is plain byte order and encoding never changes case.
 */
typealias MemberId = String
typealias PaymentId = String
typealias ArrivalId = String

/** The JSON body inside an event blob (§6.2), without `data`. */
data class EventHeader(
    val v: Int,
    val type: String,
    val author: MemberId,
    val at: String,
    val seen: Seen,
) {
    data class Seen(val seq: Long, val chain: String)
}

/** Typed event content. One case per event type of §7. */
sealed interface EventData {
    val type: String

    data class GroupCreated(val data: GroupCreatedData) : EventData {
        override val type get() = "group.created"
    }

    data class GroupUpdated(val data: GroupUpdatedData) : EventData {
        override val type get() = "group.updated"
    }

    data class MemberAdded(val data: MemberAddedData) : EventData {
        override val type get() = "member.added"
    }

    data class MemberInviteRenewed(val data: MemberInviteRenewedData) : EventData {
        override val type get() = "member.invite_renewed"
    }

    data class MemberClaimed(val data: MemberClaimedData) : EventData {
        override val type get() = "member.claimed"
    }

    data class MemberUpdated(val data: MemberUpdatedData) : EventData {
        override val type get() = "member.updated"
    }

    data class MemberDeviceInvited(val data: MemberDeviceInviteData) : EventData {
        override val type get() = "member.device_invited"
    }

    data class MemberDeviceClaimed(val data: MemberDeviceClaimedData) : EventData {
        override val type get() = "member.device_claimed"
    }

    data class MemberDeviceInviteRevoked(val data: MemberDeviceInviteData) : EventData {
        override val type get() = "member.device_invite_revoked"
    }

    data class PaymentCreated(val payment: Payment) : EventData {
        override val type get() = "payment.created"
    }

    data class PaymentUpdated(val payment: Payment) : EventData {
        override val type get() = "payment.updated"
    }

    data class PaymentDeleted(val data: PaymentDeletedData) : EventData {
        override val type get() = "payment.deleted"
    }

    data class ArrivalRecorded(val data: ArrivalRecordedData) : EventData {
        override val type get() = "arrival.recorded"
    }

    data class ArrivalRemoved(val data: ArrivalRemovedData) : EventData {
        override val type get() = "arrival.removed"
    }

    /** A type this client doesn't know: kept in the history, otherwise ignored. */
    data class Unsupported(override val type: String) : EventData
}

data class GroupCreatedData(val name: String, val currency: String, val admin: Admin) {
    data class Admin(val id: MemberId, val name: String, val key: String)
}

data class GroupUpdatedData(val name: String)

data class MemberAddedData(val id: MemberId, val name: String, val inviteKey: String)

data class MemberInviteRenewedData(val id: MemberId, val inviteKey: String)

data class MemberClaimedData(val id: MemberId, val key: String, val inviteSig: String)

data class MemberUpdatedData(val id: MemberId, val name: String)

/** `member.device_invited` and `member.device_invite_revoked` (§7.3). */
data class MemberDeviceInviteData(val id: MemberId, val inviteKey: String)

/** `member.device_claimed` (§7.3): one more key for a claimed member. */
data class MemberDeviceClaimedData(val id: MemberId, val key: String, val inviteKey: String, val inviteSig: String)

/** A payment (§7.4). `inSide` is who received the money, `outSide` whom it belongs to. */
data class Payment(
    val id: PaymentId,
    val kind: String,
    val title: String,
    val note: String? = null,
    val date: String,
    val amount: Long,
    val track: Boolean,
    val inSide: Side,
    val outSide: Side,
    /** Only on payment.updated: the event id this edit is based on. */
    val base: String? = null,
) {
    enum class Kind(val raw: String) {
        Income("income"), Expense("expense"), Settlement("settlement");

        companion object {
            fun of(raw: String): Kind? = entries.firstOrNull { it.raw == raw }
        }
    }

    data class Side(val mode: String, val lines: List<Line>) {
        fun amountOf(member: MemberId): Long = lines.firstOrNull { it.member == member }?.amount ?: 0
    }

    data class Line(val member: MemberId, val amount: Long, val value: Long? = null, val rest: Boolean? = null)

    /** Unknown kinds display as income (§7.4). */
    val displayKind: Kind get() = Kind.of(kind) ?: Kind.Income

    companion object {
        operator fun invoke(
            id: PaymentId, kind: Kind, title: String, note: String? = null, date: String, amount: Long, track: Boolean,
            inSide: Side, outSide: Side, base: String? = null,
        ) = Payment(id, kind.raw, title, note, date, amount, track, inSide, outSide, base)
    }
}

data class PaymentDeletedData(val id: PaymentId)

data class ArrivalRecordedData(val id: ArrivalId, val payment: PaymentId, val member: MemberId, val amount: Long)

data class ArrivalRemovedData(val id: ArrivalId)

// MARK: - Coding

/**
 * Event bodies to and from JSON. Decoding is strict in the same way as the
 * Swift client's `JSONDecoder`: required fields must be present with the
 * right JSON type (no quoted numbers, no numbers as strings), optional fields
 * may be missing or null, unknown fields are ignored (§6.2). Every client
 * must reject the same bodies as malformed.
 */
object EventCoding {
    class Malformed(message: String = "malformed") : Exception(message)

    private val json = Json { prettyPrint = false }

    /** Encode a body. Key order is irrelevant: signatures cover the bytes as written. */
    fun encode(header: EventHeader, data: EventData): ByteArray {
        val obj = buildJsonObject {
            put("v", header.v)
            put("type", header.type)
            put("author", header.author)
            put("at", header.at)
            put("seen", buildJsonObject {
                put("seq", header.seen.seq)
                put("chain", header.seen.chain)
            })
            put("data", encodeData(data))
        }
        return json.encodeToString(JsonObject.serializer(), obj).toByteArray(Charsets.UTF_8)
    }

    private fun encodeData(data: EventData): JsonObject = when (data) {
        is EventData.GroupCreated -> buildJsonObject {
            put("name", data.data.name)
            put("currency", data.data.currency)
            put("admin", buildJsonObject {
                put("id", data.data.admin.id)
                put("name", data.data.admin.name)
                put("key", data.data.admin.key)
            })
        }
        is EventData.GroupUpdated -> buildJsonObject { put("name", data.data.name) }
        is EventData.MemberAdded -> buildJsonObject {
            put("id", data.data.id)
            put("name", data.data.name)
            put("inviteKey", data.data.inviteKey)
        }
        is EventData.MemberInviteRenewed -> buildJsonObject {
            put("id", data.data.id)
            put("inviteKey", data.data.inviteKey)
        }
        is EventData.MemberClaimed -> buildJsonObject {
            put("id", data.data.id)
            put("key", data.data.key)
            put("inviteSig", data.data.inviteSig)
        }
        is EventData.MemberUpdated -> buildJsonObject {
            put("id", data.data.id)
            put("name", data.data.name)
        }
        is EventData.MemberDeviceInvited -> deviceInvite(data.data)
        is EventData.MemberDeviceInviteRevoked -> deviceInvite(data.data)
        is EventData.MemberDeviceClaimed -> buildJsonObject {
            put("id", data.data.id)
            put("key", data.data.key)
            put("inviteKey", data.data.inviteKey)
            put("inviteSig", data.data.inviteSig)
        }
        is EventData.PaymentCreated -> encodePayment(data.payment)
        is EventData.PaymentUpdated -> encodePayment(data.payment)
        is EventData.PaymentDeleted -> buildJsonObject { put("id", data.data.id) }
        is EventData.ArrivalRecorded -> buildJsonObject {
            put("id", data.data.id)
            put("payment", data.data.payment)
            put("member", data.data.member)
            put("amount", data.data.amount)
        }
        is EventData.ArrivalRemoved -> buildJsonObject { put("id", data.data.id) }
        is EventData.Unsupported -> throw Malformed("can't write unsupported events")
    }

    private fun deviceInvite(d: MemberDeviceInviteData) = buildJsonObject {
        put("id", d.id)
        put("inviteKey", d.inviteKey)
    }

    private fun encodePayment(p: Payment) = buildJsonObject {
        put("id", p.id)
        put("kind", p.kind)
        put("title", p.title)
        p.note?.let { put("note", it) }
        put("date", p.date)
        put("amount", p.amount)
        put("track", p.track)
        put("in", encodeSide(p.inSide))
        put("out", encodeSide(p.outSide))
        p.base?.let { put("base", it) }
    }

    private fun encodeSide(s: Payment.Side) = buildJsonObject {
        put("mode", s.mode)
        put("lines", buildJsonArray {
            for (l in s.lines) add(buildJsonObject {
                put("member", l.member)
                put("amount", l.amount)
                l.value?.let { put("value", it) }
                l.rest?.let { put("rest", it) }
            })
        })
    }

    /** Decode a body into header and typed data. Unknown types decode as [EventData.Unsupported]. */
    fun decode(body: ByteArray): Pair<EventHeader, EventData> {
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(body)).toString()
        } catch (_: CharacterCodingException) {
            throw Malformed("not UTF-8")
        }
        val root = try {
            json.parseToJsonElement(text)
        } catch (_: Exception) {
            throw Malformed("not JSON")
        } as? JsonObject ?: throw Malformed("not an object")

        val seen = root.obj("seen")
        val header = EventHeader(
            v = root.int("v"),
            type = root.str("type"),
            author = root.str("author"),
            at = root.str("at"),
            seen = EventHeader.Seen(seq = seen.long("seq"), chain = seen.str("chain")),
        )
        // seen.seq is unsigned on the wire.
        if (header.v != 1 || header.seen.seq < 0) throw Malformed("version or seq")

        val data: EventData = when (header.type) {
            "group.created" -> root.obj("data").let { d ->
                val a = d.obj("admin")
                EventData.GroupCreated(GroupCreatedData(d.str("name"), d.str("currency"), GroupCreatedData.Admin(a.str("id"), a.str("name"), a.str("key"))))
            }
            "group.updated" -> EventData.GroupUpdated(GroupUpdatedData(root.obj("data").str("name")))
            "member.added" -> root.obj("data").let { EventData.MemberAdded(MemberAddedData(it.str("id"), it.str("name"), it.str("inviteKey"))) }
            "member.invite_renewed" -> root.obj("data").let { EventData.MemberInviteRenewed(MemberInviteRenewedData(it.str("id"), it.str("inviteKey"))) }
            "member.claimed" -> root.obj("data").let { EventData.MemberClaimed(MemberClaimedData(it.str("id"), it.str("key"), it.str("inviteSig"))) }
            "member.updated" -> root.obj("data").let { EventData.MemberUpdated(MemberUpdatedData(it.str("id"), it.str("name"))) }
            "member.device_invited" -> root.obj("data").let { EventData.MemberDeviceInvited(MemberDeviceInviteData(it.str("id"), it.str("inviteKey"))) }
            "member.device_claimed" -> root.obj("data").let {
                EventData.MemberDeviceClaimed(MemberDeviceClaimedData(it.str("id"), it.str("key"), it.str("inviteKey"), it.str("inviteSig")))
            }
            "member.device_invite_revoked" -> root.obj("data").let { EventData.MemberDeviceInviteRevoked(MemberDeviceInviteData(it.str("id"), it.str("inviteKey"))) }
            "payment.created" -> EventData.PaymentCreated(decodePayment(root.obj("data")))
            "payment.updated" -> EventData.PaymentUpdated(decodePayment(root.obj("data")))
            "payment.deleted" -> EventData.PaymentDeleted(PaymentDeletedData(root.obj("data").str("id")))
            "arrival.recorded" -> root.obj("data").let {
                EventData.ArrivalRecorded(ArrivalRecordedData(it.str("id"), it.str("payment"), it.str("member"), it.long("amount")))
            }
            "arrival.removed" -> EventData.ArrivalRemoved(ArrivalRemovedData(root.obj("data").str("id")))
            else -> EventData.Unsupported(header.type)
        }
        return header to data
    }

    private fun decodePayment(d: JsonObject) = Payment(
        id = d.str("id"),
        kind = d.str("kind"),
        title = d.str("title"),
        note = d.optStr("note"),
        date = d.str("date"),
        amount = d.long("amount"),
        track = d.bool("track"),
        inSide = decodeSide(d.obj("in")),
        outSide = decodeSide(d.obj("out")),
        base = d.optStr("base"),
    )

    private fun decodeSide(s: JsonObject) = Payment.Side(
        mode = s.str("mode"),
        lines = s.arr("lines").map { e ->
            val l = e as? JsonObject ?: throw Malformed("line")
            Payment.Line(l.str("member"), l.long("amount"), l.optLong("value"), l.optBool("rest"))
        },
    )

    // Typed field access. Missing or null required fields, and fields of the
    // wrong JSON type, are malformed.

    private val integer = Regex("^-?(0|[1-9][0-9]*)$")

    private fun JsonObject.field(name: String): JsonElement = this[name]?.takeIf { it !is JsonNull } ?: throw Malformed("missing $name")

    private fun JsonObject.obj(name: String): JsonObject = field(name) as? JsonObject ?: throw Malformed("$name: object")

    private fun JsonObject.arr(name: String): JsonArray = field(name) as? JsonArray ?: throw Malformed("$name: array")

    private fun JsonObject.str(name: String): String = string(field(name)) ?: throw Malformed("$name: string")

    private fun JsonObject.long(name: String): Long = number(field(name)) ?: throw Malformed("$name: integer")

    private fun JsonObject.int(name: String): Int {
        val v = long(name)
        if (v < Int.MIN_VALUE || v > Int.MAX_VALUE) throw Malformed("$name: int")
        return v.toInt()
    }

    private fun JsonObject.bool(name: String): Boolean = boolean(field(name)) ?: throw Malformed("$name: bool")

    private fun JsonObject.optional(name: String): JsonElement? = this[name]?.takeIf { it !is JsonNull }

    private fun JsonObject.optStr(name: String): String? = optional(name)?.let { string(it) ?: throw Malformed("$name: string") }

    private fun JsonObject.optLong(name: String): Long? = optional(name)?.let { number(it) ?: throw Malformed("$name: integer") }

    private fun JsonObject.optBool(name: String): Boolean? = optional(name)?.let { boolean(it) ?: throw Malformed("$name: bool") }

    private fun string(e: JsonElement): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun number(e: JsonElement): Long? {
        val p = e as? JsonPrimitive ?: return null
        if (p.isString || !integer.matches(p.content)) return null
        return p.content.toLongOrNull()
    }

    private fun boolean(e: JsonElement): Boolean? {
        val p = e as? JsonPrimitive ?: return null
        if (p.isString) return null
        return when (p.content) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }
}
