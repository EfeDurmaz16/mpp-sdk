import Foundation

// MARK: - Session intent wire types
//
// Mirrors the Rust spine `rust/crates/mpp/src/protocol/intents/session.rs`
// exactly for wire shapes. Load-bearing parity points:
//
// - `salt` is a `u64` serialized as a decimal string, but deserialized
//   from either a string or a JSON number (legacy compatibility).
// - `cumulativeAmount` is the wire name; the alias `cumulative` is also
//   accepted on decode. Serialize only as `cumulativeAmount`.
// - The `SessionAction` tag uses `topUp` (capital U) for the top-up
//   variant; `open`/`voucher`/`commit`/`close` are lower-case.
// - `SessionMode` is camelCase (`push`/`pull`).
// - `CommitStatus` is camelCase (`committed`/`replayed`).
// - Voucher signing bytes are the on-chain Borsh `VoucherArgs` layout:
//   `channelId (32) || cumulativeAmount (u64 LE, 8) || expiresAt (i64 LE,
//   8)` = 48 bytes. See `VoucherData.messageBytes`.

/// Default session voucher/directive expiry: 2100-01-01T00:00:00Z.
///
/// This stays below JavaScript's max safe integer so JSON intermediaries
/// do not round it before the credential is decoded.
public let DEFAULT_SESSION_EXPIRES_AT: Int64 = 4_102_444_800

/// On-chain funding mechanism for a session, advertised by the server in
/// `SessionRequest.modes`.
public enum SessionMode: String, Codable, Equatable, Sendable {
    case push
    case pull
}

/// Voucher authority used when `SessionMode.pull` is advertised.
public enum SessionPullVoucherStrategy: String, Codable, Equatable, Sendable {
    case clientVoucher
    case operatedVoucher
}

/// A payment split committed at channel open; distributed to a specific
/// recipient when the channel closes.
public struct SessionSplit: Codable, Equatable, Sendable {
    public let recipient: String
    public let bps: UInt16

    public init(recipient: String, bps: UInt16) {
        self.recipient = recipient
        self.bps = bps
    }
}

/// Session intent request — the payload embedded in a 402 challenge.
public struct SessionRequest: Codable, Equatable, Sendable {
    public let cap: String
    public let currency: String
    public let decimals: UInt8?
    public let network: String?
    public let `operator`: String
    public let recipient: String
    public let splits: [SessionSplit]
    public let programId: String?
    public let description: String?
    public let externalId: String?
    public let minVoucherDelta: String?
    public let modes: [SessionMode]
    public let pullVoucherStrategy: SessionPullVoucherStrategy?
    public let recentBlockhash: String?

    public init(
        cap: String,
        currency: String,
        decimals: UInt8? = nil,
        network: String? = nil,
        operator op: String,
        recipient: String,
        splits: [SessionSplit] = [],
        programId: String? = nil,
        description: String? = nil,
        externalId: String? = nil,
        minVoucherDelta: String? = nil,
        modes: [SessionMode] = [],
        pullVoucherStrategy: SessionPullVoucherStrategy? = nil,
        recentBlockhash: String? = nil
    ) {
        self.cap = cap
        self.currency = currency
        self.decimals = decimals
        self.network = network
        self.operator = op
        self.recipient = recipient
        self.splits = splits
        self.programId = programId
        self.description = description
        self.externalId = externalId
        self.minVoucherDelta = minVoucherDelta
        self.modes = modes
        self.pullVoucherStrategy = pullVoucherStrategy
        self.recentBlockhash = recentBlockhash
    }

    private enum CodingKeys: String, CodingKey {
        case cap, currency, decimals, network, `operator`, recipient, splits
        case programId, description, externalId, minVoucherDelta, modes
        case pullVoucherStrategy, recentBlockhash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cap = try c.decode(String.self, forKey: .cap)
        currency = try c.decode(String.self, forKey: .currency)
        decimals = try c.decodeIfPresent(UInt8.self, forKey: .decimals)
        network = try c.decodeIfPresent(String.self, forKey: .network)
        `operator` = try c.decode(String.self, forKey: .operator)
        recipient = try c.decode(String.self, forKey: .recipient)
        splits = try c.decodeIfPresent([SessionSplit].self, forKey: .splits) ?? []
        programId = try c.decodeIfPresent(String.self, forKey: .programId)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        minVoucherDelta = try c.decodeIfPresent(String.self, forKey: .minVoucherDelta)
        modes = try c.decodeIfPresent([SessionMode].self, forKey: .modes) ?? []
        pullVoucherStrategy = try c.decodeIfPresent(
            SessionPullVoucherStrategy.self, forKey: .pullVoucherStrategy
        )
        recentBlockhash = try c.decodeIfPresent(String.self, forKey: .recentBlockhash)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cap, forKey: .cap)
        try c.encode(currency, forKey: .currency)
        try c.encodeIfPresent(decimals, forKey: .decimals)
        try c.encodeIfPresent(network, forKey: .network)
        try c.encode(`operator`, forKey: .operator)
        try c.encode(recipient, forKey: .recipient)
        if !splits.isEmpty { try c.encode(splits, forKey: .splits) }
        try c.encodeIfPresent(programId, forKey: .programId)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(externalId, forKey: .externalId)
        try c.encodeIfPresent(minVoucherDelta, forKey: .minVoucherDelta)
        if !modes.isEmpty { try c.encode(modes, forKey: .modes) }
        try c.encodeIfPresent(pullVoucherStrategy, forKey: .pullVoucherStrategy)
        try c.encodeIfPresent(recentBlockhash, forKey: .recentBlockhash)
    }
}

// MARK: - Open payload

/// Payload for the `open` action. Use `OpenPayload.push`,
/// `OpenPayload.paymentChannel`, or `OpenPayload.pull` to construct.
public struct OpenPayload: Codable, Equatable, Sendable {
    public var mode: SessionMode
    // Push fields
    public var channelId: String?
    public var deposit: String?
    public var payer: String?
    public var payee: String?
    public var mint: String?
    public var salt: UInt64?
    public var gracePeriod: UInt32?
    public var transaction: String?
    // Pull fields
    public var tokenAccount: String?
    public var approvedAmount: String?
    public var owner: String?
    public var initMultiDelegateTx: String?
    public var updateDelegationTx: String?
    // Shared
    public var authorizedSigner: String
    public var signature: String

    init(
        mode: SessionMode,
        channelId: String? = nil,
        deposit: String? = nil,
        payer: String? = nil,
        payee: String? = nil,
        mint: String? = nil,
        salt: UInt64? = nil,
        gracePeriod: UInt32? = nil,
        transaction: String? = nil,
        tokenAccount: String? = nil,
        approvedAmount: String? = nil,
        owner: String? = nil,
        initMultiDelegateTx: String? = nil,
        updateDelegationTx: String? = nil,
        authorizedSigner: String,
        signature: String
    ) {
        self.mode = mode
        self.channelId = channelId
        self.deposit = deposit
        self.payer = payer
        self.payee = payee
        self.mint = mint
        self.salt = salt
        self.gracePeriod = gracePeriod
        self.transaction = transaction
        self.tokenAccount = tokenAccount
        self.approvedAmount = approvedAmount
        self.owner = owner
        self.initMultiDelegateTx = initMultiDelegateTx
        self.updateDelegationTx = updateDelegationTx
        self.authorizedSigner = authorizedSigner
        self.signature = signature
    }

    /// Construct a **push** payment-channel open payload.
    public static func push(
        channelId: String,
        deposit: String,
        authorizedSigner: String,
        signature: String
    ) -> OpenPayload {
        OpenPayload(
            mode: .push,
            channelId: channelId,
            deposit: deposit,
            authorizedSigner: authorizedSigner,
            signature: signature
        )
    }

    /// Construct a payment-channel **push** open payload.
    public static func paymentChannel(
        channelId: String,
        deposit: String,
        payer: String,
        payee: String,
        mint: String,
        salt: UInt64,
        gracePeriod: UInt32,
        authorizedSigner: String,
        signature: String
    ) -> OpenPayload {
        paymentChannel(
            mode: .push,
            channelId: channelId,
            deposit: deposit,
            payer: payer,
            payee: payee,
            mint: mint,
            salt: salt,
            gracePeriod: gracePeriod,
            authorizedSigner: authorizedSigner,
            signature: signature
        )
    }

    /// Construct a payment-channel open payload with an explicit submission mode.
    public static func paymentChannel(
        mode: SessionMode,
        channelId: String,
        deposit: String,
        payer: String,
        payee: String,
        mint: String,
        salt: UInt64,
        gracePeriod: UInt32,
        authorizedSigner: String,
        signature: String
    ) -> OpenPayload {
        OpenPayload(
            mode: mode,
            channelId: channelId,
            deposit: deposit,
            payer: payer,
            payee: payee,
            mint: mint,
            salt: salt,
            gracePeriod: gracePeriod,
            authorizedSigner: authorizedSigner,
            signature: signature
        )
    }

    /// Construct a **pull** (SPL delegation) open payload.
    public static func pull(
        tokenAccount: String,
        approvedAmount: String,
        owner: String,
        authorizedSigner: String,
        signature: String
    ) -> OpenPayload {
        OpenPayload(
            mode: .pull,
            tokenAccount: tokenAccount,
            approvedAmount: approvedAmount,
            owner: owner,
            authorizedSigner: authorizedSigner,
            signature: signature
        )
    }

    /// Attach a signed open transaction for operator/server broadcast.
    public func withTransaction(_ txBase64: String) -> OpenPayload {
        var copy = self
        copy.transaction = txBase64
        return copy
    }

    /// Attach a pre-signed `InitMultiDelegate` + `CreateFixedDelegation` transaction.
    public func withInitTx(_ txBase64: String) -> OpenPayload {
        var copy = self
        copy.initMultiDelegateTx = txBase64
        return copy
    }

    /// Attach a pre-signed `CreateFixedDelegation` (cap update) transaction.
    public func withUpdateTx(_ txBase64: String) -> OpenPayload {
        var copy = self
        copy.updateDelegationTx = txBase64
        return copy
    }

    /// Session identifier used as the store key: `channelId` for push,
    /// `tokenAccount` for operated-voucher pull.
    public func sessionId() throws -> String {
        if let channelId = channelId { return channelId }
        switch mode {
        case .push:
            throw MppError.missingField("push open missing channelId")
        case .pull:
            guard let tokenAccount = tokenAccount else {
                throw MppError.missingField("pull open missing channelId or tokenAccount")
            }
            return tokenAccount
        }
    }

    /// Deposit / approved amount for this open (base units).
    public func depositAmount() throws -> UInt64 {
        let raw: String
        if let deposit = deposit {
            raw = deposit
        } else {
            switch mode {
            case .push:
                throw MppError.missingField("push open missing deposit")
            case .pull:
                guard let approved = approvedAmount else {
                    throw MppError.missingField("pull open missing deposit or approvedAmount")
                }
                raw = approved
            }
        }
        guard let parsed = UInt64(raw) else {
            throw MppError.invalidTransaction("invalid deposit amount: \(raw)")
        }
        return parsed
    }

    private enum CodingKeys: String, CodingKey {
        case mode, channelId, deposit, payer, payee, mint, salt, gracePeriod
        case transaction, tokenAccount, approvedAmount, owner
        case initMultiDelegateTx, updateDelegationTx, authorizedSigner, signature
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(SessionMode.self, forKey: .mode)
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId)
        deposit = try c.decodeIfPresent(String.self, forKey: .deposit)
        payer = try c.decodeIfPresent(String.self, forKey: .payer)
        payee = try c.decodeIfPresent(String.self, forKey: .payee)
        mint = try c.decodeIfPresent(String.self, forKey: .mint)
        salt = try OpenPayload.decodeOptionalU64(c, forKey: .salt)
        gracePeriod = try c.decodeIfPresent(UInt32.self, forKey: .gracePeriod)
        transaction = try c.decodeIfPresent(String.self, forKey: .transaction)
        tokenAccount = try c.decodeIfPresent(String.self, forKey: .tokenAccount)
        approvedAmount = try c.decodeIfPresent(String.self, forKey: .approvedAmount)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        initMultiDelegateTx = try c.decodeIfPresent(String.self, forKey: .initMultiDelegateTx)
        updateDelegationTx = try c.decodeIfPresent(String.self, forKey: .updateDelegationTx)
        authorizedSigner = try c.decode(String.self, forKey: .authorizedSigner)
        signature = try c.decode(String.self, forKey: .signature)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(channelId, forKey: .channelId)
        try c.encodeIfPresent(deposit, forKey: .deposit)
        try c.encodeIfPresent(payer, forKey: .payer)
        try c.encodeIfPresent(payee, forKey: .payee)
        try c.encodeIfPresent(mint, forKey: .mint)
        // `salt` is always emitted as a decimal string (never a JSON
        // number) because arbitrary u64 values are not safe JSON numbers.
        if let salt = salt { try c.encode(String(salt), forKey: .salt) }
        try c.encodeIfPresent(gracePeriod, forKey: .gracePeriod)
        try c.encodeIfPresent(transaction, forKey: .transaction)
        try c.encodeIfPresent(tokenAccount, forKey: .tokenAccount)
        try c.encodeIfPresent(approvedAmount, forKey: .approvedAmount)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encodeIfPresent(initMultiDelegateTx, forKey: .initMultiDelegateTx)
        try c.encodeIfPresent(updateDelegationTx, forKey: .updateDelegationTx)
        try c.encode(authorizedSigner, forKey: .authorizedSigner)
        try c.encode(signature, forKey: .signature)
    }

    /// Decode an optional `u64` that may appear as a decimal string
    /// (canonical) or a JSON number (legacy ecosystem compatibility).
    private static func decodeOptionalU64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UInt64? {
        guard container.contains(key) else { return nil }
        if (try? container.decodeNil(forKey: key)) == true { return nil }
        if let string = try? container.decode(String.self, forKey: key) {
            guard let value = UInt64(string) else {
                throw MppError.invalidJSON("salt must be an unsigned 64-bit integer")
            }
            return value
        }
        if let number = try? container.decode(UInt64.self, forKey: key) {
            return number
        }
        if !container.contains(key) { return nil }
        throw MppError.invalidJSON(
            "salt must be a decimal string or unsigned 64-bit integer"
        )
    }
}

// MARK: - Vouchers

/// The canonical content of a voucher, signed by the client's session key.
///
/// Serialized to the on-chain `VoucherArgs` layout before signing:
/// `channelId || cumulativeAmount_le || expiresAt_le`.
public struct VoucherData: Codable, Equatable, Sendable {
    /// The channel/session ID this voucher is bound to (base58).
    public let channelId: String
    /// Cumulative amount authorized (base units, monotonically increasing).
    public let cumulative: String
    /// Unix timestamp at which this voucher expires.
    public let expiresAt: Int64
    /// Optional client-side request counter. Not in the on-chain bytes.
    public let nonce: UInt64?

    public init(channelId: String, cumulative: String, expiresAt: Int64, nonce: UInt64? = nil) {
        self.channelId = channelId
        self.cumulative = cumulative
        self.expiresAt = expiresAt
        self.nonce = nonce
    }

    private enum CodingKeys: String, CodingKey {
        case channelId
        case cumulative = "cumulativeAmount"
        case cumulativeAlias = "cumulative"
        case expiresAt
        case nonce
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try c.decode(String.self, forKey: .channelId)
        // Wire name is `cumulativeAmount`; accept `cumulative` as an alias.
        if let value = try c.decodeIfPresent(String.self, forKey: .cumulative) {
            cumulative = value
        } else {
            cumulative = try c.decode(String.self, forKey: .cumulativeAlias)
        }
        expiresAt = try c.decode(Int64.self, forKey: .expiresAt)
        nonce = try c.decodeIfPresent(UInt64.self, forKey: .nonce)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channelId, forKey: .channelId)
        // Serialize only as `cumulativeAmount`.
        try c.encode(cumulative, forKey: .cumulative)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(nonce, forKey: .nonce)
    }

    /// Serialize to the payment-channels `VoucherArgs` bytes signed by
    /// Ed25519: `channelId (32) || cumulativeAmount (u64 LE) || expiresAt
    /// (i64 LE)` = 48 bytes.
    public func messageBytes() throws -> Data {
        let channel = try Pubkey(base58: channelId)
        guard let cumulativeValue = UInt64(cumulative) else {
            throw MppError.invalidTransaction("invalid voucher cumulative")
        }
        return PaymentChannels.voucherMessageBytes(
            channelId: channel,
            cumulativeAmount: cumulativeValue,
            expiresAt: expiresAt
        )
    }
}

/// A signed voucher authorizing cumulative payment up to `cumulative`.
public struct SignedVoucher: Codable, Equatable, Sendable {
    public let data: VoucherData
    /// Ed25519 signature over the Borsh voucher bytes (base58).
    public let signature: String

    public init(data: VoucherData, signature: String) {
        self.data = data
        self.signature = signature
    }
}

// MARK: - Action payloads

/// Payload for the `voucher` action (per-request micropayment).
public struct VoucherPayload: Codable, Equatable, Sendable {
    public let voucher: SignedVoucher

    public init(voucher: SignedVoucher) {
        self.voucher = voucher
    }
}

/// Payload for the `commit` action.
public struct CommitPayload: Codable, Equatable, Sendable {
    public let deliveryId: String
    public let voucher: SignedVoucher

    public init(deliveryId: String, voucher: SignedVoucher) {
        self.deliveryId = deliveryId
        self.voucher = voucher
    }
}

/// Payload for the `topUp` action.
public struct TopUpPayload: Codable, Equatable, Sendable {
    public let channelId: String
    public let newDeposit: String
    public let signature: String

    public init(channelId: String, newDeposit: String, signature: String) {
        self.channelId = channelId
        self.newDeposit = newDeposit
        self.signature = signature
    }
}

/// Payload for the `close` action.
public struct ClosePayload: Codable, Equatable, Sendable {
    public let channelId: String
    public let voucher: SignedVoucher?

    public init(channelId: String, voucher: SignedVoucher? = nil) {
        self.channelId = channelId
        self.voucher = voucher
    }
}

/// The action submitted by the client in an Authorization header.
///
/// Serialized as a tagged object with
/// `"action": "open" | "voucher" | "commit" | "topUp" | "close"`. Note the
/// capital `U` in `topUp` matches the Rust spine `rename_all = "camelCase"`
/// derivation of the `TopUp` variant.
public enum SessionAction: Codable, Equatable, Sendable {
    case open(OpenPayload)
    case voucher(VoucherPayload)
    case commit(CommitPayload)
    case topUp(TopUpPayload)
    case close(ClosePayload)

    private enum ActionKey: String, CodingKey {
        case action
    }

    private static let openTag = "open"
    private static let voucherTag = "voucher"
    private static let commitTag = "commit"
    private static let topUpTag = "topUp"
    private static let closeTag = "close"

    public init(from decoder: Decoder) throws {
        let tagContainer = try decoder.container(keyedBy: ActionKey.self)
        let tag = try tagContainer.decode(String.self, forKey: .action)
        switch tag {
        case SessionAction.openTag:
            self = .open(try OpenPayload(from: decoder))
        case SessionAction.voucherTag:
            self = .voucher(try VoucherPayload(from: decoder))
        case SessionAction.commitTag:
            self = .commit(try CommitPayload(from: decoder))
        case SessionAction.topUpTag:
            self = .topUp(try TopUpPayload(from: decoder))
        case SessionAction.closeTag:
            self = .close(try ClosePayload(from: decoder))
        default:
            throw MppError.invalidJSON("unknown session action \"\(tag)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Encode the tag, then merge the payload's fields into the same
        // object. JSONEncoder flattens because the payload encodes into
        // the shared keyed container of `encoder`.
        var tagContainer = encoder.container(keyedBy: ActionKey.self)
        switch self {
        case .open(let payload):
            try tagContainer.encode(SessionAction.openTag, forKey: .action)
            try payload.encode(to: encoder)
        case .voucher(let payload):
            try tagContainer.encode(SessionAction.voucherTag, forKey: .action)
            try payload.encode(to: encoder)
        case .commit(let payload):
            try tagContainer.encode(SessionAction.commitTag, forKey: .action)
            try payload.encode(to: encoder)
        case .topUp(let payload):
            try tagContainer.encode(SessionAction.topUpTag, forKey: .action)
            try payload.encode(to: encoder)
        case .close(let payload):
            try tagContainer.encode(SessionAction.closeTag, forKey: .action)
            try payload.encode(to: encoder)
        }
    }
}

// MARK: - Metering

/// Server-issued metering directive attached to a delivered message.
public struct MeteringDirective: Codable, Equatable, Sendable {
    public let deliveryId: String
    public let sessionId: String
    public let amount: String
    public let currency: String
    public let sequence: UInt64
    public let expiresAt: Int64
    public let commitUrl: String?
    public let proof: String?

    public init(
        deliveryId: String,
        sessionId: String,
        amount: String,
        currency: String,
        sequence: UInt64,
        expiresAt: Int64,
        commitUrl: String? = nil,
        proof: String? = nil
    ) {
        self.deliveryId = deliveryId
        self.sessionId = sessionId
        self.amount = amount
        self.currency = currency
        self.sequence = sequence
        self.expiresAt = expiresAt
        self.commitUrl = commitUrl
        self.proof = proof
    }

    /// Parse `amount` as base units.
    public func amountBaseUnits() throws -> UInt64 {
        guard let value = UInt64(amount) else {
            throw MppError.invalidTransaction("invalid metering amount: \(amount)")
        }
        return value
    }
}

/// Final usage reported by a streaming response.
public struct MeteringUsage: Codable, Equatable, Sendable {
    public let deliveryId: String
    public let amount: String

    public init(deliveryId: String, amount: String) {
        self.deliveryId = deliveryId
        self.amount = amount
    }

    public func amountBaseUnits() throws -> UInt64 {
        guard let value = UInt64(amount) else {
            throw MppError.invalidTransaction("invalid metering usage amount: \(amount)")
        }
        return value
    }
}

/// A payload paired with the metering directive required to acknowledge it.
public struct MeteredEnvelope<T: Codable & Sendable>: Codable, Sendable {
    public let payload: T
    public let metering: MeteringDirective

    public init(payload: T, metering: MeteringDirective) {
        self.payload = payload
        self.metering = metering
    }
}

/// Commit receipt status.
public enum CommitStatus: String, Codable, Equatable, Sendable {
    case committed
    case replayed
}

/// Result returned after a delivery commit is accepted.
public struct CommitReceipt: Codable, Equatable, Sendable {
    public let deliveryId: String
    public let sessionId: String
    public let amount: String
    public let cumulative: String
    public let status: CommitStatus

    public init(
        deliveryId: String,
        sessionId: String,
        amount: String,
        cumulative: String,
        status: CommitStatus
    ) {
        self.deliveryId = deliveryId
        self.sessionId = sessionId
        self.amount = amount
        self.cumulative = cumulative
        self.status = status
    }
}
