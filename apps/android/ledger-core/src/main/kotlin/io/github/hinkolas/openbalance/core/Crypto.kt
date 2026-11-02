package io.github.hinkolas.openbalance.core

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

/**
 * An Ed25519 key pair from its 32-byte seed (the RFC 8032 private key).
 * Member keys and invite keys are both of this kind.
 */
class SigningKey(seed: ByteArray) {
    init {
        require(seed.size == 32) { "Ed25519 seeds are 32 bytes" }
    }

    private val private = Ed25519PrivateKeyParameters(seed, 0)

    /** The seed; what gets stored. */
    val seed: ByteArray get() = private.encoded

    /** 32 raw bytes. */
    val publicKey: ByteArray = private.generatePublicKey().encoded

    fun sign(message: ByteArray): ByteArray {
        val s = Ed25519Signer()
        s.init(true, private)
        s.update(message, 0, message.size)
        return s.generateSignature()
    }

    companion object {
        fun generate(): SigningKey = SigningKey(randomBytes(32))
    }
}

/**
 * An X25519 box key (§3.5): 32 private bytes, clamped as RFC 7748 says when
 * used. Receives epoch secrets sealed to its public key.
 */
class BoxKey(privateBytes: ByteArray) {
    init {
        require(privateBytes.size == 32) { "X25519 private keys are 32 bytes" }
    }

    private val private = X25519PrivateKeyParameters(privateBytes, 0)

    /** The bytes as given (not clamped), like CryptoKit's rawRepresentation. */
    val privateBytes: ByteArray = privateBytes.copyOf()

    /** 32 raw bytes. */
    val publicKey: ByteArray = private.generatePublicKey().encoded

    /** X25519 with [peer]. Throws on a low-order peer (all-zero result). */
    fun agree(peer: ByteArray): ByteArray {
        if (peer.size != 32) throw LedgerCrypto.Failure("bad box key")
        val out = ByteArray(32)
        try {
            private.generateSecret(X25519PublicKeyParameters(peer, 0), out, 0)
        } catch (e: Exception) {
            throw LedgerCrypto.Failure("key agreement: ${e.message}")
        }
        if (out.all { it == 0.toByte() }) throw LedgerCrypto.Failure("all-zero shared secret")
        return out
    }

    companion object {
        fun generate(): BoxKey = BoxKey(randomBytes(32))
    }
}

object Ed25519 {
    fun verify(publicKey: ByteArray, signature: ByteArray, message: ByteArray): Boolean {
        if (publicKey.size != 32 || signature.size != 64) return false
        return try {
            val v = Ed25519Signer()
            v.init(false, Ed25519PublicKeyParameters(publicKey, 0))
            v.update(message, 0, message.size)
            v.verifySignature(signature)
        } catch (_: Exception) {
            false
        }
    }
}

fun sha256(vararg parts: ByteArray): ByteArray {
    val d = MessageDigest.getInstance("SHA-256")
    for (p in parts) d.update(p)
    return d.digest()
}

/**
 * Key derivation, event envelope, signatures, hash chain and request signing
 * (PROTOCOL.md §3, §5.1, §6). Mirrors internal/protocol in Go.
 */
object LedgerCrypto {
    const val BLOB_VERSION: Byte = 0x02
    const val PAD_BLOCK = 256
    /** Version, epoch and nonce (§6.1). */
    const val BLOB_HEADER = 1 + 4 + 12
    const val LABEL_EPOCH = "open-balance/v1/epoch"
    const val LABEL_KEYRING = "open-balance/v1/keyring"

    private const val LABEL_ENC = "open-balance/v1/enc"
    private const val LABEL_EVENT = "open-balance/v1/event"
    private const val LABEL_SIG = "open-balance/v1/sig"
    private const val LABEL_CHAIN = "open-balance/v1/chain"
    private const val LABEL_REQ = "open-balance/v1/req\n"
    private const val LABEL_CLAIM = "open-balance/v1/claim"
    private const val LABEL_RECOVER = "open-balance/v1/recover"
    private const val LABEL_BOX = "open-balance/v1/box"

    class Failure(message: String) : Exception(message)

    /** K_e, the key of epoch [epoch] of a group (§3.1). */
    fun encKey(secret: ByteArray, groupId: UUID, epoch: Long): ByteArray {
        if (secret.size != 32) throw Failure("bad secret")
        return hkdf(secret, groupId.bytes, LABEL_ENC.toByteArray() + u32(epoch))
    }

    private fun hkdf(ikm: ByteArray, salt: ByteArray?, info: ByteArray): ByteArray {
        val g = HKDFBytesGenerator(SHA256Digest())
        g.init(HKDFParameters(ikm, salt, info))
        return ByteArray(32).also { g.generateBytes(it, 0, 32) }
    }

    /** u32be; epochs are unsigned 32-bit, kept in a Long. */
    fun u32(v: Long): ByteArray = ByteBuffer.allocate(4).putInt(v.toInt()).array()

    fun aad(groupId: UUID, eventId: UUID, epoch: Long): ByteArray =
        LABEL_EVENT.toByteArray() + groupId.bytes + eventId.bytes + u32(epoch)

    /** The epoch a blob was sealed with, null if it isn't a version 2 blob (§6.1). */
    fun blobEpoch(blob: ByteArray): Long? {
        if (blob.size < BLOB_HEADER + 16 || blob[0] != BLOB_VERSION) return null
        return ByteBuffer.wrap(blob, 1, 4).int.toLong() and 0xFFFFFFFFL
    }

    fun eventSigningInput(groupId: UUID, eventId: UUID, body: ByteArray): ByteArray =
        LABEL_SIG.toByteArray() + groupId.bytes + eventId.bytes + body

    /** Frame and pad body + signature (§6.1). */
    fun plaintext(body: ByteArray, signature: ByteArray): ByteArray {
        val n = 4 + body.size + 64
        val padded = (n + PAD_BLOCK - 1) / PAD_BLOCK * PAD_BLOCK
        return ByteBuffer.allocate(padded).putInt(body.size).put(body).put(signature).array()
    }

    /** ChaCha20-Poly1305 with a 96-bit nonce: ciphertext ‖ tag. */
    fun chachaSeal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray {
        val c = ChaCha20Poly1305()
        c.init(true, AEADParameters(KeyParameter(key), 128, nonce, aad))
        val out = ByteArray(c.getOutputSize(plaintext.size))
        val n = c.processBytes(plaintext, 0, plaintext.size, out, 0)
        c.doFinal(out, n)
        return out
    }

    fun chachaOpen(key: ByteArray, nonce: ByteArray, sealed: ByteArray, aad: ByteArray): ByteArray {
        val c = ChaCha20Poly1305()
        c.init(false, AEADParameters(KeyParameter(key), 128, nonce, aad))
        val out = ByteArray(c.getOutputSize(sealed.size))
        val n = c.processBytes(sealed, 0, sealed.size, out, 0)
        c.doFinal(out, n)
        return out
    }

    /** Sign the body with the author's key and encrypt it into a blob of [epoch]; [key] is that epoch's K_e. */
    fun seal(
        body: ByteArray, groupId: UUID, eventId: UUID, epoch: Long, key: ByteArray, signer: SigningKey,
        nonce: ByteArray = randomBytes(12),
    ): ByteArray {
        val signature = signer.sign(eventSigningInput(groupId, eventId, body))
        return sealSigned(body, signature, groupId, eventId, epoch, key, nonce)
    }

    /** Encrypt an already signed body. Split out so tests can match vectors byte for byte. */
    fun sealSigned(body: ByteArray, signature: ByteArray, groupId: UUID, eventId: UUID, epoch: Long, key: ByteArray, nonce: ByteArray): ByteArray {
        val box = chachaSeal(key, nonce, plaintext(body, signature), aad(groupId, eventId, epoch))
        return byteArrayOf(BLOB_VERSION) + u32(epoch) + nonce + box
    }

    class Opened(val body: ByteArray, val signature: ByteArray)

    /**
     * Decrypt a blob with the key of its epoch (see [blobEpoch]). Does not
     * verify the signature (the author's key comes from the ledger).
     */
    fun open(blob: ByteArray, groupId: UUID, eventId: UUID, key: ByteArray): Opened {
        val epoch = blobEpoch(blob) ?: throw Failure("not a blob")
        val nonce = blob.copyOfRange(5, BLOB_HEADER)
        val p = try {
            chachaOpen(key, nonce, blob.copyOfRange(BLOB_HEADER, blob.size), aad(groupId, eventId, epoch))
        } catch (e: Exception) {
            throw Failure("decrypt: ${e.message}")
        }
        if (p.size < 4) throw Failure("bad plaintext")
        val n = ByteBuffer.wrap(p, 0, 4).int.toLong() and 0xFFFFFFFFL
        if (4 + n + 64 > p.size) throw Failure("bad plaintext")
        val len = n.toInt()
        return Opened(p.copyOfRange(4, 4 + len), p.copyOfRange(4 + len, 4 + len + 64))
    }

    fun verify(signature: ByteArray, body: ByteArray, groupId: UUID, eventId: UUID, publicKey: ByteArray): Boolean =
        Ed25519.verify(publicKey, signature, eventSigningInput(groupId, eventId, body))

    val chainZero: ByteArray get() = ByteArray(32)

    /** chain_n from chain_{n-1} (§6.4). */
    fun chainNext(prev: ByteArray, seq: Long, eventId: UUID, blob: ByteArray): ByteArray =
        sha256(LABEL_CHAIN.toByteArray(), prev, ByteBuffer.allocate(8).putLong(seq).array(), eventId.bytes, sha256(blob))

    /**
     * Signed twice during a join: member key over the invite key (server
     * proof), invite key over the member key (ledger inviteSig).
     */
    fun claimInput(groupId: UUID, key: ByteArray): ByteArray = LABEL_CLAIM.toByteArray() + groupId.bytes + key

    /** Signed by the recovery key for the admin's new device key (§3.4). */
    fun recoverInput(groupId: UUID, key: ByteArray): ByteArray = LABEL_RECOVER.toByteArray() + groupId.bytes + key

    // MARK: - Box keys and sealing (§3.5)

    /** The X25519 box key of a seed: a member key seed, an invite seed or the recovery seed. */
    fun boxKey(seed: ByteArray): BoxKey {
        if (seed.size != 32) throw Failure("bad seed")
        return BoxKey(hkdf(seed, null, LABEL_BOX.toByteArray()))
    }

    /** Seal [message] to the box key [to] (32 raw bytes). */
    fun seal(message: ByteArray, to: ByteArray, label: String, groupId: UUID, ephemeral: BoxKey = BoxKey.generate()): ByteArray {
        val ePub = ephemeral.publicKey
        val key = sealKey(ephemeral.agree(to), ePub, to, label, groupId)
        return ePub + chachaSeal(key, ByteArray(12), message, ByteArray(0))
    }

    /** Open what [seal] sealed to [box]'s public key. */
    fun open(sealed: ByteArray, box: BoxKey, label: String, groupId: UUID): ByteArray {
        if (sealed.size < 32 + 16) throw Failure("sealed data too short")
        val ePub = sealed.copyOfRange(0, 32)
        val key = sealKey(box.agree(ePub), ePub, box.publicKey, label, groupId)
        return try {
            chachaOpen(key, ByteArray(12), sealed.copyOfRange(32, sealed.size), ByteArray(0))
        } catch (e: Exception) {
            throw Failure("open: ${e.message}")
        }
    }

    private fun sealKey(z: ByteArray, ePub: ByteArray, to: ByteArray, label: String, groupId: UUID): ByteArray =
        hkdf(z, groupId.bytes, label.toByteArray() + ePub + to)

    fun requestSigningInput(method: String, pathAndQuery: String, ts: Long, body: ByteArray): ByteArray =
        "$LABEL_REQ$method\n$pathAndQuery\n$ts\n${sha256(body).hex}".toByteArray()

    /** `Authorization: OB1 key=…, ts=…, sig=…` (§5.1). */
    fun authorization(signer: SigningKey, method: String, pathAndQuery: String, ts: Long, body: ByteArray): String {
        val sig = signer.sign(requestSigningInput(method, pathAndQuery, ts, body))
        return "OB1 key=${signer.publicKey.base64Url}, ts=$ts, sig=${sig.base64Url}"
    }
}
