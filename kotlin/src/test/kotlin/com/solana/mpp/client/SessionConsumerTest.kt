package com.solana.mpp.client

import com.solana.mpp.crypto.MemorySigner
import com.solana.mpp.crypto.PublicKey

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * SessionConsumer metered delivery flow. Mirrors the Rust spine
 * (client/session_consumer.rs) and the Go session_consumer_test.go:
 * the local watermark advances only after the transport accepts the commit,
 * directives are validated against the active session, and a failed commit
 * leaves the watermark untouched so a retry does not drift.
 */
class SessionConsumerTest {
    private val channel = PublicKey(ByteArray(32) { 9 })
    private val signer = MemorySigner.fromSeed(ByteArray(32) { 3 })

    private fun directive(amount: String, sessionId: String = channel.toBase58()): MeteringDirective =
        MeteringDirective(
            deliveryId = "d1",
            sessionId = sessionId,
            amount = amount,
            currency = "USDC",
            sequence = 1,
            expiresAt = DEFAULT_SESSION_EXPIRES_AT,
        )

    private class RecordingTransport(private val status: CommitStatus = CommitStatus.COMMITTED) : CommitTransport {
        var lastPayload: CommitPayload? = null
        var calls = 0
        override fun commit(directive: MeteringDirective, payload: CommitPayload): CommitReceipt {
            calls += 1
            lastPayload = payload
            return CommitReceipt(
                deliveryId = directive.deliveryId,
                sessionId = directive.sessionId,
                amount = directive.amount,
                cumulative = payload.voucher.data.cumulative,
                status = status,
            )
        }
    }

    @Test
    fun commitDirectiveSignsAdvancesAndReturnsReceipt() {
        val session = ActiveSession.create(channel, signer)
        val transport = RecordingTransport()
        val consumer = SessionConsumer(session, transport)

        val receipt = consumer.commitDirective(directive("125"))
        assertEquals(CommitStatus.COMMITTED, receipt.status)
        assertEquals("125", receipt.cumulative)
        assertEquals(125L, session.cumulative)
        assertEquals("d1", transport.lastPayload?.deliveryId)
    }

    @Test
    fun acceptAndAckSettlesDelivery() {
        val session = ActiveSession.create(channel, signer)
        val consumer = SessionConsumer(session, RecordingTransport())
        val delivery = consumer.accept(directive("200"))
        assertEquals("d1", delivery.metering().deliveryId)
        val receipt = delivery.commit()
        assertEquals("200", receipt.cumulative)
        assertEquals(200L, session.cumulative)
    }

    @Test
    fun mismatchedSessionRejected() {
        val session = ActiveSession.create(channel, signer)
        val consumer = SessionConsumer(session, RecordingTransport())
        assertFailsWith<com.solana.mpp.protocol.MppException> {
            consumer.commitDirective(directive("125", sessionId = "other-session"))
        }
    }

    @Test
    fun zeroAmountRejected() {
        val session = ActiveSession.create(channel, signer)
        val consumer = SessionConsumer(session, RecordingTransport())
        assertFailsWith<com.solana.mpp.protocol.MppException> {
            consumer.commitDirective(directive("0"))
        }
    }

    @Test
    fun failedCommitLeavesWatermarkUntouched() {
        val session = ActiveSession.create(channel, signer)
        val failing = object : CommitTransport {
            override fun commit(directive: MeteringDirective, payload: CommitPayload): CommitReceipt {
                throw com.solana.mpp.protocol.MppException.InvalidTransaction("transport down")
            }
        }
        val consumer = SessionConsumer(session, failing)
        assertFailsWith<com.solana.mpp.protocol.MppException> {
            consumer.commitDirective(directive("125"))
        }
        // Watermark unchanged so the same directive can be retried.
        assertEquals(0L, session.cumulative)

        // A subsequent successful commit for the same directive amount works.
        val ok = SessionConsumer(session, RecordingTransport())
        val receipt = ok.commitDirective(directive("125"))
        assertEquals("125", receipt.cumulative)
        assertEquals(125L, session.cumulative)
    }

    @Test
    fun replayedStatusPropagates() {
        val session = ActiveSession.create(channel, signer)
        val consumer = SessionConsumer(session, RecordingTransport(CommitStatus.REPLAYED))
        val receipt = consumer.commitDirective(directive("125"))
        assertEquals(CommitStatus.REPLAYED, receipt.status)
    }

    @Test
    fun sessionAccessor() {
        val session = ActiveSession.create(channel, signer)
        val consumer = SessionConsumer(session, RecordingTransport())
        assertTrue(consumer.session() === session)
    }
}
