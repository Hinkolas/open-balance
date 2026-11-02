package io.github.hinkolas.openbalance.core

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.UUID

/** A signed, encrypted event ready to append. */
class SealedEvent(val id: UUID, val body: ByteArray, val blob: ByteArray) {
    /** The epoch it is sealed with. */
    val epoch: Long? get() = LedgerCrypto.blobEpoch(blob)
}

/**
 * Writes events as one member of one group. [secret] is the secret of
 * [epoch], the current epoch (§7.2).
 */
class EventWriter(
    val groupId: UUID, secret: ByteArray, val epoch: Long = 0, val author: MemberId, private val signer: SigningKey,
) {
    private val encKey = LedgerCrypto.encKey(secret, groupId, epoch)

    fun write(data: EventData, seen: EventHeader.Seen, at: Instant = Instant.now(), id: UUID = Uuids.v7()): SealedEvent {
        val header = EventHeader(v = 1, type = data.type, author = author, at = timestamp(at), seen = seen)
        val body = EventCoding.encode(header, data)
        val blob = LedgerCrypto.seal(body, groupId, id, epoch, encKey, signer)
        return SealedEvent(id, body, blob)
    }

    /**
     * The same event (id and body) sealed with this writer's epoch, for an
     * unsent event written before a new epoch started (§5.4 step 10).
     */
    fun reseal(e: SealedEvent): SealedEvent = SealedEvent(e.id, e.body, LedgerCrypto.seal(e.body, groupId, e.id, epoch, encKey, signer))

    companion object {
        /** RFC 3339 UTC to the second: "2026-11-01T14:03:11Z". */
        fun timestamp(at: Instant): String = DateTimeFormatter.ISO_INSTANT.format(at.truncatedTo(ChronoUnit.SECONDS))
    }
}
