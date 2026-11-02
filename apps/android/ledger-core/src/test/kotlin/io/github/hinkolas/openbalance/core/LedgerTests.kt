package io.github.hinkolas.openbalance.core

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A small in-memory server: assigns seq, keeps blobs. */
class FakeServer {
    val events = ArrayList<RawEvent>()
    fun append(e: SealedEvent) {
        events.add(RawEvent(events.size + 1L, e.id, e.blob))
    }
}

class Actor(group: UUID, secret: ByteArray, val id: MemberId = Uuids.v7().lower, val key: SigningKey = SigningKey.generate()) {
    val writer = EventWriter(group, secret, author = id, signer = key)
    val pub: ByteArray get() = key.publicKey
    val box: BoxKey = LedgerCrypto.boxKey(key.seed)
    val boxKey: String get() = box.publicKey.base64Url
}

/** The box key (base64url) of an invite or other seed key. */
fun boxKey(k: SigningKey): String = LedgerCrypto.boxKey(k.seed).publicKey.base64Url

class Fixture {
    val group: UUID = Uuids.v7()
    val secret = randomBytes(32)
    val server = FakeServer()
    val admin = Actor(group, secret)
    val ledger = Ledger(group, listOf(secret), listOf(admin.box))
    val recovery = SigningKey.generate()

    init {
        write(admin, EventData.GroupCreated(GroupCreatedData("Italien", "EUR", GroupCreatedData.Admin(admin.id, "Jonas", admin.pub.base64Url, admin.boxKey),
            recovery.publicKey.base64Url, boxKey(recovery))))
    }

    /** A writer for the ledger's current epoch. */
    fun writer(who: Actor) = EventWriter(group, ledger.currentSecret ?: secret, ledger.state.epoch, who.id, who.key)

    /** Write as [who], append, reduce; returns the rejection of that event. */
    fun write(who: Actor, data: EventData): Rejection? {
        server.append(writer(who).write(data, ledger.state.head))
        ledger.apply(server.events.takeLast(1))
        return ledger.state.history.last().rejection
    }

    fun writeAs(writer: EventWriter, data: EventData, seen: EventHeader.Seen = ledger.state.head): HistoryItem {
        server.append(writer.write(data, seen))
        ledger.apply(server.events.takeLast(1))
        return ledger.state.history.last()
    }

    /** Admin adds a member; the member claims with a fresh key. */
    fun join(name: String): Actor {
        val invite = SigningKey.generate()
        val member = Actor(group, secret)
        write(admin, EventData.MemberAdded(MemberAddedData(member.id, name, invite.publicKey.base64Url, boxKey(invite))))
        val sig = invite.sign(LedgerCrypto.claimInput(group, member.pub))
        assertNull(write(member, EventData.MemberClaimed(MemberClaimedData(member.id, member.pub.base64Url, member.boxKey, sig.base64Url))))
        return member
    }

    fun payment(
        id: PaymentId = Uuids.v7().lower, kind: Payment.Kind = Payment.Kind.Income, amount: Long, track: Boolean,
        inLines: List<Pair<MemberId, Long>>, outLines: List<Pair<MemberId, Long>>,
    ) = Payment(id, kind, "Rate 1", date = "2026-10-30", amount = amount, track = track,
        inSide = Payment.Side("exact", inLines.map { Payment.Line(it.first, it.second) }),
        outSide = Payment.Side("exact", outLines.map { Payment.Line(it.first, it.second) }))
}

class LedgerTests {
    @Test
    fun incomeWithArrivalsAndSettleUp() {
        val f = Fixture()
        val ben = f.join("Ben")
        val a = f.admin.id

        // 1000 arrives at Jonas, belongs 600 Jonas / 400 Ben.
        val p = f.payment(amount = 100_000, track = true, inLines = listOf(a to 100_000L), outLines = listOf(a to 60_000L, ben.id to 40_000L))
        assertNull(f.write(ben, EventData.PaymentCreated(p)))
        assertEquals(mapOf(a to 0L, ben.id to 0L), f.ledger.state.summary().balances)

        // Ben can't confirm money that arrived at Jonas; Jonas can.
        assertEquals(Rejection.Forbidden, f.write(ben, EventData.ArrivalRecorded(ArrivalRecordedData("r1", p.id, a, 50_000))))
        assertNull(f.write(f.admin, EventData.ArrivalRecorded(ArrivalRecordedData("r2", p.id, a, 50_000))))
        var s = f.ledger.state.summary()
        assertEquals(mapOf(a to -20_000L, ben.id to 20_000L), s.balances)
        assertEquals(20_000L, s.pendingOwned[ben.id])
        assertEquals(listOf(Balances.Transfer(a, ben.id, 20_000)), s.transfers)

        // Settle up: Jonas pays Ben, counts once Ben confirms.
        val settle = f.payment(kind = Payment.Kind.Settlement, amount = 20_000, track = true, inLines = listOf(ben.id to 20_000L), outLines = listOf(a to 20_000L))
        assertNull(f.write(f.admin, EventData.PaymentCreated(settle)))
        assertEquals(mapOf(a to -20_000L, ben.id to 20_000L), f.ledger.state.summary().balances)
        assertNull(f.write(ben, EventData.ArrivalRecorded(ArrivalRecordedData("r3", settle.id, ben.id, 20_000))))
        s = f.ledger.state.summary()
        assertEquals(mapOf(a to 0L, ben.id to 0L), s.balances)
        assertTrue(s.transfers.isEmpty())
    }

    @Test
    fun permissions() {
        val f = Fixture()
        val ben = f.join("Ben")
        val cem = f.join("Cem")
        val p = f.payment(amount = 900, track = false, inLines = listOf(ben.id to 300L, cem.id to 300L, f.admin.id to 300L), outLines = listOf(ben.id to 900L))
        assertNull(f.write(ben, EventData.PaymentCreated(p)))

        val edit = p.copy(title = "Dinner", base = f.ledger.state.payments.getValue(p.id).lastEventId.lower)
        assertEquals(Rejection.Forbidden, f.write(cem, EventData.PaymentUpdated(edit)))
        assertNull(f.write(f.admin, EventData.PaymentUpdated(edit)))
        assertEquals("Dinner", f.ledger.state.payments[p.id]?.payment?.title)
        assertEquals(false, f.ledger.state.payments[p.id]?.editedConcurrently)

        assertEquals(Rejection.Forbidden, f.write(cem, EventData.GroupUpdated(GroupUpdatedData("Mine"))))
        val x = SigningKey.generate()
        assertEquals(Rejection.Forbidden, f.write(cem, EventData.MemberAdded(MemberAddedData("x", "X", x.publicKey.base64Url, boxKey(x)))))
        assertNull(f.write(cem, EventData.MemberUpdated(MemberUpdatedData(cem.id, "Cem K."))))
        assertEquals(Rejection.Forbidden, f.write(cem, EventData.MemberUpdated(MemberUpdatedData(ben.id, "Benny"))))
        assertNull(f.write(ben, EventData.PaymentDeleted(PaymentDeletedData(p.id))))
        assertEquals(Rejection.UnknownTarget, f.write(ben, EventData.PaymentDeleted(PaymentDeletedData(p.id))))

        // Sums must match.
        var bad = f.payment(amount = 1000, track = false, inLines = listOf(ben.id to 999L), outLines = listOf(ben.id to 1000L))
        assertEquals(Rejection.InvalidData, f.write(ben, EventData.PaymentCreated(bad)))
        bad = f.payment(amount = 1000, track = false, inLines = listOf(ben.id to 1000L), outLines = listOf("nobody" to 1000L))
        assertEquals(Rejection.InvalidData, f.write(ben, EventData.PaymentCreated(bad)))
        // Lines whose sum wraps around 64 bits don't add up.
        bad = f.payment(amount = 1000, track = false, inLines = listOf(ben.id to Long.MAX_VALUE, cem.id to Long.MAX_VALUE, f.admin.id to 1002L), outLines = listOf(ben.id to 1000L))
        assertEquals(Rejection.InvalidData, f.write(ben, EventData.PaymentCreated(bad)))
    }

    @Test
    fun unclaimedSeatsAndClaims() {
        val f = Fixture()
        val invite = SigningKey.generate()
        val oma = Uuids.v7().lower
        f.write(f.admin, EventData.MemberAdded(MemberAddedData(oma, "Oma", invite.publicKey.base64Url, boxKey(invite))))
        val ben = f.join("Ben")

        // Anyone may record arrivals for an unclaimed seat.
        val p = f.payment(amount = 500, track = true, inLines = listOf(oma to 500L), outLines = listOf(ben.id to 500L))
        assertNull(f.write(ben, EventData.PaymentCreated(p)))
        assertNull(f.write(ben, EventData.ArrivalRecorded(ArrivalRecordedData("r", p.id, oma, 500))))
        assertEquals(-500L, f.ledger.state.summary().balances[oma])

        // A claim needs the invite's signature.
        val impostor = Actor(f.group, f.secret, id = oma)
        val wrongSig = SigningKey.generate().sign(LedgerCrypto.claimInput(f.group, impostor.pub))
        assertEquals(Rejection.BadInviteSig, f.write(impostor, EventData.MemberClaimed(MemberClaimedData(oma, impostor.pub.base64Url, impostor.boxKey, wrongSig.base64Url))))

        val real = Actor(f.group, f.secret, id = oma)
        val sig = invite.sign(LedgerCrypto.claimInput(f.group, real.pub))
        assertNull(f.write(real, EventData.MemberClaimed(MemberClaimedData(oma, real.pub.base64Url, real.boxKey, sig.base64Url))))
        assertEquals(Rejection.AlreadyClaimed, f.write(real, EventData.MemberClaimed(MemberClaimedData(oma, real.pub.base64Url, real.boxKey, sig.base64Url))))
    }

    @Test
    fun forgedAuthorIsRejected() {
        val f = Fixture()
        val ben = f.join("Ben")
        // Ben signs with his key but claims to be the admin.
        val forger = EventWriter(f.group, f.secret, author = f.admin.id, signer = ben.key)
        assertEquals(Rejection.BadSignature, f.writeAs(forger, EventData.GroupUpdated(GroupUpdatedData("Hacked"))).rejection)
        assertEquals("Italien", f.ledger.state.name)
    }

    @Test
    fun serverForkIsDetected() {
        val f = Fixture()
        val ben = f.join("Ben")
        // Ben saw a different event 2 than everyone else.
        val item = f.writeAs(ben.writer, EventData.GroupUpdated(GroupUpdatedData("x")), EventHeader.Seen(2, randomBytes(32).base64Url))
        assertTrue(f.ledger.state.inconsistency is Inconsistency.Fork)
        assertNull(item.rejection)
        // Nothing applies after it.
        f.write(f.admin, EventData.GroupUpdated(GroupUpdatedData("y")))
        assertEquals("Italien", f.ledger.state.name)
    }

    @Test
    fun replayFromScratchMatches() {
        val f = Fixture()
        val ben = f.join("Ben")
        f.write(ben, EventData.PaymentCreated(f.payment(amount = 900, track = false, inLines = listOf(ben.id to 900L), outLines = listOf(f.admin.id to 900L))))
        val fresh = Ledger(f.group, listOf(f.secret), listOf(f.admin.box))
        fresh.apply(f.server.events)
        assertEquals(f.ledger.state, fresh.state)
    }

    @Test
    fun wrongSecretCannotRead() {
        val f = Fixture()
        val other = Ledger(f.group, randomBytes(32))
        other.apply(f.server.events)
        assertEquals(Inconsistency.BadGenesis, other.state.inconsistency)
        assertEquals(Rejection.Decrypt, other.state.history.first().rejection)
    }

    @Test
    fun gapsAreDetected() {
        val f = Fixture()
        f.write(f.admin, EventData.GroupUpdated(GroupUpdatedData("a")))
        val fresh = Ledger(f.group, listOf(f.secret), listOf(f.admin.box))
        fresh.apply(listOf(f.server.events[1]))
        assertEquals(Inconsistency.Gap(1, 2), fresh.state.inconsistency)
    }

    @Test
    fun pendingEventsLayerOnACopy() {
        val f = Fixture()
        val copy = f.ledger.copy()
        val e = f.admin.writer.write(EventData.GroupUpdated(GroupUpdatedData("Pending")), f.ledger.state.head)
        copy.applyPending(e.id, e.body)
        assertEquals("Pending", copy.state.name)
        assertTrue(copy.state.history.last().pending)
        assertEquals("Italien", f.ledger.state.name)
    }

    /** Further devices of a member (§7.3): a company member shared by two people. */
    @Test
    fun memberDevices() {
        val f = Fixture()
        val globex = f.join("Globex")
        val ben = f.join("Ben")
        fun claim(device: Actor, invite: SigningKey, signedBy: SigningKey? = null): Rejection? {
            val sig = (signedBy ?: invite).sign(LedgerCrypto.claimInput(f.group, device.pub))
            return f.write(device, EventData.MemberDeviceClaimed(MemberDeviceClaimedData(globex.id, device.pub.base64Url, device.boxKey, invite.publicKey.base64Url, sig.base64Url)))
        }

        // Only the member itself invites its devices, not the admin or others.
        val invite = SigningKey.generate()
        val deviceInvite = EventData.MemberDeviceInvited(MemberDeviceInvitedData(globex.id, invite.publicKey.base64Url, boxKey(invite)))
        assertEquals(Rejection.Forbidden, f.write(f.admin, deviceInvite))
        assertEquals(Rejection.Forbidden, f.write(ben, deviceInvite))
        assertNull(f.write(globex, deviceInvite))
        assertEquals(Rejection.InvalidData, f.write(globex, deviceInvite)) // key reuse
        assertEquals(listOf(Bytes(invite.publicKey)), f.ledger.state.members[globex.id]?.deviceInvites)

        // The second device needs the invite's signature, then writes as Globex.
        val second = Actor(f.group, f.secret, id = globex.id)
        assertEquals(Rejection.BadInviteSig, claim(second, invite, signedBy = SigningKey.generate()))
        assertNull(claim(second, invite))
        assertEquals(listOf(Bytes(globex.pub), Bytes(second.pub)), f.ledger.state.members[globex.id]?.keys)
        assertTrue(f.ledger.state.members.getValue(globex.id).deviceInvites.isEmpty())
        assertNull(f.write(second, EventData.MemberUpdated(MemberUpdatedData(globex.id, "Globex GmbH"))))
        val p = f.payment(amount = 1000, track = false, inLines = listOf(globex.id to 1000L), outLines = listOf(ben.id to 1000L))
        assertNull(f.write(second, EventData.PaymentCreated(p)))
        assertEquals(globex.id, f.ledger.state.payments[p.id]?.creator)
        assertNull(f.write(globex, EventData.PaymentDeleted(PaymentDeletedData(p.id)))) // the first device edits what the second made

        // An invite is good for one device.
        val third = Actor(f.group, f.secret, id = globex.id)
        assertEquals(Rejection.BadInviteSig, claim(third, invite))

        // The second device can't speak for Ben.
        val forger = EventWriter(f.group, f.secret, author = ben.id, signer = second.key)
        assertEquals(Rejection.BadSignature, f.writeAs(forger, EventData.MemberUpdated(MemberUpdatedData(ben.id, "x"))).rejection)

        // Revoking a pending device invite: the member or the admin.
        val spare = SigningKey.generate()
        assertNull(f.write(second, EventData.MemberDeviceInvited(MemberDeviceInvitedData(globex.id, spare.publicKey.base64Url, boxKey(spare)))))
        val revoke = EventData.MemberDeviceInviteRevoked(MemberDeviceInviteData(globex.id, spare.publicKey.base64Url))
        assertEquals(Rejection.Forbidden, f.write(ben, revoke))
        assertNull(f.write(f.admin, revoke))
        assertEquals(Rejection.UnknownTarget, f.write(f.admin, revoke))
        assertEquals(Rejection.BadInviteSig, claim(third, spare))

        // Replaying from scratch gives the same state.
        val fresh = Ledger(f.group, listOf(f.secret), listOf(f.admin.box))
        fresh.apply(f.server.events)
        assertEquals(f.ledger.state, fresh.state)
        assertNotNull(fresh.state.members[globex.id])
    }

    /** Removing devices and resetting a member (§7.3 member.device_removed). */
    @Test
    fun deviceRemoval() {
        val f = Fixture()
        val anna = f.join("Anna")
        val ben = f.join("Ben")
        val invite = SigningKey.generate()
        assertNull(f.write(anna, EventData.MemberDeviceInvited(MemberDeviceInvitedData(anna.id, invite.publicKey.base64Url, boxKey(invite)))))
        val phone = Actor(f.group, f.secret, id = anna.id)
        val sig = invite.sign(LedgerCrypto.claimInput(f.group, phone.pub))
        assertNull(f.write(phone, EventData.MemberDeviceClaimed(MemberDeviceClaimedData(anna.id, phone.pub.base64Url, phone.boxKey, invite.publicKey.base64Url, sig.base64Url))))

        // Only Anna herself or the admin removes Anna's devices.
        val removePhone = EventData.MemberDeviceRemoved(MemberDeviceRemovedData(anna.id, phone.pub.base64Url))
        assertEquals(Rejection.Forbidden, f.write(ben, removePhone))
        assertEquals(Rejection.UnknownTarget, f.write(anna, EventData.MemberDeviceRemoved(MemberDeviceRemovedData(anna.id, ben.pub.base64Url))))
        assertNull(f.write(anna, removePhone))
        assertEquals(listOf(Bytes(anna.pub)), f.ledger.state.members[anna.id]?.keys)
        assertTrue(Bytes(phone.pub) in f.ledger.state.removedKeys)
        assertEquals(Rejection.UnknownTarget, f.write(anna, removePhone))

        // The removed device can't write any more, and its key can't come back.
        assertEquals(Rejection.BadSignature, f.write(phone, EventData.MemberUpdated(MemberUpdatedData(anna.id, "Thief"))))
        val again = SigningKey.generate()
        assertNull(f.write(anna, EventData.MemberDeviceInvited(MemberDeviceInvitedData(anna.id, again.publicKey.base64Url, boxKey(again)))))
        val sig2 = again.sign(LedgerCrypto.claimInput(f.group, phone.pub))
        assertEquals(Rejection.InvalidData, f.write(phone, EventData.MemberDeviceClaimed(MemberDeviceClaimedData(anna.id, phone.pub.base64Url, phone.boxKey, again.publicKey.base64Url, sig2.base64Url))))

        // Reset: the admin removes Anna's last key; she is a seat again, keeps her
        // payments, and her pending device invites are gone.
        val p = f.payment(amount = 1000, track = true, inLines = listOf(anna.id to 1000L), outLines = listOf(ben.id to 1000L))
        assertNull(f.write(anna, EventData.PaymentCreated(p)))
        assertNull(f.write(f.admin, EventData.MemberDeviceRemoved(MemberDeviceRemovedData(anna.id, anna.pub.base64Url))))
        val seat = f.ledger.state.members.getValue(anna.id)
        assertTrue(!seat.isClaimed && seat.inviteKey == null && seat.deviceInvites.isEmpty())
        assertNull(f.write(ben, EventData.ArrivalRecorded(ArrivalRecordedData("a1", p.id, anna.id, 500))))

        val fresh = SigningKey.generate()
        assertNull(f.write(f.admin, EventData.MemberInviteRenewed(MemberInviteRenewedData(anna.id, fresh.publicKey.base64Url, boxKey(fresh)))))
        val newPhone = Actor(f.group, f.secret, id = anna.id)
        val claimSig = fresh.sign(LedgerCrypto.claimInput(f.group, newPhone.pub))
        assertNull(f.write(newPhone, EventData.MemberClaimed(MemberClaimedData(anna.id, newPhone.pub.base64Url, newPhone.boxKey, claimSig.base64Url))))
        assertEquals(listOf(Bytes(newPhone.pub)), f.ledger.state.members[anna.id]?.keys)
        assertEquals(anna.id, f.ledger.state.payments[p.id]?.creator)
        assertNull(f.write(newPhone, EventData.PaymentDeleted(PaymentDeletedData(p.id))))

        val replay = Ledger(f.group, listOf(f.secret), listOf(f.admin.box))
        replay.apply(f.server.events)
        assertEquals(f.ledger.state, replay.state)
    }

    /** The recovery key replaces the admin's devices (§7.3 member.recovered, §7.2). */
    @Test
    fun adminRecovery() {
        val f = Fixture()
        val anna = f.join("Anna")
        val deviceInvite = SigningKey.generate()
        assertNull(f.write(f.admin, EventData.MemberDeviceInvited(MemberDeviceInvitedData(f.admin.id, deviceInvite.publicKey.base64Url, boxKey(deviceInvite)))))

        fun recover(device: Actor, with: SigningKey, id: MemberId = device.id): Rejection? {
            val sig = with.sign(LedgerCrypto.recoverInput(f.group, device.pub))
            return f.write(device, EventData.MemberRecovered(MemberRecoveredData(id, device.pub.base64Url, device.boxKey, sig.base64Url)))
        }

        // Only the admin's seat, only with the recovery key, and not with a claim signature.
        val annaNew = Actor(f.group, f.secret, id = anna.id)
        assertEquals(Rejection.Forbidden, recover(annaNew, f.recovery))
        val restored = Actor(f.group, f.secret, id = f.admin.id)
        assertEquals(Rejection.BadRecoverySig, recover(restored, SigningKey.generate()))
        val claimSig = f.recovery.sign(LedgerCrypto.claimInput(f.group, restored.pub))
        assertEquals(Rejection.BadRecoverySig, f.write(restored, EventData.MemberRecovered(MemberRecoveredData(f.admin.id, restored.pub.base64Url, restored.boxKey, claimSig.base64Url))))
        assertNull(recover(restored, f.recovery))

        val admin = f.ledger.state.members.getValue(f.admin.id)
        assertTrue(admin.keys == listOf(Bytes(restored.pub)) && admin.deviceInvites.isEmpty())
        assertTrue(Bytes(f.admin.pub) in f.ledger.state.removedKeys)
        assertEquals(Rejection.BadSignature, f.write(f.admin, EventData.GroupUpdated(GroupUpdatedData("Lost phone"))))
        assertNull(f.write(restored, EventData.GroupUpdated(GroupUpdatedData("Italien 2026"))))
        assertEquals(Rejection.InvalidData, recover(restored, f.recovery)) // key reuse

        // A new recovery key: admin only, new key, the old one stops working.
        val next = SigningKey.generate()
        val change = EventData.GroupRecoveryChanged(GroupRecoveryChangedData(next.publicKey.base64Url, boxKey(next)))
        assertEquals(Rejection.Forbidden, f.write(anna, change))
        assertEquals(Rejection.InvalidData, f.write(restored, EventData.GroupRecoveryChanged(GroupRecoveryChangedData(f.admin.pub.base64Url, boxKey(SigningKey.generate())))))
        assertNull(f.write(restored, change))
        assertEquals(Bytes(next.publicKey), f.ledger.state.recoveryKey)
        val second = Actor(f.group, f.secret, id = f.admin.id)
        assertEquals(Rejection.BadRecoverySig, recover(second, f.recovery))
        assertNull(recover(second, next))
        assertEquals(listOf(Bytes(second.pub)), f.ledger.state.members[f.admin.id]?.keys)
    }

    /** group.created needs a recovery key different from the admin key. */
    @Test
    fun genesisNeedsRecoveryKey() {
        val group = Uuids.v7()
        val secret = randomBytes(32)
        val admin = Actor(group, secret)
        val k = admin.pub.base64Url
        val e = admin.writer.write(EventData.GroupCreated(GroupCreatedData("G", "EUR", GroupCreatedData.Admin(admin.id, "A", k, admin.boxKey), k, boxKey(SigningKey.generate()))), LedgerState(group).head)
        val l = Ledger(group, secret)
        l.apply(listOf(RawEvent(1, e.id, e.blob)))
        assertEquals(Rejection.InvalidData, l.state.history.first().rejection)
        assertNotNull(l.state.inconsistency)
    }

    @Test
    fun datesLikeTheSwiftClient() {
        assertTrue(Ledger.validDate("2026-10-30"))
        assertTrue(Ledger.validDate("2026-+1-05"))
        for (d in listOf("2026-13-01", "2026-00-10", "26-10-30", "2026-1-30", "2026-10-3x", "2026/10/30")) assertTrue(!Ledger.validDate(d), d)
    }

    /**
     * Key epochs (§7.2): a removed device can't read what follows the next
     * epoch, stale writes are invalid, the reader set must match, and a member
     * who joins later reads all of it from its keyring and the entries sealed
     * to its invite.
     */
    @Test
    fun keyEpochs() {
        val f = Fixture()
        val anna = f.join("Anna")
        val ben = f.join("Ben")
        val invite = SigningKey.generate()
        assertNull(f.write(anna, EventData.MemberDeviceInvited(MemberDeviceInvitedData(anna.id, invite.publicKey.base64Url, boxKey(invite)))))
        val phone = Actor(f.group, f.secret, id = anna.id)
        val sig = invite.sign(LedgerCrypto.claimInput(f.group, phone.pub))
        assertNull(f.write(phone, EventData.MemberDeviceClaimed(MemberDeviceClaimedData(anna.id, phone.pub.base64Url, phone.boxKey, invite.publicKey.base64Url, sig.base64Url))))
        assertEquals(5, f.ledger.state.readers.size) // admin, Anna, her phone, Ben, recovery
        assertTrue(!f.ledger.state.epochDue)

        // Anna removes her phone: a new epoch is due, by her.
        assertNull(f.write(anna, EventData.MemberDeviceRemoved(MemberDeviceRemovedData(anna.id, phone.pub.base64Url))))
        assertTrue(f.ledger.state.epochDue)
        assertEquals(anna.id, f.ledger.state.epochDueBy)
        val readers = f.ledger.state.readers
        val phoneBox = Bytes(phone.box.publicKey)
        assertEquals(4, readers.size)
        assertTrue(phoneBox !in readers)

        // The reader set must match exactly, and the epoch must be the next one.
        val start = { epoch: Long, r: Set<Bytes> -> EventData.GroupEpochStarted(Epochs.start(epoch, r, f.group).first) }
        assertEquals(Rejection.InvalidData, f.write(anna, start(1, readers + phoneBox)))
        assertEquals(Rejection.InvalidData, f.write(anna, start(1, readers - f.ledger.state.recoveryBoxKey!!)))
        assertEquals(Rejection.InvalidData, f.write(anna, start(2, readers)))

        // Two devices start epoch 1 at the same time: the first wins, the second is stale.
        val (first, s1) = Epochs.start(1, readers, f.group)
        val (second, _) = Epochs.start(1, readers, f.group)
        assertNull(f.write(anna, EventData.GroupEpochStarted(first)))
        assertEquals(1L, f.ledger.state.epoch)
        assertTrue(!f.ledger.state.epochDue)
        assertTrue(s1.contentEquals(f.ledger.currentSecret)) // the admin found its entry
        val epoch0 = EventWriter(f.group, f.secret, 0, f.admin.id, f.admin.key)
        assertEquals(Rejection.StaleEpoch, f.writeAs(epoch0, EventData.GroupEpochStarted(second)).rejection)
        assertEquals(1L, f.ledger.state.epoch)

        // Writes in the old epoch are stale; in the new one they count.
        assertEquals(Rejection.StaleEpoch, f.writeAs(epoch0, EventData.GroupUpdated(GroupUpdatedData("Old key"))).rejection)
        val p = f.payment(amount = 5000, track = false, inLines = listOf(anna.id to 5000L), outLines = listOf(ben.id to 5000L))
        assertNull(f.write(ben, EventData.PaymentCreated(p)))

        // The removed phone reads up to the new epoch and nothing after.
        val phoneView = Ledger(f.group, listOf(f.secret), listOf(phone.box))
        phoneView.apply(f.server.events)
        assertEquals(1, phoneView.secrets.size)
        assertNull(phoneView.state.payments[p.id])
        assertEquals(Rejection.Decrypt, phoneView.state.history.last().rejection)

        // Cem is invited in epoch 1; epoch 2 starts before he joins, sealed to his invite too.
        val cemInvite = SigningKey.generate()
        val cem = Actor(f.group, f.secret)
        assertNull(f.write(f.admin, EventData.MemberAdded(MemberAddedData(cem.id, "Cem", cemInvite.publicKey.base64Url, boxKey(cemInvite)))))
        val inviteBox = LedgerCrypto.boxKey(cemInvite.seed)
        val keyring = Epochs.sealKeyring(f.ledger.secrets, inviteBox.publicKey, f.group)
        assertTrue(Bytes(inviteBox.publicKey) in f.ledger.state.readers)
        assertNull(f.write(f.admin, start(2, f.ledger.state.readers)))

        val cemView = Ledger(f.group, Epochs.openKeyring(keyring, inviteBox, f.group), listOf(cem.box, inviteBox))
        cemView.apply(f.server.events)
        assertEquals(f.ledger.secrets.map { it.toList() }, cemView.secrets.map { it.toList() })
        assertEquals(f.ledger.state, cemView.state)
        val claimSig = cemInvite.sign(LedgerCrypto.claimInput(f.group, cem.pub))
        assertNull(f.write(cem, EventData.MemberClaimed(MemberClaimedData(cem.id, cem.pub.base64Url, cem.boxKey, claimSig.base64Url))))
        assertTrue(Bytes(inviteBox.publicKey) !in f.ledger.state.readers)

        // A recovery and a new recovery key make an epoch due too.
        val next = SigningKey.generate()
        assertNull(f.write(f.admin, EventData.GroupRecoveryChanged(GroupRecoveryChangedData(next.publicKey.base64Url, boxKey(next)))))
        assertTrue(f.ledger.state.epochDue)
        assertEquals(f.admin.id, f.ledger.state.epochDueBy)

        val replay = Ledger(f.group, listOf(f.secret), listOf(f.admin.box))
        replay.apply(f.server.events)
        assertEquals(f.ledger.state, replay.state)
        assertEquals(f.ledger.secrets.map { it.toList() }, replay.secrets.map { it.toList() })
    }

    /** `group.epoch_started.epoch` is an unsigned 32-bit number, like Swift's `UInt32`. */
    @Test
    fun epochNumbersAreUnsigned32() {
        fun body(epoch: String) = """{"v":1,"type":"group.epoch_started","author":"a","at":"t","seen":{"seq":0,"chain":"x"},"data":{"epoch":$epoch,"keys":[]}}""".toByteArray()
        assertEquals(4294967295L, (EventCoding.decode(body("4294967295")).second as EventData.GroupEpochStarted).data.epoch)
        for (bad in listOf("-1", "4294967296", "1.5", "\"1\"")) {
            kotlin.test.assertFailsWith<EventCoding.Malformed>(bad) { EventCoding.decode(body(bad)) }
        }
    }
}
