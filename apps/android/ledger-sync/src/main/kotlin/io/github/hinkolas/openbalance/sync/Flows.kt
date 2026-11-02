package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.Bytes
import io.github.hinkolas.openbalance.core.EventData
import io.github.hinkolas.openbalance.core.GroupCreatedData
import io.github.hinkolas.openbalance.core.LedgerCrypto
import io.github.hinkolas.openbalance.core.MemberAddedData
import io.github.hinkolas.openbalance.core.MemberClaimedData
import io.github.hinkolas.openbalance.core.MemberDeviceClaimedData
import io.github.hinkolas.openbalance.core.MemberDeviceInviteData
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.MemberInviteRenewedData
import io.github.hinkolas.openbalance.core.SigningKey
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.base64Url
import io.github.hinkolas.openbalance.core.lower
import io.github.hinkolas.openbalance.core.randomBytes
import kotlinx.coroutines.CoroutineScope
import java.io.File

/** Why a create, invite or join flow stopped. The app words it. */
class FlowError(val kind: Kind) : Exception(kind.name) {
    enum class Kind { NotAdmin, InviteUsed, SeatMissing, SeatTaken, UnsupportedServer }
}

// Create, invite, add devices and join (PROTOCOL.md §5.4).

/** Create a group on a server this device owns, as its admin. */
suspend fun GroupSession.Companion.create(
    server: String, ownerToken: String, name: String, currency: String, myName: String,
    store: CredentialStore, cacheRoot: File, scope: CoroutineScope,
): GroupSession {
    val client = ServerClient(server)
    if (1 !in client.info().protocols) throw FlowError(FlowError.Kind.UnsupportedServer)
    val groupId = Uuids.v7()
    val key = SigningKey.generate()
    client.createGroup(ownerToken, groupId, key.publicKey)
    val creds = GroupCredentials.create(server, groupId, randomBytes(32), Uuids.v7().lower, key.seed, registered = true)
    store.save(creds)
    val session = GroupSession(creds, store, cacheRoot, scope)
    session.submit(EventData.GroupCreated(GroupCreatedData(name, currency, GroupCreatedData.Admin(creds.memberId, myName, key.publicKey.base64Url))))
    session.syncNow()
    return session
}

private fun GroupSession.link(member: MemberId, seed: ByteArray): InviteLink {
    val c = credentials.value
    return InviteLink(c.server, id, member, c.secretBytes, seed)
}

/**
 * Add a member seat and return the invite to show as QR. The seat is on
 * the server before this returns, so the invite works right away.
 */
suspend fun GroupSession.addMember(name: String): InviteLink {
    if (!isAdmin) throw FlowError(FlowError.Kind.NotAdmin)
    val memberId = Uuids.v7().lower
    val seed = randomBytes(32)
    val invite = SigningKey(seed)
    client.createInvite(credentials.value.signer, id, invite.publicKey)
    updateCredentials { it.copy(invites = it.invites + (memberId to seed.base64Url)) }
    submit(EventData.MemberAdded(MemberAddedData(memberId, name, invite.publicKey.base64Url)))
    syncNow()
    return link(memberId, seed)
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
    val seed = randomBytes(32)
    val invite = SigningKey(seed)
    client.createInvite(credentials.value.signer, id, invite.publicKey)
    updateCredentials { it.copy(invites = it.invites + (member to seed.base64Url)) }
    submit(EventData.MemberInviteRenewed(MemberInviteRenewedData(member, invite.publicKey.base64Url)))
    syncNow()
    return link(member, seed)
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
    val seed = randomBytes(32)
    val invite = SigningKey(seed)
    client.createInvite(credentials.value.signer, id, invite.publicKey, role = if (isAdmin) "admin" else "member")
    updateCredentials { it.copy(deviceInvite = seed.base64Url) }
    submit(EventData.MemberDeviceInvited(MemberDeviceInviteData(me, invite.publicKey.base64Url)))
    syncNow()
    return link(me, seed)
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
    var creds = existing ?: GroupCredentials.create(link.server, link.groupId, link.secret, link.memberId, SigningKey.generate().seed, registered = false)
    if (!creds.registered) {
        // Save the key before the server learns it, so a crash can't strand the seat.
        store.save(creds)
        val member = creds.signer
        try {
            client.claim(invite, member, link.groupId)
        } catch (e: ServerError) {
            if (e.status != 403 && e.status != 409) throw e
            // Used already: by us in an earlier attempt, or by someone else.
            try {
                client.read(member, link.groupId, after = 0, limit = 1)
            } catch (_: Exception) {
                store.delete(link.groupId)
                throw FlowError(FlowError.Kind.InviteUsed)
            }
        }
        creds = creds.copy(registered = true)
        store.save(creds)
    }
    val session = GroupSession(creds, store, cacheRoot, scope)
    session.syncNow()
    val seat = session.state.value.members[creds.memberId] ?: throw FlowError(FlowError.Kind.SeatMissing)
    val memberKey = creds.signer.publicKey
    val inviteKey = invite.publicKey
    val sig = invite.sign(LedgerCrypto.claimInput(link.groupId, memberKey))
    when {
        Bytes(memberKey) in seat.keys -> return session
        !seat.isClaimed -> session.submit(EventData.MemberClaimed(MemberClaimedData(creds.memberId, memberKey.base64Url, sig.base64Url)))
        Bytes(inviteKey) in seat.deviceInvites -> session.submit(
            EventData.MemberDeviceClaimed(MemberDeviceClaimedData(creds.memberId, memberKey.base64Url, inviteKey.base64Url, sig.base64Url)),
        )
        else -> throw FlowError(FlowError.Kind.SeatTaken)
    }
    session.syncNow()
    return session
}
