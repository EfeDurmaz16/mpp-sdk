import Foundation

// MARK: - x402 exact challenge parsing and payment building

/// ComputeBudget SetComputeUnitLimit units for x402 exact transactions.
///
/// Canonical value from the rust spine
/// (`rust/crates/x402/src/client/exact/payment.rs:56`). The MPP charge
/// client uses 200_000 for its own transactions; x402 uses 20_000.
let X402ComputeUnitLimit: UInt32 = 20_000

/// ComputeBudget SetComputeUnitPrice micro-lamports.
let X402ComputeUnitPrice: UInt64 = 1

/// Default SPL decimals when the offer omits `extra.decimals`.
let X402DefaultDecimals: UInt8 = 6

// MARK: - Challenge parsing

/// Parse an x402 challenge from response headers and/or body, applying the
/// client's network + currency-preference selection.
///
/// Checks (in strict order, returning the first that yields an offer):
/// 1. v2 `PAYMENT-REQUIRED` header containing standard-base64
///    `{ "accepts": [...] }` JSON.
/// 2. Legacy v1 `X-PAYMENT-REQUIRED` header containing a raw-JSON flat
///    `PaymentRequirements` object (no base64, no `accepts[]` wrapper).
/// 3. Response body with `{ "accepts": [...] }`.
///
/// Header lookup is case-insensitive. Returns `nil` when no supported Solana
/// x402 exact offer matches. Mirrors the rust
/// `parse_x402_challenge_with_selection`
/// (`rust/crates/x402/src/client/exact/payment.rs:222`).
public func parseX402Challenge(
    headers: [(name: String, value: String)],
    body: String?,
    selection: X402ChallengeSelection = X402ChallengeSelection()
) -> X402AcceptsEntry? {
    if let headerValue = headers.first(where: {
        $0.name.caseInsensitiveCompare(X402V2PaymentRequiredHeader) == .orderedSame
    })?.value,
       let offer = _selectFromHeader(headerValue, selection: selection) {
        return offer
    }

    // Legacy v1: `X-PAYMENT-REQUIRED` is a raw-JSON, flat single
    // `PaymentRequirements` object — no base64 decode, no `accepts[]`
    // envelope. Returned directly without the selection step since it is a
    // single requirement (rust `payment.rs:236-243`).
    if let headerValue = headers.first(where: {
        $0.name.caseInsensitiveCompare(X402V1PaymentRequiredHeader) == .orderedSame
    })?.value,
       let offer = _parseV1ChallengeHeader(headerValue) {
        return offer
    }

    if let body = body,
       let offer = _selectFromBody(body, selection: selection) {
        return offer
    }

    return nil
}

// MARK: - Payment header building

/// x402 exact Memo size cap, matching the spec MAX (256 bytes UTF-8).
///
/// The x402 spec limits the memo field to 256 bytes. This is more
/// conservative than the SPL Memo program's own limit (566 bytes).
let X402MemoMaxBytes: Int = 256

/// Build the standard-base64 `Payment-Signature` header value for an x402
/// exact offer.
///
/// Transaction shape (v0, fee-payer from `extra.feePayer` or client):
///   1. `ComputeBudgetSetUnitLimit(20_000)`
///   2. `ComputeBudgetSetUnitPrice(1)`
///   3. `splTransferChecked` (SPL) **or** `systemTransfer` (native SOL)
///   4. Memo instruction: `extra.memo` when present, else a random 16-byte
///      hex-encoded nonce (always appended to guarantee transaction
///      uniqueness). Mirrors the Rust `build_payment_transaction` which
///      generates a random nonce when `extra.memo` is absent.
///
/// Blockhash: `offer.extra.recentBlockhash` when present, else
/// `rpc.getLatestBlockhash()`.
///
/// The output is standard base64 (not base64url); the header name is
/// `Payment-Signature`.
///
/// - Parameters:
///   - nonceGenerator: Optional closure that returns 16 random bytes.
///     Defaults to `SystemRandomNumberGenerator`. Pass a fixed value in
///     tests to make the output deterministic.
public func buildX402PaymentHeader(
    signer: any SolanaSigner,
    rpc: RpcClient,
    offer: X402AcceptsEntry,
    nonceGenerator: (() -> Data)? = nil
) async throws -> String {
    let payload = try await _buildPaymentPayload(
        signer: signer, rpc: rpc, offer: offer, nonceGenerator: nonceGenerator
    )
    let envelope = X402PaymentSignatureEnvelope(
        x402Version: X402VersionV2,
        accepted: offer,
        resource: offer.resourceInfo,
        payload: payload
    )
    return try _encodeX402Envelope(envelope)
}

/// Build the standard-base64 legacy v1 `X-PAYMENT` header value for an x402
/// exact offer, for older integrations.
///
/// The signed-transaction proof is byte-for-byte identical to
/// `buildX402PaymentHeader` (both call the same builder); only the envelope
/// differs. The v1 envelope carries `x402Version=1`, a top-level
/// `scheme="exact"`, and a top-level legacy `network` string (see
/// `_v1NetworkForOffer`); it has no `accepted` and no `resource`. Mirrors the
/// rust `build_payment_header_v1`
/// (`rust/crates/x402/src/client/exact/payment.rs:144`).
///
/// v2 (`buildX402PaymentHeader` -> `PAYMENT-SIGNATURE`) stays the default; the
/// value returned here is written to `X-PAYMENT`.
public func buildX402PaymentHeaderV1(
    signer: any SolanaSigner,
    rpc: RpcClient,
    offer: X402AcceptsEntry,
    nonceGenerator: (() -> Data)? = nil
) async throws -> String {
    let payload = try await _buildPaymentPayload(
        signer: signer, rpc: rpc, offer: offer, nonceGenerator: nonceGenerator
    )
    let envelope = X402PaymentSignatureEnvelope(
        scheme: X402ExactScheme,
        network: _v1NetworkForOffer(offer),
        x402Version: X402VersionV1,
        accepted: nil,
        resource: nil,
        payload: payload
    )
    return try _encodeX402Envelope(envelope)
}

private func _encodeX402Envelope(_ envelope: X402PaymentSignatureEnvelope) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try encoder.encode(envelope)
    return json.base64EncodedString()
}

/// Legacy v1 network string for an offer, collapsing the full CAIP-2 space
/// into the two legacy strings the v1 wire uses.
///
/// Selector is the offer's `cluster` slug when present, otherwise its
/// `network`. Devnet (`"devnet"`, `"solana-devnet"`, or the devnet CAIP-2 id)
/// maps to `"solana-devnet"`; everything else (mainnet, testnet, localnet,
/// any unrecognized value) maps to `"solana"`. Mirrors the rust
/// `v1_network_for_requirements`
/// (`rust/crates/x402/src/client/exact/payment.rs:383`).
private func _v1NetworkForOffer(_ offer: X402AcceptsEntry) -> String {
    let selector = offer.cluster ?? offer.network
    switch selector {
    case "devnet", "solana-devnet", SolanaNetwork.devnet:
        return "solana-devnet"
    default:
        return SolanaNetwork.legacyAlias
    }
}

// MARK: - Internal payment builder

private func _buildPaymentPayload(
    signer: any SolanaSigner,
    rpc: RpcClient,
    offer: X402AcceptsEntry,
    nonceGenerator: (() -> Data)? = nil
) async throws -> X402PaymentPayload {
    guard let amountStr = offer.effectiveAmount, let amount = UInt64(amountStr) else {
        throw MppError.invalidTransaction(
            "x402 offer has missing or invalid amount: \(offer.effectiveAmount ?? "nil")"
        )
    }
    guard let payToStr = offer.effectivePayTo, !payToStr.isEmpty else {
        throw MppError.invalidTransaction("x402 offer is missing payTo / recipient")
    }
    guard let assetStr = offer.effectiveAsset, !assetStr.isEmpty else {
        throw MppError.invalidTransaction("x402 offer is missing asset")
    }

    let signerPubkey = try Pubkey(bytes: signer.publicKey)
    let recipientPubkey = try Pubkey(base58: payToStr)

    // Managed fee payer: prefer the top-level `feePayerKey`, then the nested
    // `extra.feePayer` alias, gated by the `feePayer` toggle (rust types.rs
    // normalization). When absent, the local signer pays.
    let feePayerPubkey: Pubkey
    if let fpStr = offer.effectiveFeePayerKey {
        feePayerPubkey = try Pubkey(base58: fpStr)
    } else {
        feePayerPubkey = signerPubkey
    }

    var instructions: [SolanaInstruction] = []
    instructions.append(Instructions.computeBudgetSetUnitLimit(units: X402ComputeUnitLimit))
    instructions.append(Instructions.computeBudgetSetUnitPrice(microLamports: X402ComputeUnitPrice))

    let clusterLabel = SolanaNetwork.clusterLabel(for: offer.network)
    let mintAddress = Mints.resolveMint(currency: assetStr, cluster: clusterLabel)

    if let mintStr = mintAddress {
        // Default the token program from the currency (Token vs Token-2022)
        // when the offer omits `extra.tokenProgram`, so Token-2022 mints
        // (USDG / PYUSD / CASH) derive the correct ATA. Mirrors rust
        // `default_token_program_for_currency`.
        let tokenProgramStr = offer.effectiveTokenProgram
            ?? Mints.defaultTokenProgram(currency: assetStr, cluster: clusterLabel)
        let tokenProgram = try Pubkey(base58: tokenProgramStr)
        let mint = try Pubkey(base58: mintStr)
        let decimals: UInt8
        if let d = offer.effectiveDecimals, d >= 0, d <= 255 {
            decimals = UInt8(d)
        } else {
            decimals = X402DefaultDecimals
        }
        let sourceAta = try AssociatedTokenAccount.address(
            owner: signerPubkey, mint: mint, tokenProgram: tokenProgram
        )
        let destAta = try AssociatedTokenAccount.address(
            owner: recipientPubkey, mint: mint, tokenProgram: tokenProgram
        )
        instructions.append(Instructions.splTransferChecked(
            programId: tokenProgram,
            source: sourceAta,
            mint: mint,
            destination: destAta,
            authority: signerPubkey,
            amount: amount,
            decimals: decimals
        ))
    } else {
        instructions.append(Instructions.systemTransfer(
            from: signerPubkey, to: recipientPubkey, lamports: amount
        ))
    }

    try _appendX402Memo(into: &instructions, offer: offer, nonceGenerator: nonceGenerator)

    // Blockhash: prefer offer's stamp; fall back to RPC.
    let blockhash: Data
    if let bhStr = offer.effectiveRecentBlockhash {
        let decoded = try Base58.decode(bhStr)
        guard decoded.count == 32 else {
            throw MppError.invalidTransaction(
                "x402 recentBlockhash decodes to \(decoded.count) bytes, expected 32"
            )
        }
        blockhash = decoded
    } else {
        blockhash = try await rpc.getLatestBlockhash().bytes
    }

    // Compile v0 message.
    let message = try TransactionBuilder.compile(
        version: .v0,
        feePayer: feePayerPubkey,
        instructions: instructions,
        recentBlockhash: blockhash
    )

    let messageBytes = message.serialize()
    let signature = try await signer.sign(message: messageBytes)
    guard signature.count == 64 else {
        throw MppError.signingFailure("signer returned \(signature.count) bytes, expected 64")
    }

    var signatures = SignedTransaction.emptySignatureSlots(
        count: Int(message.header.numRequiredSignatures)
    )
    guard let signerIndex = message.accountKeys.firstIndex(of: signerPubkey) else {
        throw MppError.signingFailure("signer pubkey not found in transaction accounts")
    }
    guard signerIndex < signatures.count else {
        throw MppError.signingFailure(
            "signer index \(signerIndex) exceeds required signature count"
        )
    }
    signatures[signerIndex] = signature

    let signedTx = try SignedTransaction(signatures: signatures, message: message)
    return X402PaymentPayload(transaction: signedTx.serialize().base64EncodedString())
}

/// Append a Memo instruction to every x402 payment transaction.
///
/// When `offer.extra.memo` is present, use it as the memo text (the Rust
/// verifier asserts the memo equals the stamped value). When absent,
/// generate a random 16-byte nonce and hex-encode it as UTF-8 to make
/// the transaction unique and prevent replay of otherwise-identical
/// payments. Mirrors the Rust `build_payment_transaction` memo path.
///
/// The memo is capped at `X402MemoMaxBytes` (256 bytes UTF-8).
///
/// - Parameter nonceGenerator: A closure producing 16 random bytes.
///   Pass a deterministic value in tests; defaults to
///   `SystemRandomNumberGenerator`.
private func _appendX402Memo(
    into instructions: inout [SolanaInstruction],
    offer: X402AcceptsEntry,
    nonceGenerator: (() -> Data)? = nil
) throws {
    let memoText: String
    // Use the raw value so a present-but-empty `extra.memo` emits a
    // zero-length memo (which the rust verifier expects), rather than
    // falling through to a random nonce. Mirrors rust `memo_instruction`,
    // which emits the memo bytes for any `Some(memo)` including `""`.
    if let memo = offer.extraRawString("memo") {
        memoText = memo
    } else {
        // Generate a random 16-byte nonce and hex-encode it.
        let nonceBytes: Data
        if let generator = nonceGenerator {
            nonceBytes = generator()
        } else {
            var rng = SystemRandomNumberGenerator()
            var bytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { bytes[i] = rng.next() }
            nonceBytes = Data(bytes)
        }
        memoText = nonceBytes.map { String(format: "%02x", $0) }.joined()
    }
    let memoBytes = Data(memoText.utf8)
    guard memoBytes.count <= X402MemoMaxBytes else {
        throw MppError.invalidTransaction(
            "x402 memo exceeds \(X402MemoMaxBytes) bytes"
        )
    }
    instructions.append(SolanaInstruction(
        programId: .memoProgram,
        accounts: [],
        data: memoBytes
    ))
}

// MARK: - Selection helpers

/// Parse a legacy v1 `X-PAYMENT-REQUIRED` header value: a raw-JSON, flat
/// single `PaymentRequirements` object (no base64, no `accepts[]` wrapper).
///
/// Mirrors the rust `serde_json::from_str::<PaymentRequirements>(&header.1)`
/// path (`rust/crates/x402/src/client/exact/payment.rs:240`). The rust
/// `PaymentRequirements` deserializer normalizes the flat legacy network
/// string (`"solana"` / `"solana-devnet"` / `"devnet"` / ...) to its CAIP-2
/// form (`types.rs:320`, `normalize_network_identifier`), so the parsed entry
/// here is rebuilt with the CAIP-2 `network` and a derived `cluster` slug so
/// the downstream payment builder resolves the correct mint and ATA. Returns
/// `nil` for a non-Solana network or malformed JSON.
private func _parseV1ChallengeHeader(_ headerValue: String) -> X402AcceptsEntry? {
    guard let data = headerValue.data(using: .utf8),
          let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
          let entry = try? JSONDecoder().decode(X402AcceptsEntry.self, from: data)
    else { return nil }

    // Normalize the flat legacy network to CAIP-2 (rust `normalize_network_identifier`).
    let normalizedNetwork = SolanaNetwork.caip2(for: entry.network)
    // Drop non-Solana offers (rust selection filters on
    // `cluster_for_caip2_network(...).is_some()`, applied via the same
    // network normalization).
    guard SolanaNetwork.clusterForCaip2(normalizedNetwork) != nil else { return nil }
    let derivedCluster = entry.cluster ?? SolanaNetwork.clusterLabel(for: normalizedNetwork)

    return X402AcceptsEntry(
        scheme: entry.scheme,
        network: normalizedNetwork,
        amount: entry.amount,
        maxAmountRequired: entry.maxAmountRequired,
        asset: entry.asset,
        payTo: entry.payTo,
        recipient: entry.recipient,
        extra: entry.extra,
        currency: entry.currency,
        decimals: entry.decimals,
        tokenProgram: entry.tokenProgram,
        recentBlockhash: entry.recentBlockhash,
        feePayerKey: entry.feePayerKey,
        feePayer: entry.feePayer,
        maxTimeoutSeconds: entry.maxTimeoutSeconds,
        cluster: derivedCluster,
        resource: entry.resource,
        description: entry.description,
        raw: raw
    )
}

private func _selectFromHeader(
    _ headerValue: String,
    selection: X402ChallengeSelection
) -> X402AcceptsEntry? {
    guard let data = Data(base64Encoded: headerValue),
          let envelope = try? JSONDecoder().decode(X402PaymentRequiredEnvelope.self, from: data)
    else { return nil }
    return _selectRequirement(from: envelope.accepts, selection: selection)
}

private func _selectFromBody(
    _ body: String,
    selection: X402ChallengeSelection
) -> X402AcceptsEntry? {
    guard let data = body.data(using: .utf8),
          let envelope = try? JSONDecoder().decode(X402PaymentRequiredEnvelope.self, from: data)
    else { return nil }
    return _selectRequirement(from: envelope.accepts, selection: selection)
}

private func _selectRequirement(
    from accepts: [X402AcceptsEntry],
    selection: X402ChallengeSelection
) -> X402AcceptsEntry? {
    let preferredNetwork = SolanaNetwork.caip2(for: selection.network)
    let clusterLabel = SolanaNetwork.clusterLabel(for: preferredNetwork)

    let solana = accepts.filter { _isSolanaExact($0) }
    let onPreferred = solana.filter { _networkMatches($0, preferred: preferredNetwork) }

    if let currencies = selection.currencies {
        for wanted in currencies {
            for offer in onPreferred {
                if let asset = offer.effectiveAsset,
                   _currenciesMatch(offered: asset, accepted: wanted, label: clusterLabel) {
                    return offer
                }
            }
        }
        return nil
    }

    let candidates = onPreferred.isEmpty ? solana : onPreferred
    return candidates.min(by: { _effectiveAmountOf($0) < _effectiveAmountOf($1) })
}

/// Eligibility filter for an x402 offer, mirroring the rust spine.
///
/// Rust selects on network alone: an offer is a candidate when
/// `cluster_for_caip2_network(requirement.network).is_some()`
/// (`rust/crates/x402/src/client/exact/payment.rs:303`), which accepts the
/// canonical CAIP-2 ids, the cluster slugs (`mainnet`/`devnet`/`testnet`
/// /`localnet`/`mainnet-beta`), the legacy `solana` alias, and any
/// `solana:*` id. Rust never inspects `scheme` while selecting, so neither
/// does the swift client (the previous `scheme == "exact"` gate diverged).
private func _isSolanaExact(_ offer: X402AcceptsEntry) -> Bool {
    SolanaNetwork.clusterForCaip2(offer.network) != nil
}

/// True when an offer's network matches the client's preferred network,
/// mirroring the rust `network_matches`
/// (`rust/crates/x402/src/client/exact/payment.rs:291`):
/// direct equality, the legacy `solana` alias against mainnet, or the
/// offer's `cluster` slug mapping back to the preferred CAIP-2 id.
private func _networkMatches(_ offer: X402AcceptsEntry, preferred: String) -> Bool {
    if offer.network == preferred { return true }
    if preferred == SolanaNetwork.mainnet && offer.network == SolanaNetwork.legacyAlias {
        return true
    }
    if let cluster = offer.cluster,
       SolanaNetwork.caip2(for: cluster) == preferred {
        return true
    }
    return false
}

private func _effectiveAmountOf(_ offer: X402AcceptsEntry) -> UInt64 {
    UInt64(offer.effectiveAmount ?? "") ?? UInt64.max
}

private func _currenciesMatch(offered: String, accepted: String, label: String) -> Bool {
    let offeredMint = Mints.resolveMint(currency: offered, cluster: label) ?? offered
    let acceptedMint = Mints.resolveMint(currency: accepted, cluster: label) ?? accepted
    return offeredMint == acceptedMint
}
