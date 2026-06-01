// Command mpp-conformance is the Swift cross-SDK conformance-vector runner.
//
// It honors the same stdin/stdout contract as the TypeScript reference
// runner (harness/src/conformance/ts-runner.ts) and the Go runner
// (go/cmd/conformance): read one conformance vector as JSON on stdin,
// drive the real SolanaPayKit client build (Charge.buildChargeTransaction)
// and the wire canonical-JSON / base64url encoders for the requested mode,
// and emit one RunnerResult line as JSON on stdout.
//
// Swift is a CLIENT-only SDK. It implements build-transaction (client build
// path) and canonical-bytes (JCS / base64url). It does NOT implement the
// server pre-broadcast verifier, so verify-transaction vectors emit an
// "unsupported-mode" reject the driver SKIPs for this language.
//
// The oracle for build vectors is the DECODED SEMANTIC SHAPE of the
// transaction (fee payer, transfer set, compute caps, memos) rather than
// raw bytes, because signatures and account ordering can legitimately
// differ across SDKs. The canonical-bytes mode pins exact bytes for the
// JCS / base64url vectors where byte-for-byte agreement is the whole point.
//
// The run is deterministic and RPC-free: build vectors pin a recent
// blockhash and resolve the token program ahead of time (explicit ->
// rpcFixtures.mintOwners -> default-by-currency), so the SDK build path is
// invoked with rpc == nil and never contacts a live validator. A vector
// that under-specifies the token program surfaces as a clear reject rather
// than a network call.

import Foundation
import SolanaPayKit

// MARK: - Program ids (mirror harness/src/conformance/decode.ts)

private let tokenProgramId = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
private let token2022ProgramId = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
private let systemProgramId = "11111111111111111111111111111111"
private let computeBudgetProgramId = "ComputeBudget111111111111111111111111111111"
private let memoProgramId = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
private let defaultNetwork = "mainnet"
private let defaultSPLDecimals = 6

// MARK: - Vector decoding (mirror schema.ts ConformanceVector)

private struct Vector: Decodable {
    let id: String
    let mode: String
    let input: VectorInput
}

private struct VectorInput: Decodable {
    let request: VectorChargeRequest?
    let transaction: String?
    let signerSecretKey: [UInt8]?
    let rpcFixtures: RPCFixtures?
    // canonical-bytes payloads are decoded lazily from the raw JSON because
    // `value` is an arbitrary JSON document Codable cannot model directly.
    let encodeBase64Url: EncodeBase64URL?
}

private struct VectorChargeRequest: Decodable {
    let amount: String
    let currency: String
    let externalId: String?
    let recipient: String?
    let payTo: String?
    let asset: String?
    let methodDetails: MethodDetails?
    let computeUnitLimit: UInt32?
    let computeUnitPrice: String?
}

private struct MethodDetails: Decodable {
    let network: String?
    let decimals: Int?
    let tokenProgram: String?
    let recentBlockhash: String?
    let feePayer: Bool?
    let feePayerKey: String?
    let splits: [Split]?
}

private struct Split: Decodable {
    let recipient: String
    let amount: String
    let ataCreationRequired: Bool?
    let memo: String?
}

private struct RPCFixtures: Decodable {
    let recentBlockhash: String?
    let mintOwners: [String: String]?
}

private struct EncodeBase64URL: Decodable {
    let hexBytes: String?
    let utf8: String?
}

// MARK: - Result encoding (mirror schema.ts RunnerResult)

private struct TransferShape: Encodable {
    let kind: String
    let destination: String?
    let mint: String?
    let amount: String
    let decimals: Int?
    let tokenProgram: String?

    enum CodingKeys: String, CodingKey {
        case kind, destination, mint, amount, decimals, tokenProgram
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(amount, forKey: .amount)
        if let destination { try c.encode(destination, forKey: .destination) }
        if let mint { try c.encode(mint, forKey: .mint) }
        if let decimals { try c.encode(decimals, forKey: .decimals) }
        if let tokenProgram { try c.encode(tokenProgram, forKey: .tokenProgram) }
    }
}

private struct TransactionShape: Encodable {
    var feePayer: String?
    var transfers: [TransferShape]
    var forbiddenPrograms: [String]
    var maxComputeUnitLimit: UInt32?
    var maxComputeUnitPrice: String?
    var memo: [String]

    enum CodingKeys: String, CodingKey {
        case feePayer, transfers, forbiddenPrograms, maxComputeUnitLimit, maxComputeUnitPrice, memo
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let feePayer { try c.encode(feePayer, forKey: .feePayer) }
        try c.encode(transfers, forKey: .transfers)
        try c.encode(forbiddenPrograms, forKey: .forbiddenPrograms)
        if let maxComputeUnitLimit { try c.encode(maxComputeUnitLimit, forKey: .maxComputeUnitLimit) }
        if let maxComputeUnitPrice { try c.encode(maxComputeUnitPrice, forKey: .maxComputeUnitPrice) }
        try c.encode(memo, forKey: .memo)
    }
}

private struct ExactBytes: Encodable {
    var canonicalJson: String?
    var base64Url: String?
    var bytes: [Int]?

    enum CodingKeys: String, CodingKey {
        case canonicalJson, base64Url, bytes
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let canonicalJson { try c.encode(canonicalJson, forKey: .canonicalJson) }
        if let base64Url { try c.encode(base64Url, forKey: .base64Url) }
        if let bytes { try c.encode(bytes, forKey: .bytes) }
    }
}

private struct RunnerResult: Encodable {
    let id: String
    let outcome: String
    var transactionShape: TransactionShape?
    var exactBytes: ExactBytes?
    var error: String?
    var rejectCode: String?

    enum CodingKeys: String, CodingKey {
        case id, outcome, transactionShape, exactBytes, error, rejectCode
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(outcome, forKey: .outcome)
        if let transactionShape { try c.encode(transactionShape, forKey: .transactionShape) }
        if let exactBytes { try c.encode(exactBytes, forKey: .exactBytes) }
        if let error { try c.encode(error, forKey: .error) }
        if let rejectCode { try c.encode(rejectCode, forKey: .rejectCode) }
    }
}

// MARK: - Reject classification
//
// The harness asserts a normalized reject CATEGORY per reject vector. Map the
// Swift SDK's native reject message (the `MppError` payload string) onto the
// shared RejectCode vocabulary so the driver can compare categories across
// SDKs rather than brittle prose. Swift is a CLIENT-only SDK, so the only
// harness reject vector it actually processes is the splits-consume-amount
// build vector; the rest of the vocabulary is mapped for completeness and
// future build-path rejects. Returns nil for messages outside the vocabulary
// (e.g. the unsupported-mode skip), and the runner omits `rejectCode` then.
private func classifyReject(_ message: String) -> String? {
    let m = message.lowercased()

    func has(_ needle: String) -> Bool { m.contains(needle) }

    if has("splits consume the entire amount")
        || (has("primary") && has("positive"))
        || (has("split") && has("exceed")) {
        return "splits-exceed-amount"
    }
    if has("too many splits") {
        return "too-many-splits"
    }
    if has("compute unit price") && has("exceed") && (has("cap") || has("maximum")) {
        return "compute-price-over-cap"
    }
    if has("compute unit limit") && has("exceed") {
        return "compute-limit-over-cap"
    }
    if has("fee payer cannot authorize") {
        return "fee-payer-not-authority"
    }
    if (has("no matching") || has("unexpected")) && has("transfer") {
        return "no-matching-transfer"
    }
    if has("amount") && (has("mismatch") || has("does not match")) {
        return "amount-mismatch"
    }
    if has("invalid") || has("malformed") || has("decode") || has("payload") {
        return "invalid-payload"
    }
    return nil
}

private enum RunnerError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case let .message(text): return text
        }
    }
}

// MARK: - Local signer

private struct ConformanceSigner: SolanaSigner {
    let publicKey: Data
    let address: String
    private let handler: @Sendable (Data) async throws -> Data

    init(secretKey: [UInt8]) throws {
        guard secretKey.count == 64 else {
            throw RunnerError.message("signerSecretKey must be 64 bytes, got \(secretKey.count)")
        }
        let inner = try MemorySigner(secretKey: Data(secretKey))
        self.publicKey = inner.publicKey
        self.address = inner.address
        self.handler = { try await inner.sign(message: $0) }
    }

    func sign(message: Data) async throws -> Data {
        try await handler(message)
    }
}

// MARK: - base64url helper (mirror the SDK PayCore/Base64URL transform)

private func base64Url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - Request flattening (mirror ts-runner / go flattenRequest)

private func resolveTokenProgram(
    currency: String,
    network: String,
    explicit: String?,
    mintOwners: [String: String]?
) -> String? {
    if let explicit { return explicit }
    if currency.lowercased() == "sol" { return nil }
    let resolvedMint = Charge.resolveStablecoinMint(currency: currency, network: network) ?? currency
    if let owner = mintOwners?[resolvedMint] { return owner }
    return Mints.defaultTokenProgram(currency: currency, cluster: network)
}

// Apply the precedence rules a vector can probe: top-level asset / payTo win
// over currency / recipient; methodDetails carry the rest. Resolve the token
// program ahead of time so the SDK build path stays RPC-free, mirroring the
// TS and Go reference runners. The flattened request is decoded through the
// SDK's own `ChargeRequest` Decodable path (the model has no cross-module
// public initializer), so the runner exercises the same decode the SDK
// uses on the wire.
private func flattenRequest(
    _ request: VectorChargeRequest,
    mintOwners: [String: String]?
) throws -> ChargeRequest {
    let currency = request.asset ?? request.currency
    guard let recipient = request.payTo ?? request.recipient else {
        throw RunnerError.message("vector request is missing recipient/payTo")
    }
    let md = request.methodDetails
    let network = md?.network ?? defaultNetwork

    let tokenProgram = resolveTokenProgram(
        currency: currency,
        network: network,
        explicit: md?.tokenProgram,
        mintOwners: mintOwners
    )

    let isSOL = currency.lowercased() == "sol"
    let decimals = md?.decimals ?? (isSOL ? nil : defaultSPLDecimals)

    var methodDetails: [String: Any] = [:]
    methodDetails["network"] = network
    if let decimals { methodDetails["decimals"] = decimals }
    if let tokenProgram { methodDetails["tokenProgram"] = tokenProgram }
    if let bh = md?.recentBlockhash { methodDetails["recentBlockhash"] = bh }
    if let fp = md?.feePayer { methodDetails["feePayer"] = fp }
    if let fpk = md?.feePayerKey { methodDetails["feePayerKey"] = fpk }
    if let splits = md?.splits {
        methodDetails["splits"] = splits.map { split -> [String: Any] in
            var out: [String: Any] = ["recipient": split.recipient, "amount": split.amount]
            if let req = split.ataCreationRequired { out["ataCreationRequired"] = req }
            if let memo = split.memo { out["memo"] = memo }
            return out
        }
    }

    var object: [String: Any] = [
        "amount": request.amount,
        "currency": currency,
        "recipient": recipient,
        "methodDetails": methodDetails,
    ]
    if let externalId = request.externalId { object["externalId"] = externalId }

    let data = try JSONSerialization.data(withJSONObject: object)
    do {
        return try JSONDecoder().decode(ChargeRequest.self, from: data)
    } catch {
        throw RunnerError.message("failed to decode flattened ChargeRequest: \(error)")
    }
}

// MARK: - Build path

private func buildTransaction(_ vector: Vector) async throws -> String {
    let input = vector.input
    guard let request = input.request else {
        throw RunnerError.message("build/verify vector is missing input.request")
    }
    guard let secret = input.signerSecretKey else {
        throw RunnerError.message("build/verify vector is missing input.signerSecretKey")
    }
    let signer = try ConformanceSigner(secretKey: secret)
    let charge = try flattenRequest(request, mintOwners: input.rpcFixtures?.mintOwners)

    var options = Charge.Options()
    if let limit = request.computeUnitLimit { options.computeUnitLimit = limit }
    if let priceStr = request.computeUnitPrice {
        guard let price = UInt64(priceStr) else {
            throw RunnerError.message("invalid computeUnitPrice \(priceStr)")
        }
        options.computeUnitPrice = price
    }

    // rpc == nil: recentBlockhash is pinned and the token program is resolved
    // ahead of time, so the SDK never reaches for a live RPC.
    return try await Charge.buildChargeTransaction(
        request: charge,
        signer: signer,
        rpc: nil,
        options: options
    )
}

// MARK: - Wire decode (mirror decode.ts / go shapeFromTransaction)

private struct DecodeCursor {
    let data: [UInt8]
    var offset = 0
    init(_ data: Data) { self.data = [UInt8](data) }

    mutating func shortVecLength() throws -> Int {
        var value = 0
        var shift = 0
        for _ in 0..<3 {
            guard offset < data.count else {
                throw RunnerError.message("short-vec length truncated")
            }
            let byte = data[offset]; offset += 1
            value |= Int(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { return value }
            shift += 7
        }
        throw RunnerError.message("short-vec length exceeds 3 bytes")
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard offset + count <= data.count else {
            throw RunnerError.message("unexpected end of transaction bytes")
        }
        let slice = Array(data[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else {
            throw RunnerError.message("unexpected end of transaction bytes")
        }
        let b = data[offset]; offset += 1
        return b
    }
}

private func u32LE(_ d: [UInt8], _ at: Int) -> UInt32 {
    UInt32(d[at]) | (UInt32(d[at + 1]) << 8) | (UInt32(d[at + 2]) << 16) | (UInt32(d[at + 3]) << 24)
}

private func u64LE(_ d: [UInt8], _ at: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(d[at + i]) << (8 * i) }
    return v
}

private func shapeFromTransaction(_ base64: String) throws -> TransactionShape {
    guard let txData = Data(base64Encoded: base64) else {
        throw RunnerError.message("transaction is not valid base64")
    }
    var cur = DecodeCursor(txData)
    let sigCount = try cur.shortVecLength()
    _ = try cur.take(sigCount * 64)
    // Legacy messages carry no version prefix byte (the SDK always emits
    // legacy for charge). Header is 3 bytes.
    let header = try cur.take(3)
    _ = header
    let keyCount = try cur.shortVecLength()
    var keys: [String] = []
    keys.reserveCapacity(keyCount)
    for _ in 0..<keyCount {
        let raw = try cur.take(32)
        keys.append(try Pubkey(bytes: Data(raw)).base58)
    }
    _ = try cur.take(32) // recent blockhash

    func accountAt(_ accounts: [UInt8], _ pos: Int) -> String? {
        guard pos >= 0, pos < accounts.count else { return nil }
        let idx = Int(accounts[pos])
        guard idx >= 0, idx < keys.count else { return nil }
        return keys[idx]
    }

    guard !keys.isEmpty else {
        throw RunnerError.message("transaction has no account keys")
    }

    var shape = TransactionShape(
        feePayer: keys[0],
        transfers: [],
        forbiddenPrograms: [],
        memo: []
    )

    let ixCount = try cur.shortVecLength()
    for _ in 0..<ixCount {
        let programIdx = Int(try cur.byte())
        let acctCount = try cur.shortVecLength()
        let accounts = try cur.take(acctCount)
        let dataLen = try cur.shortVecLength()
        let data = try cur.take(dataLen)

        guard programIdx >= 0, programIdx < keys.count else { continue }
        let program = keys[programIdx]

        switch program {
        case computeBudgetProgramId:
            if data.count == 5, data[0] == 2 {
                shape.maxComputeUnitLimit = u32LE(data, 1)
            } else if data.count == 9, data[0] == 3 {
                shape.maxComputeUnitPrice = String(u64LE(data, 1))
            }
        case memoProgramId:
            shape.memo.append(String(decoding: data, as: UTF8.self))
        case systemProgramId:
            // System transfer: u32 LE discriminator 2 + u64 LE lamports.
            if data.count >= 12, u32LE(data, 0) == 2 {
                guard let dest = accountAt(accounts, 1) else { continue }
                shape.transfers.append(TransferShape(
                    kind: "sol",
                    destination: dest,
                    mint: nil,
                    amount: String(u64LE(data, 4)),
                    decimals: nil,
                    tokenProgram: nil
                ))
            }
        case tokenProgramId, token2022ProgramId:
            // transferChecked: discriminator 12, u64 amount at [1], decimals [9].
            if data.count >= 10, data[0] == 12, accounts.count >= 4 {
                guard let mint = accountAt(accounts, 1),
                      let dest = accountAt(accounts, 2) else { continue }
                shape.transfers.append(TransferShape(
                    kind: "spl",
                    destination: dest,
                    mint: mint,
                    amount: String(u64LE(data, 1)),
                    decimals: Int(data[9]),
                    tokenProgram: program
                ))
            }
        default:
            continue
        }
    }

    return shape
}

// MARK: - canonical-bytes

private func runCanonicalBytes(_ vector: Vector, rawValue: Any?) throws -> ExactBytes {
    var eb = ExactBytes()
    if let value = rawValue {
        // Canonical JSON via Foundation's sorted-key serializer, the same
        // canonicalization the SDK wire path relies on
        // (JSONEncoder.outputFormatting = [.sortedKeys]). RFC 8785 key order
        // for BMP keys agrees with sorted-key order.
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        eb.canonicalJson = String(decoding: data, as: UTF8.self)
        eb.base64Url = base64Url(data)
    }
    if let enc = vector.input.encodeBase64Url {
        if let hex = enc.hexBytes {
            let bytes = try hexDecode(hex)
            eb.bytes = bytes.map { Int($0) }
            eb.base64Url = base64Url(Data(bytes))
        } else if let utf8 = enc.utf8 {
            eb.base64Url = base64Url(Data(utf8.utf8))
        }
    }
    return eb
}

private func hexDecode(_ hex: String) throws -> [UInt8] {
    let chars = Array(hex)
    guard chars.count % 2 == 0 else {
        throw RunnerError.message("hex string has odd length")
    }
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else {
            throw RunnerError.message("invalid hex digit")
        }
        out.append(UInt8(hi << 4 | lo))
        i += 2
    }
    return out
}

// MARK: - Dispatch

private func runVector(_ vector: Vector, rawValue: Any?) async -> RunnerResult {
    do {
        switch vector.mode {
        case "canonical-bytes":
            let eb = try runCanonicalBytes(vector, rawValue: rawValue)
            return RunnerResult(id: vector.id, outcome: "accept", exactBytes: eb)
        case "build-transaction":
            let tx = try await buildTransaction(vector)
            let shape = try shapeFromTransaction(tx)
            return RunnerResult(id: vector.id, outcome: "accept", transactionShape: shape)
        case "verify-transaction":
            // Swift is a client-only SDK: it has no server pre-broadcast
            // verifier. Emit a clear unsupported-mode result the driver
            // SKIPs for this language rather than a false accept/reject.
            return RunnerResult(
                id: vector.id,
                outcome: "reject",
                error: "unsupported-mode: swift is a client-only SDK and does not implement verify-transaction"
            )
        default:
            return RunnerResult(
                id: vector.id,
                outcome: "reject",
                error: "unsupported mode \(vector.mode)"
            )
        }
    } catch {
        let message = String(describing: error)
        return RunnerResult(
            id: vector.id,
            outcome: "reject",
            error: message,
            rejectCode: classifyReject(message)
        )
    }
}

// MARK: - Entry point

func main() async {
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    guard !raw.isEmpty else {
        FileHandle.standardError.write(Data("swift conformance runner received empty stdin".utf8))
        exit(1)
    }

    let vector: Vector
    let rawValue: Any?
    do {
        vector = try JSONDecoder().decode(Vector.self, from: raw)
        // `value` is an arbitrary JSON document; pull it from the parsed
        // object tree rather than Codable so canonical-bytes vectors can
        // canonicalize any shape.
        if let top = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let input = top["input"] as? [String: Any] {
            rawValue = input["value"]
        } else {
            rawValue = nil
        }
    } catch {
        FileHandle.standardError.write(Data("failed to parse vector: \(error)".utf8))
        exit(1)
    }

    let result = await runVector(vector, rawValue: rawValue)
    do {
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        var line = data
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    } catch {
        FileHandle.standardError.write(Data("failed to encode result: \(error)".utf8))
        exit(1)
    }
}

await main()
