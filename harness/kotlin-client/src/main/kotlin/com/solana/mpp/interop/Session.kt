package com.solana.mpp.interop

import com.solana.mpp.client.ActiveSession
import com.solana.mpp.client.CommitPayload
import com.solana.mpp.client.CommitReceipt
import com.solana.mpp.client.CommitStatus
import com.solana.mpp.client.CommitTransport
import com.solana.mpp.client.MeteringDirective
import com.solana.mpp.client.SessionConsumer
import com.solana.mpp.client.SessionRequest
import com.solana.mpp.crypto.MemorySigner
import com.solana.mpp.crypto.PublicKey
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Session intent adapter for the Kotlin harness client.
 *
 * Opt-in: activated by Main when MPP_INTEROP_INTENT=session. The harness does
 * not ship session scenarios today (see harness/src/contracts.ts intent
 * "session"); this drives the off-chain session lifecycle against a session
 * server adapter: fetch the challenge, open a push channel, sign and submit a
 * metered commit voucher, then close. Vouchers are produced by the Kotlin SDK
 * ActiveSession so the 48 byte signing layout is exercised over the wire.
 * On-chain open/settlement signatures are stubbed; Surfpool-backed runs cover
 * the chain side.
 */
fun runSessionAdapter() {
    val baseUrl = requireEnv("MPP_SESSION_INTEROP_TARGET_URL")
    val json = Json { ignoreUnknownKeys = true; encodeDefaults = false; explicitNulls = false }
    val okHttp = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .callTimeout(150, TimeUnit.SECONDS)
        .build()

    // 1. Fetch the session challenge.
    val challengeBody = httpGet(okHttp, "$baseUrl/session/challenge")
    json.decodeFromString(SessionRequest.serializer(), challengeBody)

    // 2. Generate a session signer and a channel id.
    val signer = readSessionSigner()
    val channel = PublicKey(deterministicChannelSeed())
    val session = ActiveSession.create(channel, signer)

    val deposit = 1_000_000L
    val openTxSig = System.getenv("MPP_SESSION_INTEROP_OPEN_SIGNATURE")
        ?: com.solana.mpp.crypto.Base58.encode(deterministicChannelSeed())
    val openAction = session.openAction(deposit, openTxSig)
    val openPayloadJson = json.encodeToString(
        com.solana.mpp.client.OpenPayload.serializer(),
        (openAction as com.solana.mpp.client.SessionAction.Open).payload,
    )
    httpPost(okHttp, "$baseUrl/session/open", openPayloadJson)

    // 3. Reserve a metered delivery, sign + commit a voucher for it.
    val beginBody = buildJsonObject {
        put("sessionId", session.channelIdString)
        put("amount", 125)
    }
    val directiveJson = httpPost(okHttp, "$baseUrl/session/begin-delivery", Json.encodeToString(JsonObject.serializer(), beginBody))
    val directive = json.decodeFromString(MeteringDirective.serializer(), directiveJson)

    val transport = CommitTransport { _, payload ->
        val body = json.encodeToString(CommitPayload.serializer(), payload)
        val receiptJson = httpPost(okHttp, "$baseUrl/session/commit", body)
        json.decodeFromString(CommitReceipt.serializer(), receiptJson)
    }
    val consumer = SessionConsumer(session, transport)
    val delivery = consumer.accept(directive)
    val receipt = delivery.commit()

    // 4. Close the session.
    val closeAction = session.closeAction(null) as com.solana.mpp.client.SessionAction.Close
    val closeJson = httpPost(
        okHttp,
        "$baseUrl/session/close",
        json.encodeToString(com.solana.mpp.client.ClosePayload.serializer(), closeAction.payload),
    )

    val result = buildJsonObject {
        put("type", "result")
        put("implementation", "kotlin")
        put("role", "client")
        put("ok", receipt.status == CommitStatus.COMMITTED)
        put("status", 200)
        put("responseHeaders", buildJsonObject {})
        put(
            "responseBody",
            buildJsonObject {
                put("channelId", session.channelIdString)
                put("committed", receipt.cumulative)
                put("closeState", Json.parseToJsonElement(closeJson))
            },
        )
    }
    println(Json.encodeToString(JsonObject.serializer(), result))
}

private fun readSessionSigner(): MemorySigner {
    val raw = System.getenv("MPP_SESSION_INTEROP_CLIENT_SECRET_KEY")
    if (!raw.isNullOrBlank()) {
        return MemorySigner.fromSecretKey(parseSecretKey(raw))
    }
    // Deterministic ephemeral key when none is supplied.
    return MemorySigner.fromSeed(ByteArray(32) { 42 })
}

private fun deterministicChannelSeed(): ByteArray = ByteArray(32) { 7 }

private fun httpGet(client: OkHttpClient, url: String): String {
    val request = Request.Builder().url(url).get().build()
    client.newCall(request).execute().use { response ->
        val body = response.body?.string() ?: ""
        if (!response.isSuccessful) {
            error("GET $url failed: ${response.code} $body")
        }
        return body
    }
}

private fun httpPost(client: OkHttpClient, url: String, jsonBody: String): String {
    val request = Request.Builder()
        .url(url)
        .post(jsonBody.toRequestBody("application/json".toMediaType()))
        .build()
    client.newCall(request).execute().use { response ->
        val body = response.body?.string() ?: ""
        if (!response.isSuccessful) {
            error("POST $url failed: ${response.code} $body")
        }
        return body
    }
}
