package com.solana.paykit.conformance

import com.solana.paykit.paycore.Base58
import com.solana.paykit.paycore.Base64Url
import com.solana.paykit.paycore.MemorySigner
import com.solana.paykit.paycore.Programs
import com.solana.paykit.paycore.resolveStablecoinMint
import com.solana.paykit.protocols.mpp.client.BlockhashProvider
import com.solana.paykit.protocols.mpp.client.Charge
import com.solana.paykit.protocols.mpp.client.MintOwnerResolver
import com.solana.paykit.protocols.mpp.core.CanonicalJson
import com.solana.paykit.protocols.mpp.core.ChargeRequest
import com.solana.paykit.protocols.mpp.core.SolanaChargeMethodDetails
import com.solana.paykit.protocols.mpp.core.SolanaChargeSplit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.Base64

/**
 * Kotlin cross-SDK conformance-vector runner.
 *
 * Honors the same stdin/stdout contract as the TypeScript reference runner
 * (harness/src/conformance/ts-runner.ts) and the Go runner
 * (go/cmd/conformance/main.go): read one conformance vector as JSON on stdin,
 * drive the real Kotlin pay-kit MPP charge client build plus the canonical
 * JSON / base64url encoders for the requested mode, and emit one RunnerResult
 * line as JSON on stdout.
 *
 * The oracle for build vectors is the DECODED SEMANTIC SHAPE of the
 * transaction (fee payer, transfer set, compute caps, memos), not raw bytes,
 * because signatures and account ordering can legitimately differ across SDKs.
 * The canonical-bytes mode pins exact bytes for the JCS / base64url vectors
 * where byte-for-byte agreement is the whole point.
 *
 * ROLE: the Kotlin SDK is a CLIENT. It builds charge transactions and encodes
 * canonical bytes, but it has no server-side pre-broadcast verifier. A
 * verify-transaction vector is therefore emitted as outcome "unsupported-mode";
 * the driver SKIPs those for Kotlin rather than failing them.
 *
 * The run is deterministic and RPC-free: build vectors pin a recent blockhash
 * and resolve the token program from the pinned methodDetails, the rpcFixtures
 * mint owners, or the known-stablecoin table, so no live validator is
 * contacted. A vector that omits all three surfaces as a clear reject rather
 * than a network call.
 */

private const val TOKEN_PROGRAM = Programs.TOKEN_PROGRAM
private const val TOKEN_2022_PROGRAM = Programs.TOKEN_2022_PROGRAM
private const val SYSTEM_PROGRAM = Programs.SYSTEM_PROGRAM
private const val COMPUTE_BUDGET_PROGRAM = Programs.COMPUTE_BUDGET_PROGRAM
private const val MEMO_PROGRAM = Programs.MEMO_PROGRAM
private const val DEFAULT_NETWORK = "mainnet"
private const val DEFAULT_SPL_DECIMALS = 6

private val json = Json { ignoreUnknownKeys = true }

fun main() {
    val raw = System.`in`.readBytes().toString(Charsets.UTF_8).trim()
    if (raw.isEmpty()) {
        System.err.println("kotlin conformance runner received empty stdin")
        kotlin.system.exitProcess(1)
    }
    val vector = json.parseToJsonElement(raw).jsonObject
    val result = runVector(vector)
    // Logs go to stderr; the single RunnerResult JSON line is the only thing
    // written to stdout, so the driver parses it cleanly.
    println(CanonicalLessJson.encode(result))
}

private fun runVector(vector: JsonObject): JsonObject {
    val id = vector["id"]?.jsonPrimitive?.contentOrNull ?: ""
    val mode = vector["mode"]?.jsonPrimitive?.contentOrNull ?: ""
    val input = vector["input"]?.jsonObject ?: JsonObject(emptyMap())
    return try {
        when (mode) {
            "canonical-bytes" -> accept(id, exactBytes = runCanonicalBytes(input))
            "build-transaction" -> {
                val tx = buildTransaction(input)
                accept(id, transactionShape = shapeFromTransaction(tx))
            }
            // CLIENT-only SDK: no pre-broadcast verifier. Signal unsupported so
            // the driver SKIPs the vector for Kotlin rather than failing it.
            "verify-transaction" -> unsupported(id, "verify-transaction")
            else -> reject(id, "unsupported mode \"$mode\"")
        }
    } catch (error: Throwable) {
        reject(id, error.message ?: error.toString())
    }
}

private fun accept(
    id: String,
    transactionShape: JsonObject? = null,
    exactBytes: JsonObject? = null,
): JsonObject = buildJsonObject {
    put("id", id)
    put("outcome", "accept")
    if (transactionShape != null) put("transactionShape", transactionShape)
    if (exactBytes != null) put("exactBytes", exactBytes)
}

private fun reject(id: String, error: String): JsonObject = buildJsonObject {
    put("id", id)
    put("outcome", "reject")
    put("error", error)
}

private fun unsupported(id: String, mode: String): JsonObject = buildJsonObject {
    put("id", id)
    put("outcome", "unsupported-mode")
    put("error", "kotlin SDK is client-only and does not support $mode vectors")
}

/**
 * Applies the same precedence rules as the TS and Go reference runners:
 * top-level `asset` / `payTo` win over `currency` / `recipient`, and the token
 * program resolves explicit methodDetails -> rpcFixtures mint owner ->
 * known-stablecoin default so the build path stays RPC-free. Returns the
 * Kotlin ChargeRequest plus the build-time compute overrides.
 */
private data class FlattenedRequest(
    val request: ChargeRequest,
    val computeUnitLimit: Int?,
    val computeUnitPrice: Long?,
)

private fun flattenRequest(input: JsonObject): FlattenedRequest {
    val req = input["request"]?.jsonObject
        ?: throw IllegalArgumentException("build/verify vector is missing input.request")

    val currency = req["asset"]?.jsonPrimitive?.contentOrNull
        ?: req["currency"]?.jsonPrimitive?.contentOrNull
        ?: throw IllegalArgumentException("vector request is missing currency/asset")
    val recipient = req["payTo"]?.jsonPrimitive?.contentOrNull
        ?: req["recipient"]?.jsonPrimitive?.contentOrNull
        ?: throw IllegalArgumentException("vector request is missing recipient/payTo")

    val md = req["methodDetails"]?.jsonObject
    val network = md?.get("network")?.jsonPrimitive?.contentOrNull ?: DEFAULT_NETWORK

    var tokenProgram = md?.get("tokenProgram")?.jsonPrimitive?.contentOrNull
    val isSol = currency.equals("sol", ignoreCase = true)
    if (tokenProgram == null && !isSol) {
        val resolvedMint = resolveStablecoinMint(currency, network) ?: currency
        val mintOwners = input["rpcFixtures"]?.jsonObject?.get("mintOwners")?.jsonObject
        tokenProgram = mintOwners?.get(resolvedMint)?.jsonPrimitive?.contentOrNull
        // When no explicit program and no rpc fixture, leave it null so the
        // client resolves from its known-stablecoin table (or fails closed for
        // an arbitrary mint with no resolver), matching the SDK default path.
    }

    val decimals = md?.get("decimals")?.jsonPrimitive?.intOrNull
        ?: if (isSol) null else DEFAULT_SPL_DECIMALS

    val splits = md?.get("splits")?.jsonArray?.map { element ->
        val split = element.jsonObject
        SolanaChargeSplit(
            recipient = split["recipient"]!!.jsonPrimitive.content,
            amount = split["amount"]!!.jsonPrimitive.content,
            ataCreationRequired = split["ataCreationRequired"]?.jsonPrimitive?.booleanOrNull,
            memo = split["memo"]?.jsonPrimitive?.contentOrNull,
            label = split["label"]?.jsonPrimitive?.contentOrNull,
        )
    }

    val methodDetails = SolanaChargeMethodDetails(
        network = network,
        decimals = decimals,
        feePayer = md?.get("feePayer")?.jsonPrimitive?.booleanOrNull,
        feePayerKey = md?.get("feePayerKey")?.jsonPrimitive?.contentOrNull,
        recentBlockhash = md?.get("recentBlockhash")?.jsonPrimitive?.contentOrNull,
        splits = splits,
        tokenProgram = tokenProgram,
    )

    val request = ChargeRequest(
        amount = req["amount"]!!.jsonPrimitive.content,
        currency = currency,
        recipient = recipient,
        externalId = req["externalId"]?.jsonPrimitive?.contentOrNull,
        methodDetails = methodDetails,
    )

    val computeUnitLimit = req["computeUnitLimit"]?.jsonPrimitive?.intOrNull
    val computeUnitPrice = req["computeUnitPrice"]?.jsonPrimitive?.contentOrNull?.toLong()

    return FlattenedRequest(request, computeUnitLimit, computeUnitPrice)
}

/**
 * Drives the real Kotlin client build path (Charge.buildChargeTransaction) and
 * returns the standard base64 wire transaction. The signer is the transfer
 * authority / fee payer the vector ships as a 64-byte secret key. The
 * blockhash provider refuses every call: build vectors pin
 * methodDetails.recentBlockhash, so a provider hit signals an under-specified
 * vector rather than a determinism gap to paper over.
 */
private fun buildTransaction(input: JsonObject): String {
    val secret = input["signerSecretKey"]?.jsonArray
        ?: throw IllegalArgumentException("build/verify vector is missing input.signerSecretKey")
    val secretBytes = ByteArray(secret.size) { secret[it].jsonPrimitive.int.toByte() }
    val signer = MemorySigner.fromSecretKey(secretBytes)

    val flattened = flattenRequest(input)

    val offlineBlockhash = BlockhashProvider {
        throw IllegalStateException(
            "offline conformance runner refused a recent-blockhash fetch: " +
                "vector must pin methodDetails.recentBlockhash",
        )
    }
    val offlineMintOwner = MintOwnerResolver { mint ->
        throw IllegalStateException(
            "offline conformance runner refused a mint-owner RPC for $mint: " +
                "vector must pin methodDetails.tokenProgram or rpcFixtures.mintOwners",
        )
    }

    return Charge.buildChargeTransaction(
        signer = signer,
        request = flattened.request,
        blockhashProvider = offlineBlockhash,
        computeUnitLimit = flattened.computeUnitLimit ?: 200_000,
        computeUnitPrice = flattened.computeUnitPrice ?: 1L,
        mintOwnerResolver = offlineMintOwner,
    )
}

/** Drives the canonical-JSON / base64url encoders. */
private fun runCanonicalBytes(input: JsonObject): JsonObject = buildJsonObject {
    val value = input["value"]
    if (value != null) {
        val canonical = CanonicalJson.encode(value)
        put("canonicalJson", canonical)
        put("base64Url", Base64Url.encode(canonical.toByteArray(Charsets.UTF_8)))
    }
    val enc = input["encodeBase64Url"]?.jsonObject
    if (enc != null) {
        val hex = enc["hexBytes"]?.jsonPrimitive?.contentOrNull
        val utf8 = enc["utf8"]?.jsonPrimitive?.contentOrNull
        when {
            hex != null -> {
                val bytes = hexDecode(hex)
                put("bytes", JsonArray(bytes.map { JsonPrimitive(it.toInt() and 0xff) }))
                put("base64Url", Base64Url.encode(bytes))
            }
            utf8 != null -> {
                put("base64Url", Base64Url.encode(utf8.toByteArray(Charsets.UTF_8)))
            }
        }
    }
}

private fun hexDecode(hex: String): ByteArray {
    require(hex.length % 2 == 0) { "hex string must have even length" }
    return ByteArray(hex.length / 2) {
        hex.substring(it * 2, it * 2 + 2).toInt(16).toByte()
    }
}

// ── transaction decoding ──

/**
 * Decodes a standard base64 legacy Solana transaction into the semantic shape
 * the conformance driver asserts against. Mirrors the TS reference decoder
 * (harness/src/conformance/decode.ts) and the Go decoder: fee payer is
 * account[0], SPL transfers come from transferChecked (discriminator 12), SOL
 * transfers from the System Program transfer (discriminator 2), memos from the
 * Memo Program, and compute caps from the ComputeBudget program.
 */
private fun shapeFromTransaction(transactionBase64: String): JsonObject {
    val txBytes = Base64.getDecoder().decode(transactionBase64)
    val cursor = ByteCursor(txBytes)

    val signatureCount = cursor.readCompactU16()
    cursor.skip(signatureCount * 64)

    val numRequiredSignatures = cursor.readByte()
    cursor.readByte() // numReadonlySigned
    cursor.readByte() // numReadonlyUnsigned
    require(numRequiredSignatures >= 0)

    val accountCount = cursor.readCompactU16()
    val accounts = ArrayList<String>(accountCount)
    repeat(accountCount) {
        accounts.add(Base58.encode(cursor.read(32)))
    }
    cursor.skip(32) // recentBlockhash

    val transfers = mutableListOf<JsonObject>()
    val memos = mutableListOf<String>()
    var computeUnitLimit: Int? = null
    var computeUnitPrice: String? = null

    val instructionCount = cursor.readCompactU16()
    repeat(instructionCount) {
        val programIndex = cursor.readByte()
        val accountIndexCount = cursor.readCompactU16()
        val accountIndices = IntArray(accountIndexCount) { cursor.readByte() }
        val dataLen = cursor.readCompactU16()
        val data = cursor.read(dataLen)
        val program = accounts[programIndex]

        when (program) {
            COMPUTE_BUDGET_PROGRAM -> {
                if (data.size == 5 && data[0].toInt() == 2) {
                    computeUnitLimit = readU32Le(data, 1)
                } else if (data.size == 9 && data[0].toInt() == 3) {
                    computeUnitPrice = readU64Le(data, 1).toString()
                }
            }
            MEMO_PROGRAM -> memos.add(data.toString(Charsets.UTF_8))
            SYSTEM_PROGRAM -> {
                if (data.size >= 12 && readU32Le(data, 0) == 2) {
                    transfers.add(
                        buildJsonObject {
                            put("kind", "sol")
                            put("destination", accounts[accountIndices[1]])
                            put("amount", readU64Le(data, 4).toString())
                        },
                    )
                }
            }
            TOKEN_PROGRAM, TOKEN_2022_PROGRAM -> {
                if (data.size >= 10 && data[0].toInt() == 12 && accountIndices.size >= 4) {
                    transfers.add(
                        buildJsonObject {
                            put("kind", "spl")
                            put("destination", accounts[accountIndices[2]])
                            put("mint", accounts[accountIndices[1]])
                            put("amount", readU64Le(data, 1).toString())
                            put("decimals", data[9].toInt() and 0xff)
                            put("tokenProgram", program)
                        },
                    )
                }
            }
        }
    }

    return buildJsonObject {
        put("feePayer", accounts[0])
        put("forbiddenPrograms", JsonArray(emptyList()))
        if (computeUnitLimit != null) put("maxComputeUnitLimit", computeUnitLimit!!)
        if (computeUnitPrice != null) put("maxComputeUnitPrice", computeUnitPrice!!)
        put("memo", JsonArray(memos.map { JsonPrimitive(it) }))
        put("transfers", JsonArray(transfers))
    }
}

private fun readU32Le(data: ByteArray, offset: Int): Int {
    return (data[offset].toInt() and 0xff) or
        ((data[offset + 1].toInt() and 0xff) shl 8) or
        ((data[offset + 2].toInt() and 0xff) shl 16) or
        ((data[offset + 3].toInt() and 0xff) shl 24)
}

private fun readU64Le(data: ByteArray, offset: Int): java.math.BigInteger {
    var value = java.math.BigInteger.ZERO
    for (i in 7 downTo 0) {
        value = value.shiftLeft(8).or(java.math.BigInteger.valueOf((data[offset + i].toLong() and 0xff)))
    }
    return value
}

/** Minimal forward cursor over the transaction wire bytes. */
private class ByteCursor(private val bytes: ByteArray) {
    private var pos = 0

    fun readByte(): Int = bytes[pos++].toInt() and 0xff

    fun read(n: Int): ByteArray {
        val out = bytes.copyOfRange(pos, pos + n)
        pos += n
        return out
    }

    fun skip(n: Int) {
        pos += n
    }

    /** Solana compact-u16 (shortvec): 7 bits per byte, MSB continuation. */
    fun readCompactU16(): Int {
        var result = 0
        var shift = 0
        while (true) {
            val b = readByte()
            result = result or ((b and 0x7f) shl shift)
            if (b and 0x80 == 0) break
            shift += 7
        }
        return result
    }
}

/**
 * Tiny JSON serializer for RunnerResult. The RunnerResult shape only carries
 * structural JSON the driver parses with JSON.parse, so kotlinx's default
 * encoder over the JsonObject we assembled is sufficient.
 */
private object CanonicalLessJson {
    fun encode(value: JsonElement): String = value.toString()
}
