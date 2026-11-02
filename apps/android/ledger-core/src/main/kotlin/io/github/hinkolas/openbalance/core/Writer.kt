package io.github.hinkolas.openbalance.core

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.UUID

/** A signed, encrypted event ready to append. */
class SealedEvent(val id: UUID, val body: ByteArray, val blob: ByteArray)

/** Writes events as one member of one group. */
class EventWriter(val groupId: UUID, secret: ByteArray, val author: MemberId, private val signer: SigningKey) {
    private val encKey = LedgerCrypto.encKey(secret, groupId)

    fun write(data: EventData, seen: EventHeader.Seen, at: Instant = Instant.now(), id: UUID = Uuids.v7()): SealedEvent {
        val header = EventHeader(v = 1, type = data.type, author = author, at = timestamp(at), seen = seen)
        val body = EventCoding.encode(header, data)
        val blob = LedgerCrypto.seal(body, groupId, id, encKey, signer)
        return SealedEvent(id, body, blob)
    }

    companion object {
        /** RFC 3339 UTC to the second: "2026-11-01T14:03:11Z". */
        fun timestamp(at: Instant): String = DateTimeFormatter.ISO_INSTANT.format(at.truncatedTo(ChronoUnit.SECONDS))
    }
}
