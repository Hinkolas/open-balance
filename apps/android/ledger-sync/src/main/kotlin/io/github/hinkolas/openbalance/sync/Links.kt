package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.Base64Url
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.base64Url
import io.github.hinkolas.openbalance.core.lower
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.util.UUID

/**
 * `openbalance://recover?v=1&s=<server>&g=<group>&m=<admin>#r=<recovery seed>`
 * (PROTOCOL.md §4.2). The admin keeps it outside the app; it is as powerful
 * as the admin's devices.
 */
class RecoveryLink(
    val server: String,
    val groupId: UUID,
    val adminId: MemberId,
    recoverySeed: ByteArray,
) {
    private val seedBytes = recoverySeed.copyOf()
    val recoverySeed: ByteArray get() = seedBytes.copyOf()

    val url: String
        get() = "openbalance://recover?v=1&s=${InviteLink.encode(server)}&g=${groupId.lower}&m=$adminId#r=${seedBytes.base64Url}"

    override fun equals(other: Any?): Boolean =
        other is RecoveryLink && server == other.server && groupId == other.groupId && adminId == other.adminId &&
            seedBytes.contentEquals(other.seedBytes)

    override fun hashCode(): Int = groupId.hashCode()

    /** Never print secrets (CLAUDE.md). */
    override fun toString(): String = "RecoveryLink(server=$server, group=$groupId)"

    companion object {
        fun parse(text: String): RecoveryLink? {
            val (q, f) = LinkCoding.parse(text, "recover") ?: return null
            val s = LinkCoding.server(q["s"]) ?: return null
            val group = q["g"]?.let(Uuids::parse) ?: return null
            val m = q["m"]?.takeIf { Uuids.parse(it) != null } ?: return null
            val r = LinkCoding.bytes32(f["r"]) ?: return null
            return RecoveryLink(s, group, m.lowercase(), r)
        }
    }
}

/** `openbalance://create?v=1&s=<server>#c=<code>` (PROTOCOL.md §4.3): the server owner lets someone create one group. */
class CreationLink(val server: String, val code: String) {
    val url: String get() = "openbalance://create?v=1&s=${InviteLink.encode(server)}#c=$code"

    override fun equals(other: Any?): Boolean = other is CreationLink && server == other.server && code == other.code
    override fun hashCode(): Int = server.hashCode()

    /** Never print the code (CLAUDE.md). */
    override fun toString(): String = "CreationLink(server=$server)"

    companion object {
        fun parse(text: String): CreationLink? {
            val (q, f) = LinkCoding.parse(text, "create") ?: return null
            val s = LinkCoding.server(q["s"]) ?: return null
            val c = f["c"]?.takeIf { LinkCoding.bytes32(it) != null } ?: return null
            return CreationLink(s, c)
        }
    }
}

/** Any link the app opens. */
sealed interface AppLink {
    data class Invite(val link: InviteLink) : AppLink
    data class Recovery(val link: RecoveryLink) : AppLink
    data class Creation(val link: CreationLink) : AppLink

    companion object {
        fun parse(text: String): AppLink? =
            InviteLink.parse(text)?.let(::Invite)
                ?: RecoveryLink.parse(text)?.let(::Recovery)
                ?: CreationLink.parse(text)?.let(::Creation)
    }
}

internal object LinkCoding {
    /** Query and fragment of a v1 link for [host], with whitespace around it. */
    fun parse(text: String, host: String): Pair<Map<String, String>, Map<String, String>>? {
        val raw = text.trim()
        val hash = raw.indexOf('#').takeIf { it >= 0 } ?: return null
        val beforeFragment = raw.substring(0, hash)
        val prefix = listOf("openbalance://$host?", "openbalance://$host/?").firstOrNull { beforeFragment.startsWith(it) } ?: return null
        val query = InviteLink.pairs(beforeFragment.substring(prefix.length)) ?: return null
        val fragment = InviteLink.pairs(raw.substring(hash + 1)) ?: return null
        val q = LinkedHashMap<String, String>()
        for ((k, v) in query) if (k !in q && v != null) q[k] = v
        val f = LinkedHashMap<String, String>()
        for ((k, v) in fragment) if (v != null) f[k] = v
        if (q["v"] != "1") return null
        return q to f
    }

    fun server(s: String?): String? {
        val url = s?.toHttpUrlOrNull() ?: return null
        return s.takeIf { url.scheme == "https" || url.scheme == "http" }
    }

    fun bytes32(s: String?): ByteArray? = s?.let(Base64Url::decode)?.takeIf { it.size == 32 }
}
