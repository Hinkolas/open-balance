package io.github.hinkolas.openbalance.model

import android.app.Application
import android.content.Context
import androidx.core.content.edit
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.sync.AppLink
import io.github.hinkolas.openbalance.sync.CreationLink
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.sync.InviteLink
import io.github.hinkolas.openbalance.sync.RecoveryLink
import io.github.hinkolas.openbalance.sync.ServerClient
import io.github.hinkolas.openbalance.sync.ServerOwnership
import io.github.hinkolas.openbalance.sync.create
import io.github.hinkolas.openbalance.sync.join
import io.github.hinkolas.openbalance.sync.recover
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * App-wide state: the groups on this device, which one is active, the
 * servers this device may create groups on, and links (invite, recovery,
 * creation) waiting for their screen.
 */
class AppModel(private val app: Application) {
    /** Sessions sync here, off the main thread. */
    private val sessionScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val credentials = KeystoreCredentialStore(app)
    private val serverStore = ServerStore(app)
    private val prefs = app.getSharedPreferences("app", Context.MODE_PRIVATE)
    private val cacheRoot: File = app.filesDir

    private val _loaded = MutableStateFlow(false)
    /** False until the groups on this device have been read and replayed. */
    val loaded: StateFlow<Boolean> = _loaded.asStateFlow()

    private val _sessions = MutableStateFlow<List<GroupSession>>(emptyList())
    val sessions: StateFlow<List<GroupSession>> = _sessions.asStateFlow()

    private val _servers = MutableStateFlow<List<ServerOwnership>>(emptyList())
    val servers: StateFlow<List<ServerOwnership>> = _servers.asStateFlow()

    private val activeId = MutableStateFlow<UUID?>(null)

    val active: StateFlow<GroupSession?> = combine(_sessions, activeId) { s, id -> s.firstOrNull { it.id == id } ?: s.firstOrNull() }
        .stateIn(scope, SharingStarted.Eagerly, null)

    /** A link opened from outside or scanned, waiting for the join or create screen. */
    val pendingLink = MutableStateFlow<AppLink?>(null)

    /** A one-line message for the user, shown once. */
    val toast = MutableStateFlow<String?>(null)

    /** What a screen hands to the next one (a payment draft, an invite to show). */
    val handoff = Handoff()

    private var foreground = false

    init {
        scope.launch {
            load()
            active.collect { updateLive() }
        }
    }

    /** Reads credentials and replays cached ledgers, off the main thread. */
    private suspend fun load() {
        val (sessions, servers) = withContext(Dispatchers.Default) {
            val creds = credentials.all().filter { it.registered }.sortedBy { it.addedAt }
            val s = creds.mapNotNull { c ->
                try {
                    GroupSession(c, credentials, cacheRoot, sessionScope)
                } catch (_: Exception) {
                    null
                }
            }
            s to serverStore.all().sortedBy { it.name }
        }
        _sessions.value = sessions
        _servers.value = servers
        val saved = prefs.getString("activeGroup", null)?.let { runCatching { UUID.fromString(it) }.getOrNull() }
        activeId.value = saved?.takeIf { id -> sessions.any { it.id == id } } ?: sessions.firstOrNull()?.id
        _loaded.value = true
    }

    fun activate(id: UUID) {
        activeId.value = id
        prefs.edit { putString("activeGroup", id.toString()) }
    }

    fun setForeground(on: Boolean) {
        foreground = on
        updateLive()
    }

    private fun updateLive() {
        val current = active.value
        for (s in _sessions.value) if (s.id != current?.id || !foreground) s.stopLive()
        if (foreground) current?.startLive()
    }

    // MARK: - Links

    /** An `openbalance://join`, `recover` or `create` link from a VIEW intent, a scan or the clipboard. */
    fun handle(url: String) {
        val link = AppLink.parse(url)
        if (link != null) {
            pendingLink.value = link
        } else {
            toast.value = app.getString(R.string.not_an_app_link)
        }
    }

    // MARK: - Groups

    suspend fun join(link: InviteLink) {
        _sessions.value.firstOrNull { it.id == link.groupId }?.let {
            activate(it.id)
            return
        }
        val interrupted = withContext(Dispatchers.IO) {
            credentials.all().firstOrNull { it.groupUuid == link.groupId && it.memberId == link.memberId }
        }
        val session = GroupSession.join(link, interrupted, credentials, cacheRoot, sessionScope)
        _sessions.value = _sessions.value + session
        activate(session.id)
    }

    /**
     * Take over the admin's seat with a recovery kit. A group this device
     * still has access to is just shown; one it was removed from is
     * forgotten first.
     */
    suspend fun recover(link: RecoveryLink) {
        _sessions.value.firstOrNull { it.id == link.groupId }?.let {
            if (!it.isRemoved) {
                activate(it.id)
                return
            }
            forget(it)
        }
        val interrupted = withContext(Dispatchers.IO) {
            credentials.all().firstOrNull { it.groupUuid == link.groupId && it.memberId == link.adminId && !it.registered }
        }
        val session = GroupSession.recover(link, interrupted, credentials, cacheRoot, sessionScope)
        _sessions.value = _sessions.value + session
        activate(session.id)
    }

    /**
     * Create a group as its admin, with the server's admin token or a
     * creation code. Returns the recovery kit to show once.
     */
    suspend fun create(server: String, token: String, name: String, currency: String, myName: String): RecoveryLink {
        val (session, kit) = GroupSession.create(server, token, name, currency, myName, credentials, cacheRoot, sessionScope)
        _sessions.value = _sessions.value + session
        activate(session.id)
        return kit
    }

    /** A one-time link (7 days) that lets someone else create a group on a server this device owns. */
    suspend fun creationLink(server: ServerOwnership): CreationLink {
        val (code, _) = ServerClient(server.server).createCreationCode(server.token)
        return CreationLink(server.server, code)
    }

    /** Remove a group from this device. The ledger stays on the server. */
    fun forget(session: GroupSession) {
        session.forget()
        _sessions.value = _sessions.value.filter { it.id != session.id }
        if (activeId.value == session.id) _sessions.value.firstOrNull()?.let { activate(it.id) } ?: run { activeId.value = null }
    }

    // MARK: - Servers

    suspend fun addServer(url: String, token: String): ServerOwnership {
        val info = ServerClient(url).info()
        val ownership = ServerOwnership(url, token, info.name)
        withContext(Dispatchers.IO) { serverStore.save(ownership) }
        _servers.value = (_servers.value.filter { it.server != url } + ownership).sortedBy { it.name }
        return ownership
    }

    fun removeServer(s: ServerOwnership) {
        serverStore.delete(s.server)
        _servers.value = _servers.value.filter { it.server != s.server }
    }
}

/**
 * Objects too rich for a navigation argument, passed from one screen to the
 * next. The receiving screen takes them once.
 */
class Handoff {
    var draft: PaymentDraft? = null
    var invite: InviteLink? = null
    var recoveryKit: RecoveryLink? = null
    var creationLink: CreationLink? = null
}
