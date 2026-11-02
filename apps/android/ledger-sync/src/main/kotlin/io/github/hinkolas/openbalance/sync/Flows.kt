package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.Bytes
import io.github.hinkolas.openbalance.core.Epochs
import io.github.hinkolas.openbalance.core.EventData
import io.github.hinkolas.openbalance.core.GroupCreatedData
import io.github.hinkolas.openbalance.core.GroupRecoveryChangedData
import io.github.hinkolas.openbalance.core.LedgerCrypto
import io.github.hinkolas.openbalance.core.MemberAddedData
import io.github.hinkolas.openbalance.core.MemberClaimedData
import io.github.hinkolas.openbalance.core.MemberDeviceClaimedData
import io.github.hinkolas.openbalance.core.MemberDeviceInviteData
import io.github.hinkolas.openbalance.core.MemberDeviceInvitedData
import io.github.hinkolas.openbalance.core.MemberDeviceRemovedData
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.MemberInviteRenewedData
import io.github.hinkolas.openbalance.core.MemberRecoveredData
import io.github.hinkolas.openbalance.core.SigningKey
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.base64Url
import io.github.hinkolas.openbalance.core.lower
import io.github.hinkolas.openbalance.core.randomBytes
import kotlinx.coroutines.CoroutineScope
import java.io.File

/** Why a create, invite or join flow stopped. The app words it. */
class FlowError(val kind: Kind) : Exception(kind.name) {
    enum class Kind { NotAdmin, InviteUsed, SeatMissing, SeatTaken, UnsupportedServer, CreationCodeUsed, RecoveryReplaced, NotRecoverable, NoEpochSecret }
}

// Create, invite, add and remove devices, join and recover (PROTOCOL.md §5.4).

/**
 * Create a group as its admin. [token] is the server's ADMIN_TOKEN or a
 * creation code from the server owner. Returns the recovery kit too, which
 * this device doesn't keep: show it once.
 */
suspend fun GroupSession.Companion.create(
    server: String, token: String, name: String, currency: String, myName: String,
    store: CredentialStore, cacheRoot: File, scope: CoroutineScope,
): Pair<GroupSession, RecoveryLink> {
    val client = ServerClient(server)
    if (1 !in client.info().protocols) throw FlowError(FlowError.Kind.UnsupportedServer)
    val groupId = Uuids.v7()
    val key = SigningKey.generate()
    val secret = randomBytes(32)
    val recoverySeed = randomBytes(32)
    val recovery = SigningKey(recoverySeed)
    val recoveryBox = LedgerCrypto.boxKey(recoverySeed).publicKey
    try {
        client.createGroup(token, groupId, key.publicKey, recovery.publicKey, Epochs.sealKeyring(listOf(secret), recoveryBox, groupId))
    } catch (e: ServerError) {
        if (e.status == 401) throw FlowError(FlowError.Kind.CreationCodeUsed)
        throw e
    }
    val creds = GroupCredentials.create(server, groupId, listOf(secret), Uuids.v7().lower, key.seed, registered = true)
    store.save(creds)
    val session = GroupSession(creds, store, cacheRoot, scope)
    val admin = GroupCreatedData.Admin(creds.memberId, myName, key.publicKey.base64Url, creds.box.publicKey.base64Url)
    session.submit(EventData.GroupCreated(GroupCreatedData(name, currency, admin, recovery.publicKey.base64Url, recoveryBox.base64Url)))
    session.syncNow()
    return session to RecoveryLink(server, groupId, creds.memberId, recoverySeed)
}

/** A new invite: its seed, key, box key, and keyring (every epoch secret so far, sealed to the box key; §5.4 steps 2 and 5). */
private class NewInvite(val seed: ByteArray, val key: ByteArray, val box: ByteArray, val keyring: ByteArray)

private fun GroupSession.newInvite(): NewInvite {
    val seed = randomBytes(32)
    val box = LedgerCrypto.boxKey(seed).publicKey
    return NewInvite(seed, SigningKey(seed).publicKey, box, Epochs.sealKeyring(secrets, box, id))
}

/** Replace the recovery kit: the old one stops working. Returns the new one, which this device doesn't keep. */
suspend fun GroupSession.newRecoveryKit(): RecoveryLink {
    if (!isAdmin) throw FlowError(FlowError.Kind.NotAdmin)
    val seed = randomBytes(32)
    val recovery = SigningKey(seed).publicKey
    val box = LedgerCrypto.boxKey(seed).publicKey
    client.replaceRecovery(credentials.value.signer, id, recovery, Epochs.sealKeyring(secrets, box, id))
    // Starts a new epoch too, so the old kit can't read what follows.
    submit(EventData.GroupRecoveryChanged(GroupRecoveryChangedData(recovery.base64Url, box.base64Url)))
    syncNow()
    return RecoveryLink(credentials.value.server, id, me, seed)
}

/**
 * Remove a device of a member: one of my own other devices, or (admin) any
 * member's. The ledger first, then the server cuts the key off.
 */
suspend fun GroupSession.removeDevice(member: MemberId, key: Bytes) {
    if (member != me && !isAdmin) throw FlowError(FlowError.Kind.NotAdmin)
    if (state.value.members[member]?.keys?.contains(key) == true) {
        submit(EventData.MemberDeviceRemoved(MemberDeviceRemovedData(member, key.base64Url)))
        syncNow()
    }
    try {
        client.removeKey(credentials.value.signer, id, key.toByteArray())
    } catch (e: ServerError) {
        if (e.status != 404) throw e
    }
}

/**
 * Reset a member who lost every device (admin): remove all its devices and
 * return a new invite for its new first device. The member keeps its
 * payments and balance.
 */
suspend fun GroupSession.resetMember(member: MemberId): InviteLink {
    if (!isAdmin || member == me) throw FlowError(FlowError.Kind.NotAdmin)
    val keys = state.value.members[member]?.keys ?: emptyList()
    for (key in keys) submit(EventData.MemberDeviceRemoved(MemberDeviceRemovedData(member, key.base64Url)))
    if (keys.isNotEmpty()) syncNow()
    for (key in keys) {
        try {
            client.removeKey(credentials.value.signer, id, key.toByteArray())
        } catch (e: ServerError) {
            if (e.status != 404) throw e
        }
    }
    return renewInvite(member)
}

private fun GroupSession.link(member: MemberId, seed: ByteArray): InviteLink {
    return InviteLink(credentials.value.server, id, member, seed)
}

/**
 * Add a member seat and return the invite to show as QR. The seat is on
 * the server before this returns, so the invite works right away.
 */
suspend fun GroupSession.addMember(name: String): InviteLink {
    if (!isAdmin) throw FlowError(FlowError.Kind.NotAdmin)
    val memberId = Uuids.v7().lower
    val invite = newInvite()
    client.createInvite(credentials.value.signer, id, invite.key, invite.keyring)
    updateCredentials { it.copy(invites = it.invites + (memberId to invite.seed.base64Url)) }
    submit(EventData.MemberAdded(MemberAddedData(memberId, name, invite.key.base64Url, invite.box.base64Url)))
    syncNow()
    return link(memberId, invite.seed)
}

/** The invite of an unclaimed member, if this device created it. */
fun GroupSession.inviteLink(member: MemberId): InviteLink? {
    val m = state.value.members[member] ?: return null
    if (m.isClaimed) return null
    val seed = credentials.value.invites[member]?.let(io.github.hinkolas.openbalance.core.Base64Url::decode) ?: return null
    if (seed.size != 32 || Bytes(SigningKey(seed).publicKey) != m.inviteKey) return null
    return link(member, seed)
}

/** Replace a lost or leaked invite: the old QR stops working. */
suspend fun GroupSession.renewInvite(member: MemberId): InviteLink {
    if (!isAdmin) throw FlowError(FlowError.Kind.NotAdmin)
    val m = state.value.members[member]?.takeIf { !it.isClaimed } ?: throw FlowError(FlowError.Kind.SeatTaken)
    m.inviteKey?.let { old ->
        try {
            client.revokeInvite(credentials.value.signer, id, old.toByteArray())
        } catch (e: ServerError) {
            if (e.status != 404) throw e
        }
    }
    val invite = newInvite()
    client.createInvite(credentials.value.signer, id, invite.key, invite.keyring)
    updateCredentials { it.copy(invites = it.invites + (member to invite.seed.base64Url)) }
    submit(EventData.MemberInviteRenewed(MemberInviteRenewedData(member, invite.key.base64Url, invite.box.base64Url)))
    syncNow()
    return link(member, invite.seed)
}

/**
 * The pending invite for a further device of my own member, if this device
 * made it and it hasn't been used or revoked.
 */
fun GroupSession.deviceInviteLink(): InviteLink? {
    val seed = credentials.value.deviceInvite?.let(io.github.hinkolas.openbalance.core.Base64Url::decode)?.takeIf { it.size == 32 } ?: return null
    val pub = Bytes(SigningKey(seed).publicKey)
    if (state.value.members[me]?.deviceInvites?.contains(pub) != true) return null
    return link(me, seed)
}

/**
 * Invite a further device of my own member, e.g. the second person of a
 * company. Shows this device's pending invite again if there is one.
 */
suspend fun GroupSession.addDevice(): InviteLink {
    deviceInviteLink()?.let { return it }
    val invite = newInvite()
    client.createInvite(credentials.value.signer, id, invite.key, invite.keyring, role = if (isAdmin) "admin" else "member")
    updateCredentials { it.copy(deviceInvite = invite.seed.base64Url) }
    submit(EventData.MemberDeviceInvited(MemberDeviceInvitedData(me, invite.key.base64Url, invite.box.base64Url)))
    syncNow()
    return link(me, invite.seed)
}

/** Withdraw this device's pending device invite: its QR stops working. */
suspend fun GroupSession.revokeDeviceInvite() {
    val seed = credentials.value.deviceInvite?.let(io.github.hinkolas.openbalance.core.Base64Url::decode)?.takeIf { it.size == 32 } ?: return
    val pub = SigningKey(seed).publicKey
    try {
        client.revokeInvite(credentials.value.signer, id, pub)
    } catch (e: ServerError) {
        if (e.status != 404) throw e
    }
    if (state.value.members[me]?.deviceInvites?.contains(Bytes(pub)) == true) {
        submit(EventData.MemberDeviceInviteRevoked(MemberDeviceInviteData(me, pub.base64Url)))
    }
    updateCredentials { it.copy(deviceInvite = null) }
    syncNow()
}

/**
 * Join with an invite: register a new member key with the server, then
 * announce it in the ledger, as the member's first device or a further
 * one. Safe to retry with the same link.
 */
suspend fun GroupSession.Companion.join(
    link: InviteLink, existing: GroupCredentials?, store: CredentialStore, cacheRoot: File, scope: CoroutineScope,
): GroupSession {
    val client = ServerClient(link.server)
    val invite = SigningKey(link.inviteSeed)
    val inviteBox = LedgerCrypto.boxKey(link.inviteSeed)
    var creds = existing ?: GroupCredentials.create(link.server, link.groupId, emptyList(), link.memberId, SigningKey.generate().seed, registered = false)
    if (!creds.registered || creds.secrets.isEmpty()) {
        // Save the key before the server learns it, so a crash can't strand the seat.
        store.save(creds)
        val member = creds.signer
        val keyring = try {
            client.claim(invite, member, link.groupId)
        } catch (e: ServerError) {
            if (e.status != 403 && e.status != 409) throw e
            // Used already: by us in an earlier attempt, or by someone else.
            try {
                client.keyring(member, link.groupId)
            } catch (_: Exception) {
                store.delete(link.groupId)
                throw FlowError(FlowError.Kind.InviteUsed)
            }
        }
        creds = creds.copy(secrets = Epochs.openKeyring(keyring, inviteBox, link.groupId).map { it.base64Url }, registered = true)
        store.save(creds)
    }
    val session = GroupSession(creds, store, cacheRoot, scope, listOf(inviteBox))
    session.syncNow()
    val seat = session.state.value.members[creds.memberId] ?: throw FlowError(FlowError.Kind.SeatMissing)
    val memberKey = creds.signer.publicKey
    val boxKey = creds.box.publicKey.base64Url
    val inviteKey = invite.publicKey
    val sig = invite.sign(LedgerCrypto.claimInput(link.groupId, memberKey))
    when {
        Bytes(memberKey) in seat.keys -> return session
        !seat.isClaimed -> session.submit(EventData.MemberClaimed(MemberClaimedData(creds.memberId, memberKey.base64Url, boxKey, sig.base64Url)))
        Bytes(inviteKey) in seat.deviceInvites -> session.submit(
            EventData.MemberDeviceClaimed(MemberDeviceClaimedData(creds.memberId, memberKey.base64Url, boxKey, inviteKey.base64Url, sig.base64Url)),
        )
        else -> throw FlowError(FlowError.Kind.SeatTaken)
    }
    session.syncNow()
    return session
}

/**
 * Take over the admin's seat with the recovery kit: the server swaps all of
 * the admin's devices for this one, then the ledger records it. Safe to
 * retry with the same kit and [existing] credentials.
 */
suspend fun GroupSession.Companion.recover(
    link: RecoveryLink, existing: GroupCredentials?, store: CredentialStore, cacheRoot: File, scope: CoroutineScope,
): GroupSession {
    val client = ServerClient(link.server)
    val recovery = SigningKey(link.recoverySeed)
    val recoveryBox = LedgerCrypto.boxKey(link.recoverySeed)
    var creds = existing ?: GroupCredentials.create(link.server, link.groupId, emptyList(), link.adminId, SigningKey.generate().seed, registered = false)
    if (!creds.registered || creds.secrets.isEmpty()) {
        store.save(creds)
        val member = creds.signer
        val keyring = try {
            client.recover(recovery, member, link.groupId)
        } catch (e: ServerError) {
            if (e.status != 403 && e.status != 409) throw e
            // Registered by an earlier attempt, or the kit was replaced.
            try {
                client.keyring(member, link.groupId)
            } catch (err: Exception) {
                store.delete(link.groupId)
                if (e.status == 403) throw FlowError(FlowError.Kind.RecoveryReplaced)
                throw err
            }
        }
        creds = creds.copy(secrets = Epochs.openKeyring(keyring, recoveryBox, link.groupId).map { it.base64Url }, registered = true)
        store.save(creds)
    }
    val session = GroupSession(creds, store, cacheRoot, scope, listOf(recoveryBox))
    session.syncNow()
    if (session.state.value.adminId != link.adminId) throw FlowError(FlowError.Kind.NotRecoverable)
    val memberKey = creds.signer.publicKey
    if (session.state.value.members[link.adminId]?.keys?.contains(Bytes(memberKey)) != true) {
        val sig = recovery.sign(LedgerCrypto.recoverInput(link.groupId, memberKey))
        session.submit(EventData.MemberRecovered(MemberRecoveredData(link.adminId, memberKey.base64Url, creds.box.publicKey.base64Url, sig.base64Url)))
        // Starts a new epoch too: the old admin devices can't read what follows.
        session.syncNow()
    }
    return session
}
