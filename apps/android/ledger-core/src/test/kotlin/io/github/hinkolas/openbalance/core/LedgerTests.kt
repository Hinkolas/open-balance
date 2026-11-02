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
    val writer = EventWriter(group, secret, id, key)
    val pub: ByteArray get() = key.publicKey
}

class Fixture {
    val group: UUID = Uuids.v7()
    val secret = randomBytes(32)
    val server = FakeServer()
    val ledger = Ledger(group, secret)
    val admin = Actor(group, secret)

    init {
        write(admin, EventData.GroupCreated(GroupCreatedData("Italien", "EUR", GroupCreatedData.Admin(admin.id, "Jonas", admin.pub.base64Url))))
    }

    /** Write as [who], append, reduce; returns the rejection of that event. */
    fun write(who: Actor, data: EventData): Rejection? {
        server.append(who.writer.write(data, ledger.state.head))
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
        write(admin, EventData.MemberAdded(MemberAddedData(member.id, name, invite.publicKey.base64Url)))
        val sig = invite.sign(LedgerCrypto.claimInput(group, member.pub))
        assertNull(write(member, EventData.MemberClaimed(MemberClaimedData(member.id, member.pub.base64Url, sig.base64Url))))
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
        assertEquals(Rejection.Forbidden, f.write(cem, EventData.MemberAdded(MemberAddedData("x", "X", SigningKey.generate().publicKey.base64Url))))
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
        f.write(f.admin, EventData.MemberAdded(MemberAddedData(oma, "Oma", invite.publicKey.base64Url)))
        val ben = f.join("Ben")

        // Anyone may record arrivals for an unclaimed seat.
        val p = f.payment(amount = 500, track = true, inLines = listOf(oma to 500L), outLines = listOf(ben.id to 500L))
        assertNull(f.write(ben, EventData.PaymentCreated(p)))
        assertNull(f.write(ben, EventData.ArrivalRecorded(ArrivalRecordedData("r", p.id, oma, 500))))
        assertEquals(-500L, f.ledger.state.summary().balances[oma])

        // A claim needs the invite's signature.
        val impostor = Actor(f.group, f.secret, id = oma)
        val wrongSig = SigningKey.generate().sign(LedgerCrypto.claimInput(f.group, impostor.pub))
        assertEquals(Rejection.BadInviteSig, f.write(impostor, EventData.MemberClaimed(MemberClaimedData(oma, impostor.pub.base64Url, wrongSig.base64Url))))

        val real = Actor(f.group, f.secret, id = oma)
        val sig = invite.sign(LedgerCrypto.claimInput(f.group, real.pub))
        assertNull(f.write(real, EventData.MemberClaimed(MemberClaimedData(oma, real.pub.base64Url, sig.base64Url))))
        assertEquals(Rejection.AlreadyClaimed, f.write(real, EventData.MemberClaimed(MemberClaimedData(oma, real.pub.base64Url, sig.base64Url))))
    }

    @Test
    fun forgedAuthorIsRejected() {
        val f = Fixture()
        val ben = f.join("Ben")
        // Ben signs with his key but claims to be the admin.
        val forger = EventWriter(f.group, f.secret, f.admin.id, ben.key)
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
        val fresh = Ledger(f.group, f.secret)
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
        val fresh = Ledger(f.group, f.secret)
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
            return f.write(device, EventData.MemberDeviceClaimed(MemberDeviceClaimedData(globex.id, device.pub.base64Url, invite.publicKey.base64Url, sig.base64Url)))
        }

        // Only the member itself invites its devices, not the admin or others.
        val invite = SigningKey.generate()
        val deviceInvite = EventData.MemberDeviceInvited(MemberDeviceInviteData(globex.id, invite.publicKey.base64Url))
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
        val forger = EventWriter(f.group, f.secret, ben.id, second.key)
        assertEquals(Rejection.BadSignature, f.writeAs(forger, EventData.MemberUpdated(MemberUpdatedData(ben.id, "x"))).rejection)

        // Revoking a pending device invite: the member or the admin.
        val spare = SigningKey.generate()
        assertNull(f.write(second, EventData.MemberDeviceInvited(MemberDeviceInviteData(globex.id, spare.publicKey.base64Url))))
        val revoke = EventData.MemberDeviceInviteRevoked(MemberDeviceInviteData(globex.id, spare.publicKey.base64Url))
        assertEquals(Rejection.Forbidden, f.write(ben, revoke))
        assertNull(f.write(f.admin, revoke))
        assertEquals(Rejection.UnknownTarget, f.write(f.admin, revoke))
        assertEquals(Rejection.BadInviteSig, claim(third, spare))

        // Replaying from scratch gives the same state.
        val fresh = Ledger(f.group, f.secret)
        fresh.apply(f.server.events)
        assertEquals(f.ledger.state, fresh.state)
        assertNotNull(fresh.state.members[globex.id])
    }

    @Test
    fun datesLikeTheSwiftClient() {
        assertTrue(Ledger.validDate("2026-10-30"))
        assertTrue(Ledger.validDate("2026-+1-05"))
        for (d in listOf("2026-13-01", "2026-00-10", "26-10-30", "2026-1-30", "2026-10-3x", "2026/10/30")) assertTrue(!Ledger.validDate(d), d)
    }
}
