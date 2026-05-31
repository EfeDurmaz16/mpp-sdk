package com.solana.mpp.client

import com.solana.mpp.crypto.PublicKey

import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Wire-format parity for the session intent types. Field casing, salt-as-
 * string, the cumulativeAmount rename + cumulative alias, and the topUp
 * action tag mirror the Rust spine
 * (`rust/crates/mpp/src/protocol/intents/session.rs`) and the Go port.
 */
class SessionModelsTest {
    private val json = Json { encodeDefaults = false; explicitNulls = false; ignoreUnknownKeys = true }

    private fun base58Pk(byte: Int): String = PublicKey(ByteArray(32) { byte.toByte() }).toBase58()

    // ── SessionMode / strategy ──

    @Test
    fun sessionModeSerializesCamelCase() {
        assertEquals("\"push\"", json.encodeToString(SessionMode.serializer(), SessionMode.PUSH))
        assertEquals("\"pull\"", json.encodeToString(SessionMode.serializer(), SessionMode.PULL))
    }

    @Test
    fun pullVoucherStrategyRoundtrip() {
        val client = json.encodeToString(SessionPullVoucherStrategy.serializer(), SessionPullVoucherStrategy.CLIENT_VOUCHER)
        assertEquals("\"clientVoucher\"", client)
        val operated = json.encodeToString(SessionPullVoucherStrategy.serializer(), SessionPullVoucherStrategy.OPERATED_VOUCHER)
        assertEquals("\"operatedVoucher\"", operated)
    }

    // ── SessionRequest ──

    @Test
    fun sessionRequestOmitsEmptyCollectionsAndNulls() {
        val req = SessionRequest(cap = "1000", currency = "USDC", operator = "op", recipient = "rec")
        val wire = json.encodeToString(SessionRequest.serializer(), req)
        assertTrue(!wire.contains("splits"))
        assertTrue(!wire.contains("modes"))
        assertTrue(!wire.contains("decimals"))
        assertTrue(!wire.contains("network"))
        assertTrue(!wire.contains("externalId"))
    }

    @Test
    fun sessionRequestWithModesAndStrategy() {
        val req = SessionRequest(
            cap = "1000",
            currency = "USDC",
            operator = "op",
            recipient = "rec",
            modes = listOf(SessionMode.PUSH, SessionMode.PULL),
            pullVoucherStrategy = SessionPullVoucherStrategy.CLIENT_VOUCHER,
        )
        val wire = json.encodeToString(SessionRequest.serializer(), req)
        assertTrue(wire.contains("\"push\""))
        assertTrue(wire.contains("\"pull\""))
        assertTrue(wire.contains("\"pullVoucherStrategy\":\"clientVoucher\""))
        val back = json.decodeFromString(SessionRequest.serializer(), wire)
        assertEquals(2, back.modes.size)
        assertEquals(SessionPullVoucherStrategy.CLIENT_VOUCHER, back.pullVoucherStrategy)
    }

    // ── OpenPayload ──

    @Test
    fun openPayloadPushRoundtrip() {
        val p = OpenPayload.push("chan1", "1000000", "signer1", "txsig")
        val wire = json.encodeToString(OpenPayload.serializer(), p)
        assertTrue(wire.contains("\"mode\":\"push\""))
        assertTrue(wire.contains("\"channelId\":\"chan1\""))
        assertTrue(!wire.contains("tokenAccount"))
        val back = json.decodeFromString(OpenPayload.serializer(), wire)
        assertEquals(SessionMode.PUSH, back.mode)
        assertEquals("chan1", back.channelId)
        assertEquals("chan1", back.sessionId())
        assertEquals(1_000_000L, back.depositAmount())
    }

    @Test
    fun openPayloadPullRoundtrip() {
        val p = OpenPayload.pull("tokacct", "5000000", "wallet1", "signer1", "approvesig")
        val wire = json.encodeToString(OpenPayload.serializer(), p)
        assertTrue(wire.contains("\"mode\":\"pull\""))
        assertTrue(wire.contains("\"tokenAccount\":\"tokacct\""))
        assertTrue(wire.contains("\"owner\":\"wallet1\""))
        assertTrue(!wire.contains("channelId"))
        val back = json.decodeFromString(OpenPayload.serializer(), wire)
        assertEquals(SessionMode.PULL, back.mode)
        assertEquals("tokacct", back.sessionId())
        assertEquals(5_000_000L, back.depositAmount())
    }

    @Test
    fun paymentChannelSaltSerializesAsStringAndAcceptsNumber() {
        val salt = Long.MAX_VALUE - 7
        val p = OpenPayload.paymentChannel("chan1", "1000000", "payer1", "payee1", "mint1", salt, 900, "signer1", "txsig")
        val wire = json.encodeToString(OpenPayload.serializer(), p)
        assertTrue(wire.contains("\"salt\":\"$salt\""))
        val back = json.decodeFromString(OpenPayload.serializer(), wire)
        assertEquals(salt, back.salt)

        val legacy = """{"mode":"push","channelId":"chan1","deposit":"1000000","salt":42,"gracePeriod":900,"authorizedSigner":"s","signature":"sig"}"""
        val legacyBack = json.decodeFromString(OpenPayload.serializer(), legacy)
        assertEquals(42L, legacyBack.salt)
    }

    @Test
    fun openPayloadTxHelpers() {
        val p = OpenPayload.paymentChannel("chan1", "1000000", "payer1", "payee1", "mint1", 99, 45, "signer1", "txsig")
            .withTransaction("open-tx")
            .withInitTx("init-tx")
            .withUpdateTx("update-tx")
        assertEquals("open-tx", p.transaction)
        assertEquals("init-tx", p.initMultiDelegateTx)
        assertEquals("update-tx", p.updateDelegationTx)
        assertEquals(99L, p.salt)
        assertEquals(45, p.gracePeriod)
    }

    @Test
    fun openPayloadInvalidDepositAndMissingSessionId() {
        val bad = OpenPayload.push("chan1", "not-a-number", "s", "sig")
        assertFailsWith<com.solana.mpp.protocol.MppException> { bad.depositAmount() }
        val noChannel = OpenPayload(mode = SessionMode.PUSH, authorizedSigner = "s", signature = "sig")
        assertFailsWith<com.solana.mpp.protocol.MppException> { noChannel.sessionId() }
    }

    // ── VoucherData ──

    @Test
    fun voucherDataSerializesCumulativeAmount() {
        val v = VoucherData(channelId = base58Pk(3), cumulative = "1000", expiresAt = 42, nonce = 1)
        val wire = json.encodeToString(VoucherData.serializer(), v)
        assertTrue(wire.contains("\"cumulativeAmount\":\"1000\""))
        assertTrue(!wire.contains("\"cumulative\":"))
        val back = json.decodeFromString(VoucherData.serializer(), wire)
        assertEquals("1000", back.cumulative)
        assertEquals(1L, back.nonce)
    }

    @Test
    fun voucherDataAcceptsLegacyCumulativeAlias() {
        val legacy = """{"channelId":"${base58Pk(3)}","cumulative":"777","expiresAt":42}"""
        val back = json.decodeFromString(VoucherData.serializer(), legacy)
        assertEquals("777", back.cumulative)
    }

    @Test
    fun voucherDataMessageBytesGolden() {
        val v = VoucherData(channelId = base58Pk(3), cumulative = "1000", expiresAt = 42, nonce = 1)
        val bytes = v.messageBytes()
        assertEquals(48, bytes.size)
        assertContentEquals(PublicKey(ByteArray(32) { 3 }).bytes, bytes.copyOfRange(0, 32))
        val expected = PaymentChannels.voucherMessageBytes(PublicKey(ByteArray(32) { 3 }), 1000, 42)
        assertContentEquals(expected, bytes)
    }

    // ── SessionAction tags ──

    @Test
    fun sessionActionOpenPushTag() {
        val action: SessionAction = SessionAction.Open(OpenPayload.push("chan123", "5000000", "signer123", "sig456"))
        val wire = json.encodeToString(SessionAction.serializer(), action)
        assertTrue(wire.contains("\"action\":\"open\""))
        assertTrue(wire.contains("\"mode\":\"push\""))
        val back = json.decodeFromString(SessionAction.serializer(), wire)
        assertTrue(back is SessionAction.Open)
        assertEquals("chan123", back.payload.channelId)
    }

    @Test
    fun sessionActionVoucherTag() {
        val voucher = SignedVoucher(VoucherData(base58Pk(1), "500000", Long.MAX_VALUE, 3), "sig_here")
        val action: SessionAction = SessionAction.Voucher(VoucherPayload(voucher))
        val wire = json.encodeToString(SessionAction.serializer(), action)
        assertTrue(wire.contains("\"action\":\"voucher\""))
        val back = json.decodeFromString(SessionAction.serializer(), wire)
        assertTrue(back is SessionAction.Voucher)
        assertEquals("500000", back.payload.voucher.data.cumulative)
    }

    @Test
    fun sessionActionCommitTag() {
        val voucher = SignedVoucher(VoucherData(base58Pk(1), "500000", Long.MAX_VALUE, 3), "sig_here")
        val action: SessionAction = SessionAction.Commit(CommitPayload("delivery-1", voucher))
        val wire = json.encodeToString(SessionAction.serializer(), action)
        assertTrue(wire.contains("\"action\":\"commit\""))
        assertTrue(wire.contains("\"deliveryId\":\"delivery-1\""))
        val back = json.decodeFromString(SessionAction.serializer(), wire)
        assertEquals("delivery-1", (back as SessionAction.Commit).payload.deliveryId)
    }

    @Test
    fun sessionActionTopUpUsesCapitalU() {
        val action: SessionAction = SessionAction.TopUp(TopUpPayload("chan1", "9000000", "txsig"))
        val wire = json.encodeToString(SessionAction.serializer(), action)
        assertTrue(wire.contains("\"action\":\"topUp\""))
        val back = json.decodeFromString(SessionAction.serializer(), wire)
        assertEquals("9000000", (back as SessionAction.TopUp).payload.newDeposit)
    }

    @Test
    fun sessionActionCloseNoVoucher() {
        val action: SessionAction = SessionAction.Close(ClosePayload("chan1", null))
        val wire = json.encodeToString(SessionAction.serializer(), action)
        assertTrue(wire.contains("\"action\":\"close\""))
        assertTrue(!wire.contains("voucher"))
        val back = json.decodeFromString(SessionAction.serializer(), wire)
        assertNull((back as SessionAction.Close).payload.voucher)
    }

    @Test
    fun sessionActionCloseWithVoucher() {
        val voucher = SignedVoucher(VoucherData(base58Pk(1), "700000", Long.MAX_VALUE, 7), "final_sig")
        val action: SessionAction = SessionAction.Close(ClosePayload("chan1", voucher))
        val wire = json.encodeToString(SessionAction.serializer(), action)
        val back = json.decodeFromString(SessionAction.serializer(), wire)
        assertEquals("700000", (back as SessionAction.Close).payload.voucher?.data?.cumulative)
    }

    // ── Metering ──

    @Test
    fun meteringDirectiveRoundtripAndAmount() {
        val directive = MeteringDirective(
            deliveryId = "d1",
            sessionId = "chan1",
            amount = "125",
            currency = "USDC",
            sequence = 7,
            expiresAt = DEFAULT_SESSION_EXPIRES_AT,
            commitUrl = "https://example.test/commit",
        )
        assertEquals(125L, directive.amountBaseUnits())
        val wire = json.encodeToString(MeteringDirective.serializer(), directive)
        assertTrue(wire.contains("\"deliveryId\":\"d1\""))
        assertTrue(wire.contains("\"commitUrl\":\"https://example.test/commit\""))
        val back = json.decodeFromString(MeteringDirective.serializer(), wire)
        assertEquals(7L, back.sequence)
    }

    @Test
    fun meteringAmountParsersReject() {
        val directive = MeteringDirective("d1", "chan1", "not-a-number", "USDC", 1, DEFAULT_SESSION_EXPIRES_AT)
        assertFailsWith<com.solana.mpp.protocol.MppException> { directive.amountBaseUnits() }
        val usage = MeteringUsage("d1", "bad")
        assertFailsWith<com.solana.mpp.protocol.MppException> { usage.amountBaseUnits() }
        assertEquals(42L, MeteringUsage("d1", "42").amountBaseUnits())
    }

    @Test
    fun commitReceiptRoundtrip() {
        val receipt = CommitReceipt("d1", "chan1", "125", "500", CommitStatus.COMMITTED)
        val wire = json.encodeToString(CommitReceipt.serializer(), receipt)
        assertTrue(wire.contains("\"status\":\"committed\""))
        val back = json.decodeFromString(CommitReceipt.serializer(), wire)
        assertEquals(CommitStatus.COMMITTED, back.status)
        val replayed = json.decodeFromString(CommitStatus.serializer(), "\"replayed\"")
        assertEquals(CommitStatus.REPLAYED, replayed)
    }
}
