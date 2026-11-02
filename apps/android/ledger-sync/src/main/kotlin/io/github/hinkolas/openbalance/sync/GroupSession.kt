package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.Base64Url
import io.github.hinkolas.openbalance.core.Bytes
import io.github.hinkolas.openbalance.core.EventData
import io.github.hinkolas.openbalance.core.EventWriter
import io.github.hinkolas.openbalance.core.Ledger
import io.github.hinkolas.openbalance.core.LedgerState
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.RawEvent
import io.github.hinkolas.openbalance.core.SealedEvent
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.base64Url
import io.github.hinkolas.openbalance.core.lower
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One group on this device: the confirmed ledger from the server, the outbox
 * of events written here and not yet appended, and the state both produce.
 *
 * Writes are optimistic: [submit] seals the event, shows it immediately and
 * syncs in the background. Appends are idempotent (event ids), so retries
 * after a crash or a lost response are safe.
 *
 * Thread-safe: state changes happen under one lock, syncs run one after
 * another, and everything observable is a [StateFlow].
 */
class GroupSession(
    credentials: GroupCredentials,
    internal val store: CredentialStore,
    cacheRoot: File,
    private val scope: CoroutineScope,
) {
    val id: UUID = credentials.groupUuid

    private val _credentials = MutableStateFlow(credentials)
    val credentials: StateFlow<GroupCredentials> = _credentials.asStateFlow()

    private val lock = Any()
    private val cache = GroupCache(File(cacheRoot, "groups/${id.lower}"))
    internal val client = ServerClient(credentials.server)
    private val ledger = Ledger(id, credentials.secretBytes)
    private val confirmed = ArrayList<RawEvent>(cache.loadEvents())
    private val outbox = ArrayList<SealedEvent>(cache.loadOutbox())
    private val pushed = HashSet<UUID>()

    /** Confirmed ledger plus pending outbox events. */
    private val _state: MutableStateFlow<LedgerState>
    val state: StateFlow<LedgerState>

    private val _pendingCount = MutableStateFlow(0)
    /** Events written here that the server hasn't confirmed yet. */
    val pendingCount: StateFlow<Int> = _pendingCount.asStateFlow()

    private val _isSyncing = MutableStateFlow(false)
    val isSyncing: StateFlow<Boolean> = _isSyncing.asStateFlow()

    private val _lastError = MutableStateFlow<Throwable?>(null)
    /** The last background sync failed with this; cleared by the next success. */
    val lastError: StateFlow<Throwable?> = _lastError.asStateFlow()

    private val _isLive = MutableStateFlow(false)
    val isLive: StateFlow<Boolean> = _isLive.asStateFlow()

    private val _accessLost = MutableStateFlow(false)
    /** The server refused this device's key: it was removed, or the group is gone. */
    val accessLost: StateFlow<Boolean> = _accessLost.asStateFlow()

    /** This device's public member key. */
    val deviceKey: Bytes = Bytes(credentials.signer.publicKey)

    private val syncMutex = Mutex()
    private val syncQueued = AtomicBoolean(false)
    private var liveJob: Job? = null

    init {
        ledger.apply(confirmed)
        _state = MutableStateFlow(ledger.state.snapshot())
        state = _state.asStateFlow()
        recompute()
    }

    val me: MemberId get() = _credentials.value.memberId
    val isAdmin: Boolean get() = _state.value.adminId == me && !isRemoved

    /**
     * This device no longer belongs to the group: removed in the ledger, or
     * refused by the server. It can only forget the group.
     */
    val isRemoved: Boolean get() = isRemoved(_state.value, _accessLost.value)

    /** [isRemoved] for a given state, for UIs that observe [state] and [accessLost]. */
    fun isRemoved(state: LedgerState, accessLost: Boolean): Boolean = accessLost || deviceKey in state.removedKeys

    // MARK: - Writing

    /** Seal an event as this member, show it, and sync. */
    fun submit(data: EventData): SealedEvent {
        val event = synchronized(lock) {
            val c = _credentials.value
            val writer = EventWriter(id, c.secretBytes, c.memberId, c.signer)
            val e = writer.write(data, ledger.state.head)
            outbox.add(e)
            cache.saveOutbox(outbox)
            recompute()
            e
        }
        requestSync()
        return event
    }

    fun updateCredentials(change: (GroupCredentials) -> GroupCredentials) {
        synchronized(lock) {
            val next = change(_credentials.value)
            store.save(next)
            _credentials.value = next
        }
    }

    // MARK: - Sync

    /** Push the outbox, then pull new events, in the background. Requests while one is queued coalesce. */
    fun requestSync() {
        if (!syncQueued.compareAndSet(false, true)) return
        scope.launch {
            syncMutex.withLock {
                syncQueued.set(false)
                _isSyncing.value = true
                try {
                    noteAccess {
                        push()
                        pull()
                    }
                    _lastError.value = null
                } catch (e: CancellationException) {
                    throw e
                } catch (e: ServerError) {
                    _lastError.value = if (e.status == 403 && _accessLost.value) null else e
                } catch (e: Exception) {
                    _lastError.value = e
                } finally {
                    _isSyncing.value = false
                }
            }
        }
    }

    /** Sync and wait for it, throwing the first error. */
    suspend fun syncNow() {
        syncMutex.withLock {
            noteAccess {
                push()
                pull()
            }
            _lastError.value = null
        }
    }

    /** A 403 for a registered key means the server cut this device off. */
    private suspend fun noteAccess(op: suspend () -> Unit) {
        try {
            op()
        } catch (e: ServerError) {
            if (e.status == 403 && _credentials.value.registered) {
                _accessLost.value = true
                stopLive()
            }
            throw e
        }
    }

    /**
     * Append outbox events not yet sent in this run. They stay in the outbox
     * (and on screen as pending) until a pull returns them.
     */
    private suspend fun push() {
        val c = _credentials.value
        if (!c.registered) return
        val unsent = synchronized(lock) { outbox.filter { it.id !in pushed } }
        if (unsent.isEmpty()) return
        for (batch in unsent.chunked(100)) {
            client.append(c.signer, id, batch)
            synchronized(lock) { pushed.addAll(batch.map { it.id }) }
        }
    }

    private suspend fun pull() {
        val c = _credentials.value
        if (!c.registered) return
        val signer = c.signer
        while (true) {
            val after = synchronized(lock) { ledger.state.lastSeq }
            val (page, head) = client.read(signer, id, after)
            val done = synchronized(lock) {
                val events = page.filter { it.seq > ledger.state.lastSeq }
                if (events.isNotEmpty()) {
                    confirmed.addAll(events)
                    ledger.apply(events)
                    cache.saveEvents(confirmed)
                    outbox.removeAll { it.id in ledger.state.seenIds }
                    cache.saveOutbox(outbox)
                    recompute()
                }
                page.isEmpty() || ledger.state.lastSeq >= head || ledger.state.inconsistency != null
            }
            if (done) break
        }
    }

    /** Must hold [lock]. */
    private fun recompute() {
        val l = ledger.copy()
        val confirmedIds = l.state.seenIds.toSet()
        for (e in outbox) if (e.id !in confirmedIds) l.applyPending(e.id, e.body)
        _state.value = l.state
        _pendingCount.value = outbox.size
    }

    /** The newest seq the confirmed ledger has. */
    val lastSeq: Long get() = synchronized(lock) { ledger.state.lastSeq }

    // MARK: - Live updates

    /** Keep a stream open while the app is in the foreground; pull on every new head. */
    fun startLive() {
        synchronized(lock) {
            if (liveJob != null || isRemoved) return
            liveJob = scope.launch {
                var backoff = 1_000L
                while (isActive) {
                    requestSync()
                    try {
                        client.heads(_credentials.value.signer, id).collect { head ->
                            _isLive.value = true
                            backoff = 1_000L
                            if (head > lastSeq) requestSync()
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                    }
                    _isLive.value = false
                    delay(backoff)
                    backoff = minOf(backoff * 2, 30_000L)
                }
            }
        }
    }

    fun stopLive() {
        synchronized(lock) {
            liveJob?.cancel()
            liveJob = null
        }
        _isLive.value = false
    }

    /** Remove all local data of this group (credentials and cache). */
    fun forget() {
        stopLive()
        cache.deleteAll()
        store.delete(id)
    }

    /** Create and join live in Flows.kt as extensions on this. */
    companion object
}

/** Files under <cacheRoot>/groups/<id>/. Blobs are ciphertext; the key lives with the credentials. */
internal class GroupCache(private val dir: File) {
    @Serializable
    private data class Event(val seq: Long, val id: String, val blob: String, val receivedAt: String? = null)

    @Serializable
    private data class Outgoing(val id: String, val body: String, val blob: String)

    private val json = Json { ignoreUnknownKeys = true }

    init {
        dir.mkdirs()
    }

    fun loadEvents(): List<RawEvent> = load("events.json", ListSerializer(Event.serializer()))?.mapNotNull { e ->
        val id = Uuids.parse(e.id) ?: return@mapNotNull null
        RawEvent(e.seq, id, Base64Url.decode(e.blob) ?: return@mapNotNull null, e.receivedAt)
    } ?: emptyList()

    fun saveEvents(events: List<RawEvent>) =
        save("events.json", ListSerializer(Event.serializer()), events.map { Event(it.seq, it.id.lower, it.blob.base64Url, it.receivedAt) })

    fun loadOutbox(): List<SealedEvent> = load("outbox.json", ListSerializer(Outgoing.serializer()))?.mapNotNull { e ->
        val id = Uuids.parse(e.id) ?: return@mapNotNull null
        SealedEvent(id, Base64Url.decode(e.body) ?: return@mapNotNull null, Base64Url.decode(e.blob) ?: return@mapNotNull null)
    } ?: emptyList()

    fun saveOutbox(events: List<SealedEvent>) =
        save("outbox.json", ListSerializer(Outgoing.serializer()), events.map { Outgoing(it.id.lower, it.body.base64Url, it.blob.base64Url) })

    fun deleteAll() {
        dir.deleteRecursively()
    }

    private fun <T> load(name: String, serializer: kotlinx.serialization.KSerializer<T>): T? = try {
        File(dir, name).takeIf { it.exists() }?.readText()?.let { json.decodeFromString(serializer, it) }
    } catch (_: Exception) {
        null
    }

    /** Write to a temporary file, then rename: a crash never leaves half a file. */
    private fun <T> save(name: String, serializer: kotlinx.serialization.KSerializer<T>, value: T) {
        try {
            dir.mkdirs()
            val tmp = File(dir, "$name.tmp")
            tmp.writeText(json.encodeToString(serializer, value))
            if (!tmp.renameTo(File(dir, name))) {
                File(dir, name).delete()
                tmp.renameTo(File(dir, name))
            }
        } catch (_: Exception) {
        }
    }
}
