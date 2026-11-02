package io.github.hinkolas.openbalance.core

import java.util.UUID

/** Starting epochs and sealing keyrings (PROTOCOL.md §3.5, §7.2). */
object Epochs {
    /**
     * `group.epoch_started` for [epoch] with a fresh secret sealed to every
     * reader. Returns the event data and the secret.
     */
    fun start(epoch: Long, readers: Set<Bytes>, groupId: UUID): Pair<GroupEpochStartedData, ByteArray> {
        val secret = randomBytes(32)
        val m = LedgerCrypto.u32(epoch) + secret
        val keys = readers.sorted().map { reader ->
            GroupEpochStartedData.Entry(
                key = reader.base64Url,
                secret = LedgerCrypto.seal(m, reader.toByteArray(), LedgerCrypto.LABEL_EPOCH, groupId).base64Url,
            )
        }
        return GroupEpochStartedData(epoch, keys) to secret
    }

    /** Every epoch secret so far, sealed to a box key (an invite's or the recovery key's). */
    fun sealKeyring(secrets: List<ByteArray>, to: ByteArray, groupId: UUID): ByteArray =
        LedgerCrypto.seal(secrets.fold(ByteArray(0)) { a, b -> a + b }, to, LedgerCrypto.LABEL_KEYRING, groupId)

    /** The epoch secrets in a keyring sealed to [box]. */
    fun openKeyring(sealed: ByteArray, box: BoxKey, groupId: UUID): List<ByteArray> {
        val m = LedgerCrypto.open(sealed, box, LedgerCrypto.LABEL_KEYRING, groupId)
        if (m.isEmpty() || m.size % 32 != 0) throw LedgerCrypto.Failure("bad keyring")
        return (0 until m.size / 32).map { m.copyOfRange(it * 32, it * 32 + 32) }
    }
}
