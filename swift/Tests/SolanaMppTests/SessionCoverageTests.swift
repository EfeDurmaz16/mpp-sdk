import Foundation
import Testing
@testable import SolanaMpp

// MARK: - Helpers shared across this file

private func makeChannel(seed: UInt8 = 3) throws -> Pubkey {
    try Pubkey(bytes: Data(repeating: seed, count: 32))
}

private func makeRealSigner(seed: UInt8 = 42) throws -> MemorySigner {
    try MemorySigner(secretKey: Data(repeating: seed, count: 32))
}

/// A fake signer whose `sign` returns the wrong number of bytes.
private struct BadByteCountSigner: SolanaSigner, Sendable {
    let publicKey: Data = Data(repeating: 0, count: 32)
    var address: String { Base58.encode(publicKey) }
    let returnCount: Int

    func sign(message: Data) async throws -> Data {
        Data(repeating: 0xAA, count: returnCount)
    }
}

// MARK: - ActiveSession error paths

@Suite("ActiveSession error paths")
struct ActiveSessionErrorPathTests {

    @Test
    func signerReturningWrongByteCountThrows() async throws {
        // Covers Session.swift line 98: signer returned N bytes, expected 64.
        let channel = try makeChannel()
        let badSigner = BadByteCountSigner(returnCount: 32) // not 64
        let session = ActiveSession(channelId: channel, signer: badSigner)
        await #expect(throws: (any Error).self) {
            _ = try await session.prepareIncrement(100)
        }
    }

    @Test
    func signerReturningExactly64BytesSucceeds() async throws {
        // Confirm the guard passes when the signer produces exactly 64 bytes.
        let channel = try makeChannel()
        let goodSigner = BadByteCountSigner(returnCount: 64)
        let session = ActiveSession(channelId: channel, signer: goodSigner)
        let voucher = try await session.prepareIncrement(50)
        #expect(voucher.data.cumulative == "50")
    }

    @Test
    func recordVoucherWithNonNumericCumulativeThrows() throws {
        // Covers Session.swift line 112: invalid voucher cumulative string.
        let channel = try makeChannel()
        let signer = try makeRealSigner()
        let session = ActiveSession(channelId: channel, signer: signer)
        let badVoucher = SignedVoucher(
            data: VoucherData(channelId: channel.base58, cumulative: "not-a-number", expiresAt: 0),
            signature: "fakesig"
        )
        #expect(throws: (any Error).self) { try session.recordVoucher(badVoucher) }
    }

    @Test
    func voucherActionBuildsVoucherSessionAction() async throws {
        // Covers Session.swift lines 130-135: voucherAction(_:) was never called.
        let channel = try makeChannel()
        let signer = try makeRealSigner()
        let session = ActiveSession(channelId: channel, signer: signer)
        let action = try await session.voucherAction(250)
        guard case .voucher(let p) = action else {
            Issue.record("expected voucher action"); return
        }
        #expect(p.voucher.data.cumulative == "250")
        #expect(session.cumulative == 250)
    }

    @Test
    func voucherActionAdvancesWatermarkMonotonically() async throws {
        let channel = try makeChannel()
        let signer = try makeRealSigner()
        let session = ActiveSession(channelId: channel, signer: signer)
        _ = try await session.voucherAction(100)
        _ = try await session.voucherAction(50)
        #expect(session.cumulative == 150)
    }
}

// MARK: - Session dispatch optional challenge fields

@Suite("Session dispatch optional challenge fields")
struct SessionDispatchOptionalFieldsTests {

    /// Build a session challenge header with optional fields included.
    private func sessionChallengeHeaderWithOptionals() -> String {
        let request = SessionRequest(
            cap: "5000000", currency: "USDC", operator: "op", recipient: "rec", modes: [.push]
        )
        let json = try! JSONEncoder().encode(request)
        let b64 = Base64URL.encode(json)
        return "Payment id=\"s1\", realm=\"api\", method=\"solana\", intent=\"session\", request=\"\(b64)\", expires=\"2100-01-01\", digest=\"sha256-abc\", opaque=\"opaquevalue\""
    }

    @Test
    func authorizationHeaderIncludesOptionalChallengeFields() throws {
        // Covers Session.swift lines 287-289: expires, digest, and opaque
        // are present in the challenge and must flow into the echoed credential.
        let challenge = try Session.pickChallenge(
            wwwAuthenticateHeaders: [sessionChallengeHeaderWithOptionals()]
        )
        #expect(challenge.expires == "2100-01-01")
        #expect(challenge.digest == "sha256-abc")
        #expect(challenge.opaque == "opaquevalue")

        let action = SessionAction.close(ClosePayload(channelId: "chan1"))
        let header = try Session.authorizationHeader(for: challenge, action: action)

        let b64 = String(header.dropFirst("Payment ".count))
        let data = try Base64URL.decode(b64)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let echoed = object?["challenge"] as? [String: Any]
        #expect(echoed?["expires"] as? String == "2100-01-01")
        #expect(echoed?["digest"] as? String == "sha256-abc")
        #expect(echoed?["opaque"] as? String == "opaquevalue")
    }

    @Test
    func authorizationHeaderWithExpiresOnly() throws {
        let request = SessionRequest(cap: "1000", currency: "USDC", operator: "op", recipient: "rec")
        let json = try JSONEncoder().encode(request)
        let b64 = Base64URL.encode(json)
        let header = "Payment id=\"s2\", realm=\"api\", method=\"solana\", intent=\"session\", request=\"\(b64)\", expires=\"2050-12-31\""
        let challenge = try Session.pickChallenge(wwwAuthenticateHeaders: [header])
        let action = SessionAction.close(ClosePayload(channelId: "ch"))
        let authHeader = try Session.authorizationHeader(for: challenge, action: action)
        let decoded = try Base64URL.decode(String(authHeader.dropFirst("Payment ".count)))
        let obj = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        let echoed = obj?["challenge"] as? [String: Any]
        #expect(echoed?["expires"] as? String == "2050-12-31")
        // digest and opaque must not appear when absent.
        #expect(echoed?["digest"] == nil)
        #expect(echoed?["opaque"] == nil)
    }

    @Test
    func pickChallengeSkipsChallengeWithMalformedSessionRequest() throws {
        // A session-intent challenge whose request is not a valid SessionRequest
        // must be skipped (guard `try? challenge.sessionRequest`) and the next one picked.
        let goodRequest = SessionRequest(cap: "1000", currency: "USDC", operator: "op", recipient: "rec")
        let goodJson = try JSONEncoder().encode(goodRequest)
        let goodB64 = Base64URL.encode(goodJson)

        // "e30" decodes to "{}" which is missing required SessionRequest fields.
        let badHeader = "Payment id=\"bad\", realm=\"api\", method=\"solana\", intent=\"session\", request=\"e30\""
        let goodHeader = "Payment id=\"good\", realm=\"api\", method=\"solana\", intent=\"session\", request=\"\(goodB64)\""

        let picked = try Session.pickChallenge(wwwAuthenticateHeaders: [badHeader, goodHeader])
        #expect(picked.id == "good")
    }
}

// MARK: - OpenPayload error paths

@Suite("OpenPayload error paths")
struct OpenPayloadErrorPathTests {

    @Test
    func sessionIdThrowsForPushMissingChannelId() throws {
        // Covers SessionTypes.swift line 320: push open missing channelId.
        // We must fabricate an OpenPayload with mode=.push but no channelId.
        // Use JSON decode since the memberwise init is internal.
        let json = """
        {"mode":"push","deposit":"1000","authorizedSigner":"s","signature":"x"}
        """
        let payload = try JSONDecoder().decode(OpenPayload.self, from: Data(json.utf8))
        #expect(payload.channelId == nil)
        #expect(throws: (any Error).self) { _ = try payload.sessionId() }
    }

    @Test
    func sessionIdThrowsForPullMissingTokenAccount() throws {
        // Covers SessionTypes.swift line 323: pull open missing tokenAccount.
        let json = """
        {"mode":"pull","approvedAmount":"5000","authorizedSigner":"s","signature":"x"}
        """
        let payload = try JSONDecoder().decode(OpenPayload.self, from: Data(json.utf8))
        #expect(payload.tokenAccount == nil)
        #expect(throws: (any Error).self) { _ = try payload.sessionId() }
    }

    @Test
    func depositAmountThrowsForPushMissingDeposit() throws {
        // Covers SessionTypes.swift line 337: push open missing deposit.
        let json = """
        {"mode":"push","channelId":"chan1","authorizedSigner":"s","signature":"x"}
        """
        let payload = try JSONDecoder().decode(OpenPayload.self, from: Data(json.utf8))
        #expect(payload.deposit == nil)
        #expect(throws: (any Error).self) { _ = try payload.depositAmount() }
    }

    @Test
    func depositAmountThrowsForPullMissingApprovedAmount() throws {
        // Covers SessionTypes.swift line 340: pull open missing approvedAmount.
        let json = """
        {"mode":"pull","tokenAccount":"tok1","authorizedSigner":"s","signature":"x"}
        """
        let payload = try JSONDecoder().decode(OpenPayload.self, from: Data(json.utf8))
        #expect(payload.approvedAmount == nil)
        #expect(throws: (any Error).self) { _ = try payload.depositAmount() }
    }

    @Test
    func depositAmountThrowsForNonNumericString() throws {
        // Covers SessionTypes.swift line 346: invalid deposit amount string.
        let json = """
        {"mode":"push","channelId":"chan1","deposit":"not-a-number","authorizedSigner":"s","signature":"x"}
        """
        let payload = try JSONDecoder().decode(OpenPayload.self, from: Data(json.utf8))
        #expect(throws: (any Error).self) { _ = try payload.depositAmount() }
    }

    @Test
    func saltDecodeThrowsForNonNumericString() throws {
        // Covers SessionTypes.swift line 409: salt string that cannot parse as UInt64.
        let json = """
        {"mode":"push","channelId":"c","deposit":"1","salt":"not-a-uint64","authorizedSigner":"s","signature":"x"}
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OpenPayload.self, from: Data(json.utf8))
        }
    }

    @Test
    func saltDecodeThrowsForBooleanValue() throws {
        // Covers SessionTypes.swift lines 416-419: salt present, not null, not a string,
        // and not a valid UInt64 (boolean falls through both decode paths).
        let json = """
        {"mode":"push","channelId":"c","deposit":"1","salt":true,"authorizedSigner":"s","signature":"x"}
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OpenPayload.self, from: Data(json.utf8))
        }
    }

    @Test
    func saltDecodeThrowsForArrayValue() throws {
        // Additional coverage for decodeOptionalU64 error path: salt is a JSON array.
        let json = """
        {"mode":"push","channelId":"c","deposit":"1","salt":[1,2],"authorizedSigner":"s","signature":"x"}
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OpenPayload.self, from: Data(json.utf8))
        }
    }
}

// MARK: - VoucherData.messageBytes error path

@Suite("VoucherData.messageBytes error path")
struct VoucherDataMessageBytesErrorTests {

    @Test
    func messageBytesThrowsForNonNumericCumulative() throws {
        // Covers SessionTypes.swift line 482: invalid voucher cumulative in messageBytes.
        let channel = try Pubkey(bytes: Data(repeating: 7, count: 32))
        let data = VoucherData(channelId: channel.base58, cumulative: "bad-value", expiresAt: 0)
        #expect(throws: (any Error).self) { _ = try data.messageBytes() }
    }
}

// MARK: - MeteredDelivery commit alias

@Suite("MeteredDelivery commit alias")
struct MeteredDeliveryCommitAliasTests {

    private func makeConsumer() throws -> SessionConsumer<RecordingTransport> {
        let channel = try Pubkey(bytes: Data(repeating: 9, count: 32))
        let signer = try MemorySigner(secretKey: Data(repeating: 11, count: 32))
        let session = ActiveSession(channelId: channel, signer: signer)
        return SessionConsumer(session: session, transport: RecordingTransport())
    }

    @Test
    func commitAliasIsEquivalentToAck() async throws {
        let consumer = try makeConsumer()
        let directive = MeteringDirective(
            deliveryId: "d-commit", sessionId: consumer.session.channelIdString(),
            amount: "300", currency: "USDC", sequence: 1, expiresAt: DEFAULT_VOUCHER_EXPIRES_AT
        )
        let envelope = MeteredEnvelope(payload: "payload", metering: directive)
        let delivery = try consumer.accept(envelope)
        let receipt = try await delivery.commit()
        #expect(receipt.status == .committed)
        #expect(receipt.cumulative == "300")
        #expect(consumer.session.cumulative == 300)
    }
}

// MARK: - openPaymentChannelAction with explicit pull mode

@Suite("openPaymentChannelAction pull mode")
struct OpenPaymentChannelPullModeTests {

    @Test
    func openPaymentChannelActionWithPullMode() throws {
        let channel = try Pubkey(bytes: Data(repeating: 5, count: 32))
        let signer = try MemorySigner(secretKey: Data(repeating: 13, count: 32))
        let session = ActiveSession(channelId: channel, signer: signer)
        let action = session.openPaymentChannelAction(
            mode: .pull,
            deposit: 2_000_000,
            payer: "payer2",
            payee: "payee2",
            mint: "mint2",
            salt: 7,
            gracePeriod: 30,
            openTxSignature: "pullsig"
        )
        guard case .open(let p) = action else {
            Issue.record("expected open"); return
        }
        #expect(p.mode == .pull)
        #expect(p.payer == "payer2")
        #expect(p.salt == 7)
        #expect(p.signature == "pullsig")
    }
}
