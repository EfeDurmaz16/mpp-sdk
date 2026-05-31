import Foundation

// MARK: - Active session
//
// Client-side session intent implementation. Mirrors the Rust spine
// `rust/crates/mpp/src/client/session.rs` and
// `client/session_consumer.rs`: track an open payment channel and sign
// cumulative vouchers for each API call. Vouchers are Ed25519-signed over
// the on-chain Borsh voucher layout used by the payment-channels program.

/// Default voucher expiry: 2100-01-01T00:00:00Z. Stays below JavaScript's
/// max safe integer so JSON intermediaries do not round it.
public let DEFAULT_VOUCHER_EXPIRES_AT: Int64 = DEFAULT_SESSION_EXPIRES_AT

/// Tracks the client-side state of an active payment session.
///
/// Holds a `SolanaSigner` session key and advances the cumulative
/// watermark with each signed voucher. The signer may be a local memory
/// signer, a hardware wallet, or any cloud KMS via the `SolanaSigner`
/// protocol.
///
/// This is a reference type (`actor`-free `final class`) because the
/// watermark is read-modify-write state that must not be copied by value
/// when shared with a `SessionConsumer`.
public final class ActiveSession: @unchecked Sendable {
    /// On-chain channel address.
    public let channelId: Pubkey

    /// Cumulative amount authorized so far (base units).
    public private(set) var cumulative: UInt64 = 0

    /// Nonce counter, incremented with each signed voucher.
    private var nonce: UInt64 = 0

    /// Unix timestamp at which newly signed vouchers expire.
    private var expiresAt: Int64

    /// Session signing key.
    private let signer: any SolanaSigner

    public init(channelId: Pubkey, signer: any SolanaSigner) {
        self.channelId = channelId
        self.signer = signer
        self.expiresAt = DEFAULT_VOUCHER_EXPIRES_AT
    }

    public init(channelId: Pubkey, signer: any SolanaSigner, expiresAt: Int64) {
        self.channelId = channelId
        self.signer = signer
        self.expiresAt = expiresAt
    }

    /// Update the expiry timestamp used for subsequent vouchers.
    public func setExpiresAt(_ expiresAt: Int64) {
        self.expiresAt = expiresAt
    }

    /// The authorized signer public key (base58) for the `open` action.
    public func authorizedSigner() -> String {
        Base58.encode(signer.publicKey)
    }

    /// Channel ID as base58.
    public func channelIdString() -> String {
        channelId.base58
    }

    /// Sign a voucher with an absolute cumulative amount and advance the
    /// local watermark. `cumulative` MUST strictly exceed the current
    /// watermark.
    @discardableResult
    public func signVoucher(cumulative: UInt64) async throws -> SignedVoucher {
        let voucher = try await prepareVoucher(cumulative: cumulative)
        try recordVoucher(voucher)
        return voucher
    }

    /// Prepare a signed voucher without advancing the local watermark.
    ///
    /// Useful for ack/commit transports: if the commit fails, the client
    /// can retry the same cumulative amount without local state drifting
    /// ahead of the server.
    public func prepareVoucher(cumulative: UInt64) async throws -> SignedVoucher {
        guard cumulative > self.cumulative else {
            throw MppError.invalidTransaction(
                "Voucher cumulative \(cumulative) must exceed current watermark \(self.cumulative)"
            )
        }
        let data = VoucherData(
            channelId: channelIdString(),
            cumulative: String(cumulative),
            expiresAt: expiresAt,
            nonce: nonce + 1
        )
        let bytes = try data.messageBytes()
        let sig = try await signer.sign(message: bytes)
        guard sig.count == 64 else {
            throw MppError.signingFailure("signer returned \(sig.count) bytes, expected 64")
        }
        return SignedVoucher(data: data, signature: Base58.encode(sig))
    }

    /// Prepare a signed voucher adding `amount` without advancing the
    /// watermark.
    public func prepareIncrement(_ amount: UInt64) async throws -> SignedVoucher {
        try await prepareVoucher(cumulative: cumulative + amount)
    }

    /// Record a prepared voucher as accepted by the server.
    public func recordVoucher(_ voucher: SignedVoucher) throws {
        guard let cumulativeValue = UInt64(voucher.data.cumulative) else {
            throw MppError.invalidTransaction("invalid voucher cumulative")
        }
        guard cumulativeValue > cumulative else {
            throw MppError.invalidTransaction(
                "Voucher cumulative \(cumulativeValue) must exceed current watermark \(cumulative)"
            )
        }
        cumulative = cumulativeValue
        nonce = max(nonce, voucher.data.nonce ?? (nonce + 1))
    }

    /// Sign a voucher adding `amount` to the current cumulative.
    @discardableResult
    public func signIncrement(_ amount: UInt64) async throws -> SignedVoucher {
        try await signVoucher(cumulative: cumulative + amount)
    }

    /// Build a `SessionAction.voucher` wrapping a freshly-signed increment.
    public func voucherAction(_ amount: UInt64) async throws -> SessionAction {
        let voucher = try await signIncrement(amount)
        return .voucher(VoucherPayload(voucher: voucher))
    }

    /// Build a `SessionAction.close` for cooperative channel close.
    ///
    /// If `finalIncrement` is non-nil and > 0, signs one last voucher for
    /// the remaining balance before closing.
    public func closeAction(finalIncrement: UInt64?) async throws -> SessionAction {
        let voucher: SignedVoucher?
        if let amount = finalIncrement, amount > 0 {
            voucher = try await signIncrement(amount)
        } else {
            voucher = nil
        }
        return .close(ClosePayload(channelId: channelIdString(), voucher: voucher))
    }

    /// Build a `SessionAction.open` for **push** mode.
    public func openAction(deposit: UInt64, openTxSignature: String) -> SessionAction {
        .open(OpenPayload.push(
            channelId: channelIdString(),
            deposit: String(deposit),
            authorizedSigner: authorizedSigner(),
            signature: openTxSignature
        ))
    }

    /// Build a `SessionAction.open` for the payment-channels program.
    public func openPaymentChannelAction(
        deposit: UInt64,
        payer: String,
        payee: String,
        mint: String,
        salt: UInt64,
        gracePeriod: UInt32,
        openTxSignature: String
    ) -> SessionAction {
        openPaymentChannelAction(
            mode: .push,
            deposit: deposit,
            payer: payer,
            payee: payee,
            mint: mint,
            salt: salt,
            gracePeriod: gracePeriod,
            openTxSignature: openTxSignature
        )
    }

    /// Build a payment-channel `SessionAction.open` with an explicit mode.
    public func openPaymentChannelAction(
        mode: SessionMode,
        deposit: UInt64,
        payer: String,
        payee: String,
        mint: String,
        salt: UInt64,
        gracePeriod: UInt32,
        openTxSignature: String
    ) -> SessionAction {
        .open(OpenPayload.paymentChannel(
            mode: mode,
            channelId: channelIdString(),
            deposit: String(deposit),
            payer: payer,
            payee: payee,
            mint: mint,
            salt: salt,
            gracePeriod: gracePeriod,
            authorizedSigner: authorizedSigner(),
            signature: openTxSignature
        ))
    }

    /// Build a `SessionAction.open` for **pull** mode (SPL delegation).
    public func openPullAction(
        approvedAmount: UInt64,
        owner: String,
        approveTxSignature: String
    ) -> SessionAction {
        .open(OpenPayload.pull(
            tokenAccount: channelIdString(), // token account is the session id
            approvedAmount: String(approvedAmount),
            owner: owner,
            authorizedSigner: authorizedSigner(),
            signature: approveTxSignature
        ))
    }

    /// Build a `SessionAction.topUp` after a top-up transaction.
    public func topupAction(newDeposit: UInt64, topupTxSignature: String) -> SessionAction {
        .topUp(TopUpPayload(
            channelId: channelIdString(),
            newDeposit: String(newDeposit),
            signature: topupTxSignature
        ))
    }
}

// MARK: - Session dispatch entry point

/// High-level entry points for the Solana session client. Mirrors the
/// Rust spine `solana_mpp::client::session` dispatch surface: pick a
/// `solana` + `session` challenge from a multi-challenge 402 response,
/// decode the embedded `SessionRequest`, and frame a `SessionAction` into
/// an `Authorization: Payment ...` header value.
public enum Session {
    /// Returns the first `solana` + `session` challenge in a list of raw
    /// `WWW-Authenticate` header values whose embedded `SessionRequest`
    /// also decodes cleanly. Mirrors `Charge.pickChallenge`.
    public static func pickChallenge(wwwAuthenticateHeaders: [String]) throws -> PaymentChallenge {
        for header in wwwAuthenticateHeaders {
            guard let challenge = try? MppHeaders.parseWWWAuthenticate(header),
                  challenge.method == "solana", challenge.intent == "session" else {
                continue
            }
            guard (try? challenge.sessionRequest) != nil else { continue }
            return challenge
        }
        throw MppError.unsupportedChallenge(method: "(missing)", intent: "(missing)")
    }

    /// Frame a `SessionAction` into the `Authorization: Payment ...`
    /// header value, echoing the challenge the action responds to.
    public static func authorizationHeader(
        for challenge: PaymentChallenge,
        action: SessionAction
    ) throws -> String {
        try challenge.requireSolanaSession()
        let encoder = JSONEncoder()
        let actionData = try encoder.encode(action)
        guard let actionObject = try JSONSerialization.jsonObject(with: actionData) as? [String: Any] else {
            throw MppError.invalidJSON("session action did not encode to a JSON object")
        }
        let credential: [String: Any] = [
            "challenge": [
                "id": challenge.id,
                "realm": challenge.realm,
                "method": challenge.method,
                "intent": challenge.intent,
                "request": challenge.request,
            ].merging(optionalChallengeFields(challenge)) { current, _ in current },
            "payload": [
                "type": "session",
                "action": actionObject,
            ],
        ]
        let credentialData = try JSONSerialization.data(
            withJSONObject: credential, options: [.sortedKeys]
        )
        return "\(MppHeaders.paymentScheme) \(Base64URL.encode(credentialData))"
    }

    private static func optionalChallengeFields(_ challenge: PaymentChallenge) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let expires = challenge.expires { fields["expires"] = expires }
        if let digest = challenge.digest { fields["digest"] = digest }
        if let opaque = challenge.opaque { fields["opaque"] = opaque }
        return fields
    }
}

// MARK: - Session consumer

/// Transport used by `SessionConsumer` to send commit payloads.
///
/// HTTP clients, queues, and in-process tests can all implement this.
/// The directive is passed alongside the payload so transports can use
/// `commitUrl`, `proof`, or other routing hints without repeating them in
/// the signed commit body.
public protocol CommitTransport: Sendable {
    func commit(directive: MeteringDirective, payload: CommitPayload) async throws -> CommitReceipt
}

/// Client-side consumer for session-metered deliveries.
public final class SessionConsumer<Transport: CommitTransport>: @unchecked Sendable {
    public let session: ActiveSession
    public let transport: Transport

    public init(session: ActiveSession, transport: Transport) {
        self.session = session
        self.transport = transport
    }

    /// Accept an envelope and return a delivery handle with `ack`/`commit`.
    public func accept<P: Codable & Sendable>(
        _ envelope: MeteredEnvelope<P>
    ) throws -> MeteredDelivery<Transport, P> {
        try validateDirective(envelope.metering)
        return MeteredDelivery(consumer: self, payload: envelope.payload, metering: envelope.metering)
    }

    /// Commit a directive directly, without constructing a delivery handle.
    @discardableResult
    public func commitDirective(_ directive: MeteringDirective) async throws -> CommitReceipt {
        try validateDirective(directive)
        let amount = try directive.amountBaseUnits()
        guard amount > 0 else {
            throw MppError.invalidTransaction("metered delivery amount must be greater than zero")
        }
        let voucher = try await session.prepareIncrement(amount)
        let payload = CommitPayload(deliveryId: directive.deliveryId, voucher: voucher)
        let receipt = try await transport.commit(directive: directive, payload: payload)
        try session.recordVoucher(payload.voucher)
        return receipt
    }

    private func validateDirective(_ directive: MeteringDirective) throws {
        let channelId = session.channelIdString()
        guard directive.sessionId == channelId else {
            throw MppError.invalidTransaction(
                "metered delivery session \(directive.sessionId) does not match active session \(channelId)"
            )
        }
    }
}

/// A delivered payload plus its metering directive. Call `ack` (or its
/// `commit` alias) after the application has processed `payload`.
public struct MeteredDelivery<Transport: CommitTransport, P: Codable & Sendable>: Sendable {
    private let consumer: SessionConsumer<Transport>
    public let payload: P
    public let metering: MeteringDirective

    init(consumer: SessionConsumer<Transport>, payload: P, metering: MeteringDirective) {
        self.consumer = consumer
        self.payload = payload
        self.metering = metering
    }

    @discardableResult
    public func ack() async throws -> CommitReceipt {
        try await consumer.commitDirective(metering)
    }

    @discardableResult
    public func commit() async throws -> CommitReceipt {
        try await ack()
    }
}
