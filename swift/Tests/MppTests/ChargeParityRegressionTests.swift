import Foundation
import Testing
@testable import Mpp
import PayCore

// Regression tests pinning the swift mpp charge client to the rust canonical
// spine (`rust/crates/mpp`). Each test asserts rust-matching behaviour the
// pre-fix swift implementation diverged from.

@Suite("mpp charge rust-parity regressions", .serialized)
struct ChargeParityRegressionTests {
    /// Minimal legacy-message decoder: returns the program id of each
    /// instruction. Legacy messages have no version prefix byte.
    static func instructionProgramIds(base64: String) throws -> [Pubkey] {
        let txBytes = Data(base64Encoded: base64)!
        var offset = 0
        let sigCount = try ShortVec.decodeLength(txBytes, at: &offset)
        offset += sigCount * 64
        // Header: 3 bytes.
        offset += 3
        let keyCount = try ShortVec.decodeLength(txBytes, at: &offset)
        var keys: [Pubkey] = []
        for _ in 0..<keyCount {
            let raw = txBytes.subdata(in: offset..<(offset + 32))
            keys.append(try Pubkey(bytes: raw))
            offset += 32
        }
        offset += 32 // blockhash
        let ixCount = try ShortVec.decodeLength(txBytes, at: &offset)
        var programIds: [Pubkey] = []
        for _ in 0..<ixCount {
            let progIdx = Int(txBytes[txBytes.startIndex + offset]); offset += 1
            let acctCount = try ShortVec.decodeLength(txBytes, at: &offset)
            offset += acctCount
            let dataLen = try ShortVec.decodeLength(txBytes, at: &offset)
            offset += dataLen
            programIds.append(keys[progIdx])
        }
        return programIds
    }

    static func transactionBase64(fromCredentialHeader header: String) throws -> String {
        let credEncoded = String(header.dropFirst("Payment ".count))
        let credData = try Base64URL.decode(credEncoded)
        let credential = try JSONDecoder().decode(PaymentCredential.self, from: credData)
        guard case let .transaction(tx) = credential.payload else {
            throw PayCoreError.invalidTransaction("expected transaction payload")
        }
        return tx
    }

    static let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    static let recipient = "5wEwLBR3aTGdz8wWUFKafdGiLcQNqotQK1ndJxXLfHir"
    static let splitRecipient = "11111111111111111111111111111112"

    // MARK: - feePayer=true with missing feePayerKey falls back to signer

    /// Rust client computes
    /// `use_fee_payer = fee_payer.unwrap_or(false) && fee_payer_key.is_some()`
    /// (`charge.rs:96`): a `feePayer == true` request without a `feePayerKey`
    /// does NOT use a server fee payer, the signer pays. Pre-fix swift threw.
    /// And because rust keys split ATA-creation off `fee_payer.is_none()`
    /// (`charge.rs:413`), every split owner still gets an idempotent ATA
    /// create in this case.
    @Test
    func feePayerTrueWithoutKeyFallsBackAndCreatesAtas() async throws {
        let signer = try MemorySigner(secretKey: Data(repeating: 7, count: 32))
        let blockhash = Base58.encode(Data(repeating: 0x11, count: 32))
        let requestJson = """
        {
          "amount": "1000",
          "currency": "\(Self.mint)",
          "recipient": "\(Self.recipient)",
          "methodDetails": {
            "network": "localnet",
            "decimals": 6,
            "feePayer": true,
            "recentBlockhash": "\(blockhash)",
            "splits": [
              {"recipient": "\(Self.splitRecipient)", "amount": "100"}
            ],
            "tokenProgram": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
          }
        }
        """
        let requestB64 = Base64URL.encode(Data(requestJson.utf8))
        let challenge = try PaymentChallenge(
            id: "ch-fp",
            realm: "MPP Payment",
            method: "solana",
            intent: "charge",
            request: requestB64
        )

        // Pre-fix swift threw here; now it must succeed.
        let header = try await Charge.buildPullCredential(challenge: challenge, signer: signer)
        let tx = try Self.transactionBase64(fromCredentialHeader: header)
        let programIds = try Self.instructionProgramIds(base64: tx)

        // With no actual fee payer, the split owner gets an idempotent ATA
        // create (rust `fee_payer.is_none()`).
        let ataCreates = programIds.filter { $0 == .associatedTokenProgram }.count
        #expect(ataCreates == 1)

        // The fee payer must be the signer (account key 0), not a server key.
        let txBytes = Data(base64Encoded: tx)!
        var offset = 0
        let sigCount = try ShortVec.decodeLength(txBytes, at: &offset)
        offset += sigCount * 64 + 3
        _ = try ShortVec.decodeLength(txBytes, at: &offset)
        let feePayerKey = try Pubkey(bytes: txBytes.subdata(in: offset..<(offset + 32)))
        #expect(feePayerKey == (try Pubkey(bytes: signer.publicKey)))
    }

    /// When a server fee payer IS present (feePayer == true AND feePayerKey
    /// set), a split without `ataCreationRequired` must NOT get an ATA create,
    /// matching rust `fee_payer.is_none() || ata_creation_required` being
    /// false here.
    @Test
    func serverFeePayerSuppressesUnflaggedSplitAtaCreate() async throws {
        let signer = try MemorySigner(secretKey: Data(repeating: 8, count: 32))
        let blockhash = Base58.encode(Data(repeating: 0x22, count: 32))
        let feePayerKey = "CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY"
        let requestJson = """
        {
          "amount": "1000",
          "currency": "\(Self.mint)",
          "recipient": "\(Self.recipient)",
          "methodDetails": {
            "network": "localnet",
            "decimals": 6,
            "feePayer": true,
            "feePayerKey": "\(feePayerKey)",
            "recentBlockhash": "\(blockhash)",
            "splits": [
              {"recipient": "\(Self.splitRecipient)", "amount": "100"}
            ],
            "tokenProgram": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
          }
        }
        """
        let requestB64 = Base64URL.encode(Data(requestJson.utf8))
        let challenge = try PaymentChallenge(
            id: "ch-fp2",
            realm: "MPP Payment",
            method: "solana",
            intent: "charge",
            request: requestB64
        )
        let header = try await Charge.buildPullCredential(challenge: challenge, signer: signer)
        let tx = try Self.transactionBase64(fromCredentialHeader: header)
        let programIds = try Self.instructionProgramIds(base64: tx)
        let ataCreates = programIds.filter { $0 == .associatedTokenProgram }.count
        #expect(ataCreates == 0)
    }

    // MARK: - selectChallenge currency/network filtering

    private static func chargeChallenge(
        id: String,
        method: String,
        currency: String,
        network: String
    ) throws -> PaymentChallenge {
        let requestJson = """
        {
          "amount": "1000",
          "currency": "\(currency)",
          "recipient": "\(Self.recipient)",
          "methodDetails": { "network": "\(network)", "decimals": 6 }
        }
        """
        return try PaymentChallenge(
            id: id,
            realm: "MPP Payment",
            method: method,
            intent: "charge",
            request: Base64URL.encode(Data(requestJson.utf8))
        )
    }

    /// Rust `select_charge_challenge` filters candidates by network then by
    /// currency preference, in preference order (`charge.rs:246`). Pre-fix
    /// swift only had `pickChallenge`, which returned the first solana/charge
    /// challenge regardless of currency or network.
    @Test
    func selectChallengePicksByCurrencyPreference() throws {
        let challenges = [
            try Self.chargeChallenge(id: "a", method: "solana", currency: "USDC", network: "devnet"),
            try Self.chargeChallenge(id: "b", method: "solana", currency: "USDT", network: "devnet"),
        ]
        let selected = try Charge.selectChallenge(
            challenges: challenges,
            options: Charge.SelectChallengeOptions(
                currencyPreferences: ["USDT"],
                network: "devnet"
            )
        )
        #expect(selected?.id == "b")
    }

    /// A network filter drops challenges on other networks.
    @Test
    func selectChallengeFiltersByNetwork() throws {
        let challenges = [
            try Self.chargeChallenge(id: "a", method: "solana", currency: "USDC", network: "mainnet-beta"),
            try Self.chargeChallenge(id: "b", method: "solana", currency: "USDC", network: "devnet"),
        ]
        let selected = try Charge.selectChallenge(
            challenges: challenges,
            options: Charge.SelectChallengeOptions(network: "devnet")
        )
        #expect(selected?.id == "b")
    }

    /// With a currency preference and no match, rust returns `None`; swift
    /// must return `nil` rather than the first candidate.
    @Test
    func selectChallengeReturnsNilWhenNoCurrencyMatches() throws {
        let challenges = [
            try Self.chargeChallenge(id: "a", method: "solana", currency: "USDC", network: "devnet"),
        ]
        let selected = try Charge.selectChallenge(
            challenges: challenges,
            options: Charge.SelectChallengeOptions(currencyPreferences: ["USDT"], network: "devnet")
        )
        #expect(selected == nil)
    }

    // MARK: - Combined WWW-Authenticate header splitting

    /// Rust `parse_www_authenticate_all` splits a single header value that
    /// packs multiple `Payment ...` challenges (`headers.rs:70`). Pre-fix
    /// swift parsed only a single challenge per header string.
    @Test
    func pickChallengeSplitsCombinedHeaderValue() throws {
        let reqA = Base64URL.encode(Data("""
        {"amount":"1","currency":"USDC","recipient":"\(Self.recipient)","methodDetails":{"network":"devnet"}}
        """.utf8))
        let reqB = Base64URL.encode(Data("""
        {"amount":"2","currency":"USDT","recipient":"\(Self.recipient)","methodDetails":{"network":"devnet"}}
        """.utf8))
        // Two Payment challenges combined into a single header value.
        let combined = "Payment id=\"a\", realm=\"MPP Payment\", method=\"http\", intent=\"charge\", request=\"\(reqA)\", " +
            "Payment id=\"b\", realm=\"MPP Payment\", method=\"solana\", intent=\"charge\", request=\"\(reqB)\""

        let picked = try Charge.pickChallenge(wwwAuthenticateHeaders: [combined])
        // The first chunk is method="http" (skipped); the solana/charge chunk
        // must be recovered from the same combined value.
        #expect(picked.id == "b")
        #expect(picked.method == "solana")
    }

    @Test
    func parseAllRecoversBothChallengesFromCombinedValue() throws {
        let req = Base64URL.encode(Data("""
        {"amount":"1","currency":"USDC","recipient":"\(Self.recipient)","methodDetails":{"network":"devnet"}}
        """.utf8))
        let combined = "Payment id=\"a\", realm=\"r\", method=\"solana\", intent=\"charge\", request=\"\(req)\", " +
            "Payment id=\"b\", realm=\"r\", method=\"solana\", intent=\"charge\", request=\"\(req)\""
        let all = MppHeaders.parseWWWAuthenticateAll([combined])
        #expect(all.count == 2)
        #expect(all.map { $0.id } == ["a", "b"])
    }
}
