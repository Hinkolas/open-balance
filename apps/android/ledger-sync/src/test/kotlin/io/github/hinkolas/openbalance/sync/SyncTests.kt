package io.github.hinkolas.openbalance.sync

import io.github.hinkolas.openbalance.core.ArrivalRecordedData
import io.github.hinkolas.openbalance.core.Balances
import io.github.hinkolas.openbalance.core.EventData
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
    private val link = InviteLink("https://open-balance.example.com", Uuids.v7(), Uuids.v7().lower, randomBytes(32), randomBytes(32))

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
        val withPath = InviteLink("https://example.com/ob?x=1&y=2", link.groupId, link.memberId, link.secret, link.inviteSeed)
        assertEquals(withPath, InviteLink.parse(withPath.url))
    }

    @Test
    fun rejectsBrokenLinks() {
        for (bad in listOf(
            "", "https://example.com", link.url.substringBefore('#'),
            link.url.replace("v=1", "v=2"), link.url.replace("openbalance://join", "openbalance://other"),
            link.url.replace("s=https", "s=ftp"), link.url.replace(link.groupId.lower, "1-1-1-1-1"),
            link.url.substringBefore("&i="),
        )) assertNull(InviteLink.parse(bad), bad)
    }

    @Test
    fun neverPrintsSecrets() {
        val creds = GroupCredentials.create("https://x", link.groupId, link.secret, link.memberId, link.inviteSeed, registered = true)
        assertTrue(creds.secret !in creds.toString() && creds.memberSeed !in creds.toString())
        assertTrue("#" !in link.toString() && "k=" !in link.toString())
    }
}

class OutboxTests {
    @Test
    fun outboxSurvivesARestartAndShowsOptimistically() {
        val dir = Files.createTempDirectory("ob-outbox").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val key = SigningKey.generate()
            val creds = GroupCredentials.create("http://127.0.0.1:9", Uuids.v7(), randomBytes(32), Uuids.v7().lower, key.seed, registered = false)
            val store = MemoryCredentialStore()
            val s = GroupSession(creds, store, dir, scope)
            s.submit(EventData.GroupCreated(io.github.hinkolas.openbalance.core.GroupCreatedData("Trip", "EUR",
                io.github.hinkolas.openbalance.core.GroupCreatedData.Admin(creds.memberId, "Jonas", io.github.hinkolas.openbalance.core.Base64Url.encode(key.publicKey)))))
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
        val jonas = GroupSession.create(server!!, token, "Italien 2026", "EUR", "Jonas", MemoryCredentialStore(), dir("jonas"), scope)
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
}
