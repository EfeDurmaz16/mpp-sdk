import Foundation
import Testing
@testable import SolanaMpp

/// Wire-shape parity for session intent types. Mirrors the Rust spine
/// `rust/crates/mpp/src/protocol/intents/session.rs::tests`.
@Suite("Session intent wire parity")
struct SessionWireTests {
    private func encodeString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // ── SessionMode / strategy ──

    @Test
    func sessionModeCamelCase() throws {
        #expect(try encodeString(SessionMode.push) == "\"push\"")
        #expect(try encodeString(SessionMode.pull) == "\"pull\"")
        #expect(try decode(SessionMode.self, "\"push\"") == .push)
    }

    @Test
    func pullVoucherStrategyRoundtrip() throws {
        #expect(try encodeString(SessionPullVoucherStrategy.clientVoucher) == "\"clientVoucher\"")
        #expect(try encodeString(SessionPullVoucherStrategy.operatedVoucher) == "\"operatedVoucher\"")
        #expect(try decode(SessionPullVoucherStrategy.self, "\"operatedVoucher\"") == .operatedVoucher)
    }

    // ── SessionRequest ──

    @Test
    func sessionRequestOmitsEmptyCollectionsAndNilFields() throws {
        let req = SessionRequest(cap: "1000", currency: "USDC", operator: "op", recipient: "rec")
        let json = try encodeString(req)
        #expect(!json.contains("splits"))
        #expect(!json.contains("modes"))
        #expect(!json.contains("decimals"))
        #expect(!json.contains("network"))
        #expect(!json.contains("description"))
        #expect(!json.contains("externalId"))
        #expect(!json.contains("minVoucherDelta"))
    }

    @Test
    func sessionRequestWithModesAndStrategy() throws {
        let req = SessionRequest(
            cap: "1000", currency: "USDC", operator: "op", recipient: "rec",
            modes: [.push, .pull], pullVoucherStrategy: .clientVoucher
        )
        let json = try encodeString(req)
        #expect(json.contains("\"push\""))
        #expect(json.contains("\"pull\""))
        #expect(json.contains("\"pullVoucherStrategy\":\"clientVoucher\""))
        let back = try decode(SessionRequest.self, json)
        #expect(back.modes == [.push, .pull])
        #expect(back.pullVoucherStrategy == .clientVoucher)
    }

    @Test
    func sessionRequestRoundtrip() throws {
        let req = SessionRequest(
            cap: "10000000", currency: "USDC", decimals: 6, network: "mainnet-beta",
            operator: "op", recipient: "rec",
            splits: [SessionSplit(recipient: "s1", bps: 100)],
            programId: "prog", description: "API session", externalId: "ref-1",
            minVoucherDelta: "500", modes: [.push]
        )
        let back = try decode(SessionRequest.self, try encodeString(req))
        #expect(back.cap == "10000000")
        #expect(back.decimals == 6)
        #expect(back.splits.count == 1)
        #expect(back.splits[0].bps == 100)
        #expect(back.minVoucherDelta == "500")
        #expect(back.description == "API session")
    }

    // ── OpenPayload ──

    @Test
    func openPushOmitsPullFields() throws {
        let p = OpenPayload.push(
            channelId: "chan1", deposit: "1000000", authorizedSigner: "signer1", signature: "txsig"
        )
        let json = try encodeString(p)
        #expect(json.contains("\"mode\":\"push\""))
        #expect(json.contains("\"channelId\":\"chan1\""))
        #expect(!json.contains("tokenAccount"))
        let back = try decode(OpenPayload.self, json)
        #expect(back.mode == .push)
        #expect(back.channelId == "chan1")
    }

    @Test
    func openPullOmitsChannelId() throws {
        let p = OpenPayload.pull(
            tokenAccount: "tokacct", approvedAmount: "5000000", owner: "wallet1",
            authorizedSigner: "signer1", signature: "approvesig"
        )
        let json = try encodeString(p)
        #expect(json.contains("\"mode\":\"pull\""))
        #expect(json.contains("\"tokenAccount\":\"tokacct\""))
        #expect(json.contains("\"owner\":\"wallet1\""))
        #expect(!json.contains("channelId"))
        let back = try decode(OpenPayload.self, json)
        #expect(back.tokenAccount == "tokacct")
        #expect(back.owner == "wallet1")
    }

    @Test
    func sessionIdAndDepositResolution() throws {
        let push = OpenPayload.push(
            channelId: "chan1", deposit: "2000000", authorizedSigner: "s", signature: "sig"
        )
        #expect(try push.sessionId() == "chan1")
        #expect(try push.depositAmount() == 2_000_000)

        let pull = OpenPayload.pull(
            tokenAccount: "tokacct", approvedAmount: "3000000", owner: "w",
            authorizedSigner: "s", signature: "sig"
        )
        #expect(try pull.sessionId() == "tokacct")
        #expect(try pull.depositAmount() == 3_000_000)
    }

    @Test
    func paymentChannelTxHelpers() throws {
        let p = OpenPayload.paymentChannel(
            channelId: "chan1", deposit: "1000000", payer: "payer1", payee: "payee1",
            mint: "mint1", salt: 99, gracePeriod: 45, authorizedSigner: "signer1", signature: "txsig"
        )
        .withTransaction("open-tx")
        .withInitTx("init-tx")
        .withUpdateTx("update-tx")
        #expect(p.salt == 99)
        #expect(p.gracePeriod == 45)
        #expect(p.transaction == "open-tx")
        #expect(p.initMultiDelegateTx == "init-tx")
        #expect(p.updateDelegationTx == "update-tx")
    }

    @Test
    func saltSerializesAsStringAndAcceptsNumber() throws {
        let salt: UInt64 = UInt64.max - 7
        let p = OpenPayload.paymentChannel(
            channelId: "chan1", deposit: "1", payer: "p", payee: "pe",
            mint: "m", salt: salt, gracePeriod: 900, authorizedSigner: "s", signature: "x"
        )
        let json = try encodeString(p)
        #expect(json.contains("\"salt\":\"\(salt)\""))
        #expect(try decode(OpenPayload.self, json).salt == salt)

        // Legacy: salt as a JSON number must still decode.
        let legacy = """
        {"mode":"push","channelId":"chan1","deposit":"1","payer":"p","payee":"pe","mint":"m","salt":42,"gracePeriod":900,"authorizedSigner":"s","signature":"x"}
        """
        #expect(try decode(OpenPayload.self, legacy).salt == 42)
    }

    @Test
    func openPayloadMissingModeFails() {
        let json = """
        {"channelId":"chan1","deposit":"1000","authorizedSigner":"s","signature":"sig"}
        """
        #expect(throws: (any Error).self) {
            _ = try decode(OpenPayload.self, json)
        }
    }

    // ── SessionAction tags ──

    @Test
    func actionOpenTag() throws {
        let action = SessionAction.open(OpenPayload.push(
            channelId: "chan123", deposit: "5000000", authorizedSigner: "signer123", signature: "sig456"
        ))
        let json = try encodeString(action)
        #expect(json.contains("\"action\":\"open\""))
        #expect(json.contains("\"mode\":\"push\""))
        let back = try decode(SessionAction.self, json)
        guard case .open(let p) = back else { Issue.record("expected open"); return }
        #expect(try p.sessionId() == "chan123")
    }

    @Test
    func actionVoucherTag() throws {
        let action = SessionAction.voucher(VoucherPayload(voucher: SignedVoucher(
            data: VoucherData(channelId: "chan1", cumulative: "500000", expiresAt: Int64.max, nonce: 3),
            signature: "sig_here"
        )))
        let json = try encodeString(action)
        #expect(json.contains("\"action\":\"voucher\""))
        let back = try decode(SessionAction.self, json)
        guard case .voucher(let p) = back else { Issue.record("expected voucher"); return }
        #expect(p.voucher.data.cumulative == "500000")
        #expect(p.voucher.data.nonce == 3)
    }

    @Test
    func actionCommitTag() throws {
        let action = SessionAction.commit(CommitPayload(
            deliveryId: "delivery-1",
            voucher: SignedVoucher(
                data: VoucherData(channelId: "chan1", cumulative: "500000", expiresAt: Int64.max),
                signature: "sig_here"
            )
        ))
        let json = try encodeString(action)
        #expect(json.contains("\"action\":\"commit\""))
        #expect(json.contains("\"deliveryId\":\"delivery-1\""))
        let back = try decode(SessionAction.self, json)
        guard case .commit(let p) = back else { Issue.record("expected commit"); return }
        #expect(p.deliveryId == "delivery-1")
    }

    @Test
    func actionTopUpTagHasCapitalU() throws {
        let action = SessionAction.topUp(TopUpPayload(
            channelId: "chan1", newDeposit: "9000000", signature: "txsig"
        ))
        let json = try encodeString(action)
        #expect(json.contains("\"action\":\"topUp\""))
        let back = try decode(SessionAction.self, json)
        guard case .topUp(let p) = back else { Issue.record("expected topUp"); return }
        #expect(p.newDeposit == "9000000")
    }

    @Test
    func actionCloseTags() throws {
        let noVoucher = SessionAction.close(ClosePayload(channelId: "chan1"))
        let json = try encodeString(noVoucher)
        #expect(json.contains("\"action\":\"close\""))
        #expect(!json.contains("voucher"))

        let withVoucher = SessionAction.close(ClosePayload(
            channelId: "chan1",
            voucher: SignedVoucher(
                data: VoucherData(channelId: "chan1", cumulative: "700000", expiresAt: Int64.max),
                signature: "final"
            )
        ))
        let back = try decode(SessionAction.self, try encodeString(withVoucher))
        guard case .close(let p) = back else { Issue.record("expected close"); return }
        #expect(p.voucher?.data.cumulative == "700000")
    }

    // ── VoucherData wire ──

    @Test
    func voucherSerializesCumulativeAmountAndReadsAlias() throws {
        let v = VoucherData(channelId: "chan1", cumulative: "100", expiresAt: 42, nonce: 5)
        let json = try encodeString(v)
        #expect(json.contains("\"cumulativeAmount\":\"100\""))
        #expect(!json.contains("\"cumulative\":"))

        // Alias `cumulative` must decode for backwards compatibility.
        let alias = """
        {"channelId":"chan1","cumulative":"250","expiresAt":42}
        """
        #expect(try decode(VoucherData.self, alias).cumulative == "250")

        // Canonical `cumulativeAmount` must also decode.
        let canonical = """
        {"channelId":"chan1","cumulativeAmount":"250","expiresAt":42}
        """
        #expect(try decode(VoucherData.self, canonical).cumulative == "250")
    }

    @Test
    func meteringDirectiveAndUsageRoundtrip() throws {
        let directive = MeteringDirective(
            deliveryId: "d1", sessionId: "chan1", amount: "125", currency: "USDC",
            sequence: 7, expiresAt: DEFAULT_SESSION_EXPIRES_AT, commitUrl: "https://x.test/commit"
        )
        let json = try encodeString(directive)
        #expect(json.contains("\"deliveryId\":\"d1\""))
        #expect(json.contains("commitUrl"))
        let backDirective = try decode(MeteringDirective.self, json)
        #expect(try backDirective.amountBaseUnits() == 125)
        #expect(backDirective.commitUrl == "https://x.test/commit")
        #expect(backDirective.sequence == 7)

        let usage = MeteringUsage(deliveryId: "d1", amount: "42")
        #expect(try decode(MeteringUsage.self, try encodeString(usage)).amountBaseUnits() == 42)

        #expect(throws: (any Error).self) {
            _ = try MeteringDirective(
                deliveryId: "d1", sessionId: "c", amount: "nope", currency: "USDC",
                sequence: 1, expiresAt: 0
            ).amountBaseUnits()
        }
    }

    @Test
    func commitStatusCamelCase() throws {
        let receipt = CommitReceipt(
            deliveryId: "d1", sessionId: "chan1", amount: "10", cumulative: "10", status: .replayed
        )
        let json = try encodeString(receipt)
        #expect(json.contains("\"status\":\"replayed\""))
        #expect(try decode(CommitReceipt.self, json).status == .replayed)
    }
}
