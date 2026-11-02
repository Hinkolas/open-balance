package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.Base64Url
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.base64Url
import io.github.hinkolas.openbalance.core.lower
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.ByteArrayOutputStream
import java.util.UUID

/** `openbalance://join?v=1&s=<server>&g=<group>&m=<member>#k=<secret>&i=<invite seed>` (PROTOCOL.md §4). */
class InviteLink(
    val server: String,
    val groupId: UUID,
    val memberId: MemberId,
    secret: ByteArray,
    inviteSeed: ByteArray,
) {
    private val secretBytes = secret.copyOf()
    private val seedBytes = inviteSeed.copyOf()
    val secret: ByteArray get() = secretBytes.copyOf()
    val inviteSeed: ByteArray get() = seedBytes.copyOf()

    /** Secrets sit in the fragment so a link pasted into a browser never sends them anywhere. */
    val url: String
        get() = "openbalance://join?v=1&s=${encode(server)}&g=${groupId.lower}&m=$memberId" +
            "#k=${secretBytes.base64Url}&i=${seedBytes.base64Url}"

    /** Identifies the seat, not the secrets: safe for keys in UI state. */
    val id: String get() = groupId.lower + memberId

    override fun equals(other: Any?): Boolean =
        other is InviteLink && server == other.server && groupId == other.groupId && memberId == other.memberId &&
            secretBytes.contentEquals(other.secretBytes) && seedBytes.contentEquals(other.seedBytes)

    override fun hashCode(): Int = id.hashCode()

    /** Never print secrets (CLAUDE.md). */
    override fun toString(): String = "InviteLink(server=$server, group=$groupId, member=$memberId)"

    companion object {
        /** Parse a scanned or pasted link, with whitespace around it. Null if it isn't a valid invite. */
        fun parse(text: String): InviteLink? {
            val raw = text.trim()
            val hash = raw.indexOf('#').takeIf { it >= 0 } ?: return null
            val beforeFragment = raw.substring(0, hash)
            val fragment = raw.substring(hash + 1)
            val prefix = listOf("openbalance://join?", "openbalance://join/?").firstOrNull { beforeFragment.startsWith(it) } ?: return null
            val query = pairs(beforeFragment.substring(prefix.length)) ?: return null
            val f = pairs(fragment) ?: return null
            fun q(name: String) = query.firstOrNull { it.first == name }?.second
            fun fr(name: String) = f.firstOrNull { it.first == name }?.second

            if (q("v") != "1") return null
            val s = q("s") ?: return null
            val url = s.toHttpUrlOrNull() ?: return null
            if (url.scheme != "https" && url.scheme != "http") return null
            val group = q("g")?.let(Uuids::parse) ?: return null
            val m = q("m")?.takeIf { Uuids.parse(it) != null } ?: return null
            val k = fr("k")?.let(Base64Url::decode)?.takeIf { it.size == 32 } ?: return null
            val i = fr("i")?.let(Base64Url::decode)?.takeIf { it.size == 32 } ?: return null
            return InviteLink(s, group, m.lowercase(), k, i)
        }

        private fun pairs(text: String): List<Pair<String, String?>>? =
            text.split('&').filter { it.isNotEmpty() }.map { item ->
                val eq = item.indexOf('=')
                if (eq < 0) {
                    (decode(item) ?: return null) to null
                } else {
                    (decode(item.substring(0, eq)) ?: return null) to (decode(item.substring(eq + 1)) ?: return null)
                }
            }

        /** Percent-decoding as in a URL query; "+" stays "+". Null for broken escapes. */
        private fun decode(s: String): String? {
            if ('%' !in s) return s
            val out = ByteArrayOutputStream()
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '%') {
                    if (i + 2 >= s.length) return null
                    val v = s.substring(i + 1, i + 3).toIntOrNull(16) ?: return null
                    out.write(v)
                    i += 3
                } else {
                    out.write(c.toString().toByteArray())
                    i++
                }
            }
            return out.toString(Charsets.UTF_8.name())
        }

        /** Percent-encode a query value, keeping ":" and "/" readable like the Swift client. */
        private fun encode(s: String): String = buildString {
            for (b in s.toByteArray()) {
                val c = b.toInt().toChar()
                if (b >= 0 && (c.isLetterOrDigit() || c in "-._~:/@!$'()*,;?")) append(c) else append("%%%02X".format(b.toInt() and 0xFF))
            }
        }
    }
}
