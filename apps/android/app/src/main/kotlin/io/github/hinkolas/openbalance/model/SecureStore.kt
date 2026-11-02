package io.github.hinkolas.openbalance.model

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.github.hinkolas.openbalance.core.hex
import io.github.hinkolas.openbalance.core.sha256
import io.github.hinkolas.openbalance.sync.CredentialStore
import io.github.hinkolas.openbalance.sync.GroupCredentials
import io.github.hinkolas.openbalance.sync.ServerOwnership
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small records sealed with AES-256-GCM under a key in the Android Keystore,
 * one file each, in app storage that is never backed up. The Android
 * counterpart of the iOS Keychain items: group secrets, member keys and
 * server admin tokens live here and nowhere else.
 *
 * The key needs no user authentication, so sync works in the background
 * (like iOS's "after first unlock"). Unlike iCloud Keychain it doesn't sync:
 * another device joins with a device invite (PROTOCOL.md §5.4).
 */
class SecureStore(context: Context, private val name: String) {
    private val dir = File(context.noBackupFilesDir, "secure/$name").apply { mkdirs() }

    fun save(account: String, value: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val sealed = cipher.doFinal(value)
        val out = ByteBuffer.allocate(1 + iv.size + sealed.size).put(iv.size.toByte()).put(iv).put(sealed).array()
        val tmp = File(dir, "${file(account)}.tmp")
        tmp.writeBytes(out)
        if (!tmp.renameTo(File(dir, file(account)))) throw java.io.IOException("Can't write $name")
    }

    fun load(account: String): ByteArray? = open(File(dir, file(account)))

    fun all(): List<ByteArray> = dir.listFiles { f -> f.isFile && !f.name.endsWith(".tmp") }?.mapNotNull(::open) ?: emptyList()

    fun delete(account: String) {
        File(dir, file(account)).delete()
    }

    private fun open(f: File): ByteArray? = try {
        val bytes = f.readBytes()
        val ivLen = bytes[0].toInt()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 1, ivLen))
        cipher.doFinal(bytes, 1 + ivLen, bytes.size - 1 - ivLen)
    } catch (_: Exception) {
        null
    }

    /** Account names may be URLs; file names are their hash. */
    private fun file(account: String) = sha256(account.toByteArray()).hex.take(32)


    companion object {
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val ALIAS = "open-balance.secure-store"

        @Synchronized
        private fun key(): SecretKey {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
            val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            gen.init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            return gen.generateKey()
        }
    }
}

private val json = Json { ignoreUnknownKeys = true }

/** Group credentials in the [SecureStore]. */
class KeystoreCredentialStore(context: Context) : CredentialStore {
    private val store = SecureStore(context, "groups")

    override fun save(credentials: GroupCredentials) =
        store.save(credentials.groupId, json.encodeToString(GroupCredentials.serializer(), credentials).toByteArray())

    override fun delete(groupId: UUID) = store.delete(groupId.toString())

    override fun all(): List<GroupCredentials> = store.all().mapNotNull {
        try {
            json.decodeFromString(GroupCredentials.serializer(), it.decodeToString())
        } catch (_: Exception) {
            null
        }
    }
}

/** Servers this device may create groups on, with their admin tokens. */
class ServerStore(context: Context) {
    private val store = SecureStore(context, "servers")

    fun save(s: ServerOwnership) = store.save(s.server, json.encodeToString(ServerOwnership.serializer(), s).toByteArray())

    fun delete(server: String) = store.delete(server)

    fun all(): List<ServerOwnership> = store.all().mapNotNull {
        try {
            json.decodeFromString(ServerOwnership.serializer(), it.decodeToString())
        } catch (_: Exception) {
            null
        }
    }
}
