package com.solana.mpp.client

import com.solana.mpp.crypto.Base58
import com.solana.mpp.crypto.PublicKey
import com.solana.mpp.crypto.SolanaSigner
import com.solana.mpp.protocol.MppException

/**
 * Default voucher expiry: 2100-01-01T00:00:00Z. Mirrors
 * [DEFAULT_SESSION_EXPIRES_AT] in the session wire types.
 */
const val DEFAULT_VOUCHER_EXPIRES_AT: Long = DEFAULT_SESSION_EXPIRES_AT

/**
 * Tracks the client-side state of an active payment session. It holds a
 * session signing key and advances the cumulative watermark with each signed
 * voucher. Vouchers are Ed25519-signed over the on-chain Borsh voucher layout
 * used by the payment-channels program. Mirrors ActiveSession in the Rust
 * spine (client/session.rs) and the Go port (client/session.go).
 *
 * Amounts are tracked as [Long] base units. The cumulative watermark must
 * strictly increase with each voucher.
 */
class ActiveSession private constructor(
    private val channelId: PublicKey,
    private val signer: SolanaSigner,
    expiresAt: Long,
) {
    private var cumulativeValue: Long = 0
    private var nonceValue: Long = 0
    private var expiresAtValue: Long = expiresAt

    /** The current settled watermark known to the client. */
    val cumulative: Long get() = cumulativeValue

    /** The session signer public key (base58). Used as `authorizedSigner`. */
    val authorizedSigner: String get() = Base58.encode(signer.publicKeyBytes)

    /** The channel id as base58. */
    val channelIdString: String get() = channelId.toBase58()

    /** Updates the expiry used for subsequent vouchers. */
    fun setExpiresAt(expiresAt: Long) {
        expiresAtValue = expiresAt
    }

    /**
     * Prepares a signed voucher with an absolute cumulative amount without
     * advancing the local watermark. `cumulative` MUST exceed the current
     * watermark.
     */
    fun prepareVoucher(cumulative: Long): SignedVoucher {
        if (cumulative <= cumulativeValue) {
            throw MppException.InvalidTransaction(
                "voucher cumulative $cumulative must exceed current watermark $cumulativeValue",
            )
        }
        val nonce = nonceValue + 1
        val data = VoucherData(
            channelId = channelIdString,
            cumulative = cumulative.toString(),
            expiresAt = expiresAtValue,
            nonce = nonce,
        )
        val message = data.messageBytes()
        val signatureBytes = signer.sign(message)
        return SignedVoucher(data = data, signature = Base58.encode(signatureBytes))
    }

    /**
     * Prepares a signed voucher adding `amount` to the current watermark
     * without advancing the local watermark.
     */
    fun prepareIncrement(amount: Long): SignedVoucher {
        if (amount <= 0L) {
            throw MppException.InvalidTransaction("voucher increment must be positive: $amount")
        }
        return prepareVoucher(addExact(cumulativeValue, amount))
    }

    /** Advances the local watermark after a voucher is accepted. */
    fun recordVoucher(voucher: SignedVoucher) {
        val cumulative = voucher.data.cumulative.toLongOrNull()
            ?: throw MppException.InvalidTransaction("invalid voucher cumulative")
        if (cumulative <= cumulativeValue) {
            throw MppException.InvalidTransaction(
                "voucher cumulative $cumulative must exceed current watermark $cumulativeValue",
            )
        }
        cumulativeValue = cumulative
        var next = nonceValue + 1
        val voucherNonce = voucher.data.nonce
        if (voucherNonce != null && voucherNonce > next) {
            next = voucherNonce
        }
        nonceValue = next
    }

    /** Signs and records a voucher with an absolute cumulative amount. */
    fun signVoucher(cumulative: Long): SignedVoucher {
        val voucher = prepareVoucher(cumulative)
        recordVoucher(voucher)
        return voucher
    }

    /** Signs and records a voucher adding `amount` to the watermark. */
    fun signIncrement(amount: Long): SignedVoucher {
        if (amount <= 0L) {
            throw MppException.InvalidTransaction("voucher increment must be positive: $amount")
        }
        return signVoucher(addExact(cumulativeValue, amount))
    }

    /** Builds a voucher action wrapping a freshly-signed increment. */
    fun voucherAction(amount: Long): SessionAction =
        SessionAction.Voucher(VoucherPayload(signIncrement(amount)))

    /** Builds an open action for push mode after the open tx is confirmed. */
    fun openAction(deposit: Long, openTxSignature: String): SessionAction =
        SessionAction.Open(OpenPayload.push(channelIdString, deposit.toString(), authorizedSigner, openTxSignature))

    /** Builds a push payment-channel open action. */
    fun openPaymentChannelAction(
        deposit: Long,
        payer: String,
        payee: String,
        mint: String,
        salt: Long,
        gracePeriod: Int,
        openTxSignature: String,
    ): SessionAction = openPaymentChannelActionWithMode(
        SessionMode.PUSH, deposit, payer, payee, mint, salt, gracePeriod, openTxSignature,
    )

    /** Builds a payment-channel open action with an explicit submission mode. */
    fun openPaymentChannelActionWithMode(
        mode: SessionMode,
        deposit: Long,
        payer: String,
        payee: String,
        mint: String,
        salt: Long,
        gracePeriod: Int,
        openTxSignature: String,
    ): SessionAction = SessionAction.Open(
        OpenPayload.paymentChannelWithMode(
            mode, channelIdString, deposit.toString(), payer, payee, mint, salt, gracePeriod,
            authorizedSigner, openTxSignature,
        ),
    )

    /**
     * Builds an open action for pull mode (SPL token delegation). The session
     * channel id is used as the delegated token account.
     */
    fun openPullAction(approvedAmount: Long, owner: String, approveTxSignature: String): SessionAction =
        SessionAction.Open(
            OpenPayload.pull(channelIdString, approvedAmount.toString(), owner, authorizedSigner, approveTxSignature),
        )

    /** Builds a topup action after a top-up transaction. */
    fun topUpAction(newDeposit: Long, topupTxSignature: String): SessionAction =
        SessionAction.TopUp(
            TopUpPayload(
                channelId = channelIdString,
                newDeposit = newDeposit.toString(),
                signature = topupTxSignature,
            ),
        )

    /**
     * Builds a close action for cooperative channel close. When
     * `finalIncrement` is non-null and positive, a final voucher for the
     * remaining balance is signed before closing.
     */
    fun closeAction(finalIncrement: Long? = null): SessionAction {
        val voucher = if (finalIncrement != null && finalIncrement > 0L) {
            signIncrement(finalIncrement)
        } else {
            null
        }
        return SessionAction.Close(ClosePayload(channelId = channelIdString, voucher = voucher))
    }

    private fun addExact(a: Long, b: Long): Long = try {
        Math.addExact(a, b)
    } catch (_: ArithmeticException) {
        throw MppException.InvalidTransaction("cumulative voucher amount overflows")
    }

    companion object {
        /**
         * Creates a session tracker. `channelId` is the on-chain channel
         * address obtained after opening; the signer's public key becomes the
         * `authorizedSigner` in the open action.
         */
        fun create(channelId: PublicKey, signer: SolanaSigner): ActiveSession =
            ActiveSession(channelId, signer, DEFAULT_VOUCHER_EXPIRES_AT)

        /** Creates a session tracker with an explicit voucher expiry. */
        fun createWithExpiry(channelId: PublicKey, signer: SolanaSigner, expiresAt: Long): ActiveSession =
            ActiveSession(channelId, signer, expiresAt)
    }
}
