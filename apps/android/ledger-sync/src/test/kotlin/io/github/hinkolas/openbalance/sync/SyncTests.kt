package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.ArrivalRecordedData
import io.github.hinkolas.openbalance.core.Balances
import io.github.hinkolas.openbalance.core.EventData
import io.github.hinkolas.openbalance.core.Ledger
import io.github.hinkolas.openbalance.core.Rejection
import io.github.hinkolas.openbalance.core.MemberUpdatedData
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.core.SigningKey
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.lower
import io.github.hinkolas.openbalance.core.randomBytes
import io.github.hinkolas.openbalance.core.summary
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class InviteLinkTests {
    private val link = InviteLink("https://open-balance.example.com", Uuids.v7(), Uuids.v7().lower, randomBytes(32))

    @Test
    fun roundTrips() {
        assertEquals(link, InviteLink.parse(link.url))
        assertEquals(link, InviteLink.parse("  ${link.url}\n"))
        assertTrue(link.url.startsWith("openbalance://join?v=1&s=https://open-balance.example.com&g="), link.url)
    }

    @Test
    fun readsWhatTheSwiftClientWrites() {
        // URLComponents leaves ":" and "/" in the query; a fully escaped server works too.
        val escaped = link.url.replace("s=https://open-balance.example.com", "s=https%3A%2F%2Fopen-balance.example.com")
        assertEquals(link, InviteLink.parse(escaped))
        val withPath = InviteLink("https://example.com/ob?x=1&y=2", link.groupId, link.memberId, link.inviteSeed)
        assertEquals(withPath, InviteLink.parse(withPath.url))
    }

    @Test
    fun rejectsBrokenLinks() {
        for (bad in listOf(
            "", "https://example.com", link.url.substringBefore('#'),
            link.url.replace("v=1", "v=2"), link.url.replace("openbalance://join", "openbalance://other"),
            link.url.replace("s=https", "s=ftp"), link.url.replace(link.groupId.lower, "1-1-1-1-1"),
            link.url.substringBefore("#i=") + "#x=1",
        )) assertNull(InviteLink.parse(bad), bad)
    }

    @Test
    fun neverPrintsSecrets() {
        val creds = GroupCredentials.create("https://x", link.groupId, listOf(randomBytes(32)), link.memberId, link.inviteSeed, registered = true)
        assertTrue(creds.secrets.single() !in creds.toString() && creds.memberSeed !in creds.toString())
        assertTrue("#" !in link.toString() && "i=" !in link.toString())
        assertTrue("k=" !in link.url) // no group secret in the QR
    }
}

class LinkTests {
    private val server = "https://open-balance.example.com"

    @Test
    fun recoveryAndCreationLinksRoundTrip() {
        val kit = RecoveryLink(server, Uuids.v7(), Uuids.v7().lower, randomBytes(32))
        assertEquals(kit, RecoveryLink.parse(kit.url))
        assertEquals(kit, RecoveryLink.parse(" ${kit.url}\n"))
        assertTrue(kit.url.startsWith("openbalance://recover?v=1&s=https://open-balance.example.com&g="), kit.url)
        assertTrue("#" !in kit.toString())
        val creation = CreationLink(server, randomBytes(32).let(io.github.hinkolas.openbalance.core.Base64Url::encode))
        assertEquals(creation, CreationLink.parse(creation.url))
        assertEquals("openbalance://create?v=1&s=https://open-balance.example.com#c=${creation.code}", creation.url)

        assertEquals(AppLink.Recovery(kit), AppLink.parse(kit.url))
        assertEquals(AppLink.Creation(creation), AppLink.parse(creation.url))
        for (bad in listOf(kit.url.substringBefore("#r=") + "#x=1", kit.url.replace("v=1", "v=2"), creation.url.dropLast(2), creation.url.replace("create", "join"))) {
            assertNull(AppLink.parse(bad), bad)
        }
    }
}

class OutboxTests {
    @Test
    fun outboxSurvivesARestartAndShowsOptimistically() {
        val dir = Files.createTempDirectory("ob-outbox").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val key = SigningKey.generate()
            val creds = GroupCredentials.create("http://127.0.0.1:9", Uuids.v7(), listOf(randomBytes(32)), Uuids.v7().lower, key.seed, registered = false)
            val store = MemoryCredentialStore()
            val s = GroupSession(creds, store, dir, scope)
            s.submit(EventData.GroupCreated(io.github.hinkolas.openbalance.core.GroupCreatedData("Trip", "EUR",
                io.github.hinkolas.openbalance.core.GroupCreatedData.Admin(creds.memberId, "Jonas", io.github.hinkolas.openbalance.core.Base64Url.encode(key.publicKey),
                    io.github.hinkolas.openbalance.core.Base64Url.encode(creds.box.publicKey)),
                io.github.hinkolas.openbalance.core.Base64Url.encode(SigningKey.generate().publicKey),
                io.github.hinkolas.openbalance.core.Base64Url.encode(io.github.hinkolas.openbalance.core.BoxKey.generate().publicKey))))
            assertEquals("Trip", s.state.value.name)
            assertEquals(1, s.pendingCount.value)
            assertTrue(s.state.value.history.single().pending)

            // A fresh session from the same cache shows the same pending state.
            val again = GroupSession(creds, store, dir, scope)
            assertEquals("Trip", again.state.value.name)
            assertEquals(1, again.pendingCount.value)
            again.forget()
            assertTrue(!File(dir, "groups/${creds.groupId}").exists())
        } finally {
            scope.cancel()
            dir.deleteRecursively()
        }
    }
}

/**
 * End to end against a running server:
 *   OB_TEST_SERVER=http://127.0.0.1:8080 OB_TEST_OWNER_TOKEN=… ./gradlew :ledger-sync:test
 * Skipped without OB_TEST_SERVER. Mirrors LedgerSync's IntegrationTests.
 */
class IntegrationTests {
    private val server = System.getenv("OB_TEST_SERVER")
    private val token = System.getenv("OB_TEST_OWNER_TOKEN") ?: ""

    @Test
    fun twoDevicesShareALedger() = runBlocking {
        if (server == null) return@runBlocking
        val tmp = Files.createTempDirectory("ob-it").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            run(tmp, scope)
        } finally {
            scope.cancel()
            tmp.deleteRecursively()
        }
    }

    private suspend fun run(tmp: File, scope: CoroutineScope) {
        fun dir(name: String) = File(tmp, name)

        // Device 1: Jonas creates the group and adds Ben.
        val (jonas, kit) = GroupSession.create(server!!, token, "Italien 2026", "EUR", "Jonas", MemoryCredentialStore(), dir("jonas"), scope)
        assertEquals(kit, RecoveryLink.parse(kit.url))
        assertTrue(jonas.isAdmin)
        assertEquals("Italien 2026", jonas.state.value.name)
        assertEquals(0, jonas.pendingCount.value)
        val invite = jonas.addMember("Ben")
        val parsed = assertNotNull(InviteLink.parse(invite.url))
        assertEquals(invite, parsed)

        // Device 2: Ben joins with the QR.
        val benStore = MemoryCredentialStore()
        val ben = GroupSession.join(parsed, null, benStore, dir("ben"), scope)
        assertEquals(true, ben.state.value.members[ben.me]?.isClaimed)
        assertEquals("Italien 2026", ben.state.value.name)
        assertTrue(!ben.isAdmin)

        // The invite is single use.
        val used = assertFailsWith<FlowError> { GroupSession.join(parsed, null, MemoryCredentialStore(), dir("eve"), scope) }
        assertEquals(FlowError.Kind.InviteUsed, used.kind)
        // Retrying with the same device's credentials works.
        GroupSession.join(parsed, benStore.all().first(), benStore, dir("ben"), scope)

        // Jonas records an income of 1000 at himself, 600/400.
        val a = jonas.me
        val b = ben.me
        val p = Payment(Uuids.v7().lower, Payment.Kind.Income, "Projekt Nordlicht", date = "2026-10-30", amount = 100_000, track = true,
            inSide = Payment.Side("exact", listOf(Payment.Line(a, 100_000))),
            outSide = Payment.Side("percent", listOf(Payment.Line(a, 60_000, value = 6000, rest = true), Payment.Line(b, 40_000, value = 4000))))
        jonas.syncNow()
        jonas.submit(EventData.PaymentCreated(p))
        assertNotNull(jonas.state.value.payments[p.id]) // optimistic
        jonas.submit(EventData.ArrivalRecorded(ArrivalRecordedData(Uuids.v7().lower, p.id, a, 100_000)))
        jonas.syncNow()
        assertEquals(0, jonas.pendingCount.value)

        ben.syncNow()
        assertEquals(mapOf(a to -40_000L, b to 40_000L), ben.state.value.summary().balances)
        assertEquals(listOf(Balances.Transfer(a, b, 40_000)), ben.state.value.summary().transfers)
        assertEquals(jonas.state.value, ben.state.value)

        // Ben is a company: his partner joins as a second device of the same member.
        val deviceLink = ben.addDevice()
        assertEquals(deviceLink, ben.addDevice()) // shown again, not a new invite
        val partner = GroupSession.join(InviteLink.parse(deviceLink.url)!!, null, MemoryCredentialStore(), dir("partner"), scope)
        assertEquals(b, partner.me)
        assertEquals(2, partner.state.value.members[b]?.keys?.size)
        partner.submit(EventData.MemberUpdated(MemberUpdatedData(b, "Ben & Co")))
        partner.syncNow()
        jonas.syncNow()
        assertEquals("Ben & Co", jonas.state.value.members[b]?.name)
        assertTrue(jonas.state.value.history.all { it.rejection == null })

        // Used invites aren't shown again; a revoked one stops working.
        ben.syncNow()
        assertNull(ben.deviceInviteLink())
        val spare = ben.addDevice()
        ben.revokeDeviceInvite()
        assertNull(ben.deviceInviteLink())
        val revoked = assertFailsWith<FlowError> { GroupSession.join(spare, null, MemoryCredentialStore(), dir("spare"), scope) }
        assertEquals(FlowError.Kind.InviteUsed, revoked.kind)

        // The admin's second device is admin too: in the ledger, and on the server
        // it may revoke the invite the first device made when it renews it.
        jonas.addMember("Cem")
        val cem = jonas.state.value.members.values.first { it.name == "Cem" }.id
        val jonasLink = jonas.addDevice()
        val jonas2 = GroupSession.join(jonasLink, null, MemoryCredentialStore(), dir("jonas2"), scope)
        assertTrue(jonas2.isAdmin)
        jonas2.renewInvite(cem)
        jonas.syncNow()
        assertTrue(jonas.state.value.history.all { it.rejection == null })

        // A third device of nobody can't read.
        assertFailsWith<ServerError> { ServerClient(server).read(SigningKey.generate(), jonas.id, after = 0) }

        // Live updates: a head arrives over the stream and Jonas pulls Ben's change.
        jonas.startLive()
        ben.submit(EventData.MemberUpdated(MemberUpdatedData(b, "Ben & Partner")))
        ben.syncNow()
        val deadline = System.currentTimeMillis() + 10_000
        while (jonas.state.value.members[b]?.name != "Ben & Partner" && System.currentTimeMillis() < deadline) kotlinx.coroutines.delay(100)
        assertEquals("Ben & Partner", jonas.state.value.members[b]?.name)
        jonas.stopLive()
    }

    /** A creation link from the server owner, lost devices, a reset member and a recovered admin (PROTOCOL.md §5.4 steps 0, 6–9). */
    @Test
    fun lostDevicesAndRecovery() = runBlocking {
        if (server == null) return@runBlocking
        val tmp = Files.createTempDirectory("ob-it").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            recovery(tmp, scope)
        } finally {
            scope.cancel()
            tmp.deleteRecursively()
        }
    }

    private suspend fun recovery(tmp: File, scope: CoroutineScope) {
        val server = server!!
        fun dir(name: String) = File(tmp, name)

        // The server owner lets Anna create a group; the code works once.
        val (code, _) = ServerClient(server).createCreationCode(token, expiresInHours = 1)
        val creation = assertNotNull(CreationLink.parse(CreationLink(server, code).url))
        val (anna, kit) = GroupSession.create(server, creation.code, "WG", "EUR", "Anna", MemoryCredentialStore(), dir("anna"), scope)
        val used = assertFailsWith<FlowError> { GroupSession.create(server, creation.code, "WG 2", "EUR", "Eve", MemoryCredentialStore(), dir("eve"), scope) }
        assertEquals(FlowError.Kind.CreationCodeUsed, used.kind)

        // Ben joins on his phone and adds his laptop; he loses the phone and removes it from the laptop.
        val ben = GroupSession.join(anna.addMember("Ben"), null, MemoryCredentialStore(), dir("ben"), scope)
        val laptop = GroupSession.join(ben.addDevice(), null, MemoryCredentialStore(), dir("laptop"), scope)
        laptop.removeDevice(ben.me, ben.deviceKey)
        assertFailsWith<ServerError> { ben.syncNow() }
        assertTrue(ben.isRemoved)
        assertEquals(listOf(laptop.deviceKey), laptop.state.value.members[ben.me]?.keys)
        // The laptop started epoch 1 right after removing the phone.
        assertEquals(1L, laptop.state.value.epoch)
        assertTrue(!laptop.state.value.epochDue)
        anna.syncNow()
        assertEquals(laptop.secrets.map { it.toList() }, anna.secrets.map { it.toList() })

        // Then the laptop is lost too: Anna resets Ben, who joins again as himself.
        val p = Payment(Uuids.v7().lower, Payment.Kind.Expense, "Strom", date = "2026-11-02", amount = 9_000, track = false,
            inSide = Payment.Side("exact", listOf(Payment.Line(anna.me, 4_500), Payment.Line(ben.me, 4_500))),
            outSide = Payment.Side("exact", listOf(Payment.Line(laptop.me, 9_000))))
        laptop.submit(EventData.PaymentCreated(p))
        laptop.syncNow()
        anna.syncNow()

        // Even with every blob from the server, the lost phone can't read the payment.
        val all = ServerClient(server).read(laptop.credentials.value.signer, anna.id, after = 0).first
        val phoneView = Ledger(anna.id, ben.secrets, listOf(ben.credentials.value.box))
        phoneView.apply(all)
        assertEquals(1, phoneView.secrets.size)
        assertNull(phoneView.state.payments[p.id])
        assertNotNull(anna.state.value.payments[p.id])

        val again = anna.resetMember(ben.me)
        runCatching { laptop.syncNow() }
        assertTrue(laptop.isRemoved)
        val benNew = GroupSession.join(again, null, MemoryCredentialStore(), dir("benNew"), scope)
        assertEquals(ben.me, benNew.me)
        assertEquals(anna.secrets.map { it.toList() }, benNew.secrets.map { it.toList() }) // from the invite's keyring
        assertEquals(2L, anna.state.value.epoch)
        assertEquals(4_500L, benNew.state.value.summary().balances[ben.me])

        // Anna loses her phone and restores the group with her recovery kit.
        val restored = GroupSession.recover(assertNotNull(RecoveryLink.parse(kit.url)), null, MemoryCredentialStore(), dir("restored"), scope)
        assertTrue(restored.isAdmin)
        assertEquals(listOf(restored.deviceKey), restored.state.value.members[anna.me]?.keys)
        runCatching { anna.syncNow() }
        assertTrue(anna.isRemoved)
        assertTrue(!anna.isAdmin)
        assertEquals(3L, restored.state.value.epoch) // recovering started an epoch

        // A new kit replaces the old one.
        val newKit = restored.newRecoveryKit()
        val replaced = assertFailsWith<FlowError> { GroupSession.recover(kit, null, MemoryCredentialStore(), dir("old-kit"), scope) }
        assertEquals(FlowError.Kind.RecoveryReplaced, replaced.kind)
        val restored2 = GroupSession.recover(newKit, null, MemoryCredentialStore(), dir("restored2"), scope)
        assertTrue(restored2.isAdmin)
        benNew.syncNow()
        assertTrue(benNew.state.value.history.all { it.rejection == null })
        assertEquals(restored2.state.value, benNew.state.value)
        assertEquals(5L, restored2.state.value.epoch) // the new kit and the second recovery each started one
        assertEquals(6, benNew.secrets.size)
    }

    /**
     * A device that writes before it has seen a new epoch: its event is stale,
     * and it writes it again under the new epoch (PROTOCOL.md §5.4 step 10).
     */
    @Test
    fun staleWritesAreWrittenAgain() = runBlocking {
        if (server == null) return@runBlocking
        val tmp = Files.createTempDirectory("ob-it").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val (anna, _) = GroupSession.create(server, token, "Büro", "EUR", "Anna", MemoryCredentialStore(), File(tmp, "anna"), scope)
            val ben = GroupSession.join(anna.addMember("Ben"), null, MemoryCredentialStore(), File(tmp, "ben"), scope)

            // Anna starts epoch 1 (a new recovery kit); Ben hasn't seen it and writes.
            anna.newRecoveryKit()
            assertEquals(1L, anna.state.value.epoch)
            val p = Payment(Uuids.v7().lower, Payment.Kind.Expense, "Kaffee", date = "2026-11-02", amount = 1_200, track = false,
                inSide = Payment.Side("exact", listOf(Payment.Line(anna.me, 600), Payment.Line(ben.me, 600))),
                outSide = Payment.Side("exact", listOf(Payment.Line(ben.me, 1_200))))
            ben.submit(EventData.PaymentCreated(p))
            ben.syncNow()
            ben.syncNow()
            assertEquals(0, ben.pendingCount.value)
            anna.syncNow()
            assertNotNull(anna.state.value.payments[p.id])
            assertEquals(1, anna.state.value.history.count { it.rejection == Rejection.StaleEpoch }) // the first attempt
            assertEquals(anna.state.value, ben.state.value)
        } finally {
            scope.cancel()
            tmp.deleteRecursively()
        }
    }
}
