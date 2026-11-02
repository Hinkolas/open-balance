package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.Base64Url
import io.github.hinkolas.openbalance.core.LedgerCrypto
import io.github.hinkolas.openbalance.core.RawEvent
import io.github.hinkolas.openbalance.core.SealedEvent
import io.github.hinkolas.openbalance.core.SigningKey
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.base64Url
import io.github.hinkolas.openbalance.core.lower
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** An error the server answered with (`{"error": {"code", "message"}}`, PROTOCOL.md §5). */
class ServerError(val status: Int, val code: String, override val message: String) : Exception("$message ($status)")

@Serializable
data class ServerInfo(val name: String, val version: String, val protocols: List<Int>)

/** The JSON API of PROTOCOL.md §5. Stateless; every call says which key signs. */
class ServerClient(base: String, private val http: OkHttpClient = defaultHttp) {
    val base: HttpUrl = base.toHttpUrl()

    suspend fun info(): ServerInfo = json.decodeFromJsonElement(ServerInfo.serializer(), send("GET", "/v1/info", Auth.None))

    /** [token] is the server's ADMIN_TOKEN or a creation code (PROTOCOL.md §5.3). */
    suspend fun createGroup(token: String, groupId: UUID, adminKey: ByteArray, recoveryKey: ByteArray, recoveryKeyring: ByteArray) {
        send("POST", "/v1/groups", Auth.Owner(token), buildJsonObject {
            put("groupId", groupId.lower)
            put("adminKey", adminKey.base64Url)
            put("recoveryKey", recoveryKey.base64Url)
            put("recoveryKeyring", recoveryKeyring.base64Url)
        })
    }

    @Serializable
    private data class CodeOut(val code: String, val expiresAt: String)

    /** A one-time code that lets someone else create a group (server owner only). Returns the code and its expiry (RFC 3339). */
    suspend fun createCreationCode(ownerToken: String, expiresInHours: Int = 168): Pair<String, String> {
        val out = json.decodeFromJsonElement(
            CodeOut.serializer(),
            send("POST", "/v1/admin/creation-codes", Auth.Owner(ownerToken), buildJsonObject { put("expiresInHours", expiresInHours) }),
        )
        return out.code to out.expiresAt
    }

    /** Remove a member or admin key from the group (§5.3). */
    suspend fun removeKey(signer: SigningKey, groupId: UUID, key: ByteArray) {
        send("DELETE", "/v1/groups/${groupId.lower}/keys/${key.base64Url}", Auth.Key(signer))
    }

    /** Replace the group's recovery key (admin only). */
    suspend fun replaceRecovery(signer: SigningKey, groupId: UUID, recoveryKey: ByteArray, keyring: ByteArray) {
        send("PUT", "/v1/groups/${groupId.lower}/recovery", Auth.Key(signer), buildJsonObject {
            put("recoveryKey", recoveryKey.base64Url)
            put("keyring", keyring.base64Url)
        })
    }

    /** Register [member] as the admin's only device, signed with the [recovery] key. Returns its sealed keyring. */
    suspend fun recover(recovery: SigningKey, member: SigningKey, groupId: UUID): ByteArray {
        val proof = member.sign(LedgerCrypto.claimInput(groupId, recovery.publicKey))
        return keyringOf(send("POST", "/v1/groups/${groupId.lower}/recover", Auth.Key(recovery), buildJsonObject {
            put("memberKey", member.publicKey.base64Url)
            put("proof", proof.base64Url)
        }))
    }

    /** The keyring this key got with its claim or recovery, for a retry after a lost response. */
    suspend fun keyring(signer: SigningKey, groupId: UUID): ByteArray =
        keyringOf(send("GET", "/v1/groups/${groupId.lower}/keyring", Auth.Key(signer)))

    private fun keyringOf(out: JsonElement): ByteArray {
        val text = ((out as? JsonObject)?.get("keyring") as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content
        return text?.let(Base64Url::decode) ?: throw ServerError(0, "bad_keyring", "Server sent an invalid keyring")
    }

    /**
     * [role] is what the claimed key gets on the server: `member`, or `admin`
     * for the admin's own further devices (PROTOCOL.md §5.3).
     */
    suspend fun createInvite(signer: SigningKey, groupId: UUID, inviteKey: ByteArray, keyring: ByteArray, role: String = "member") {
        send("POST", "/v1/groups/${groupId.lower}/invites", Auth.Key(signer), buildJsonObject {
            put("inviteKey", inviteKey.base64Url)
            put("role", role)
            put("keyring", keyring.base64Url)
        })
    }

    suspend fun revokeInvite(signer: SigningKey, groupId: UUID, inviteKey: ByteArray) {
        send("DELETE", "/v1/groups/${groupId.lower}/invites/${inviteKey.base64Url}", Auth.Key(signer))
    }

    /** Register [member] using the one-time [invite] key. Returns the invite's sealed keyring. */
    suspend fun claim(invite: SigningKey, member: SigningKey, groupId: UUID): ByteArray {
        val proof = member.sign(LedgerCrypto.claimInput(groupId, invite.publicKey))
        return keyringOf(send("POST", "/v1/groups/${groupId.lower}/claim", Auth.Key(invite), buildJsonObject {
            put("memberKey", member.publicKey.base64Url)
            put("proof", proof.base64Url)
        }))
    }

    @Serializable
    private data class AppendOut(val events: List<Item>) {
        @Serializable
        data class Item(val id: String, val seq: Long)
    }

    suspend fun append(signer: SigningKey, groupId: UUID, events: List<SealedEvent>): Map<UUID, Long> {
        val body = buildJsonObject {
            put("events", buildJsonArray {
                for (e in events) add(buildJsonObject {
                    put("id", e.id.lower)
                    put("blob", e.blob.base64Url)
                })
            })
        }
        val out = json.decodeFromJsonElement(AppendOut.serializer(), send("POST", "/v1/groups/${groupId.lower}/events", Auth.Key(signer), body))
        return out.events.mapNotNull { i -> Uuids.parse(i.id)?.let { it to i.seq } }.toMap()
    }

    @Serializable
    private data class ReadOut(val events: List<Item>, val head: Long) {
        @Serializable
        data class Item(val seq: Long, val id: String, val blob: String, val receivedAt: String? = null)
    }

    suspend fun read(signer: SigningKey, groupId: UUID, after: Long, limit: Int = 1000): Pair<List<RawEvent>, Long> {
        val out = json.decodeFromJsonElement(
            ReadOut.serializer(),
            send("GET", "/v1/groups/${groupId.lower}/events?after=$after&limit=$limit", Auth.Key(signer)),
        )
        val events = out.events.map {
            val id = Uuids.parse(it.id) ?: throw ServerError(0, "bad_event", "Server sent an invalid event id")
            val blob = Base64Url.decode(it.blob) ?: throw ServerError(0, "bad_blob", "Server sent an invalid blob")
            RawEvent(it.seq, id, blob, it.receivedAt)
        }
        return events to out.head
    }

    /** Heads announced by the server-sent event stream. Ends when the connection drops. */
    fun heads(signer: SigningKey, groupId: UUID): Flow<Long> = callbackFlow {
        val call = streamHttp.newCall(request("GET", "/v1/groups/${groupId.lower}/stream", Auth.Key(signer), null))
        launch(Dispatchers.IO) {
            try {
                call.execute().use { res ->
                    if (res.code != 200) throw ServerError(res.code, "stream", "Live updates unavailable")
                    val source = res.body.source()
                    while (true) {
                        val line = source.readUtf8Line() ?: break
                        if (!line.startsWith("data:")) continue
                        val seq = try {
                            (json.parseToJsonElement(line.removePrefix("data:").trim()) as? JsonObject)?.get("seq")?.toString()?.toLongOrNull()
                        } catch (_: Exception) {
                            null
                        }
                        if (seq != null) trySend(seq)
                    }
                }
                close()
            } catch (e: Exception) {
                close(e)
            }
        }
        awaitClose { call.cancel() }
    }

    // MARK: - Transport

    private sealed interface Auth {
        data object None : Auth
        class Owner(val token: String) : Auth
        class Key(val signer: SigningKey) : Auth
    }

    /** The path as signed: the base URL's own path prefix, then the API path. */
    private fun fullPath(pathAndQuery: String): String {
        val prefix = base.encodedPath.trim('/')
        return (if (prefix.isEmpty()) "" else "/$prefix") + pathAndQuery
    }

    private fun request(method: String, pathAndQuery: String, auth: Auth, body: ByteArray?): Request {
        val full = fullPath(pathAndQuery)
        val url = base.resolve(full) ?: throw IOException("bad URL")
        val b = Request.Builder().url(url)
        b.method(method, body?.toRequestBody(jsonType) ?: if (method == "POST") ByteArray(0).toRequestBody(jsonType) else null)
        when (auth) {
            Auth.None -> {}
            is Auth.Owner -> b.header("Authorization", "Bearer ${auth.token}")
            is Auth.Key -> {
                val ts = System.currentTimeMillis() / 1000
                b.header("Authorization", LedgerCrypto.authorization(auth.signer, method, full, ts, body ?: ByteArray(0)))
            }
        }
        return b.build()
    }

    private suspend fun send(method: String, path: String, auth: Auth, body: JsonObject? = null): JsonElement {
        val bytes = body?.let { json.encodeToString(JsonObject.serializer(), it).toByteArray() }
        val res = http.newCall(request(method, path, auth, bytes)).await()
        val text = res.use { it.body.string() }
        if (res.code !in 200..299) {
            val err = try {
                (json.parseToJsonElement(text) as? JsonObject)?.get("error") as? JsonObject
            } catch (_: Exception) {
                null
            }
            fun field(name: String) = (err?.get(name) as? kotlinx.serialization.json.JsonPrimitive)?.content
            throw ServerError(res.code, field("code") ?: "http_${res.code}", field("message") ?: "Server error")
        }
        if (text.isBlank()) return JsonObject(emptyMap())
        return json.parseToJsonElement(text)
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }
        private val jsonType = "application/json".toMediaType()

        val defaultHttp: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(60, TimeUnit.SECONDS)
            .build()

        /** The stream sends a head every 30 s; give up after 90 s of silence. */
        private val streamHttp: OkHttpClient = defaultHttp.newBuilder()
            .readTimeout(90, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.SECONDS)
            .build()
    }
}

/** Run the call without blocking a thread; cancelling the coroutine cancels the call. */
internal suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            cont.resume(response) { _, r, _ -> r.close() }
        }

        override fun onFailure(call: Call, e: IOException) {
            if (!cont.isCancelled) cont.resumeWithException(e)
        }
    })
}
