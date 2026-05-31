import Foundation
import Testing
@testable import SolanaMpp

/// Session challenge selection and Authorization framing, mirroring the
/// charge dispatch surface.
@Suite("Session dispatch")
struct SessionDispatchTests {
    private func sessionChallengeHeader() -> String {
        let request = SessionRequest(
            cap: "10000000", currency: "USDC", operator: "op", recipient: "rec", modes: [.push]
        )
        let json = try! JSONEncoder().encode(request)
        let b64 = Base64URL.encode(json)
        return "Payment id=\"sess-1\", realm=\"api\", method=\"solana\", intent=\"session\", request=\"\(b64)\""
    }

    private func chargeChallengeHeader() -> String {
        // A non-session challenge that must be skipped by pickChallenge.
        "Payment id=\"chg-1\", realm=\"api\", method=\"solana\", intent=\"charge\", request=\"e30\""
    }

    @Test
    func pickChallengeSelectsSessionAndDecodesRequest() throws {
        let challenge = try Session.pickChallenge(
            wwwAuthenticateHeaders: [chargeChallengeHeader(), sessionChallengeHeader()]
        )
        #expect(challenge.intent == "session")
        let request = try challenge.sessionRequest
        #expect(request.cap == "10000000")
        #expect(request.modes == [.push])
    }

    @Test
    func pickChallengeThrowsWhenNoSessionChallenge() {
        #expect(throws: (any Error).self) {
            _ = try Session.pickChallenge(wwwAuthenticateHeaders: [chargeChallengeHeader()])
        }
    }

    @Test
    func authorizationHeaderEchoesChallengeAndCarriesAction() throws {
        let challenge = try Session.pickChallenge(
            wwwAuthenticateHeaders: [sessionChallengeHeader()]
        )
        let action = SessionAction.voucher(VoucherPayload(voucher: SignedVoucher(
            data: VoucherData(channelId: "chan1", cumulative: "100", expiresAt: 42, nonce: 1),
            signature: "sig"
        )))
        let header = try Session.authorizationHeader(for: challenge, action: action)
        #expect(header.hasPrefix("Payment "))

        // Decode the credential and verify framing.
        let b64 = String(header.dropFirst("Payment ".count))
        let data = try Base64URL.decode(b64)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = object?["payload"] as? [String: Any]
        #expect(payload?["type"] as? String == "session")
        let echoed = object?["challenge"] as? [String: Any]
        #expect(echoed?["id"] as? String == "sess-1")
        #expect(echoed?["intent"] as? String == "session")
        let actionObject = payload?["action"] as? [String: Any]
        #expect(actionObject?["action"] as? String == "voucher")
    }

    @Test
    func authorizationHeaderRejectsNonSessionChallenge() throws {
        let charge = try MppHeaders.parseWWWAuthenticate(
            "Payment id=\"c\", realm=\"api\", method=\"solana\", intent=\"charge\", request=\"e30\""
        )
        let action = SessionAction.close(ClosePayload(channelId: "chan1"))
        #expect(throws: (any Error).self) {
            _ = try Session.authorizationHeader(for: charge, action: action)
        }
    }
}
