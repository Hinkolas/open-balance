package io.github.hinkolas.openbalance.core

import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID

private val secureRandom = SecureRandom()

/** [count] bytes from a CSPRNG. */
fun randomBytes(count: Int): ByteArray = ByteArray(count).also { secureRandom.nextBytes(it) }

/** base64url without padding (PROTOCOL.md §2). */
object Base64Url {
    private val encoder = Base64.getUrlEncoder().withoutPadding()
    private val decoder = Base64.getUrlDecoder()

    fun encode(bytes: ByteArray): String = encoder.encodeToString(bytes)

    /**
     * base64url without padding. Like the Swift client, also accepts the
     * standard alphabet's "+" and "/" (it maps "-_" to "+/" before decoding),
     * so both clients read the same keys from the same events. No padding,
     * no whitespace.
     */
    fun decode(text: String): ByteArray? {
        if (text.any { !(it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' || it == '+' || it == '/') }) return null
        return try {
            decoder.decode(text.replace('+', '-').replace('/', '_'))
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

val ByteArray.base64Url: String get() = Base64Url.encode(this)

val ByteArray.hex: String get() = joinToString("") { "%02x".format(it) }

/**
 * Immutable bytes with value equality: public keys, chain hashes. Plain
 * `ByteArray` compares by reference, which would make states unequal.
 */
class Bytes(bytes: ByteArray) : Comparable<Bytes> {
    private val data = bytes.copyOf()
    val size: Int get() = data.size

    fun toByteArray(): ByteArray = data.copyOf()

    val base64Url: String get() = Base64Url.encode(data)

    override fun equals(other: Any?): Boolean = other is Bytes && data.contentEquals(other.data)
    override fun hashCode(): Int = data.contentHashCode()
    override fun toString(): String = base64Url
    override fun compareTo(other: Bytes): Int = compareUnsigned(data, other.data)

    companion object {
        fun ofBase64Url(text: String): Bytes? = Base64Url.decode(text)?.let(::Bytes)
    }
}

/** Unsigned lexicographic byte order. */
fun compareUnsigned(a: ByteArray, b: ByteArray): Int {
    for (i in 0 until minOf(a.size, b.size)) {
        val c = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
        if (c != 0) return c
    }
    return a.size - b.size
}

/**
 * Member ids sort by the bytes of their string (PROTOCOL.md §9.1: "byte order
 * of the lowercase UUID string"). Same as Go's string comparison.
 */
val memberIdOrder: Comparator<String> = Comparator { a, b -> compareUnsigned(a.toByteArray(), b.toByteArray()) }

object Uuids {
    private val pattern = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    /** Strict 8-4-4-4-12 form. `UUID.fromString` alone also accepts "1-1-1-1-1". */
    fun parse(text: String): UUID? = if (pattern.matches(text)) UUID.fromString(text) else null

    /** A new UUIDv7 (RFC 9562): 48-bit Unix milliseconds, version, random. */
    fun v7(nowMillis: Long = System.currentTimeMillis()): UUID {
        val b = randomBytes(16)
        val ms = maxOf(0L, nowMillis)
        for (i in 0 until 6) b[i] = ((ms ushr (8 * (5 - i))) and 0xFF).toByte()
        b[6] = ((b[6].toInt() and 0x0F) or 0x70).toByte()
        b[8] = ((b[8].toInt() and 0x3F) or 0x80).toByte()
        val bb = ByteBuffer.wrap(b)
        return UUID(bb.long, bb.long)
    }
}

/** The 16 raw bytes. */
val UUID.bytes: ByteArray
    get() = ByteBuffer.allocate(16).putLong(mostSignificantBits).putLong(leastSignificantBits).array()

/** Lowercase hyphenated form, the only form used in events. */
val UUID.lower: String get() = toString()
