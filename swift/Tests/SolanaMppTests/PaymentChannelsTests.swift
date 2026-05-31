import Foundation
import Testing
@testable import SolanaMpp

/// Golden-vector parity for the payment-channels helpers against values
/// generated from `rust/crates/mpp/src/program/payment_channels.rs`.
@Suite("Payment-channels helpers parity")
struct PaymentChannelsTests {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func pk(_ byte: UInt8) -> Pubkey {
        try! Pubkey(bytes: Data(repeating: byte, count: 32))
    }

    @Test
    func voucherMessageBytesLayout() {
        let bytes = PaymentChannels.voucherMessageBytes(
            channelId: pk(9), cumulativeAmount: 42, expiresAt: 1234
        )
        #expect(bytes.count == 48)
        #expect(hex(bytes) ==
            "09090909090909090909090909090909090909090909090909090909090909092a00000000000000d204000000000000")
    }

    @Test
    func voucherMessageBytesNegativeExpiry() {
        // i64 expiresAt encodes as two's-complement little-endian u64.
        let bytes = PaymentChannels.voucherMessageBytes(
            channelId: pk(0), cumulativeAmount: 0, expiresAt: -1
        )
        #expect(bytes.count == 48)
        #expect(hex(bytes.suffix(8)) == "ffffffffffffffff")
    }

    @Test
    func distributionHashTwoRecipients() {
        let recipients = [
            PaymentChannels.Distribution(recipient: pk(1), bps: 7500),
            PaymentChannels.Distribution(recipient: pk(2), bps: 2500),
        ]
        #expect(hex(PaymentChannels.distributionHash(recipients)) ==
            "2c00d870359f0a4861c420eaeffdf7a7d6b2cd281024ee69e1f12f743e04c416")
    }

    @Test
    func distributionHashEmpty() {
        #expect(hex(PaymentChannels.distributionHash([])) ==
            "ec2bd03bf86b935fa34d71ad7ebb049f1f10f87d343e521511d8f9e6625620cd")
    }

    @Test
    func channelPdaIsStable() throws {
        let programId = PaymentChannels.defaultProgramId()
        let (channel, bump) = try PaymentChannels.findChannelPda(
            payer: pk(1), payee: pk(2), mint: pk(3), authorizedSigner: pk(4),
            salt: 99, programId: programId
        )
        #expect(channel.base58 == "H4q6bNCrC8R1ieNqoWuMz5V4VmQPLYFhYqTKzsPCejgf")
        #expect(bump == 254)
    }

    @Test
    func anchorDiscriminatorOpen() {
        // First 8 bytes of SHA-256("global:open").
        #expect(hex(PaymentChannels.anchorDiscriminator("open")) == "e4dc9b47c7bd3c2d")
    }

    @Test
    func treasuryOwnerIsBeef() {
        let owner = PaymentChannels.treasuryOwner()
        #expect(owner.bytes.count == 32)
        #expect(owner.bytes.first == 0xBE)
        #expect(owner.bytes[owner.bytes.startIndex + 1] == 0xEF)
    }

    @Test
    func ed25519VerifyInstructionLayout() throws {
        let signer = pk(7)
        let signature = Data(repeating: 0xAB, count: 64)
        let message = Data(repeating: 0xCD, count: 48)
        let ix = try PaymentChannels.buildEd25519VerifyInstruction(
            authorizedSigner: signer, signature: signature, message: message
        )
        #expect(ix.programId == PaymentChannels.ed25519ProgramId())
        #expect(ix.accounts.isEmpty)
        // header(2) + offsets(14) + pubkey(32) + sig(64) + message(48).
        #expect(ix.data.count == 2 + 14 + 32 + 64 + 48)
        #expect(ix.data.first == 1)
        // public key embedded at offset 16.
        #expect(Array(ix.data[16..<48]) == Array(signer.bytes))
    }
}
