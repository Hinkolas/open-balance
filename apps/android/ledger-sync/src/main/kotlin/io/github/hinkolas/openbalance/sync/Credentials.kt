package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.Base64Url
import io.github.hinkolas.openbalance.core.BoxKey
import io.github.hinkolas.openbalance.core.LedgerCrypto
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.SigningKey
import io.github.hinkolas.openbalance.core.base64Url
import io.github.hinkolas.openbalance.core.lower
import kotlinx.serialization.Serializable
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Everything a device needs to act as one member of one group. Binary values
 * are base64url so the record serializes as plain JSON; the app keeps it
 * encrypted with a key from the Android Keystore.
 */
@Serializable
data class GroupCredentials(
    val server: String,
    val groupId: String,
    /** Every epoch secret this device has, by epoch (PROTOCOL.md §3.1). */
    val secrets: List<String>,
    val memberId: MemberId,
    val memberSeed: String,
    /**
     * Invite seeds of members this device (as admin) added and that have not
     * claimed yet, so their QR can be shown again.
     */
    val invites: Map<MemberId, String> = emptyMap(),
    /**
     * Seed of the pending invite this device made for a further device of
     * its own member, so its QR can be shown again.
     */
    val deviceInvite: String? = null,
    /** The server accepted our member key (claim done or we created the group). */
    val registered: Boolean,
    val addedAt: Long = System.currentTimeMillis(),
) {
    val groupUuid: UUID get() = UUID.fromString(groupId)
    val secretBytes: List<ByteArray> get() = secrets.map { Base64Url.decode(it) ?: error("corrupt secret") }
    val signer: SigningKey get() = SigningKey(Base64Url.decode(memberSeed) ?: error("corrupt member key"))

    /** This device's box key (§3.5), derived from its member key seed. */
    val box: BoxKey get() = LedgerCrypto.boxKey(Base64Url.decode(memberSeed) ?: error("corrupt member key"))

    /** Never print secrets or keys (CLAUDE.md). */
    override fun toString(): String = "GroupCredentials(group=$groupId, member=$memberId, server=$server, registered=$registered)"

    companion object {
        fun create(server: String, groupId: UUID, secrets: List<ByteArray>, memberId: MemberId, memberSeed: ByteArray, registered: Boolean) =
            GroupCredentials(server, groupId.lower, secrets.map { it.base64Url }, memberId, memberSeed.base64Url, registered = registered)
    }
}

/** A server this device may create groups on. */
@Serializable
data class ServerOwnership(val server: String, val token: String, val name: String) {
    override fun toString(): String = "ServerOwnership(server=$server, name=$name)"
}

/** Where group credentials live. The app encrypts them on disk; tests keep them in memory. */
interface CredentialStore {
    fun save(credentials: GroupCredentials)
    fun delete(groupId: UUID)
    fun all(): List<GroupCredentials>
}

class MemoryCredentialStore : CredentialStore {
    private val items = ConcurrentHashMap<UUID, GroupCredentials>()
    override fun save(credentials: GroupCredentials) {
        items[credentials.groupUuid] = credentials
    }

    override fun delete(groupId: UUID) {
        items.remove(groupId)
    }

    override fun all(): List<GroupCredentials> = items.values.toList()
}
