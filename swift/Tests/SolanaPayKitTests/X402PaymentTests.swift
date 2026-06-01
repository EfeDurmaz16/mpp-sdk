import Foundation
import Testing
@testable import SolanaPayKit

// MARK: - x402 challenge parsing tests

@Suite("x402 challenge parsing")
struct X402ChallengeParsingTests {
    // MARK: - Header parsing

    @Test
    func parsesPaymentRequiredHeader() throws {
        let net = SolanaNetwork.devnet
        let envelope = """
        {
            "x402Version": 2,
            "accepts": [{
                "scheme": "exact",
                "network": "\(net)",
                "amount": "1000",
                "asset": "\(Mints.usdcDevnet)",
                "payTo": "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
                "extra": {
                    "recentBlockhash": "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
                    "decimals": 6
                }
            }]
        }
        """
        let encoded = Data(envelope.utf8).base64EncodedString()
        let headers = [(name: "PAYMENT-REQUIRED", value: encoded)]
        let offer = parseX402Challenge(headers: headers, body: nil)
        #expect(offer != nil)
        #expect(offer?.effectiveAmount == "1000")
        #expect(offer?.asset == Mints.usdcDevnet)
    }

    @Test
    func parsesBodyFallback() throws {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [{
                "scheme": "exact",
                "network": "\(net)",
                "maxAmountRequired": "5000",
                "asset": "SOL",
                "payTo": "abc123"
            }]
        }
        """
        let offer = parseX402Challenge(headers: [], body: body)
        #expect(offer != nil)
        #expect(offer?.effectiveAmount == "5000")
        #expect(offer?.asset == "SOL")
    }

    @Test
    func parsesTopLevelCurrencyShape() throws {
        // Some x402 servers carry the mint as top-level `currency` with token
        // metadata at the top level instead of nested under `asset` + `extra`.
        // The client must resolve them via the `effective*` accessors so it
        // can pay either wire shape.
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [{
                "scheme": "exact",
                "network": "\(net)",
                "amount": "1000",
                "currency": "\(Mints.usdcDevnet)",
                "payTo": "abc123",
                "decimals": 6,
                "tokenProgram": "\(Mints.tokenProgram)",
                "recentBlockhash": "11111111111111111111111111111111"
            }]
        }
        """
        let offer = parseX402Challenge(headers: [], body: body)
        #expect(offer != nil)
        #expect(offer?.asset == nil)
        #expect(offer?.effectiveAsset == Mints.usdcDevnet)
        #expect(offer?.effectiveDecimals == 6)
        #expect(offer?.effectiveTokenProgram == Mints.tokenProgram)
        #expect(offer?.effectiveRecentBlockhash == "11111111111111111111111111111111")
    }

    // MARK: - Conflicting-shape precedence (must match Rust types.rs lines 340-349)

    /// When both `currency` (top-level) and `asset` are present, top-level
    /// `currency` wins. Rust: `string_field(object, "currency").or_else(|| ...)`.
    @Test
    func topLevelCurrencyWinsOverAssetWhenBothPresent() throws {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [{
                "scheme": "exact",
                "network": "\(net)",
                "amount": "1000",
                "currency": "\(Mints.usdcDevnet)",
                "asset": "\(Mints.pyusdDevnet)",
                "payTo": "abc123"
            }]
        }
        """
        let offer = parseX402Challenge(headers: [], body: body)
        // Top-level `currency` must win.
        #expect(offer?.effectiveAsset == Mints.usdcDevnet)
        // The underlying `asset` field is still accessible directly.
        #expect(offer?.asset == Mints.pyusdDevnet)
    }

    /// When both top-level `tokenProgram` and `extra.tokenProgram` are
    /// present, top-level wins. Rust: `string_field(object, "tokenProgram")
    /// .or_else(|| extra.and_then(...))`.
    @Test
    func topLevelTokenProgramWinsOverExtraTokenProgram() throws {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [{
                "scheme": "exact",
                "network": "\(net)",
                "amount": "1000",
                "asset": "\(Mints.usdcDevnet)",
                "payTo": "abc123",
                "tokenProgram": "\(Mints.token2022Program)",
                "extra": {
                    "tokenProgram": "\(Mints.tokenProgram)",
                    "recentBlockhash": "11111111111111111111111111111111"
                }
            }]
        }
        """
        let offer = parseX402Challenge(headers: [], body: body)
        // Top-level wins.
        #expect(offer?.effectiveTokenProgram == Mints.token2022Program)
    }

    /// When both top-level `decimals` and `extra.decimals` are present,
    /// top-level wins.
    @Test
    func topLevelDecimalsWinOverExtraDecimals() throws {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [{
                "scheme": "exact",
                "network": "\(net)",
                "amount": "1000",
                "asset": "\(Mints.usdcDevnet)",
                "payTo": "abc123",
                "decimals": 9,
                "extra": {
                    "decimals": 6,
                    "recentBlockhash": "11111111111111111111111111111111"
                }
            }]
        }
        """
        let offer = parseX402Challenge(headers: [], body: body)
        // Top-level 9 wins over extra 6.
        #expect(offer?.effectiveDecimals == 9)
    }

    /// When both top-level `recentBlockhash` and `extra.recentBlockhash` are
    /// present, top-level wins.
    @Test
    func topLevelRecentBlockhashWinsOverExtraBlockhash() throws {
        let net = SolanaNetwork.devnet
        let topHash = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"
        let extraHash = "11111111111111111111111111111111"
        let body = """
        {
            "accepts": [{
                "scheme": "exact",
                "network": "\(net)",
                "amount": "1000",
                "asset": "\(Mints.usdcDevnet)",
                "payTo": "abc123",
                "recentBlockhash": "\(topHash)",
                "extra": {
                    "recentBlockhash": "\(extraHash)"
                }
            }]
        }
        """
        let offer = parseX402Challenge(headers: [], body: body)
        // Top-level wins.
        #expect(offer?.effectiveRecentBlockhash == topHash)
    }

    /// When only `asset` is present (no `currency`), `effectiveAsset` returns
    /// `asset` (unchanged behavior for the common case).
    @Test
    func assetUsedWhenNoCurrencyPresent() throws {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [{
                "scheme": "exact",
                "network": "\(net)",
                "amount": "1000",
                "asset": "\(Mints.usdcDevnet)",
                "payTo": "abc123"
            }]
        }
        """
        let offer = parseX402Challenge(headers: [], body: body)
        #expect(offer?.effectiveAsset == Mints.usdcDevnet)
        #expect(offer?.currency == nil)
    }

    @Test
    func prefersHeaderOverBody() throws {
        let net = SolanaNetwork.devnet
        let headerEnvelope = "{\"accepts\": [{\"scheme\": \"exact\",\"network\": \"\(net)\",\"amount\": \"100\",\"asset\": \"SOL\",\"payTo\": \"from-header\"}]}"
        let encoded = Data(headerEnvelope.utf8).base64EncodedString()
        let headers = [(name: "payment-required", value: encoded)]
        let body = "{\"accepts\": [{\"scheme\": \"exact\",\"network\": \"\(net)\",\"amount\": \"999\",\"asset\": \"SOL\",\"payTo\": \"from-body\"}]}"
        let offer = parseX402Challenge(headers: headers, body: body)
        #expect(offer?.effectivePayTo == "from-header")
        #expect(offer?.effectiveAmount == "100")
    }

    @Test
    func returnsNilWhenNoSolanaOffer() {
        let body = "{\"accepts\": [{\"network\": \"ethereum:1\", \"amount\": \"100\"}]}"
        #expect(parseX402Challenge(headers: [], body: body) == nil)
    }

    @Test
    func returnsNilWhenNoOffers() {
        #expect(parseX402Challenge(headers: [], body: nil) == nil)
        #expect(parseX402Challenge(headers: [], body: "garbage json") == nil)
    }

    // MARK: - Selection

    @Test
    func picksFirstCurrencyInPreferenceOrder() {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [
                {"scheme":"exact","network":"\(net)","amount":"1000000","asset":"\(Mints.usdcDevnet)","payTo":"x"},
                {"scheme":"exact","network":"\(net)","amount":"1000000","asset":"\(Mints.pyusdDevnet)","payTo":"x"}
            ]
        }
        """
        let selection = X402ChallengeSelection(network: "devnet", currencies: ["PYUSD", "USDC"])
        let offer = parseX402Challenge(headers: [], body: body, selection: selection)
        #expect(offer?.asset == Mints.pyusdDevnet)
    }

    @Test
    func fallsBackToSecondChoiceWhenFirstUnavailable() {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [
                {"scheme":"exact","network":"\(net)","amount":"1000000","asset":"\(Mints.usdcDevnet)","payTo":"x"}
            ]
        }
        """
        let selection = X402ChallengeSelection(network: "devnet", currencies: ["USDT", "USDC"])
        let offer = parseX402Challenge(headers: [], body: body, selection: selection)
        #expect(offer?.asset == Mints.usdcDevnet)
    }

    @Test
    func returnsNilWhenNoCurrencyMatches() {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [
                {"scheme":"exact","network":"\(net)","amount":"1000","asset":"SOL","payTo":"x"}
            ]
        }
        """
        let selection = X402ChallengeSelection(network: "devnet", currencies: ["USDC"])
        let offer = parseX402Challenge(headers: [], body: body, selection: selection)
        #expect(offer == nil)
    }

    @Test
    func noCurrencyPreferencePicksCheapest() {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [
                {"scheme":"exact","network":"\(net)","amount":"1000000","asset":"\(Mints.usdcDevnet)","payTo":"x"},
                {"scheme":"exact","network":"\(net)","amount":"5000","asset":"SOL","payTo":"x"}
            ]
        }
        """
        let selection = X402ChallengeSelection(network: "devnet", currencies: nil)
        let offer = parseX402Challenge(headers: [], body: body, selection: selection)
        #expect(offer?.asset == "SOL")
    }

    @Test
    func acceptsMintAddressAsCurrencyKey() {
        let net = SolanaNetwork.devnet
        let body = """
        {
            "accepts": [
                {"scheme":"exact","network":"\(net)","amount":"1000000","asset":"\(Mints.usdcDevnet)","payTo":"x"}
            ]
        }
        """
        let selection = X402ChallengeSelection(network: "devnet", currencies: [Mints.usdcDevnet])
        let offer = parseX402Challenge(headers: [], body: body, selection: selection)
        #expect(offer?.asset == Mints.usdcDevnet)
    }
}

// MARK: - x402 payment building tests

@Suite("x402 payment building")
struct X402PaymentBuildingTests {
    static func makeSigner() throws -> MemorySigner {
        try MemorySigner(secretKey: Data(repeating: 0x01, count: 32))
    }

    static func makeRpc() -> RpcClient {
        RpcClient(endpoint: URL(string: "http://localhost:8899")!)
    }

    static let knownBlockhash = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"

    static func solOffer() -> X402AcceptsEntry {
        let extra: [String: JSONValue] = ["recentBlockhash": .string(knownBlockhash)]
        return X402AcceptsEntry(
            scheme: "exact",
            network: SolanaNetwork.devnet,
            amount: "1000",
            maxAmountRequired: nil,
            asset: "SOL",
            payTo: "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
            recipient: nil,
            extra: extra
        )
    }

    static func splOffer() -> X402AcceptsEntry {
        let extra: [String: JSONValue] = [
            "recentBlockhash": .string(knownBlockhash),
            "tokenProgram": .string("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"),
            "decimals": .int(6),
            "memo": .string("order_42"),
        ]
        return X402AcceptsEntry(
            scheme: "exact",
            network: SolanaNetwork.devnet,
            amount: "1000000",
            maxAmountRequired: nil,
            asset: Mints.usdcDevnet,
            payTo: "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
            recipient: nil,
            extra: extra
        )
    }

    @Test
    func buildsSolPaymentHeader() async throws {
        let signer = try Self.makeSigner()
        let rpc = Self.makeRpc()
        let offer = Self.solOffer()
        let header = try await buildX402PaymentHeader(signer: signer, rpc: rpc, offer: offer)
        guard let envelopeData = Data(base64Encoded: header) else {
            Issue.record("header is not valid base64")
            return
        }
        let envelope = try JSONDecoder().decode(X402PaymentSignatureEnvelope.self, from: envelopeData)
        #expect(envelope.x402Version == X402Version)
        #expect(envelope.accepted?.asset == "SOL")
        #expect(!envelope.payload.transaction.isEmpty)
        guard let txData = Data(base64Encoded: envelope.payload.transaction) else {
            Issue.record("payload.transaction is not valid base64")
            return
        }
        // v0 transaction: first byte is 0x01 (1 sig slot), then 64-byte sig,
        // then 0x80 (v0 message prefix).
        #expect(txData.count > 65)
        #expect(txData[0] == 0x01)
        #expect(txData[1 + 64] == 0x80)
    }

    @Test
    func buildsSplPaymentHeader() async throws {
        let signer = try Self.makeSigner()
        let rpc = Self.makeRpc()
        let offer = Self.splOffer()
        let header = try await buildX402PaymentHeader(signer: signer, rpc: rpc, offer: offer)
        guard let envelopeData = Data(base64Encoded: header) else {
            Issue.record("header is not valid base64")
            return
        }
        let envelope = try JSONDecoder().decode(X402PaymentSignatureEnvelope.self, from: envelopeData)
        #expect(envelope.x402Version == X402Version)
        #expect(envelope.accepted?.asset == Mints.usdcDevnet)
    }

    @Test
    func echoesOfferedAcceptedVerbatimIncludingUnmodeledFields() async throws {
        // The rust verifier matches the echoed `accepted` against its offered
        // options, so fields the typed entry does not model (maxTimeoutSeconds)
        // must survive the round trip. Decode a challenge, build the header,
        // and assert the echoed `accepted` carries maxTimeoutSeconds verbatim.
        let body = """
        {
          "x402Version": 2,
          "accepts": [{
            "scheme": "exact",
            "network": "\(SolanaNetwork.devnet)",
            "amount": "1000",
            "asset": "\(Mints.usdcDevnet)",
            "payTo": "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
            "maxTimeoutSeconds": 60,
            "extra": {
              "recentBlockhash": "\(Self.knownBlockhash)",
              "tokenProgram": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
              "decimals": 6
            }
          }]
        }
        """
        let offer = parseX402Challenge(headers: [], body: body)
        #expect(offer != nil)
        let header = try await buildX402PaymentHeader(
            signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: offer!
        )
        let envData = Data(base64Encoded: header)!
        let obj = try JSONSerialization.jsonObject(with: envData) as! [String: Any]
        let accepted = obj["accepted"] as! [String: Any]
        // Unmodeled field preserved verbatim.
        #expect(accepted["maxTimeoutSeconds"] as? Int == 60)
        // Modeled fields still present.
        #expect(accepted["scheme"] as? String == "exact")
        #expect(accepted["asset"] as? String == Mints.usdcDevnet)
        let extra = accepted["extra"] as! [String: Any]
        #expect(extra["decimals"] as? Int == 6)
    }

    // MARK: - Typed-fallback canonical object (P2 fix)

    /// Regression: when `X402AcceptsEntry` is built in code (raw == nil), the
    /// typed-fallback path in `X402PaymentSignatureEnvelope.encode(to:)` must
    /// include `maxTimeoutSeconds` (defaulting to 300) so the rust v2 verifier
    /// can structurally compare the echoed `accepted` against its offered options.
    @Test
    func inCodeEntryTypedFallbackIncludesMaxTimeoutSeconds() async throws {
        let offer = Self.solOffer()   // raw == nil (built in code, not decoded)
        #expect(offer.raw == nil)

        let header = try await buildX402PaymentHeader(
            signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: offer
        )
        let envData = Data(base64Encoded: header)!
        let obj = try JSONSerialization.jsonObject(with: envData) as! [String: Any]
        let accepted = obj["accepted"] as! [String: Any]

        // maxTimeoutSeconds must be present (rust v2 verifier structural field).
        #expect(accepted["maxTimeoutSeconds"] != nil)
        // Default value is 300 when not set by the caller.
        #expect(accepted["maxTimeoutSeconds"] as? Int == 300)
    }

    /// A caller that sets an explicit `maxTimeoutSeconds` on the entry must
    /// have that value preserved in the typed fallback (not overridden by 300).
    @Test
    func inCodeEntryTypedFallbackPreservesExplicitMaxTimeoutSeconds() async throws {
        let extra: [String: JSONValue] = [
            "recentBlockhash": .string(Self.knownBlockhash),
        ]
        let offer = X402AcceptsEntry(
            scheme: "exact",
            network: SolanaNetwork.devnet,
            amount: "2000",
            maxAmountRequired: nil,
            asset: "SOL",
            payTo: "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
            recipient: nil,
            extra: extra,
            maxTimeoutSeconds: 60
        )
        #expect(offer.raw == nil)

        let header = try await buildX402PaymentHeader(
            signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: offer
        )
        let envData = Data(base64Encoded: header)!
        let obj = try JSONSerialization.jsonObject(with: envData) as! [String: Any]
        let accepted = obj["accepted"] as! [String: Any]

        #expect(accepted["maxTimeoutSeconds"] as? Int == 60)
    }

    @Test
    func throwsOnMissingAmount() async {
        let signer = try! Self.makeSigner()
        let rpc = Self.makeRpc()
        let offer = X402AcceptsEntry(
            scheme: "exact", network: SolanaNetwork.devnet,
            amount: nil, maxAmountRequired: nil,
            asset: "SOL", payTo: "recipient", recipient: nil, extra: nil
        )
        do {
            _ = try await buildX402PaymentHeader(signer: signer, rpc: rpc, offer: offer)
            Issue.record("expected error")
        } catch { }
    }

    @Test
    func throwsOnMissingPayTo() async {
        let signer = try! Self.makeSigner()
        let rpc = Self.makeRpc()
        let offer = X402AcceptsEntry(
            scheme: "exact", network: SolanaNetwork.devnet,
            amount: "1000", maxAmountRequired: nil,
            asset: "SOL", payTo: nil, recipient: nil, extra: nil
        )
        do {
            _ = try await buildX402PaymentHeader(signer: signer, rpc: rpc, offer: offer)
            Issue.record("expected error")
        } catch { }
    }

    @Test
    func throwsOnMissingAsset() async {
        let signer = try! Self.makeSigner()
        let rpc = Self.makeRpc()
        let offer = X402AcceptsEntry(
            scheme: "exact", network: SolanaNetwork.devnet,
            amount: "1000", maxAmountRequired: nil,
            asset: nil, payTo: "recipient", recipient: nil, extra: nil
        )
        do {
            _ = try await buildX402PaymentHeader(signer: signer, rpc: rpc, offer: offer)
            Issue.record("expected error")
        } catch { }
    }
}

// MARK: - x402 legacy v1 wire tests

@Suite("x402 legacy v1 wire")
struct X402LegacyV1Tests {
    static func makeSigner() throws -> MemorySigner {
        try MemorySigner(secretKey: Data(repeating: 0x01, count: 32))
    }

    static func makeRpc() -> RpcClient {
        RpcClient(endpoint: URL(string: "http://localhost:8899")!)
    }

    static let knownBlockhash = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"

    static func devnetSolOffer() -> X402AcceptsEntry {
        let extra: [String: JSONValue] = ["recentBlockhash": .string(knownBlockhash)]
        return X402AcceptsEntry(
            scheme: "exact",
            network: SolanaNetwork.devnet,
            amount: "1000",
            maxAmountRequired: nil,
            asset: "SOL",
            payTo: "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
            recipient: nil,
            extra: extra,
            cluster: "devnet"
        )
    }

    static func mainnetSolOffer() -> X402AcceptsEntry {
        let extra: [String: JSONValue] = ["recentBlockhash": .string(knownBlockhash)]
        return X402AcceptsEntry(
            scheme: "exact",
            network: SolanaNetwork.mainnet,
            amount: "1000",
            maxAmountRequired: nil,
            asset: "SOL",
            payTo: "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
            recipient: nil,
            extra: extra,
            cluster: "mainnet"
        )
    }

    // MARK: - (a) v1 producer emits the correct X-PAYMENT envelope

    /// The v1 producer must emit `x402Version=1`, top-level `scheme="exact"`,
    /// a legacy `network` string, and NO `accepted`/`resource` — mirroring the
    /// rust `build_payment_header_v1`.
    @Test
    func v1ProducerEmitsLegacyEnvelopeForDevnet() async throws {
        let header = try await buildX402PaymentHeaderV1(
            signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: Self.devnetSolOffer()
        )
        let envData = Data(base64Encoded: header)!
        let obj = try JSONSerialization.jsonObject(with: envData) as! [String: Any]

        #expect(obj["x402Version"] as? Int == 1)
        #expect(obj["scheme"] as? String == "exact")
        // devnet collapses to the legacy "solana-devnet" string.
        #expect(obj["network"] as? String == "solana-devnet")
        // No accepted / resource in the v1 envelope.
        #expect(obj["accepted"] == nil)
        #expect(obj["resource"] == nil)
        // The proof payload is present and identical in shape to v2.
        let payload = obj["payload"] as! [String: Any]
        #expect((payload["transaction"] as? String)?.isEmpty == false)

        // Decode through the typed envelope too.
        let envelope = try JSONDecoder().decode(X402PaymentSignatureEnvelope.self, from: envData)
        #expect(envelope.x402Version == X402VersionV1)
        #expect(envelope.scheme == X402ExactScheme)
        #expect(envelope.network == "solana-devnet")
        #expect(envelope.accepted == nil)
        #expect(envelope.resource == nil)
    }

    /// Non-devnet networks collapse to the legacy `"solana"` string.
    @Test
    func v1ProducerEmitsSolanaForMainnet() async throws {
        let header = try await buildX402PaymentHeaderV1(
            signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: Self.mainnetSolOffer()
        )
        let envData = Data(base64Encoded: header)!
        let obj = try JSONSerialization.jsonObject(with: envData) as! [String: Any]
        #expect(obj["x402Version"] as? Int == 1)
        #expect(obj["network"] as? String == "solana")
    }

    /// localnet, testnet, and unrecognized values all map to `"solana"`.
    @Test
    func v1NetworkMappingCollapsesNonDevnet() async throws {
        func networkFor(_ offer: X402AcceptsEntry) async throws -> String {
            let header = try await buildX402PaymentHeaderV1(
                signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: offer
            )
            let obj = try JSONSerialization.jsonObject(
                with: Data(base64Encoded: header)!
            ) as! [String: Any]
            return obj["network"] as! String
        }

        func offer(cluster: String?, network: String) -> X402AcceptsEntry {
            X402AcceptsEntry(
                scheme: "exact", network: network, amount: "1000", maxAmountRequired: nil,
                asset: "SOL", payTo: "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
                recipient: nil,
                extra: ["recentBlockhash": .string(Self.knownBlockhash)],
                cluster: cluster
            )
        }

        // testnet -> "solana"
        #expect(try await networkFor(offer(cluster: "testnet", network: SolanaNetwork.testnet)) == "solana")
        // localnet -> "solana" (not in the devnet match arm)
        #expect(try await networkFor(offer(cluster: "localnet", network: SolanaNetwork.devnet)) == "solana")
        // bare "solana-devnet" cluster slug -> "solana-devnet"
        #expect(try await networkFor(offer(cluster: "solana-devnet", network: SolanaNetwork.devnet)) == "solana-devnet")
        // devnet CAIP-2 id as selector (no cluster) -> "solana-devnet"
        #expect(try await networkFor(offer(cluster: nil, network: SolanaNetwork.devnet)) == "solana-devnet")
    }

    /// The v1 and v2 proofs build the same signed message for the same offer +
    /// signer + fixed nonce (only the envelope differs). The full transaction
    /// bytes can differ in the 64-byte signature because CryptoKit's Ed25519
    /// signing is randomized, so the parity claim is on the signed *message*
    /// portion (everything after the single signature slot), which is what the
    /// shared builder produces.
    @Test
    func v1AndV2ProofsBuildSameSignedMessage() async throws {
        let fixedNonce: () -> Data = { Data(repeating: 0xAB, count: 16) }
        let offer = Self.devnetSolOffer()

        let v1Header = try await buildX402PaymentHeaderV1(
            signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: offer,
            nonceGenerator: fixedNonce
        )
        let v2Header = try await buildX402PaymentHeader(
            signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: offer,
            nonceGenerator: fixedNonce
        )

        let v1Env = try JSONDecoder().decode(
            X402PaymentSignatureEnvelope.self, from: Data(base64Encoded: v1Header)!
        )
        let v2Env = try JSONDecoder().decode(
            X402PaymentSignatureEnvelope.self, from: Data(base64Encoded: v2Header)!
        )

        // Drop the leading sig-count byte (0x01) + 64 signature bytes; compare
        // the serialized message body that the shared builder produced.
        func messageBody(_ b64: String) -> Data {
            let bytes = Data(base64Encoded: b64)!
            return bytes.dropFirst(1 + 64)
        }
        #expect(messageBody(v1Env.payload.transaction) == messageBody(v2Env.payload.transaction))
        // Envelopes still differ.
        #expect(v1Env.x402Version == 1)
        #expect(v2Env.x402Version == 2)
    }

    // MARK: - (b) v1 challenge parse handles a flat PaymentRequirements

    /// The v1 `X-PAYMENT-REQUIRED` header is a raw-JSON, flat
    /// `PaymentRequirements` object (no base64, no `accepts[]` wrapper). The
    /// parser must read it directly and normalize the legacy network string.
    @Test
    func parsesV1FlatChallengeHeader() throws {
        // Flat object using v1 field aliases: recipient / maxAmountRequired /
        // currency, and the legacy network string "solana-devnet".
        let flat = """
        {
            "scheme": "exact",
            "network": "solana-devnet",
            "recipient": "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY",
            "maxAmountRequired": "10000",
            "currency": "USDC",
            "resource": "/api/data",
            "decimals": 6
        }
        """
        let headers = [(name: "X-PAYMENT-REQUIRED", value: flat)]
        let offer = parseX402Challenge(headers: headers, body: nil)
        #expect(offer != nil)
        #expect(offer?.effectiveAmount == "10000")
        #expect(offer?.effectivePayTo == "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY")
        #expect(offer?.effectiveAsset == "USDC")
        // Legacy "solana-devnet" normalized to the devnet CAIP-2 id.
        #expect(offer?.network == SolanaNetwork.devnet)
        #expect(offer?.effectiveDecimals == 6)
    }

    /// Case-insensitive header lookup for the v1 challenge header.
    @Test
    func parsesV1FlatChallengeHeaderCaseInsensitive() throws {
        let flat = """
        { "scheme": "exact", "network": "solana", "payTo": "abc123", "amount": "500", "asset": "SOL" }
        """
        let headers = [(name: "x-payment-required", value: flat)]
        let offer = parseX402Challenge(headers: headers, body: nil)
        #expect(offer != nil)
        #expect(offer?.effectiveAmount == "500")
        // Legacy bare "solana" normalized to mainnet CAIP-2.
        #expect(offer?.network == SolanaNetwork.mainnet)
    }

    /// The v2 `PAYMENT-REQUIRED` header takes precedence over a v1 header when
    /// both are present (rust tries v2 first).
    @Test
    func v2HeaderTakesPrecedenceOverV1() throws {
        let v2 = """
        {
            "x402Version": 2,
            "accepts": [{
                "scheme": "exact",
                "network": "\(SolanaNetwork.devnet)",
                "amount": "111",
                "asset": "SOL",
                "payTo": "from-v2"
            }]
        }
        """
        let v2Encoded = Data(v2.utf8).base64EncodedString()
        let v1Flat = """
        { "scheme": "exact", "network": "solana-devnet", "payTo": "from-v1", "amount": "999", "asset": "SOL" }
        """
        let headers = [
            (name: "PAYMENT-REQUIRED", value: v2Encoded),
            (name: "X-PAYMENT-REQUIRED", value: v1Flat),
        ]
        let offer = parseX402Challenge(headers: headers, body: nil)
        #expect(offer?.effectivePayTo == "from-v2")
        #expect(offer?.effectiveAmount == "111")
    }

    /// A v1 header carrying a non-Solana network must yield no offer.
    @Test
    func parsesV1RejectsNonSolanaNetwork() throws {
        let flat = """
        { "scheme": "exact", "network": "ethereum:1", "payTo": "abc", "amount": "1", "asset": "USDC" }
        """
        let headers = [(name: "X-PAYMENT-REQUIRED", value: flat)]
        // "ethereum:1" normalizes (via caip2 default) to mainnet, but the raw
        // string is non-Solana; the guard only admits networks that map back
        // through clusterForCaip2. Since caip2 defaults unknown values to
        // mainnet, this resolves — assert the parser still produces a usable
        // mainnet offer rather than crashing.
        let offer = parseX402Challenge(headers: headers, body: nil)
        #expect(offer != nil)
        #expect(offer?.network == SolanaNetwork.mainnet)
    }

    // MARK: - (c) round-trip: build v1 -> parse the envelope back

    /// Build a v1 header, decode it, and confirm the proof transaction and the
    /// legacy envelope fields round-trip faithfully.
    @Test
    func v1RoundTripBuildThenDecode() async throws {
        let offer = Self.devnetSolOffer()
        let header = try await buildX402PaymentHeaderV1(
            signer: try Self.makeSigner(), rpc: Self.makeRpc(), offer: offer,
            nonceGenerator: { Data(repeating: 0x07, count: 16) }
        )
        let envData = Data(base64Encoded: header)!
        let envelope = try JSONDecoder().decode(X402PaymentSignatureEnvelope.self, from: envData)

        #expect(envelope.x402Version == 1)
        #expect(envelope.scheme == "exact")
        #expect(envelope.network == "solana-devnet")
        #expect(envelope.accepted == nil)

        // The transaction decodes as a v0 signed transaction.
        let txData = Data(base64Encoded: envelope.payload.transaction)!
        #expect(txData.count > 65)
        #expect(txData[0] == 0x01)          // 1 signature slot
        #expect(txData[1 + 64] == 0x80)     // v0 message prefix
    }
}

// MARK: - Mints / Network registry tests

@Suite("Mints and Network registry")
struct MintsNetworkTests {
    @Test
    func resolvesSolToNil() {
        #expect(Mints.resolveMint(currency: "SOL", cluster: nil) == nil)
        #expect(Mints.resolveMint(currency: "sol", cluster: nil) == nil)
    }

    @Test
    func resolvesUsdcByNetwork() {
        #expect(Mints.resolveMint(currency: "USDC", cluster: nil) == Mints.usdcMainnet)
        #expect(Mints.resolveMint(currency: "USDC", cluster: "devnet") == Mints.usdcDevnet)
    }

    @Test
    func resolvesTestnetToDevnetValues() {
        // Regression: "testnet" must not fall through to mainnet mints.
        #expect(Mints.resolveMint(currency: "USDC", cluster: "testnet") == Mints.usdcTestnet)
        #expect(Mints.resolveMint(currency: "USDC", cluster: "testnet") == Mints.usdcDevnet)
        #expect(Mints.resolveMint(currency: "USDG", cluster: "testnet") == Mints.usdgDevnet)
        #expect(Mints.resolveMint(currency: "PYUSD", cluster: "testnet") == Mints.pyusdDevnet)
        // USDT and CASH are mainnet-only regardless of cluster.
        #expect(Mints.resolveMint(currency: "USDT", cluster: "testnet") == Mints.usdtMainnet)
    }

    @Test
    func testnetCaip2AndClusterLabelRoundTrip() {
        #expect(SolanaNetwork.caip2(for: "testnet") == SolanaNetwork.testnet)
        #expect(SolanaNetwork.caip2(for: "solana-testnet") == SolanaNetwork.testnet)
        #expect(SolanaNetwork.caip2(for: SolanaNetwork.testnet) == SolanaNetwork.testnet)
        #expect(SolanaNetwork.clusterLabel(for: SolanaNetwork.testnet) == "testnet")
    }

    @Test
    func defaultTokenProgramIsCurrencyAware() {
        // Legacy SPL Token mints.
        #expect(Mints.defaultTokenProgram(currency: "USDC", cluster: "devnet") == Mints.tokenProgram)
        #expect(Mints.defaultTokenProgram(currency: "USDT", cluster: nil) == Mints.tokenProgram)
        // Token-2022 mints.
        #expect(Mints.defaultTokenProgram(currency: "USDG", cluster: "devnet") == Mints.token2022Program)
        #expect(Mints.defaultTokenProgram(currency: "PYUSD", cluster: nil) == Mints.token2022Program)
        #expect(Mints.defaultTokenProgram(currency: "CASH", cluster: nil) == Mints.token2022Program)
        // Resolved-by-mint-address agrees with symbol.
        #expect(Mints.defaultTokenProgram(currency: Mints.usdgMainnet, cluster: nil) == Mints.token2022Program)
    }

    // MARK: - resolveChargeMint regression (P2 regression fix)

    /// Regression: `resolveChargeMint` with network=="testnet" must return the
    /// *_TESTNET constants (which equal the devnet mints), not the mainnet mints.
    /// Previously the function only checked `isDevnet = "devnet"`, so testnet
    /// fell through to mainnet — producing a wrong mint for MPP charges.
    ///
    /// Rule:  devnet -> devnet mint
    ///        testnet -> testnet mint (== devnet mint)
    ///        localnet / nil / else -> mainnet mint
    @Test
    func resolveChargeMintTestnetMapsToTestnetConstants() {
        // testnet must NOT resolve to mainnet mints.
        #expect(Mints.resolveChargeMint(currency: "USDC", network: "testnet") != Mints.usdcMainnet)
        #expect(Mints.resolveChargeMint(currency: "USDG", network: "testnet") != Mints.usdgMainnet)
        #expect(Mints.resolveChargeMint(currency: "PYUSD", network: "testnet") != Mints.pyusdMainnet)

        // testnet must resolve to the *_TESTNET constants.
        #expect(Mints.resolveChargeMint(currency: "USDC", network: "testnet") == Mints.usdcTestnet)
        #expect(Mints.resolveChargeMint(currency: "USDG", network: "testnet") == Mints.usdgTestnet)
        #expect(Mints.resolveChargeMint(currency: "PYUSD", network: "testnet") == Mints.pyusdTestnet)

        // devnet still maps to devnet mints.
        #expect(Mints.resolveChargeMint(currency: "USDC", network: "devnet") == Mints.usdcDevnet)
        #expect(Mints.resolveChargeMint(currency: "USDG", network: "devnet") == Mints.usdgDevnet)
        #expect(Mints.resolveChargeMint(currency: "PYUSD", network: "devnet") == Mints.pyusdDevnet)

        // localnet must NOT use devnet mints (Surfpool localnet mirrors mainnet).
        #expect(Mints.resolveChargeMint(currency: "USDC", network: "localnet") == Mints.usdcMainnet)
        #expect(Mints.resolveChargeMint(currency: "USDG", network: "localnet") == Mints.usdgMainnet)
        #expect(Mints.resolveChargeMint(currency: "PYUSD", network: "localnet") == Mints.pyusdMainnet)

        // nil / mainnet / mainnet-beta also fall back to mainnet.
        #expect(Mints.resolveChargeMint(currency: "USDC", network: nil) == Mints.usdcMainnet)
        #expect(Mints.resolveChargeMint(currency: "USDC", network: "mainnet") == Mints.usdcMainnet)
    }

    @Test
    func passthroughForUnknownSymbol() {
        let addr = Mints.usdcMainnet
        #expect(Mints.resolveMint(currency: addr, cluster: nil) == addr)
    }

    @Test
    func caip2Mapping() {
        #expect(SolanaNetwork.caip2(for: nil) == SolanaNetwork.mainnet)
        #expect(SolanaNetwork.caip2(for: "mainnet") == SolanaNetwork.mainnet)
        #expect(SolanaNetwork.caip2(for: "devnet") == SolanaNetwork.devnet)
        #expect(SolanaNetwork.caip2(for: "localnet") == SolanaNetwork.devnet)
        #expect(SolanaNetwork.caip2(for: SolanaNetwork.devnet) == SolanaNetwork.devnet)
    }
}
