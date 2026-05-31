package com.solana.mpp.client

import com.solana.mpp.protocol.MppException

/**
 * Sends commit payloads to the server. HTTP clients, queues, and in-process
 * tests can all implement it. The directive is passed alongside the payload so
 * transports can use commitUrl/proof routing hints without those fields being
 * repeated in the signed commit body.
 */
fun interface CommitTransport {
    /** Posts a commit payload and returns the resulting receipt. */
    fun commit(directive: MeteringDirective, payload: CommitPayload): CommitReceipt
}

/**
 * Wraps an [ActiveSession] so applications can process delivered messages and
 * call commit instead of manually signing and posting vouchers. Mirrors
 * SessionConsumer in the Rust spine (client/session_consumer.rs) and the Go
 * port (client/session_consumer.go).
 */
class SessionConsumer(
    private val session: ActiveSession,
    private val transport: CommitTransport,
) {
    /** The underlying active session. */
    fun session(): ActiveSession = session

    /**
     * Signs a voucher for the directive amount, sends the commit, and advances
     * the local watermark only after the transport accepts it. A failed commit
     * leaves the local watermark untouched so the same directive can be retried
     * without drift.
     */
    fun commitDirective(directive: MeteringDirective): CommitReceipt {
        validateDirective(directive)
        val amount = directive.amountBaseUnits()
        if (amount == 0L) {
            throw MppException.InvalidTransaction("metered delivery amount must be greater than zero")
        }
        val voucher = session.prepareIncrement(amount)
        val payload = CommitPayload(deliveryId = directive.deliveryId, voucher = voucher)
        val receipt = transport.commit(directive, payload)
        session.recordVoucher(voucher)
        return receipt
    }

    /** Validates a metered envelope and returns a delivery handle. */
    fun accept(directive: MeteringDirective): MeteredDelivery {
        validateDirective(directive)
        return MeteredDelivery(this, directive)
    }

    private fun validateDirective(directive: MeteringDirective) {
        val channelId = session.channelIdString
        if (directive.sessionId != channelId) {
            throw MppException.InvalidTransaction(
                "metered delivery session ${directive.sessionId} does not match active session $channelId",
            )
        }
    }
}

/**
 * A delivery handle exposing the metering directive and the commit/ack action
 * that settles it.
 */
class MeteredDelivery internal constructor(
    private val consumer: SessionConsumer,
    private val metering: MeteringDirective,
) {
    /** The metering directive for the delivery. */
    fun metering(): MeteringDirective = metering

    /** Signs and sends the commit for the delivery. */
    fun ack(): CommitReceipt = consumer.commitDirective(metering)

    /** Alias for [ack]. */
    fun commit(): CommitReceipt = ack()
}
