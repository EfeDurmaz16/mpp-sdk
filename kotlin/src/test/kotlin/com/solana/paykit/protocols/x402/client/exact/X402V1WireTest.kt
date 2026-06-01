package com.solana.paykit.protocols.x402.client.exact

import com.solana.paykit.paycore.MemorySigner
import com.solana.paykit.paycore.Mints
import com.solana.paykit.paycore.Network
import com.solana.paykit.protocols.x402.exact.X402AcceptsEntry
import com.solana.paykit.protocols.x402.exact.effectiveAsset
import com.solana.paykit.protocols.x402.exact.effectivePayTo
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Unit tests for the legacy x402 v1 wire paths added to the Kotlin client:
 * the [buildPaymentHeaderV1] producer and the ``X-Payment-Required``
 * raw-JSON-flat challenge parse fallback.
 *
 * Mirrors the rust spine ``build_payment_header_v1`` (payment.rs:144-160),
 * ``v1_network_for_requirements`` (payment.rs:383-394), and the v1 challenge
 * fallback in ``parse_x402_challenge_with_selection`` (payment.rs:236-243).
 */
class X402V1WireTest {

    private val signer = MemorySigner.fromSeed(ByteArray(32) { 0x42 })
    private val fixedBlockhash: () -> ByteArray = { ByteArray(32) }
    private val fixedNonce = { "0011223344556677" }
    private val devnetRecipient = "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY"

    private fun decodeEnvelope(header: String) =
        Json.parseToJsonElement(Base64.getDecoder().decode(header).decodeToString()).jsonObject

    private fun solDevnetOffer(amount: String = "1000") = X402AcceptsEntry(
        scheme = "exact",
        network = Network.SOLANA_DEVNET,
        asset = "SOL",
        amount = amount,
        payTo = devnetRecipient,
    )

    private fun solMainnetOffer() = X402AcceptsEntry(
        scheme = "exact",
        network = Network.SOLANA_MAINNET,
        asset = "SOL",
        amount = "1000",
        payTo = devnetRecipient,
    )

    // ── (a) v1 producer emits the correct X-Payment envelope ───────────────────

    @Test
    fun v1ProducerEmitsLegacyEnvelopeShape() {
        val header = buildPaymentHeaderV1(signer, solDevnetOffer(), fixedBlockhash, fixedNonce)
        // Standard base64, not base64url.
        assertTrue(header.none { it == '-' || it == '_' }, "header must be standard base64")
        val envelope = decodeEnvelope(header)

        assertEquals(1, envelope["x402Version"]!!.jsonPrimitive.int, "v1 envelope stamps x402Version=1")
        assertEquals("exact", envelope["scheme"]!!.jsonPrimitive.content, "top-level scheme=exact")
        assertEquals(
            "solana-devnet",
            envelope["network"]!!.jsonPrimitive.content,
            "devnet offer maps to the legacy solana-devnet network string",
        )
        // No accepted, no resource in v1.
        assertNull(envelope["accepted"], "v1 envelope must not carry accepted")
        assertNull(envelope["resource"], "v1 envelope must not carry resource")
        // The proof is present and carries a transaction.
        val transaction = envelope["payload"]!!.jsonObject["transaction"]!!.jsonPrimitive.content
        assertTrue(transaction.isNotEmpty(), "v1 envelope must carry the transaction proof")
    }

    @Test
    fun v1MainnetOfferMapsToSolanaNetworkString() {
        val header = buildPaymentHeaderV1(signer, solMainnetOffer(), fixedBlockhash, fixedNonce)
        val envelope = decodeEnvelope(header)
        assertEquals(
            "solana",
            envelope["network"]!!.jsonPrimitive.content,
            "mainnet collapses to the legacy solana network string",
        )
    }

    @Test
    fun v1TestnetOfferMapsToSolanaNetworkString() {
        // The v1 mapping collapses everything that is not devnet to "solana",
        // including testnet (rust v1_network_for_requirements catch-all).
        val testnetOffer = X402AcceptsEntry(
            scheme = "exact",
            network = Network.SOLANA_TESTNET,
            asset = "SOL",
            amount = "1000",
            payTo = devnetRecipient,
        )
        val header = buildPaymentHeaderV1(signer, testnetOffer, fixedBlockhash, fixedNonce)
        val envelope = decodeEnvelope(header)
        assertEquals("solana", envelope["network"]!!.jsonPrimitive.content)
    }

    @Test
    fun v1ProofIsIdenticalToV2Proof() {
        // The proof is version-agnostic: v1 and v2 build the same transaction
        // from the same offer. Only the envelope differs.
        val offer = solDevnetOffer()
        val v1Header = buildPaymentHeaderV1(signer, offer, fixedBlockhash, fixedNonce)
        val v2Header = buildPaymentHeader(signer, offer, fixedBlockhash, fixedNonce)
        val v1Tx = decodeEnvelope(v1Header)["payload"]!!.jsonObject["transaction"]!!.jsonPrimitive.content
        val v2Tx = decodeEnvelope(v2Header)["payload"]!!.jsonObject["transaction"]!!.jsonPrimitive.content
        assertEquals(v2Tx, v1Tx, "v1 and v2 producers build byte-identical proofs")
    }

    @Test
    fun v2ProducerStillDefaultsToVersion2() {
        // v2 stays the default; adding the v1 producer must not regress it.
        val v2Header = buildPaymentHeader(signer, solDevnetOffer(), fixedBlockhash, fixedNonce)
        val envelope = decodeEnvelope(v2Header)
        assertEquals(2, envelope["x402Version"]!!.jsonPrimitive.int)
        assertNotNull(envelope["accepted"], "v2 envelope carries accepted")
        assertNull(envelope["scheme"], "v2 envelope omits the top-level scheme")
        assertNull(envelope["network"], "v2 envelope omits the top-level network")
    }

    // ── (b) v1 challenge parse handles a flat PaymentRequirements ───────────────

    @Test
    fun parsesV1FlatRequirementFromRawJsonHeader() {
        // The v1 X-Payment-Required header is RAW JSON (no base64), a single
        // flat PaymentRequirements using the legacy field names
        // (recipient / maxAmountRequired / currency) and legacy network string.
        val flat = """{"scheme":"exact","network":"solana-devnet",""" +
            """"maxAmountRequired":"2500","currency":"USDC",""" +
            """"recipient":"$devnetRecipient","resource":"/api/data"}"""
        val headers = mapOf("X-Payment-Required" to flat)
        val result = parseX402Challenge(headers, null, ChallengeSelection())
        assertNotNull(result)
        assertEquals("2500", result.maxAmountRequired)
        assertEquals("USDC", result.effectiveAsset)
        assertEquals(devnetRecipient, result.effectivePayTo)
        // Legacy network string normalized to CAIP-2 devnet.
        assertEquals(Network.SOLANA_DEVNET, result.network)
    }

    @Test
    fun v1FlatHeaderLookupIsCaseInsensitive() {
        val flat = """{"scheme":"exact","network":"solana","amount":"100","asset":"SOL","payTo":"$devnetRecipient"}"""
        val headers = mapOf("x-PaYmEnT-rEqUiReD" to flat)
        val result = parseX402Challenge(headers, null, ChallengeSelection())
        assertNotNull(result)
        assertEquals(Network.SOLANA_MAINNET, result.network, "legacy solana string normalizes to mainnet CAIP-2")
    }

    @Test
    fun v2HeaderPreferredOverV1FlatHeader() {
        // When both headers are present the v2 Payment-Required (base64
        // accepts[] envelope) wins, matching the rust order (v2 before v1).
        val v2Body = """{"accepts":[{"scheme":"exact","network":"${Network.SOLANA_DEVNET}",""" +
            """"amount":"100","asset":"SOL","payTo":"$devnetRecipient"}]}"""
        val v2Header = Base64.getEncoder().encodeToString(v2Body.toByteArray())
        val v1Flat = """{"scheme":"exact","network":"solana-devnet","maxAmountRequired":"999","currency":"SOL","recipient":"$devnetRecipient"}"""
        val headers = mapOf(
            "Payment-Required" to v2Header,
            "X-Payment-Required" to v1Flat,
        )
        val result = parseX402Challenge(headers, null, ChallengeSelection(network = "devnet"))
        assertNotNull(result)
        assertEquals("100", result.amount, "v2 header must win over the v1 flat header")
    }

    @Test
    fun v1FlatHeaderUsedWhenNoV2Header() {
        // The v1 flat header is the fallback after the v2 path and before body.
        val v1Flat = """{"scheme":"exact","network":"solana-devnet","maxAmountRequired":"777","currency":"SOL","recipient":"$devnetRecipient"}"""
        val body = """{"accepts":[{"scheme":"exact","network":"${Network.SOLANA_DEVNET}","amount":"5","asset":"SOL","payTo":"$devnetRecipient"}]}"""
        val headers = mapOf("X-Payment-Required" to v1Flat)
        val result = parseX402Challenge(headers, body, ChallengeSelection(network = "devnet"))
        assertNotNull(result)
        assertEquals("777", result.maxAmountRequired, "v1 flat header must win over the body")
    }

    @Test
    fun v1FlatHeaderFallsThroughToBodyWhenNotSolanaExact() {
        // A non-Solana v1 flat header is rejected and parsing falls through to
        // the body.
        val v1Flat = """{"scheme":"exact","network":"ethereum:1","maxAmountRequired":"1","currency":"ETH","recipient":"0x0"}"""
        val body = """{"accepts":[{"scheme":"exact","network":"${Network.SOLANA_DEVNET}","amount":"5","asset":"SOL","payTo":"$devnetRecipient"}]}"""
        val headers = mapOf("X-Payment-Required" to v1Flat)
        val result = parseX402Challenge(headers, body, ChallengeSelection(network = "devnet"))
        assertNotNull(result)
        assertEquals("5", result.amount, "non-Solana v1 header must fall through to the body")
    }

    @Test
    fun v1FlatHeaderRejectsMalformedJson() {
        val headers = mapOf("X-Payment-Required" to "not-json")
        assertNull(parseX402Challenge(headers, null, ChallengeSelection()))
    }

    // ── (c) round-trip: a v1 flat challenge can be paid back as a v1 envelope ────

    @Test
    fun roundTripV1ChallengeToV1Envelope() {
        // Parse a v1 flat challenge, then pay it back through the v1 producer.
        // The resulting envelope must carry the legacy devnet network string
        // and the same proof the v2 producer would build for the same offer.
        val flat = """{"scheme":"exact","network":"solana-devnet",""" +
            """"maxAmountRequired":"1000","currency":"SOL","recipient":"$devnetRecipient"}"""
        val headers = mapOf("X-Payment-Required" to flat)
        val requirement = parseX402Challenge(headers, null, ChallengeSelection(network = "devnet"))
        assertNotNull(requirement)

        val v1Header = buildPaymentHeaderV1(signer, requirement, fixedBlockhash, fixedNonce)
        val envelope = decodeEnvelope(v1Header)
        assertEquals(1, envelope["x402Version"]!!.jsonPrimitive.int)
        assertEquals("exact", envelope["scheme"]!!.jsonPrimitive.content)
        assertEquals("solana-devnet", envelope["network"]!!.jsonPrimitive.content)
        assertFalse(envelope.containsKey("accepted"))
        val transaction = envelope["payload"]!!.jsonObject["transaction"]!!.jsonPrimitive.content
        assertTrue(transaction.isNotEmpty())
    }

    @Test
    fun roundTripV1ChallengeWithStablecoinPaysExpectedMint() {
        // A v1 flat USDC devnet challenge resolves the symbol to the devnet
        // mint and builds a payable transaction.
        val flat = """{"scheme":"exact","network":"solana-devnet",""" +
            """"maxAmountRequired":"1000","currency":"USDC","recipient":"$devnetRecipient",""" +
            """"decimals":6}"""
        val headers = mapOf("X-Payment-Required" to flat)
        val requirement = parseX402Challenge(headers, null, ChallengeSelection(network = "devnet"))
        assertNotNull(requirement)
        assertEquals("USDC", requirement.effectiveAsset)
        // Building succeeds (symbol resolves to Mints.USDC_DEVNET internally).
        val v1Header = buildPaymentHeaderV1(signer, requirement, fixedBlockhash, fixedNonce)
        assertTrue(v1Header.isNotEmpty())
        // Sanity: the devnet mint is the resolution target for USDC on devnet.
        assertEquals(
            Mints.USDC_DEVNET,
            com.solana.paykit.paycore.resolveStablecoinMint("USDC", "devnet"),
        )
    }
}
