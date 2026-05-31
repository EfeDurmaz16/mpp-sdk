import Foundation
import CryptoKit

/// Typed helpers for the payment-channels program.
///
/// Mirrors `rust/crates/mpp/src/program/payment_channels.rs`: PDA
/// derivation, associated-token derivation, distribution hashing, the
/// voucher signing-byte layout, and the instruction builders the session
/// client needs (open, top-up, ed25519 verify, settle, request-close,
/// finalize). Load-bearing parity points:
///
/// - Channel PDA seed order: `b"channel" || payer || payee || mint ||
///   authorizedSigner || salt_le`.
/// - Voucher bytes: `channelId (32) || cumulativeAmount (u64 LE) ||
///   expiresAt (i64 LE)` = 48 bytes.
/// - `distributionHash`: BLAKE3 over `len_u32_le || (recipient ||
///   bps_u16_le)*`.
public enum PaymentChannels {
    /// Canonical payment-channels program ID deployed to Surfnet.
    public static let programIdBase58 = "GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc"

    /// Channel PDA seed prefix.
    public static let channelSeed = Data("channel".utf8)

    /// Event-authority PDA seed prefix.
    public static let eventAuthoritySeed = Data("event_authority".utf8)

    /// Ed25519 precompile program ID.
    public static let ed25519ProgramBase58 = "Ed25519SigVerify111111111111111111111111111"

    /// Instructions sysvar ID.
    public static let instructionsSysvarBase58 = "Sysvar1nstructions1111111111111111111111111"

    /// Rent sysvar ID.
    public static let rentSysvarBase58 = "SysvarRent111111111111111111111111111111111"

    /// Treasury owner used by the current payment-channels deployment:
    /// the 32-byte value `0xBEEF` repeated 16 times.
    public static let treasuryOwnerBytes: [UInt8] = {
        var b = [UInt8]()
        b.reserveCapacity(32)
        for _ in 0..<16 { b.append(0xBE); b.append(0xEF) }
        return b
    }()

    public static func defaultProgramId() -> Pubkey {
        // Force-try is safe: the constant is a valid base58 pubkey, locked
        // by `PaymentChannelsTests`.
        try! Pubkey(base58: programIdBase58)
    }

    public static func ed25519ProgramId() -> Pubkey {
        try! Pubkey(base58: ed25519ProgramBase58)
    }

    public static func instructionsSysvarId() -> Pubkey {
        try! Pubkey(base58: instructionsSysvarBase58)
    }

    public static func rentSysvarId() -> Pubkey {
        try! Pubkey(base58: rentSysvarBase58)
    }

    public static func treasuryOwner() -> Pubkey {
        try! Pubkey(bytes: Data(treasuryOwnerBytes))
    }

    // MARK: - Distribution

    public struct Distribution: Equatable, Sendable {
        public let recipient: Pubkey
        public let bps: UInt16

        public init(recipient: Pubkey, bps: UInt16) {
            self.recipient = recipient
            self.bps = bps
        }
    }

    /// BLAKE3 over `len(u32 LE) || (recipient(32) || bps(u16 LE))*`.
    public static func distributionHash(_ recipients: [Distribution]) -> Data {
        var hasher = Blake3()
        var preimage = Data()
        let count = UInt32(recipients.count)
        preimage.append(contentsOf: withUnsafeBytes(of: count.littleEndian, Array.init))
        for recipient in recipients {
            preimage.append(recipient.recipient.bytes)
            preimage.append(contentsOf: withUnsafeBytes(of: recipient.bps.littleEndian, Array.init))
        }
        hasher.update(preimage)
        return hasher.finalize()
    }

    // MARK: - PDA derivation

    /// Channel PDA: seeds `b"channel" || payer || payee || mint ||
    /// authorizedSigner || salt_le`.
    public static func findChannelPda(
        payer: Pubkey,
        payee: Pubkey,
        mint: Pubkey,
        authorizedSigner: Pubkey,
        salt: UInt64,
        programId: Pubkey
    ) throws -> (address: Pubkey, bump: UInt8) {
        let saltBytes = Data(withUnsafeBytes(of: salt.littleEndian, Array.init))
        let seeds: [Data] = [
            channelSeed,
            payer.bytes,
            payee.bytes,
            mint.bytes,
            authorizedSigner.bytes,
            saltBytes,
        ]
        return try ProgramDerivedAddress.find(seeds: seeds, programId: programId)
    }

    public static func findEventAuthorityPda(programId: Pubkey) throws -> (address: Pubkey, bump: UInt8) {
        try ProgramDerivedAddress.find(seeds: [eventAuthoritySeed], programId: programId)
    }

    public static func findAssociatedTokenAddress(
        owner: Pubkey,
        mint: Pubkey,
        tokenProgram: Pubkey
    ) throws -> Pubkey {
        try AssociatedTokenAccount.address(owner: owner, mint: mint, tokenProgram: tokenProgram)
    }

    public struct OpenChannelParams: Sendable {
        public let payer: Pubkey
        public let payee: Pubkey
        public let mint: Pubkey
        public let authorizedSigner: Pubkey
        public let salt: UInt64
        public let deposit: UInt64
        public let gracePeriod: UInt32
        public let recipients: [Distribution]
        public let tokenProgram: Pubkey
        public let programId: Pubkey

        public init(
            payer: Pubkey,
            payee: Pubkey,
            mint: Pubkey,
            authorizedSigner: Pubkey,
            salt: UInt64,
            deposit: UInt64,
            gracePeriod: UInt32,
            recipients: [Distribution],
            tokenProgram: Pubkey,
            programId: Pubkey
        ) {
            self.payer = payer
            self.payee = payee
            self.mint = mint
            self.authorizedSigner = authorizedSigner
            self.salt = salt
            self.deposit = deposit
            self.gracePeriod = gracePeriod
            self.recipients = recipients
            self.tokenProgram = tokenProgram
            self.programId = programId
        }
    }

    public struct ChannelAddresses: Sendable {
        public let channel: Pubkey
        public let payerTokenAccount: Pubkey
        public let channelTokenAccount: Pubkey
        public let eventAuthority: Pubkey
    }

    public static func deriveChannelAddresses(_ params: OpenChannelParams) throws -> ChannelAddresses {
        let (channel, _) = try findChannelPda(
            payer: params.payer,
            payee: params.payee,
            mint: params.mint,
            authorizedSigner: params.authorizedSigner,
            salt: params.salt,
            programId: params.programId
        )
        let payerTokenAccount = try findAssociatedTokenAddress(
            owner: params.payer, mint: params.mint, tokenProgram: params.tokenProgram
        )
        let channelTokenAccount = try findAssociatedTokenAddress(
            owner: channel, mint: params.mint, tokenProgram: params.tokenProgram
        )
        let (eventAuthority, _) = try findEventAuthorityPda(programId: params.programId)
        return ChannelAddresses(
            channel: channel,
            payerTokenAccount: payerTokenAccount,
            channelTokenAccount: channelTokenAccount,
            eventAuthority: eventAuthority
        )
    }

    // MARK: - Voucher bytes

    /// On-chain `VoucherArgs` Borsh layout signed by Ed25519:
    /// `channelId (32) || cumulativeAmount (u64 LE) || expiresAt (i64 LE)`.
    public static func voucherMessageBytes(
        channelId: Pubkey,
        cumulativeAmount: UInt64,
        expiresAt: Int64
    ) -> Data {
        var out = Data()
        out.append(channelId.bytes)
        out.append(contentsOf: withUnsafeBytes(of: cumulativeAmount.littleEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: UInt64(bitPattern: expiresAt).littleEndian, Array.init))
        return out
    }

    // MARK: - Anchor discriminators

    /// Anchor instruction discriminator: first 8 bytes of
    /// `SHA-256("global:<name>")`. Matches the generated payment-channels
    /// Codama client the Rust spine re-exports.
    static func anchorDiscriminator(_ name: String) -> Data {
        let digest = SHA256.hash(data: Data("global:\(name)".utf8))
        return Data(digest.prefix(8))
    }

    // MARK: - Instruction builders

    /// `Open` instruction. Account order and args mirror the generated
    /// `OpenBuilder` on the spine.
    public static func buildOpenInstruction(_ params: OpenChannelParams) throws -> SolanaInstruction {
        let addresses = try deriveChannelAddresses(params)
        var data = anchorDiscriminator("open")
        data.append(contentsOf: withUnsafeBytes(of: params.salt.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: params.deposit.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: params.gracePeriod.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(params.recipients.count).littleEndian, Array.init))
        for recipient in params.recipients {
            data.append(recipient.recipient.bytes)
            data.append(contentsOf: withUnsafeBytes(of: recipient.bps.littleEndian, Array.init))
        }
        return SolanaInstruction(
            programId: params.programId,
            accounts: [
                .writableSigner(params.payer),
                .readonly(params.payee),
                .readonly(params.mint),
                .readonly(params.authorizedSigner),
                .writable(addresses.channel),
                .writable(addresses.payerTokenAccount),
                .writable(addresses.channelTokenAccount),
                .readonly(params.tokenProgram),
                .readonly(rentSysvarId()),
                .readonly(.associatedTokenProgram),
                .readonly(.systemProgram),
                .readonly(addresses.eventAuthority),
                .readonly(params.programId),
            ],
            data: data
        )
    }

    /// `TopUp` instruction.
    public static func buildTopUpInstruction(
        payer: Pubkey,
        channel: Pubkey,
        mint: Pubkey,
        amount: UInt64,
        tokenProgram: Pubkey,
        programId: Pubkey
    ) throws -> SolanaInstruction {
        let payerTokenAccount = try findAssociatedTokenAddress(
            owner: payer, mint: mint, tokenProgram: tokenProgram
        )
        let channelTokenAccount = try findAssociatedTokenAddress(
            owner: channel, mint: mint, tokenProgram: tokenProgram
        )
        var data = anchorDiscriminator("top_up")
        data.append(contentsOf: withUnsafeBytes(of: amount.littleEndian, Array.init))
        return SolanaInstruction(
            programId: programId,
            accounts: [
                .writableSigner(payer),
                .writable(channel),
                .writable(payerTokenAccount),
                .writable(channelTokenAccount),
                .readonly(mint),
                .readonly(tokenProgram),
            ],
            data: data
        )
    }

    /// Ed25519 precompile verify instruction over the voucher message.
    /// Byte layout mirrors `build_ed25519_verify_instruction`.
    public static func buildEd25519VerifyInstruction(
        authorizedSigner: Pubkey,
        signature: Data,
        message: Data
    ) throws -> SolanaInstruction {
        guard signature.count == 64 else {
            throw MppError.invalidTransaction("ed25519 signature must be 64 bytes")
        }
        let publicKeyOffset: UInt16 = 16
        let signatureOffset: UInt16 = publicKeyOffset + 32
        let messageDataOffset: UInt16 = signatureOffset + 64
        guard message.count <= Int(UInt16.max) else {
            throw MppError.invalidTransaction("ed25519 message too large")
        }
        let messageDataSize = UInt16(message.count)
        let currentInstruction: UInt16 = UInt16.max

        var data = Data()
        data.append(1) // number of signatures
        data.append(0) // padding
        data.append(contentsOf: withUnsafeBytes(of: signatureOffset.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: currentInstruction.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: publicKeyOffset.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: currentInstruction.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: messageDataOffset.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: messageDataSize.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: currentInstruction.littleEndian, Array.init))
        data.append(authorizedSigner.bytes)
        data.append(signature)
        data.append(message)

        return SolanaInstruction(
            programId: ed25519ProgramId(),
            accounts: [],
            data: data
        )
    }

    /// `Settle` instruction pair: ed25519 verify + settle. Mirrors
    /// `build_settle_instructions`.
    public static func buildSettleInstructions(
        channel: Pubkey,
        authorizedSigner: Pubkey,
        signature: Data,
        cumulativeAmount: UInt64,
        expiresAt: Int64,
        programId: Pubkey
    ) throws -> [SolanaInstruction] {
        let message = voucherMessageBytes(
            channelId: channel, cumulativeAmount: cumulativeAmount, expiresAt: expiresAt
        )
        let verify = try buildEd25519VerifyInstruction(
            authorizedSigner: authorizedSigner, signature: signature, message: message
        )
        var data = anchorDiscriminator("settle")
        data.append(channel.bytes)
        data.append(contentsOf: withUnsafeBytes(of: cumulativeAmount.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt64(bitPattern: expiresAt).littleEndian, Array.init))
        let settle = SolanaInstruction(
            programId: programId,
            accounts: [
                .writable(channel),
                .readonly(instructionsSysvarId()),
            ],
            data: data
        )
        return [verify, settle]
    }

    /// `RequestClose` instruction.
    public static func buildRequestCloseInstruction(
        payer: Pubkey,
        channel: Pubkey,
        programId: Pubkey
    ) -> SolanaInstruction {
        SolanaInstruction(
            programId: programId,
            accounts: [
                .writableSigner(payer),
                .writable(channel),
            ],
            data: anchorDiscriminator("request_close")
        )
    }

    /// `Finalize` instruction.
    public static func buildFinalizeInstruction(
        channel: Pubkey,
        programId: Pubkey
    ) -> SolanaInstruction {
        SolanaInstruction(
            programId: programId,
            accounts: [.writable(channel)],
            data: anchorDiscriminator("finalize")
        )
    }
}
