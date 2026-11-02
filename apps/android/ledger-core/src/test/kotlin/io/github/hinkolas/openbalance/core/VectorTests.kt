package io.github.hinkolas.openbalance.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Loads spec/vectors/<name>: the same JSON every implementation runs. */
fun vectors(name: String): JsonObject {
    val dir = System.getProperty("vectors.dir") ?: error("vectors.dir not set")
    return Json.parseToJsonElement(File(dir, name).readText()).jsonObject
}

private fun b(s: String) = Base64Url.decode(s)!!
private fun JsonObject.s(k: String) = getValue(k).jsonPrimitive.content
private fun JsonObject.l(k: String) = getValue(k).jsonPrimitive.long
private fun JsonObject.longs(k: String) = getValue(k).jsonObject.mapValues { it.value.jsonPrimitive.long }
private fun JsonArray.transfers() = map { it.jsonObject.let { t -> Balances.Transfer(t.s("from"), t.s("to"), t.l("amount")) } }

class CryptoVectorTests {
    @Test
    fun cryptoVectors() {
        val v = vectors("crypto.json")
        val keys = v.getValue("keys").jsonObject
        val group = Uuids.parse(keys.s("groupId"))!!
        val key = LedgerCrypto.encKey(b(keys.s("groupSecret")), group)
        assertContentEquals(b(keys.s("encKey")), key)

        for (who in listOf("admin", "member", "invite", "recovery")) {
            val kp = keys.getValue(who).jsonObject
            assertContentEquals(b(kp.s("publicKey")), SigningKey(b(kp.s("seed"))).publicKey, who)
        }

        var chain = LedgerCrypto.chainZero
        for (e in v.getValue("events").jsonArray.map { it.jsonObject }) {
            val id = Uuids.parse(e.s("id"))!!
            val blob = b(e.s("blob"))
            val opened = LedgerCrypto.open(blob, group, id, key)
            assertEquals(e.s("body"), opened.body.decodeToString())
            assertContentEquals(b(e.s("signature")), opened.signature)
            assertTrue(LedgerCrypto.verify(opened.signature, opened.body, group, id, b(e.s("authorPublicKey"))))
            // Same nonce and signature → same blob: our envelope matches byte for byte.
            assertContentEquals(blob, LedgerCrypto.sealSigned(opened.body, opened.signature, group, id, key, b(e.s("nonce"))))
            // Ed25519 in BouncyCastle is deterministic (RFC 8032), so our signature matches too.
            assertContentEquals(opened.signature, SigningKey(b(keys.getValue("admin").jsonObject.s("seed"))).sign(LedgerCrypto.eventSigningInput(group, id, opened.body)))
            chain = LedgerCrypto.chainNext(chain, e.l("seq"), id, blob)
            assertContentEquals(b(e.s("chain")), chain)
            assertFailsWith<LedgerCrypto.Failure> { LedgerCrypto.open(blob, Uuids.v7(), id, key) }
        }

        for (r in v.getValue("requests").jsonArray.map { it.jsonObject }) {
            val input = LedgerCrypto.requestSigningInput(r.s("method"), r.s("pathAndQuery"), r.l("ts"), r.s("body").toByteArray())
            assertEquals(r.s("signingInput"), input.decodeToString())
            val member = SigningKey(b(keys.getValue("member").jsonObject.s("seed")))
            assertEquals(r.s("authorization"), LedgerCrypto.authorization(member, r.s("method"), r.s("pathAndQuery"), r.l("ts"), r.s("body").toByteArray()))
        }

        val claim = v.getValue("claim").jsonObject
        val memberPub = b(keys.getValue("member").jsonObject.s("publicKey"))
        val invitePub = b(keys.getValue("invite").jsonObject.s("publicKey"))
        assertTrue(Ed25519.verify(memberPub, b(claim.s("proof")), LedgerCrypto.claimInput(group, invitePub)))
        assertTrue(Ed25519.verify(invitePub, b(claim.s("inviteSig")), LedgerCrypto.claimInput(group, memberPub)))

        val recover = v.getValue("recover").jsonObject
        val recoveryPub = b(keys.getValue("recovery").jsonObject.s("publicKey"))
        val recoverInput = LedgerCrypto.recoverInput(group, memberPub)
        assertEquals(recover.s("signingInputHex"), recoverInput.hex)
        assertTrue(Ed25519.verify(recoveryPub, b(recover.s("recoverySig")), recoverInput))
        assertTrue(Ed25519.verify(memberPub, b(recover.s("proof")), LedgerCrypto.claimInput(group, recoveryPub)))
        assertTrue(!Ed25519.verify(recoveryPub, b(recover.s("recoverySig")), LedgerCrypto.claimInput(group, memberPub)))
    }
}

class MathVectorTests {
    @Test
    fun distributeVectors() {
        for (c in vectors("distribute.json").getValue("cases").jsonArray.map { it.jsonObject }) {
            assertEquals(c.longs("expect"), Balances.distribute(c.l("total"), c.longs("weights")), c.s("name"))
        }
    }

    @Test
    fun transferVectors() {
        for (c in vectors("transfers.json").getValue("cases").jsonArray.map { it.jsonObject }) {
            assertEquals(c.getValue("expect").jsonArray.transfers(), Balances.transfers(c.longs("balances")), c.s("name"))
        }
    }

    @Test
    fun balanceVectors() {
        for (c in vectors("balances.json").getValue("cases").jsonArray.map { it.jsonObject }) {
            val name = c.s("name")
            val arrivals = HashMap<PaymentId, List<Arrival>>()
            fun side(a: JsonArray) = Payment.Side("exact", a.map { it.jsonObject.let { l -> Payment.Line(l.s("member"), l.l("amount")) } })
            val payments = c.getValue("payments").jsonArray.map { it.jsonObject }
                .filter { it["deleted"]?.jsonPrimitive?.boolean != true }
                .map { p ->
                    val id = p.s("id")
                    arrivals[id] = (p["arrivals"] as? JsonArray ?: JsonArray(emptyList())).mapIndexed { i, a ->
                        Arrival("$id-$i", id, a.jsonObject.s("member"), a.jsonObject.l("amount"), author = "x", at = "")
                    }
                    Payment(id, Payment.Kind.Income, "t", date = "2026-01-01", amount = p.l("amount"), track = p.getValue("track").jsonPrimitive.boolean,
                        inSide = side(p.getValue("in").jsonArray), outSide = side(p.getValue("out").jsonArray))
                }
            val members = c.getValue("members").jsonArray.map { it.jsonPrimitive.content }
            val s = Balances.summarize(members, payments, arrivals)
            val e = c.getValue("expect").jsonObject
            assertEquals(e.longs("balances"), s.balances, name)
            assertEquals(e.longs("pendingOwned"), s.pendingOwned, name)
            assertEquals(e.longs("pendingHeld"), s.pendingHeld, name)
            assertEquals(e.getValue("transfers").jsonArray.transfers(), s.transfers, name)
            assertEquals(e.longs("expected"), s.expected, name)
            assertEquals(e.getValue("expectedTransfers").jsonArray.transfers(), s.expectedTransfers, name)
            assertEquals(e.getValue("payNow").jsonArray.transfers(), s.payNow, name)
        }
    }
}

class MoneyTests {
    @Test
    fun parseMoney() {
        val cases = listOf(
            "12,40" to 1240L, "12.4" to 1240L, "1.240,00" to 124000L, "1,240.00" to 124000L, "12" to 1200L,
            "0,5" to 50L, "1.240" to 124000L, "12," to 1200L,
        )
        for ((input, minor) in cases) assertEquals(minor, Money.parse(input, "EUR"), input)
    }

    @Test
    fun parseMoneyRejects() {
        for (s in listOf("", "abc", "12abc", "1,2,3", "12,345,6", "-5", "1.2.3,45.6")) assertNull(Money.parse(s, "EUR"), s)
        assertEquals(1500L, Money.parse("1500", "JPY"))
    }

    @Test
    fun percentWithRest() {
        assertEquals(mapOf("b" to 33_330L, "a" to 66_670L), Splits.percent(100_000, mapOf("a" to 6000L, "b" to 3333L), rest = "a"))
    }

    @Test
    fun formatsInTheLocale() {
        assertEquals("1.240,00 €", Money.format(124000, "EUR", locale = java.util.Locale.GERMANY))
        assertEquals("+€12.40", Money.format(1240, "EUR", signed = true, locale = java.util.Locale.US))
        assertEquals("130.000,00", Money.bare(13_000_000, "EUR", java.util.Locale.GERMANY))
        assertEquals("1500", Money.inputString(1500, "JPY", java.util.Locale.GERMANY))
    }
}

class EventCodingTests {
    private val header = EventHeader(1, "payment.created", "a", "2026-11-01T12:00:00Z", EventHeader.Seen(0, LedgerCrypto.chainZero.base64Url))

    @Test
    fun roundTripsAndOmitsAbsentOptionals() {
        val p = Payment("p", Payment.Kind.Income, "Rate", date = "2026-10-30", amount = 100, track = true,
            inSide = Payment.Side("exact", listOf(Payment.Line("a", 100))),
            outSide = Payment.Side("mixed", listOf(Payment.Line("a", 60, value = 6000, rest = true), Payment.Line("b", 40))))
        val body = EventCoding.encode(header, EventData.PaymentCreated(p))
        val text = body.decodeToString()
        assertTrue("note" !in text && "base" !in text, text)
        val (h, d) = EventCoding.decode(body)
        assertEquals(header, h)
        assertEquals(EventData.PaymentCreated(p), d)
    }

    @Test
    fun strictTypes() {
        fun body(data: String) = """{"v":1,"type":"arrival.recorded","author":"a","at":"x","seen":{"seq":0,"chain":"c"},"data":$data}""".toByteArray()
        EventCoding.decode(body("""{"id":"r","payment":"p","member":"m","amount":5,"extra":true}"""))
        for (bad in listOf(
            """{"id":"r","payment":"p","member":"m","amount":"5"}""",
            """{"id":"r","payment":"p","member":"m","amount":5.5}""",
            """{"id":"r","payment":"p","member":5,"amount":5}""",
            """{"id":"r","payment":"p","amount":5}""",
            """{"id":"r","payment":"p","member":null,"amount":5}""",
        )) assertFailsWith<EventCoding.Malformed>(bad) { EventCoding.decode(body(bad)) }
        assertFailsWith<EventCoding.Malformed> { EventCoding.decode("""{"v":2,"type":"x","author":"a","at":"x","seen":{"seq":0,"chain":"c"}}""".toByteArray()) }
        assertFailsWith<EventCoding.Malformed> { EventCoding.decode("""{"v":1,"type":"x","author":"a","at":"x","seen":{"seq":-1,"chain":"c"}}""".toByteArray()) }
        val (_, unknown) = EventCoding.decode("""{"v":1,"type":"poll.created","author":"a","at":"x","seen":{"seq":0,"chain":"c"}}""".toByteArray())
        assertEquals(EventData.Unsupported("poll.created"), unknown)
    }

    @Test
    fun uuidsAreStrict() {
        assertNull(Uuids.parse("1-1-1-1-1"))
        val id = Uuids.v7()
        assertEquals(id, Uuids.parse(id.lower))
        assertEquals(7, id.version())
        assertEquals(UUID.fromString(id.lower).lower, id.lower)
    }
}
