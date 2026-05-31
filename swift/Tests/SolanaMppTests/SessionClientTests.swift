import Foundation
import Testing
@testable import SolanaMpp

/// Client-side session behavior: voucher signing, monotonicity, action
/// builders, and the metered-delivery consumer with idempotent replay.
/// Mirrors `rust/crates/mpp/src/client/session.rs` and
/// `client/session_consumer.rs`.
@Suite("Session client")
struct SessionClientTests {
    private func makeSigner(seed: UInt8 = 42) throws -> MemorySigner {
        try MemorySigner(secretKey: Data(repeating: seed, count: 32))
    }

    private func makeSession(seed: UInt8 = 42) throws -> ActiveSession {
        let channel = try Pubkey(bytes: Data(repeating: 3, count: 32))
        return ActiveSession(channelId: channel, signer: try makeSigner(seed: seed))
    }

    @Test
    func signIncrementAdvancesCumulativeAndNonce() async throws {
        let s = try makeSession()
        #expect(s.cumulative == 0)
        let v1 = try await s.signIncrement(100)
        #expect(s.cumulative == 100)
        #expect(v1.data.cumulative == "100")
        #expect(v1.data.nonce == 1)
        let v2 = try await s.signIncrement(50)
        #expect(s.cumulative == 150)
        #expect(v2.data.nonce == 2)
    }

    @Test
    func signVoucherAbsolute() async throws {
        let s = try makeSession()
        try await s.signIncrement(50)
        let v = try await s.signVoucher(cumulative: 200)
        #expect(s.cumulative == 200)
        #expect(v.data.cumulative == "200")
    }

    @Test
    func prepareDoesNotAdvanceUntilRecorded() async throws {
        let s = try makeSession()
        let prepared = try await s.prepareIncrement(75)
        #expect(prepared.data.cumulative == "75")
        #expect(s.cumulative == 0)
        try s.recordVoucher(prepared)
        #expect(s.cumulative == 75)
        // Recording the same voucher again must fail (non-increasing).
        #expect(throws: (any Error).self) { try s.recordVoucher(prepared) }
    }

    @Test
    func signVoucherRejectsNonIncreasing() async throws {
        let s = try makeSession()
        try await s.signIncrement(100)
        await #expect(throws: (any Error).self) { try await s.signVoucher(cumulative: 100) }
        await #expect(throws: (any Error).self) { try await s.signVoucher(cumulative: 50) }
        await #expect(throws: (any Error).self) { try await s.signVoucher(cumulative: 0) }
    }

    @Test
    func voucherSignatureVerifiesAgainstAuthorizedSigner() async throws {
        let s = try makeSession()
        let voucher = try await s.signIncrement(1000)
        // The signed bytes must be the 48-byte on-chain voucher layout.
        let message = try voucher.data.messageBytes()
        #expect(message.count == 48)
        let signatureBytes = try Base58.decode(voucher.signature)
        let signerPubkey = try Pubkey(base58: s.authorizedSigner())
        #expect(try Ed25519.verify(
            signature: signatureBytes, message: message, publicKey: signerPubkey.bytes
        ))
        // Voucher channelId binds to the session channel.
        #expect(voucher.data.channelId == s.channelIdString())
    }

    @Test
    func capEnforcementIsCallerResponsibilityButWatermarkMonotone() async throws {
        // The client never signs a voucher below the watermark; the server
        // enforces cap. Verify the watermark cannot regress.
        let s = try makeSession()
        try await s.signVoucher(cumulative: 5)
        await #expect(throws: (any Error).self) { try await s.signVoucher(cumulative: 4) }
        #expect(s.cumulative == 5)
    }

    @Test
    func openActionPushFields() throws {
        let s = try makeSession()
        let channelId = s.channelIdString()
        let action = s.openAction(deposit: 1_000_000, openTxSignature: "txsig123")
        guard case .open(let p) = action else { Issue.record("expected open"); return }
        #expect(p.mode == .push)
        #expect(p.deposit == "1000000")
        #expect(p.signature == "txsig123")
        #expect(p.channelId == channelId)
        #expect(p.authorizedSigner == s.authorizedSigner())
    }

    @Test
    func openPaymentChannelActionFields() throws {
        let s = try makeSession()
        let action = s.openPaymentChannelAction(
            deposit: 9000, payer: "payer", payee: "payee", mint: "mint",
            salt: 42, gracePeriod: 60, openTxSignature: "open-sig"
        )
        guard case .open(let p) = action else { Issue.record("expected open"); return }
        #expect(p.mode == .push)
        #expect(p.salt == 42)
        #expect(p.gracePeriod == 60)
        #expect(p.payer == "payer")
    }

    @Test
    func openPullActionUsesTokenAccount() throws {
        let s = try makeSession()
        let channelId = s.channelIdString()
        let action = s.openPullAction(approvedAmount: 5_000_000, owner: "wallet123", approveTxSignature: "approvesig")
        guard case .open(let p) = action else { Issue.record("expected open"); return }
        #expect(p.mode == .pull)
        #expect(p.approvedAmount == "5000000")
        #expect(p.tokenAccount == channelId)
        #expect(p.owner == "wallet123")
        #expect(p.channelId == nil)
    }

    @Test
    func topupActionFields() throws {
        let s = try makeSession()
        let action = s.topupAction(newDeposit: 5_000_000, topupTxSignature: "topuptx")
        guard case .topUp(let p) = action else { Issue.record("expected topUp"); return }
        #expect(p.newDeposit == "5000000")
        #expect(p.signature == "topuptx")
    }

    @Test
    func closeActionWithAndWithoutFinalIncrement() async throws {
        let s = try makeSession()
        let none = try await s.closeAction(finalIncrement: nil)
        guard case .close(let p1) = none else { Issue.record("expected close"); return }
        #expect(p1.voucher == nil)

        try await s.signIncrement(100)
        let final = try await s.closeAction(finalIncrement: 50)
        guard case .close(let p2) = final else { Issue.record("expected close"); return }
        #expect(p2.voucher?.data.cumulative == "150")

        let zero = try await s.closeAction(finalIncrement: 0)
        guard case .close(let p3) = zero else { Issue.record("expected close"); return }
        #expect(p3.voucher == nil)
    }

    @Test
    func customExpiryFlowsIntoVouchers() async throws {
        let channel = try Pubkey(bytes: Data(repeating: 3, count: 32))
        let s = ActiveSession(channelId: channel, signer: try makeSigner(), expiresAt: 1234)
        let first = try await s.prepareIncrement(10)
        #expect(first.data.expiresAt == 1234)
        s.setExpiresAt(5678)
        let second = try await s.prepareIncrement(10)
        #expect(second.data.expiresAt == 5678)
    }
}

// MARK: - Consumer

/// In-process commit transport that records payloads and simulates
/// idempotent replay keyed on `deliveryId`.
final class RecordingTransport: CommitTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var committed: [String: CommitReceipt] = [:]
    private(set) var commits: [CommitPayload] = []
    let fail: Bool

    init(fail: Bool = false) {
        self.fail = fail
    }

    func commit(directive: MeteringDirective, payload: CommitPayload) async throws -> CommitReceipt {
        if fail {
            throw MppError.rpcFailure("commit failed")
        }
        return lock.withLock {
            if let existing = committed[directive.deliveryId] {
                // Idempotent replay: return the cached receipt as replayed.
                return CommitReceipt(
                    deliveryId: existing.deliveryId, sessionId: existing.sessionId,
                    amount: existing.amount, cumulative: existing.cumulative, status: .replayed
                )
            }
            commits.append(payload)
            let receipt = CommitReceipt(
                deliveryId: directive.deliveryId, sessionId: directive.sessionId,
                amount: directive.amount, cumulative: payload.voucher.data.cumulative,
                status: .committed
            )
            committed[directive.deliveryId] = receipt
            return receipt
        }
    }
}

@Suite("Session consumer")
struct SessionConsumerTests {
    private func makeConsumer(fail: Bool = false) throws -> SessionConsumer<RecordingTransport> {
        let channel = try Pubkey(bytes: Data(repeating: 5, count: 32))
        let signer = try MemorySigner(secretKey: Data(repeating: 7, count: 32))
        let session = ActiveSession(channelId: channel, signer: signer)
        return SessionConsumer(session: session, transport: RecordingTransport(fail: fail))
    }

    private func directive(_ consumer: SessionConsumer<RecordingTransport>, deliveryId: String = "d1", amount: UInt64) -> MeteringDirective {
        MeteringDirective(
            deliveryId: deliveryId, sessionId: consumer.session.channelIdString(),
            amount: String(amount), currency: "USDC", sequence: 1,
            expiresAt: DEFAULT_VOUCHER_EXPIRES_AT
        )
    }

    @Test
    func ackSendsCommitAndAdvancesWatermark() async throws {
        let consumer = try makeConsumer()
        let envelope = MeteredEnvelope(payload: "work", metering: directive(consumer, amount: 250))
        let delivery = try consumer.accept(envelope)
        #expect(delivery.payload == "work")
        let receipt = try await delivery.ack()
        #expect(receipt.cumulative == "250")
        #expect(receipt.status == .committed)
        #expect(consumer.session.cumulative == 250)
        #expect(consumer.transport.commits.count == 1)
    }

    @Test
    func duplicateDeliveryIdReplaysIdempotently() async throws {
        let consumer = try makeConsumer()
        let first = try await consumer.commitDirective(directive(consumer, deliveryId: "dup", amount: 100))
        #expect(first.status == .committed)
        #expect(consumer.session.cumulative == 100)

        // Re-submitting the same deliveryId returns a replayed receipt and
        // must not create a second settlement. The local watermark stays.
        let replay = try await consumer.commitDirective(directive(consumer, deliveryId: "dup", amount: 100))
        #expect(replay.status == .replayed)
        #expect(consumer.transport.commits.count == 1)
    }

    @Test
    func wrongSessionDirectiveRejected() throws {
        let consumer = try makeConsumer()
        let envelope = MeteredEnvelope(
            payload: "x",
            metering: MeteringDirective(
                deliveryId: "d", sessionId: "other-session", amount: "1",
                currency: "USDC", sequence: 1, expiresAt: 0
            )
        )
        #expect(throws: (any Error).self) { _ = try consumer.accept(envelope) }
    }

    @Test
    func zeroAndInvalidAmountsRejected() async throws {
        let consumer = try makeConsumer()
        await #expect(throws: (any Error).self) {
            _ = try await consumer.commitDirective(directive(consumer, amount: 0))
        }
        var bad = directive(consumer, amount: 1)
        bad = MeteringDirective(
            deliveryId: bad.deliveryId, sessionId: bad.sessionId, amount: "bad",
            currency: bad.currency, sequence: bad.sequence, expiresAt: bad.expiresAt
        )
        await #expect(throws: (any Error).self) {
            _ = try await consumer.commitDirective(bad)
        }
        #expect(consumer.transport.commits.isEmpty)
    }

    @Test
    func failedCommitDoesNotAdvanceWatermark() async throws {
        let consumer = try makeConsumer(fail: true)
        await #expect(throws: (any Error).self) {
            _ = try await consumer.commitDirective(directive(consumer, amount: 250))
        }
        #expect(consumer.session.cumulative == 0)
    }
}
