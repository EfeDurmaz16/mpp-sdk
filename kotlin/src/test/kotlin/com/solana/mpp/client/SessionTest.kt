package com.solana.mpp.client

import com.solana.mpp.crypto.Base58
import com.solana.mpp.crypto.Ed25519
import com.solana.mpp.crypto.MemorySigner
import com.solana.mpp.crypto.PublicKey

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Client-side ActiveSession voucher lifecycle. Mirrors the Rust spine
 * (client/session.rs) and the Go session_test.go: monotonic cumulative,
 * Ed25519 verification against the authorized signer, and action builders.
 */
class SessionTest {
    private val channel = PublicKey(ByteArray(32) { 9 })
    private val signer = MemorySigner.fromSeed(ByteArray(32) { 3 })

    private fun session(): ActiveSession = ActiveSession.create(channel, signer)

    @Test
    fun authorizedSignerMatchesSignerPublicKey() {
        val s = session()
        assertEquals(Base58.encode(signer.publicKeyBytes), s.authorizedSigner)
        assertEquals(channel.toBase58(), s.channelIdString)
    }

    @Test
    fun signIncrementAdvancesWatermarkAndVerifies() {
        val s = session()
        val v1 = s.signIncrement(100)
        assertEquals(100L, s.cumulative)
        assertEquals("100", v1.data.cumulative)

        val v2 = s.signIncrement(50)
        assertEquals(150L, s.cumulative)
        assertEquals("150", v2.data.cumulative)

        // Ed25519 verifies against the authorized signer over the 48 byte message.
        val message = v2.data.messageBytes()
        assertEquals(48, message.size)
        val sig = Base58.decode(v2.signature)
        assertTrue(Ed25519.verify(signer.publicKeyBytes, message, sig))
    }

    @Test
    fun prepareDoesNotAdvanceWatermark() {
        val s = session()
        s.signIncrement(100)
        val prepared = s.prepareIncrement(25)
        assertEquals("125", prepared.data.cumulative)
        // Watermark unchanged until recorded.
        assertEquals(100L, s.cumulative)
        s.recordVoucher(prepared)
        assertEquals(125L, s.cumulative)
    }

    @Test
    fun voucherMustStrictlyIncrease() {
        val s = session()
        s.signVoucher(100)
        assertFailsWith<com.solana.mpp.protocol.MppException> { s.signVoucher(100) }
        assertFailsWith<com.solana.mpp.protocol.MppException> { s.signVoucher(50) }
    }

    @Test
    fun incrementMustBePositive() {
        val s = session()
        assertFailsWith<com.solana.mpp.protocol.MppException> { s.signIncrement(0) }
        assertFailsWith<com.solana.mpp.protocol.MppException> { s.prepareIncrement(-1) }
    }

    @Test
    fun voucherActionWrapsSignedIncrement() {
        val s = session()
        val action = s.voucherAction(200)
        assertTrue(action is SessionAction.Voucher)
        assertEquals("200", action.payload.voucher.data.cumulative)
        assertEquals(200L, s.cumulative)
    }

    @Test
    fun openActionPush() {
        val s = session()
        val action = s.openAction(1_000_000, "opensig")
        assertTrue(action is SessionAction.Open)
        val payload = action.payload
        assertEquals(SessionMode.PUSH, payload.mode)
        assertEquals(channel.toBase58(), payload.channelId)
        assertEquals("1000000", payload.deposit)
        assertEquals(s.authorizedSigner, payload.authorizedSigner)
        assertEquals("opensig", payload.signature)
    }

    @Test
    fun openPaymentChannelAction() {
        val s = session()
        val action = s.openPaymentChannelAction(2_000_000, "payer", "payee", "mint", 99, 45, "opensig")
        val payload = (action as SessionAction.Open).payload
        assertEquals(99L, payload.salt)
        assertEquals(45, payload.gracePeriod)
        assertEquals("payer", payload.payer)
    }

    @Test
    fun openPullAction() {
        val s = session()
        val action = s.openPullAction(5_000_000, "wallet", "approvesig")
        val payload = (action as SessionAction.Open).payload
        assertEquals(SessionMode.PULL, payload.mode)
        assertEquals(channel.toBase58(), payload.tokenAccount)
        assertEquals("wallet", payload.owner)
    }

    @Test
    fun topUpAction() {
        val s = session()
        val action = s.topUpAction(9_000_000, "topupsig")
        assertTrue(action is SessionAction.TopUp)
        assertEquals("9000000", action.payload.newDeposit)
    }

    @Test
    fun closeActionWithoutFinalVoucher() {
        val s = session()
        val action = s.closeAction(null)
        assertNull((action as SessionAction.Close).payload.voucher)
    }

    @Test
    fun closeActionWithFinalVoucher() {
        val s = session()
        s.signIncrement(100)
        val action = s.closeAction(50)
        val payload = (action as SessionAction.Close).payload
        assertNotNull(payload.voucher)
        assertEquals("150", payload.voucher.data.cumulative)
        assertEquals(150L, s.cumulative)
    }

    @Test
    fun explicitExpiryPropagatesToVouchers() {
        val s = ActiveSession.createWithExpiry(channel, signer, 1234)
        val v = s.signIncrement(10)
        assertEquals(1234L, v.data.expiresAt)
        s.setExpiresAt(5678)
        val v2 = s.signIncrement(10)
        assertEquals(5678L, v2.data.expiresAt)
    }
}
