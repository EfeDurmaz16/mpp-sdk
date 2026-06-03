package com.solana.paykit.protocols.x402.client.exact

import com.solana.paykit.paycore.MemorySigner
import com.solana.paykit.protocols.x402.exact.PAYMENT_IDENTIFIER_KEY
import com.solana.paykit.protocols.x402.exact.PaymentExtensions
import com.solana.paykit.protocols.x402.exact.X402AcceptsEntry
import com.solana.paykit.protocols.x402.exact.generatePaymentIdentifierId
import java.io.File
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * x402 v2 extensions echo-and-append tests for the Kotlin client.
 *
 * Two layers:
 *
 *  1. Unit tests over [PaymentExtensions] / [generatePaymentIdentifierId],
 *     mirroring the rust spine type tests in
 *     ``rust/crates/x402/src/protocol/schemes/exact/types.rs`` (echoing,
 *     with_payment_identifier_id append-without-overwrite, is_empty,
 *     requires_payment_identifier, generate id pattern).
 *
 *  2. The cross-language extension conformance vectors
 *     (``harness/vectors/x402-extensions.json``) for the build side that the
 *     Kotlin (client-only) SDK implements. The verify-side vectors
 *     (``mode == "verify-transaction"``) are server-side and skipped — Kotlin
 *     does not implement the x402 server.
 */
class ExtensionsTest {

    private val json = Json { ignoreUnknownKeys = true }

    // Deterministic signer + blockhash so build output is reproducible.
    private val signer = MemorySigner.fromSeed(ByteArray(32) { 0x42 })
    private val fixedBlockhash: () -> ByteArray = { ByteArray(32) }
    private val fixedNonce: () -> String = { "00000000000000000000000000000000" }

    // ── PaymentExtensions unit tests (mirror rust types.rs) ────────────────────

    @Test
    fun echoingReturnsNullWhenInboundAbsent() {
        // rust: payment_extensions_echoing_returns_none_when_inbound_absent
        assertNull(PaymentExtensions.echoing(null))
    }

    @Test
    fun echoesUnknownKeysVerbatim() {
        // rust: payment_extensions_echoes_unknown_keys_verbatim
        val inbound = json.parseToJsonElement(
            """{"future-extension":{"info":{"foo":"bar"}},"bazaar":{"info":{}}}""",
        ).jsonObject
        val ext = PaymentExtensions.echoing(inbound)!!
        assertNull(ext.paymentIdentifier)
        assertEquals(2, ext.other.size)
        // Re-emission preserves both unknown keys verbatim (sorted).
        val reemitted = ext.toJsonObject()
        assertEquals(setOf("bazaar", "future-extension"), reemitted.keys)
        assertEquals(inbound["future-extension"], reemitted["future-extension"])
        assertEquals(inbound["bazaar"], reemitted["bazaar"])
    }

    @Test
    fun typedPaymentIdentifierRoundTrip() {
        // rust: payment_extensions_typed_payment_identifier_round_trip
        val inbound = json.parseToJsonElement(
            """{"payment-identifier":{"info":{"required":true},"schema":{"type":"object"}}}""",
        ).jsonObject
        val ext = PaymentExtensions.echoing(inbound)!!
        assertTrue(ext.requiresPaymentIdentifier())
        val pid = ext.paymentIdentifier!!
        assertEquals(true, (pid["info"] as JsonObject)["required"]!!.jsonPrimitive.boolean)
        assertNull((pid["info"] as JsonObject)["id"])
        assertTrue(pid.containsKey("schema"))
    }

    @Test
    fun withPaymentIdentifierIdAppendsWithoutOverwritingServerFields() {
        // rust: with_payment_identifier_id_appends_without_overwriting_server_fields
        val inbound = json.parseToJsonElement(
            """{"payment-identifier":{"info":{"required":true},""" +
                """"schema":{"type":"object","required":["id"]}}}""",
        ).jsonObject
        val ext = PaymentExtensions.echoing(inbound)!!
            .withPaymentIdentifierId("pay_abcdef1234567890abcdef1234567890")
        val pid = ext.paymentIdentifier!!
        val info = pid["info"] as JsonObject
        // Server info.required preserved per §5.1.2.
        assertEquals(true, info["required"]!!.jsonPrimitive.boolean)
        // Schema echoed verbatim.
        assertTrue(pid.containsKey("schema"))
        // Client id appended.
        assertEquals("pay_abcdef1234567890abcdef1234567890", info["id"]!!.jsonPrimitive.content)
        assertEquals("pay_abcdef1234567890abcdef1234567890", ext.paymentIdentifierId())
    }

    @Test
    fun withPaymentIdentifierIdCreatesEntryWhenServerDidntAdvertise() {
        // rust: with_payment_identifier_id_creates_entry_when_server_didnt_advertise
        val ext = PaymentExtensions.empty().withPaymentIdentifierId("pay_0000000000000000")
        assertEquals("pay_0000000000000000", ext.paymentIdentifierId())
    }

    @Test
    fun isEmptyTracksContents() {
        assertTrue(PaymentExtensions.empty().isEmpty())
        assertFalse(PaymentExtensions.empty().withPaymentIdentifierId("pay_aaaaaaaaaaaaaaaa").isEmpty())
    }

    @Test
    fun requiresPaymentIdentifierFalseWhenNotRequired() {
        val inbound = json.parseToJsonElement(
            """{"payment-identifier":{"info":{}}}""",
        ).jsonObject
        assertFalse(PaymentExtensions.echoing(inbound)!!.requiresPaymentIdentifier())
    }

    @Test
    fun echoingRejectsNonObject() {
        assertFailsWith<IllegalArgumentException> {
            PaymentExtensions.echoing(JsonPrimitive("nope"))
        }
    }

    @Test
    fun serializesWithKebabCaseKey() {
        // rust: payment_extensions_serializes_with_correct_key_casing
        val ext = PaymentExtensions.empty().withPaymentIdentifierId("pay_aaaaaaaaaaaaaaaa")
        assertTrue(ext.toJsonObject().containsKey(PAYMENT_IDENTIFIER_KEY))
    }

    @Test
    fun generateIdMatchesSpecPattern() {
        // rust: generate_payment_identifier_id_matches_spec_pattern
        val re = Regex("^pay_[A-Za-z0-9_-]{32}$")
        val wire = Regex("^[A-Za-z0-9_-]{16,128}$")
        repeat(32) {
            val id = generatePaymentIdentifierId()
            assertTrue(re.matches(id), "bad id: $id")
            assertTrue(wire.matches(id), "id violates wire pattern: $id")
        }
    }

    @Test
    fun generateIdIsUnique() {
        assertTrue(generatePaymentIdentifierId() != generatePaymentIdentifierId())
    }

    // ── Conformance vectors (build side) ───────────────────────────────────────

    @Test
    fun runsExtensionConformanceVectors() {
        val vectorsFile = locateVectors()
        val vectors = json.parseToJsonElement(vectorsFile.readText()).jsonArray
        var ran = 0
        for (element in vectors) {
            val vector = element.jsonObject
            val mode = vector["mode"]?.jsonPrimitive?.content
            // Kotlin is client-only: it implements the build side. The
            // verify-transaction vectors are server-side and skipped.
            if (mode != "build-transaction") continue
            runBuildVector(vector)
            ran++
        }
        // Guards against the vector file silently dropping the build cases.
        assertEquals(4, ran, "expected 4 build-side extension vectors")
    }

    private fun runBuildVector(vector: JsonObject) {
        val id = vector["id"]!!.jsonPrimitive.content
        val input = vector["input"]!!.jsonObject
        val expect = vector["expect"]!!.jsonObject
        val shape = expect["x402EnvelopeShape"]!!.jsonObject

        // Decode the offer into an X402AcceptsEntry carrying its verbatim raw.
        val offerElem = input["x402Offer"]!!.jsonObject
        val requirement = json.decodeFromJsonElement(X402AcceptsEntry.serializer(), offerElem)
            .copy(raw = offerElem)

        // Echo-and-append, mirroring X402Interceptor.echoAndAppendExtensions but
        // driven directly off the vector's advertised extensions + pinned id.
        val advertised = input["x402AdvertisedExtensions"]?.jsonObject
        val pinnedId = input["x402PaymentIdentifierId"]?.jsonPrimitive?.content
        val extensions: PaymentExtensions? = PaymentExtensions.echoing(advertised)?.let { echoed ->
            when {
                pinnedId != null -> echoed.withPaymentIdentifierId(pinnedId)
                echoed.requiresPaymentIdentifier() ->
                    echoed.withPaymentIdentifierId(generatePaymentIdentifierId())
                else -> echoed
            }
        }

        val header = buildPaymentHeader(
            signer = signer,
            requirement = requirement,
            rpcBlockhashProvider = fixedBlockhash,
            nonceProvider = fixedNonce,
            extensions = extensions,
        )
        val envelope = json.parseToJsonElement(
            Base64.getDecoder().decode(header).decodeToString(),
        ).jsonObject

        // Envelope-shape oracle assertions (the conformance contract).
        assertEquals(
            shape["x402Version"]!!.jsonPrimitive.content.toInt(),
            envelope["x402Version"]!!.jsonPrimitive.content.toInt(),
            "$id: x402Version",
        )
        assertEquals(
            shape["hasAccepted"]!!.jsonPrimitive.boolean,
            envelope.containsKey("accepted"),
            "$id: hasAccepted",
        )
        val payload = envelope["payload"]?.jsonObject
        assertEquals(
            shape["payloadHasTransaction"]!!.jsonPrimitive.boolean,
            payload?.containsKey("transaction") == true,
            "$id: payloadHasTransaction",
        )

        val ext = envelope["extensions"]?.jsonObject
        assertEquals(
            shape["hasExtensions"]!!.jsonPrimitive.boolean,
            ext != null,
            "$id: hasExtensions",
        )

        val hasPid = ext?.containsKey(PAYMENT_IDENTIFIER_KEY) == true
        assertEquals(
            shape["hasPaymentIdentifier"]!!.jsonPrimitive.boolean,
            hasPid,
            "$id: hasPaymentIdentifier",
        )

        shape["extensionKeys"]?.jsonArray?.let { keys ->
            val expected = keys.map { it.jsonPrimitive.content }
            // extensionKeys are pinned sorted; PaymentExtensions emits sorted.
            assertEquals(expected, ext?.keys?.toList() ?: emptyList(), "$id: extensionKeys")
        }

        shape["paymentIdentifierRequired"]?.let { req ->
            val info = (ext?.get(PAYMENT_IDENTIFIER_KEY) as? JsonObject)?.get("info") as? JsonObject
            val required = info?.get("required")?.jsonPrimitive?.boolean ?: false
            assertEquals(req.jsonPrimitive.boolean, required, "$id: paymentIdentifierRequired")
        }

        shape["paymentIdentifierId"]?.let { pid ->
            val info = (ext?.get(PAYMENT_IDENTIFIER_KEY) as? JsonObject)?.get("info") as? JsonObject
            assertEquals(
                pid.jsonPrimitive.content,
                info?.get("id")?.jsonPrimitive?.content,
                "$id: paymentIdentifierId",
            )
        }

        // For the generated-id vector (no pinned id), assert the appended id is
        // wire-pattern valid even though it is non-deterministic.
        if (shape["hasPaymentIdentifier"]!!.jsonPrimitive.boolean &&
            shape["paymentIdentifierId"] == null
        ) {
            val info = (ext?.get(PAYMENT_IDENTIFIER_KEY) as? JsonObject)?.get("info") as? JsonObject
            val generated = info?.get("id")?.jsonPrimitive?.content
            assertTrue(
                generated != null && Regex("^[A-Za-z0-9_-]{16,128}$").matches(generated),
                "$id: generated id violates wire pattern: $generated",
            )
        }
    }

    /** Resolve harness/vectors/x402-extensions.json relative to the kotlin module. */
    private fun locateVectors(): File {
        // gradle runs tests with user.dir == the kotlin/ module dir.
        val moduleDir = File(System.getProperty("user.dir"))
        val candidates = listOf(
            File(moduleDir, "../harness/vectors/x402-extensions.json"),
            File(moduleDir, "harness/vectors/x402-extensions.json"),
        )
        return candidates.firstOrNull { it.exists() }
            ?: error("x402-extensions.json not found relative to ${moduleDir.absolutePath}")
    }
}
