import Foundation
import Testing
@testable import X402
import PayCore

// Regression tests pinning the swift x402 client to the rust canonical
// spine (`rust/crates/x402`). Each test asserts the rust-matching behaviour
// that the pre-fix swift implementation diverged from.

@Suite("x402 rust-parity regressions")
struct X402ParityRegressionTests {
    private static let blockhash = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"
    private static let payTo = "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY"

    private static func signer() throws -> MemorySigner {
        try MemorySigner(secretKey: Data(repeating: 0x01, count: 32))
    }

    private static func rpc() -> RpcClient {
        RpcClient(endpoint: URL(string: "http://localhost:8899")!)
    }

    private static func splOffer(
        extra: [String: JSONValue],
        resource: String? = nil,
        description: String? = nil
    ) -> X402AcceptsEntry {
        var base: [String: JSONValue] = [
            "recentBlockhash": .string(blockhash),
            "tokenProgram": .string(Mints.tokenProgram),
            "decimals": .int(6),
        ]
        for (key, value) in extra { base[key] = value }
        return X402AcceptsEntry(
            scheme: "exact",
            network: SolanaNetwork.devnet,
            amount: "20000",
            maxAmountRequired: nil,
            asset: Mints.usdcDevnet,
            payTo: payTo,
            recipient: nil,
            extra: base,
            resource: resource,
            description: description
        )
    }

    private static func decodePayload(_ header: String) throws -> DecodedTx {
        let envData = Data(base64Encoded: header)!
        let env = try JSONDecoder().decode(X402PaymentSignatureEnvelope.self, from: envData)
        return try TxDecoder.decode(base64: env.payload.transaction)
    }

    // MARK: - Empty extra.memo emits a zero-length memo (not a random nonce)

    /// Rust `memo_instruction` emits `memo.as_bytes()` for any `Some(memo)`,
    /// including `""` (`payment.rs:350`); the verifier then expects exactly
    /// that empty memo (`verify.rs:277`). Pre-fix swift collapsed an empty
    /// `extra.memo` to `nil` and generated a random nonce instead, which the
    /// rust verifier would reject as a memo mismatch.
    @Test
    func emptyExtraMemoEmitsZeroLengthMemo() async throws {
        let header = try await buildX402PaymentHeader(
            signer: try Self.signer(),
            rpc: Self.rpc(),
            offer: Self.splOffer(extra: ["memo": .string("")])
        )
        let tx = try Self.decodePayload(header)
        #expect(tx.instructions.count == 4)
        let memoIx = tx.instructions[3]
        #expect(tx.accountKeys[memoIx.programIdIndex] == Pubkey.memoProgram)
        // Zero-length memo data, not a 32-char hex nonce.
        #expect(memoIx.data.isEmpty)
    }

    // MARK: - Payment-Signature envelope carries resource

    /// Rust `build_payment_header` sets `resource: requirements.resource_info()`
    /// (`payment.rs:136`). Pre-fix swift omitted the field entirely.
    @Test
    func paymentSignatureEnvelopeCarriesResource() async throws {
        let header = try await buildX402PaymentHeader(
            signer: try Self.signer(),
            rpc: Self.rpc(),
            offer: Self.splOffer(
                extra: ["memo": .string("m")],
                resource: "https://api.example.com/weather",
                description: "Weather data"
            )
        )
        let envData = Data(base64Encoded: header)!
        let env = try JSONDecoder().decode(X402PaymentSignatureEnvelope.self, from: envData)
        #expect(env.resource?.url == "https://api.example.com/weather")
        #expect(env.resource?.description == "Weather data")

        // The raw JSON must contain a top-level "resource" object.
        let json = try #require(
            JSONSerialization.jsonObject(with: envData) as? [String: Any]
        )
        let resource = try #require(json["resource"] as? [String: Any])
        #expect(resource["url"] as? String == "https://api.example.com/weather")
    }

    /// An offer with no resource URL must not emit a `resource` field, matching
    /// rust `resource_info()` returning `None` for an empty resource.
    @Test
    func paymentSignatureEnvelopeOmitsAbsentResource() async throws {
        let header = try await buildX402PaymentHeader(
            signer: try Self.signer(),
            rpc: Self.rpc(),
            offer: Self.splOffer(extra: ["memo": .string("m")])
        )
        let envData = Data(base64Encoded: header)!
        let json = try #require(
            JSONSerialization.jsonObject(with: envData) as? [String: Any]
        )
        #expect(json["resource"] == nil)
    }

    // MARK: - Offer eligibility filter selects by network, not scheme

    /// Rust selection filters on `cluster_for_caip2_network(network).is_some()`
    /// (`payment.rs:303`) and never inspects `scheme`. Pre-fix swift required
    /// `scheme == "exact"`, so a scheme-less offer was dropped.
    @Test
    func selectsOfferWithMissingScheme() throws {
        let envelope = """
        {
            "x402Version": 2,
            "accepts": [{
                "network": "\(SolanaNetwork.devnet)",
                "amount": "1000",
                "asset": "\(Mints.usdcDevnet)",
                "payTo": "\(Self.payTo)"
            }]
        }
        """
        let headers = [(name: "PAYMENT-REQUIRED", value: Data(envelope.utf8).base64EncodedString())]
        let offer = parseX402Challenge(
            headers: headers,
            body: nil,
            selection: X402ChallengeSelection(network: "devnet")
        )
        #expect(offer?.scheme == nil)
        #expect(offer?.effectiveAmount == "1000")
    }

    /// Rust accepts any `solana:*` id (`types.rs:50`). The legacy bare
    /// `"solana"` alias maps to mainnet and is eligible.
    @Test
    func selectsLegacySolanaAliasOnMainnet() throws {
        let envelope = """
        {
            "x402Version": 2,
            "accepts": [{
                "scheme": "exact",
                "network": "solana",
                "amount": "1000",
                "asset": "USDC",
                "payTo": "\(Self.payTo)"
            }]
        }
        """
        let headers = [(name: "PAYMENT-REQUIRED", value: Data(envelope.utf8).base64EncodedString())]
        let offer = parseX402Challenge(
            headers: headers,
            body: nil,
            selection: X402ChallengeSelection(network: "mainnet")
        )
        #expect(offer?.network == "solana")
    }

    // MARK: - Preferred-network match honours the cluster slug

    /// Rust `network_matches` also matches when the offer's `cluster` slug maps
    /// back to the preferred CAIP-2 id (`payment.rs:294`). An offer whose
    /// `network` is a non-canonical solana id but whose `cluster` is `devnet`
    /// must match a devnet preference.
    @Test
    func preferredNetworkMatchesViaClusterSlug() throws {
        let envelope = """
        {
            "x402Version": 2,
            "accepts": [{
                "scheme": "exact",
                "network": "solana:somethingelse00000000000000000000",
                "cluster": "devnet",
                "amount": "1000",
                "asset": "\(Mints.usdcDevnet)",
                "payTo": "\(Self.payTo)"
            }]
        }
        """
        let headers = [(name: "PAYMENT-REQUIRED", value: Data(envelope.utf8).base64EncodedString())]
        let offer = parseX402Challenge(
            headers: headers,
            body: nil,
            selection: X402ChallengeSelection(network: "devnet")
        )
        #expect(offer?.cluster == "devnet")
        #expect(offer?.effectiveAmount == "1000")
    }
}
