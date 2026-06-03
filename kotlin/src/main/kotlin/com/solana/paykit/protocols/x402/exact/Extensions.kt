package com.solana.paykit.protocols.x402.exact

import java.security.SecureRandom
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject

/**
 * x402 v2 ``extensions`` wire support for the Kotlin client.
 *
 * Mirrors the Rust spine
 * (``rust/crates/x402/src/protocol/schemes/exact/types.rs`` —
 * ``PaymentExtensions``, ``PaymentIdentifierExtension``,
 * ``PaymentIdentifierInfo``, ``generate_payment_identifier_id``) and the
 * TypeScript reference (``harness/src/conformance/x402.ts``).
 *
 * The challenge ``extensions`` blob is carried untyped as a [JsonElement]
 * passthrough on [X402Challenge] (rust
 * ``PaymentRequiredEnvelope.extensions: Option<serde_json::Value>``). The
 * outbound ``PAYMENT-SIGNATURE`` envelope carries a typed [PaymentExtensions]
 * (rust ``PaymentSignatureEnvelope.extensions: Option<PaymentExtensions>``).
 *
 * Echo-and-append (x402 v2 §5.1.2): the client must include at least the info
 * received; it may append additional info but cannot delete or overwrite
 * existing server-supplied info. Unknown extensions are preserved verbatim.
 */

/** Spec JSON key for the payment-identifier extension (kebab-case). */
const val PAYMENT_IDENTIFIER_KEY: String = "payment-identifier"

/**
 * Typed view over the x402 v2 ``extensions`` object on the outbound
 * ``PAYMENT-SIGNATURE`` envelope.
 *
 * Mirrors rust ``PaymentExtensions { payment_identifier, #[serde(flatten)]
 * other }``: the known ``payment-identifier`` extension is fielded out, and
 * unknown extensions flow through [other] so the echo-and-append rule does not
 * drop forward-compatible payloads.
 *
 * Backed by an immutable sorted map keyed by extension name. Re-serialization
 * emits keys in sorted order, matching the rust ``BTreeMap`` flatten store so
 * the wire bytes are deterministic.
 */
class PaymentExtensions private constructor(
    private val entries: Map<String, JsonElement>,
) {
    /**
     * The verbatim ``payment-identifier`` extension object, or ``null`` when
     * the server did not advertise one. Mirrors rust
     * ``PaymentExtensions.payment_identifier``.
     */
    val paymentIdentifier: JsonObject?
        get() = entries[PAYMENT_IDENTIFIER_KEY] as? JsonObject

    /**
     * Forward-compatible storage for extensions this SDK does not type
     * natively. Mirrors rust ``PaymentExtensions.other`` (the flatten map).
     */
    val other: Map<String, JsonElement>
        get() = entries.filterKeys { it != PAYMENT_IDENTIFIER_KEY }

    /**
     * True when no extensions are populated. Lets callers avoid emitting an
     * empty ``extensions: {}`` on outbound envelopes. Mirrors rust
     * ``PaymentExtensions::is_empty``.
     */
    fun isEmpty(): Boolean = entries.isEmpty()

    /**
     * ``payment-identifier.info.required == true``. Mirrors rust
     * ``PaymentExtensions::requires_payment_identifier``.
     */
    fun requiresPaymentIdentifier(): Boolean {
        val info = paymentIdentifier?.get("info") as? JsonObject ?: return false
        return (info["required"] as? JsonPrimitive)?.booleanOrNull == true
    }

    /**
     * The echoed client-side ``payment-identifier.info.id``, or ``null``.
     */
    fun paymentIdentifierId(): String? {
        val info = paymentIdentifier?.get("info") as? JsonObject ?: return null
        return (info["id"] as? JsonPrimitive)?.let { if (it is JsonNull) null else it.content }
    }

    /**
     * Set (or overwrite) the client-side ``payment-identifier.info.id``,
     * creating the extension entry if the server did not advertise one
     * (uncommon but spec-allowed). Server-supplied ``info`` fields and the
     * published ``schema`` are preserved verbatim per §5.1.2 — only ``info.id``
     * is appended. Mirrors rust
     * ``PaymentExtensions::with_payment_identifier_id``.
     */
    fun withPaymentIdentifierId(id: String): PaymentExtensions {
        val existing = paymentIdentifier
        val existingInfo = existing?.get("info") as? JsonObject ?: JsonObject(emptyMap())
        val nextInfo = buildJsonObject {
            // Preserve every server-supplied info field, then append the id.
            for ((key, value) in existingInfo) put(key, value)
            put("id", JsonPrimitive(id))
        }
        val nextExtension = buildJsonObject {
            // Preserve schema and any other server-supplied extension fields.
            if (existing != null) {
                for ((key, value) in existing) {
                    if (key != "info") put(key, value)
                }
            }
            put("info", nextInfo)
        }
        val next = entries.toMutableMap()
        next[PAYMENT_IDENTIFIER_KEY] = nextExtension
        return PaymentExtensions(next.toSortedMap())
    }

    /** Re-emit the extensions object with keys in sorted (rust BTreeMap) order. */
    fun toJsonObject(): JsonObject = JsonObject(entries.toSortedMap())

    companion object {
        /**
         * Echo a server's inbound ``extensions`` blob (the [JsonElement]
         * carried on [X402Challenge]) into a typed [PaymentExtensions].
         * Returns ``null`` when the inbound is ``null``. Throws when the
         * inbound is not a JSON object. Mirrors rust
         * ``PaymentExtensions::echoing``.
         */
        fun echoing(inbound: JsonElement?): PaymentExtensions? {
            if (inbound == null || inbound is JsonNull) return null
            require(inbound is JsonObject) { "x402 extensions must be a JSON object" }
            return PaymentExtensions(inbound.toSortedMap())
        }

        /** An empty extensions object (no entries). */
        fun empty(): PaymentExtensions = PaymentExtensions(emptyMap())
    }
}

/**
 * Process-wide secure RNG for minting payment-identifier ids. Thread-safe.
 */
private val extensionRandom = SecureRandom()

/**
 * Generate a fresh ``pay_``-prefixed idempotency id (32 hex chars after the
 * prefix; 36 total). Satisfies the payment-identifier spec pattern
 * ``^[A-Za-z0-9_-]{16,128}$`` and the canonical Solana
 * ``^pay_[a-zA-Z0-9_-]{10,120}$`` shape. Mirrors rust
 * ``generate_payment_identifier_id`` (``pay_`` + 16 random bytes, hex).
 *
 * Per the spec, callers must reuse the same id across retries of the same
 * logical request so the server can return a cached 200 instead of charging
 * twice.
 */
fun generatePaymentIdentifierId(): String {
    val bytes = ByteArray(16)
    extensionRandom.nextBytes(bytes)
    return "pay_" + bytes.joinToString("") { "%02x".format(it) }
}
