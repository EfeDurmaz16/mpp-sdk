package com.solana.mpp.client

import com.solana.mpp.crypto.PublicKey
import com.solana.mpp.protocol.MppException

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Session intent wire types.
 *
 * Field casing and byte layout mirror the Rust spine
 * (`rust/crates/mpp/src/protocol/intents/session.rs`) and the Go session
 * port. The signed voucher bytes are produced by [PaymentChannels.voucherMessageBytes]
 * (48 byte Borsh VoucherArgs); the JSON projection carries channelId as
 * base58, cumulativeAmount as a base-units string (also read as the legacy
 * `cumulative` alias), and expiresAt as an i64 Unix timestamp.
 */

/**
 * Default session voucher/directive expiry: 2100-01-01T00:00:00Z. It stays
 * below JavaScript's max safe integer so JSON intermediaries do not round it
 * before the credential is decoded. Mirrors DEFAULT_SESSION_EXPIRES_AT.
 */
const val DEFAULT_SESSION_EXPIRES_AT: Long = 4_102_444_800L

/** On-chain funding mechanism for a session. */
@Serializable
enum class SessionMode {
    /** Payment channel backed by an on-chain escrow deposit (client-funded). */
    @SerialName("push")
    PUSH,

    /** Operator-assisted session; voucher authority declared separately. */
    @SerialName("pull")
    PULL,
}

/** Voucher authority used when pull mode is advertised. */
@Serializable
enum class SessionPullVoucherStrategy {
    /** The client signs cumulative vouchers. */
    @SerialName("clientVoucher")
    CLIENT_VOUCHER,

    /** The operator signs vouchers. */
    @SerialName("operatedVoucher")
    OPERATED_VOUCHER,
}

/** A payment split committed at channel open. */
@Serializable
data class SessionSplit(
    val recipient: String,
    val bps: Int,
)

/** Session intent request embedded in a 402 challenge. */
@Serializable
data class SessionRequest(
    val cap: String,
    val currency: String,
    val decimals: Int? = null,
    val network: String? = null,
    val operator: String,
    val recipient: String,
    val splits: List<SessionSplit> = emptyList(),
    val programId: String? = null,
    val description: String? = null,
    val externalId: String? = null,
    val minVoucherDelta: String? = null,
    val modes: List<SessionMode> = emptyList(),
    val pullVoucherStrategy: SessionPullVoucherStrategy? = null,
    val recentBlockhash: String? = null,
)

/**
 * Payload for the `open` action. Shape varies by mode; use the
 * companion constructors to build it and [mode] to distinguish variants.
 *
 * `salt` is always serialized as a decimal string because authorization
 * headers are JSON canonicalized and arbitrary u64 values are unsafe JSON
 * numbers. On read it accepts both a string and a number for ecosystem
 * compatibility.
 */
@Serializable(with = OpenPayloadSerializer::class)
data class OpenPayload(
    val mode: SessionMode,
    // Push mode.
    val channelId: String? = null,
    val deposit: String? = null,
    val payer: String? = null,
    val payee: String? = null,
    val mint: String? = null,
    val salt: Long? = null,
    val gracePeriod: Int? = null,
    val transaction: String? = null,
    // Pull mode.
    val tokenAccount: String? = null,
    val approvedAmount: String? = null,
    val owner: String? = null,
    val initMultiDelegateTx: String? = null,
    val updateDelegationTx: String? = null,
    // Shared.
    val authorizedSigner: String,
    val signature: String,
) {
    /** Attaches a signed open transaction for operator/server broadcast. */
    fun withTransaction(txBase64: String): OpenPayload = copy(transaction = txBase64)

    /** Attaches a pre-signed InitMultiDelegate + CreateFixedDelegation tx. */
    fun withInitTx(txBase64: String): OpenPayload = copy(initMultiDelegateTx = txBase64)

    /** Attaches a pre-signed CreateFixedDelegation (cap update) tx. */
    fun withUpdateTx(txBase64: String): OpenPayload = copy(updateDelegationTx = txBase64)

    /**
     * Session identifier used as the store key: channelId for push,
     * tokenAccount for pull-without-channel.
     */
    fun sessionId(): String {
        channelId?.let { return it }
        return when (mode) {
            SessionMode.PUSH -> throw MppException.InvalidTransaction("push open missing channelId")
            SessionMode.PULL -> tokenAccount
                ?: throw MppException.InvalidTransaction("pull open missing channelId or tokenAccount")
        }
    }

    /** Deposit (push) or approved amount (pull) in base units. */
    fun depositAmount(): Long {
        val raw = deposit ?: when (mode) {
            SessionMode.PUSH -> throw MppException.InvalidTransaction("push open missing deposit")
            SessionMode.PULL -> approvedAmount
                ?: throw MppException.InvalidTransaction("pull open missing deposit or approvedAmount")
        }
        return raw.toLongOrNull()
            ?: throw MppException.InvalidTransaction("invalid deposit amount: $raw")
    }

    companion object {
        /** Builds a push payment-channel open payload. */
        fun push(channelId: String, deposit: String, authorizedSigner: String, signature: String): OpenPayload =
            OpenPayload(
                mode = SessionMode.PUSH,
                channelId = channelId,
                deposit = deposit,
                authorizedSigner = authorizedSigner,
                signature = signature,
            )

        /** Builds a push payment-channel open payload with full channel params. */
        fun paymentChannel(
            channelId: String,
            deposit: String,
            payer: String,
            payee: String,
            mint: String,
            salt: Long,
            gracePeriod: Int,
            authorizedSigner: String,
            signature: String,
        ): OpenPayload = paymentChannelWithMode(
            SessionMode.PUSH, channelId, deposit, payer, payee, mint, salt, gracePeriod, authorizedSigner, signature,
        )

        /** Builds a payment-channel open payload with an explicit submission mode. */
        fun paymentChannelWithMode(
            mode: SessionMode,
            channelId: String,
            deposit: String,
            payer: String,
            payee: String,
            mint: String,
            salt: Long,
            gracePeriod: Int,
            authorizedSigner: String,
            signature: String,
        ): OpenPayload = OpenPayload(
            mode = mode,
            channelId = channelId,
            deposit = deposit,
            payer = payer,
            payee = payee,
            mint = mint,
            salt = salt,
            gracePeriod = gracePeriod,
            authorizedSigner = authorizedSigner,
            signature = signature,
        )

        /** Builds a pull (SPL delegation) open payload. */
        fun pull(
            tokenAccount: String,
            approvedAmount: String,
            owner: String,
            authorizedSigner: String,
            signature: String,
        ): OpenPayload = OpenPayload(
            mode = SessionMode.PULL,
            tokenAccount = tokenAccount,
            approvedAmount = approvedAmount,
            owner = owner,
            authorizedSigner = authorizedSigner,
            signature = signature,
        )
    }
}

/**
 * The canonical content of a voucher signed by the client's session key.
 * The wire JSON carries channelId (base58), cumulativeAmount (string; also
 * accepts the legacy `cumulative` alias on read), and expiresAt (i64). The
 * signed bytes are the program Borsh VoucherArgs layout.
 */
@Serializable(with = VoucherDataSerializer::class)
data class VoucherData(
    val channelId: String,
    val cumulative: String,
    val expiresAt: Long,
    val nonce: Long? = null,
) {
    /**
     * Serializes the voucher to the payment-channels VoucherArgs bytes
     * signed by Ed25519: channelId(32) || cumulative(u64 LE) || expiresAt(i64 LE).
     */
    fun messageBytes(): ByteArray {
        val channel = PublicKey.fromBase58(channelId)
        val amount = cumulative.toLongOrNull()
            ?: throw MppException.InvalidTransaction("invalid voucher cumulative: $cumulative")
        return PaymentChannels.voucherMessageBytes(channel, amount, expiresAt)
    }
}

/** A voucher signed by the client's session key. */
@Serializable
data class SignedVoucher(
    val data: VoucherData,
    val signature: String,
)

/** Payload for the `voucher` action. */
@Serializable
data class VoucherPayload(val voucher: SignedVoucher)

/** Payload for the `commit` action. */
@Serializable
data class CommitPayload(
    val deliveryId: String,
    val voucher: SignedVoucher,
)

/** Payload for the `topup` action. */
@Serializable
data class TopUpPayload(
    val channelId: String,
    val newDeposit: String,
    val signature: String,
)

/** Payload for the `close` action. */
@Serializable
data class ClosePayload(
    val channelId: String,
    val voucher: SignedVoucher? = null,
)

/**
 * The tagged action submitted by the client in an Authorization header,
 * discriminated by the `action` field. The topup tag uses a capital U
 * (`topUp`) to match the Rust serde camelCase rename.
 */
@Serializable(with = SessionActionSerializer::class)
sealed class SessionAction {
    /** The wire tag for this action. */
    abstract val action: String

    data class Open(val payload: OpenPayload) : SessionAction() {
        override val action: String get() = "open"
    }

    data class Voucher(val payload: VoucherPayload) : SessionAction() {
        override val action: String get() = "voucher"
    }

    data class Commit(val payload: CommitPayload) : SessionAction() {
        override val action: String get() = "commit"
    }

    data class TopUp(val payload: TopUpPayload) : SessionAction() {
        override val action: String get() = "topUp"
    }

    data class Close(val payload: ClosePayload) : SessionAction() {
        override val action: String get() = "close"
    }
}

/** Server-issued metering directive attached to a delivered message. */
@Serializable
data class MeteringDirective(
    val deliveryId: String,
    val sessionId: String,
    val amount: String,
    val currency: String,
    val sequence: Long,
    val expiresAt: Long,
    val commitUrl: String? = null,
    val proof: String? = null,
) {
    /** Parses the directive amount as base units. */
    fun amountBaseUnits(): Long = amount.toLongOrNull()
        ?: throw MppException.InvalidTransaction("invalid metering amount: $amount")
}

/** Final usage reported by a streaming response. */
@Serializable
data class MeteringUsage(
    val deliveryId: String,
    val amount: String,
) {
    /** Parses the usage amount as base units. */
    fun amountBaseUnits(): Long = amount.toLongOrNull()
        ?: throw MppException.InvalidTransaction("invalid metering usage amount: $amount")
}

/** Commit receipt status. */
@Serializable
enum class CommitStatus {
    /** First successful commit for a delivery. */
    @SerialName("committed")
    COMMITTED,

    /** Idempotent replay of a prior accepted commit. */
    @SerialName("replayed")
    REPLAYED,
}

/** Returned after a delivery commit is accepted. */
@Serializable
data class CommitReceipt(
    val deliveryId: String,
    val sessionId: String,
    val amount: String,
    val cumulative: String,
    val status: CommitStatus,
)

// ── Custom serializers ──

/**
 * Serializes [OpenPayload] emitting salt as a decimal string and omitting
 * absent optional fields. On read salt accepts a string or a number.
 */
object OpenPayloadSerializer : KSerializer<OpenPayload> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("OpenPayload")

    override fun serialize(encoder: Encoder, value: OpenPayload) {
        val jsonEncoder = encoder as? JsonEncoder
            ?: throw MppException.InvalidJson(IllegalStateException("OpenPayload requires JSON"))
        val obj = buildMap<String, JsonElement> {
            put("mode", JsonPrimitive(modeName(value.mode)))
            value.channelId?.let { put("channelId", JsonPrimitive(it)) }
            value.deposit?.let { put("deposit", JsonPrimitive(it)) }
            value.payer?.let { put("payer", JsonPrimitive(it)) }
            value.payee?.let { put("payee", JsonPrimitive(it)) }
            value.mint?.let { put("mint", JsonPrimitive(it)) }
            value.salt?.let { put("salt", JsonPrimitive(it.toString())) }
            value.gracePeriod?.let { put("gracePeriod", JsonPrimitive(it)) }
            value.transaction?.let { put("transaction", JsonPrimitive(it)) }
            value.tokenAccount?.let { put("tokenAccount", JsonPrimitive(it)) }
            value.approvedAmount?.let { put("approvedAmount", JsonPrimitive(it)) }
            value.owner?.let { put("owner", JsonPrimitive(it)) }
            value.initMultiDelegateTx?.let { put("initMultiDelegateTx", JsonPrimitive(it)) }
            value.updateDelegationTx?.let { put("updateDelegationTx", JsonPrimitive(it)) }
            put("authorizedSigner", JsonPrimitive(value.authorizedSigner))
            put("signature", JsonPrimitive(value.signature))
        }
        jsonEncoder.encodeJsonElement(JsonObject(obj))
    }

    override fun deserialize(decoder: Decoder): OpenPayload {
        val jsonDecoder = decoder as? JsonDecoder
            ?: throw MppException.InvalidJson(IllegalStateException("OpenPayload requires JSON"))
        val obj = jsonDecoder.decodeJsonElement().jsonObject
        val modeRaw = obj["mode"]?.jsonPrimitive?.contentOrNull
            ?: throw MppException.MissingField("mode")
        val mode = parseMode(modeRaw)
        val salt = obj["salt"]?.let { element ->
            val primitive = element.jsonPrimitive
            val text = primitive.contentOrNull
                ?: throw MppException.InvalidJson(IllegalArgumentException("salt must be a string or number"))
            text.toLongOrNull()
                ?: throw MppException.InvalidJson(IllegalArgumentException("salt must be a decimal u64: $text"))
        }
        return OpenPayload(
            mode = mode,
            channelId = obj["channelId"]?.jsonPrimitive?.contentOrNull,
            deposit = obj["deposit"]?.jsonPrimitive?.contentOrNull,
            payer = obj["payer"]?.jsonPrimitive?.contentOrNull,
            payee = obj["payee"]?.jsonPrimitive?.contentOrNull,
            mint = obj["mint"]?.jsonPrimitive?.contentOrNull,
            salt = salt,
            gracePeriod = obj["gracePeriod"]?.jsonPrimitive?.longOrNull?.toInt(),
            transaction = obj["transaction"]?.jsonPrimitive?.contentOrNull,
            tokenAccount = obj["tokenAccount"]?.jsonPrimitive?.contentOrNull,
            approvedAmount = obj["approvedAmount"]?.jsonPrimitive?.contentOrNull,
            owner = obj["owner"]?.jsonPrimitive?.contentOrNull,
            initMultiDelegateTx = obj["initMultiDelegateTx"]?.jsonPrimitive?.contentOrNull,
            updateDelegationTx = obj["updateDelegationTx"]?.jsonPrimitive?.contentOrNull,
            authorizedSigner = obj["authorizedSigner"]?.jsonPrimitive?.contentOrNull
                ?: throw MppException.MissingField("authorizedSigner"),
            signature = obj["signature"]?.jsonPrimitive?.contentOrNull
                ?: throw MppException.MissingField("signature"),
        )
    }

    private fun modeName(mode: SessionMode): String = when (mode) {
        SessionMode.PUSH -> "push"
        SessionMode.PULL -> "pull"
    }

    private fun parseMode(raw: String): SessionMode = when (raw) {
        "push" -> SessionMode.PUSH
        "pull" -> SessionMode.PULL
        else -> throw MppException.InvalidJson(IllegalArgumentException("unknown session mode: $raw"))
    }
}

/**
 * Serializes [VoucherData] using `cumulativeAmount` on write and accepting
 * both `cumulativeAmount` and the legacy `cumulative` alias on read.
 */
object VoucherDataSerializer : KSerializer<VoucherData> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("VoucherData")

    override fun serialize(encoder: Encoder, value: VoucherData) {
        val jsonEncoder = encoder as? JsonEncoder
            ?: throw MppException.InvalidJson(IllegalStateException("VoucherData requires JSON"))
        val obj = buildMap<String, JsonElement> {
            put("channelId", JsonPrimitive(value.channelId))
            put("cumulativeAmount", JsonPrimitive(value.cumulative))
            put("expiresAt", JsonPrimitive(value.expiresAt))
            value.nonce?.let { put("nonce", JsonPrimitive(it)) }
        }
        jsonEncoder.encodeJsonElement(JsonObject(obj))
    }

    override fun deserialize(decoder: Decoder): VoucherData {
        val jsonDecoder = decoder as? JsonDecoder
            ?: throw MppException.InvalidJson(IllegalStateException("VoucherData requires JSON"))
        val obj = jsonDecoder.decodeJsonElement().jsonObject
        val cumulative = obj["cumulativeAmount"]?.jsonPrimitive?.contentOrNull
            ?: obj["cumulative"]?.jsonPrimitive?.contentOrNull
            ?: throw MppException.MissingField("cumulativeAmount")
        return VoucherData(
            channelId = obj["channelId"]?.jsonPrimitive?.contentOrNull
                ?: throw MppException.MissingField("channelId"),
            cumulative = cumulative,
            expiresAt = obj["expiresAt"]?.jsonPrimitive?.longOrNull
                ?: throw MppException.MissingField("expiresAt"),
            nonce = obj["nonce"]?.jsonPrimitive?.longOrNull,
        )
    }
}

/**
 * Serializes [SessionAction] by flattening the active payload alongside the
 * `action` tag, mirroring the Rust serde internally-tagged enum.
 */
object SessionActionSerializer : KSerializer<SessionAction> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("SessionAction")

    private val json = Json {
        encodeDefaults = false
        explicitNulls = false
        ignoreUnknownKeys = true
    }

    override fun serialize(encoder: Encoder, value: SessionAction) {
        val jsonEncoder = encoder as? JsonEncoder
            ?: throw MppException.InvalidJson(IllegalStateException("SessionAction requires JSON"))
        val payload: JsonObject = when (value) {
            is SessionAction.Open ->
                json.encodeToJsonElement(OpenPayload.serializer(), value.payload).jsonObject
            is SessionAction.Voucher ->
                json.encodeToJsonElement(VoucherPayload.serializer(), value.payload).jsonObject
            is SessionAction.Commit ->
                json.encodeToJsonElement(CommitPayload.serializer(), value.payload).jsonObject
            is SessionAction.TopUp ->
                json.encodeToJsonElement(TopUpPayload.serializer(), value.payload).jsonObject
            is SessionAction.Close ->
                json.encodeToJsonElement(ClosePayload.serializer(), value.payload).jsonObject
        }
        val merged = buildMap<String, JsonElement> {
            putAll(payload)
            put("action", JsonPrimitive(value.action))
        }
        jsonEncoder.encodeJsonElement(JsonObject(merged))
    }

    override fun deserialize(decoder: Decoder): SessionAction {
        val jsonDecoder = decoder as? JsonDecoder
            ?: throw MppException.InvalidJson(IllegalStateException("SessionAction requires JSON"))
        val element = jsonDecoder.decodeJsonElement()
        val obj = element.jsonObject
        val tag = obj["action"]?.jsonPrimitive?.contentOrNull
            ?: throw MppException.MissingField("action")
        return when (tag) {
            "open" -> SessionAction.Open(json.decodeFromJsonElement(OpenPayload.serializer(), element))
            "voucher" -> SessionAction.Voucher(json.decodeFromJsonElement(VoucherPayload.serializer(), element))
            "commit" -> SessionAction.Commit(json.decodeFromJsonElement(CommitPayload.serializer(), element))
            "topUp" -> SessionAction.TopUp(json.decodeFromJsonElement(TopUpPayload.serializer(), element))
            "close" -> SessionAction.Close(json.decodeFromJsonElement(ClosePayload.serializer(), element))
            else -> throw MppException.InvalidJson(IllegalArgumentException("unknown session action: $tag"))
        }
    }
}
