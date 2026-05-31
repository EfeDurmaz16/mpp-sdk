package com.solana.mpp.client

import com.solana.mpp.crypto.Blake3
import com.solana.mpp.crypto.Programs
import com.solana.mpp.crypto.PublicKey

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Byte-for-byte parity oracles for the payment-channels helpers. Golden
 * values mirror the Rust spine
 * (`rust/crates/mpp/src/program/payment_channels.rs::tests`) and the Go
 * port (`go/protocols/mpp/program/payment_channels_test.go`).
 */
class PaymentChannelsTest {
    private fun pk(byte: Int): PublicKey = PublicKey(ByteArray(32) { byte.toByte() })

    private fun u64LE(value: Long): ByteArray {
        val out = ByteArray(8)
        for (i in 0 until 8) out[i] = ((value ushr (8 * i)) and 0xff).toByte()
        return out
    }

    private fun u32LE(value: Int): ByteArray {
        val out = ByteArray(4)
        for (i in 0 until 4) out[i] = ((value ushr (8 * i)) and 0xff).toByte()
        return out
    }

    private fun u16LE(value: Int): ByteArray =
        byteArrayOf((value and 0xff).toByte(), ((value ushr 8) and 0xff).toByte())

    // ── Voucher message bytes ──

    @Test
    fun voucherMessageIsProgramBorshLayout() {
        val bytes = PaymentChannels.voucherMessageBytes(pk(9), 42, 1234)
        assertEquals(48, bytes.size)
        assertContentEquals(pk(9).bytes, bytes.copyOfRange(0, 32))
        assertContentEquals(u64LE(42), bytes.copyOfRange(32, 40))
        assertContentEquals(u64LE(1234), bytes.copyOfRange(40, 48))
    }

    @Test
    fun voucherMessageKnownValues() {
        val bytes = PaymentChannels.voucherMessageBytes(pk(3), 1000, 42)
        assertEquals(48, bytes.size)
        assertContentEquals(u64LE(1000), bytes.copyOfRange(32, 40))
        assertContentEquals(u64LE(42), bytes.copyOfRange(40, 48))
    }

    @Test
    fun voucherMessageDiffersByCumulative() {
        val a = PaymentChannels.voucherMessageBytes(pk(6), 100, 42)
        val b = PaymentChannels.voucherMessageBytes(pk(6), 200, 42)
        assertTrue(!a.contentEquals(b))
    }

    // ── Distribution hash ──

    @Test
    fun distributionHashMatchesProgramPreimageShape() {
        val recipients = listOf(
            PaymentChannels.Distribution(pk(1), 7_500),
            PaymentChannels.Distribution(pk(2), 2_500),
        )
        val hasher = Blake3()
        hasher.update(u32LE(2))
        hasher.update(pk(1).bytes)
        hasher.update(u16LE(7_500))
        hasher.update(pk(2).bytes)
        hasher.update(u16LE(2_500))
        assertContentEquals(hasher.finalize(), PaymentChannels.distributionHash(recipients))
    }

    @Test
    fun distributionHashEmpty() {
        val hasher = Blake3()
        hasher.update(byteArrayOf(0, 0, 0, 0))
        assertContentEquals(hasher.finalize(), PaymentChannels.distributionHash(emptyList()))
    }

    // ── Channel PDA ──

    @Test
    fun channelPdaIsStable() {
        val programId = PaymentChannels.defaultProgramId()
        val (channel1, bump1) = PaymentChannels.findChannelPda(pk(1), pk(2), pk(3), pk(4), 99, programId)
        val (channel2, bump2) = PaymentChannels.findChannelPda(pk(1), pk(2), pk(3), pk(4), 99, programId)
        assertEquals(channel1, channel2)
        assertEquals(bump1, bump2)
    }

    @Test
    fun channelPdaDiffersBySalt() {
        val programId = PaymentChannels.defaultProgramId()
        val (a, _) = PaymentChannels.findChannelPda(pk(1), pk(2), pk(3), pk(4), 1, programId)
        val (b, _) = PaymentChannels.findChannelPda(pk(1), pk(2), pk(3), pk(4), 2, programId)
        assertTrue(a != b)
    }

    // ── Open instruction shape ──

    @Test
    fun buildOpenInstructionShape() {
        val programId = PaymentChannels.defaultProgramId()
        val params = PaymentChannels.OpenChannelParams(
            payer = pk(1),
            payee = pk(2),
            mint = pk(3),
            authorizedSigner = pk(4),
            salt = 7,
            deposit = 1_000_000,
            gracePeriod = 900,
            recipients = emptyList(),
            tokenProgram = PublicKey.fromBase58(Programs.TOKEN_PROGRAM),
            programId = programId,
        )
        val ix = PaymentChannels.buildOpenInstruction(params)
        assertEquals(programId.toBase58(), ix.programId)
        assertEquals(13, ix.accounts.size)
        // Discriminator 1, then OpenArgs Borsh: salt(8) deposit(8) grace(4) recipients-len(4).
        assertEquals(1.toByte(), ix.data[0])
        assertContentEquals(u64LE(7), ix.data.copyOfRange(1, 9))
        assertContentEquals(u64LE(1_000_000), ix.data.copyOfRange(9, 17))
        assertContentEquals(u32LE(900), ix.data.copyOfRange(17, 21))
        assertContentEquals(u32LE(0), ix.data.copyOfRange(21, 25))
        assertEquals(25, ix.data.size)
        // payer is signer + writable, channel/payerATA/channelATA writable.
        assertTrue(ix.accounts[0].isSigner && ix.accounts[0].isWritable)
        assertTrue(ix.accounts[4].isWritable)
    }

    @Test
    fun buildOpenInstructionWithRecipients() {
        val programId = PaymentChannels.defaultProgramId()
        val params = PaymentChannels.OpenChannelParams(
            payer = pk(1),
            payee = pk(2),
            mint = pk(3),
            authorizedSigner = pk(4),
            salt = 0,
            deposit = 500,
            gracePeriod = 0,
            recipients = listOf(PaymentChannels.Distribution(pk(5), 1000)),
            tokenProgram = PublicKey.fromBase58(Programs.TOKEN_PROGRAM),
            programId = programId,
        )
        val ix = PaymentChannels.buildOpenInstruction(params)
        // 1 + 8 + 8 + 4 + 4 + (32 + 2) = 59.
        assertEquals(59, ix.data.size)
        assertContentEquals(u32LE(1), ix.data.copyOfRange(21, 25))
        assertContentEquals(pk(5).bytes, ix.data.copyOfRange(25, 57))
        assertContentEquals(u16LE(1000), ix.data.copyOfRange(57, 59))
    }

    @Test
    fun buildTopUpInstructionShape() {
        val programId = PaymentChannels.defaultProgramId()
        val ix = PaymentChannels.buildTopUpInstruction(
            payer = pk(1),
            channel = pk(2),
            mint = pk(3),
            amount = 250_000,
            tokenProgram = PublicKey.fromBase58(Programs.TOKEN_PROGRAM),
            programId = programId,
        )
        assertEquals(programId.toBase58(), ix.programId)
        assertEquals(6, ix.accounts.size)
        assertEquals(3.toByte(), ix.data[0])
        assertContentEquals(u64LE(250_000), ix.data.copyOfRange(1, 9))
        assertEquals(9, ix.data.size)
    }

    // ── Ed25519 verify instruction ──

    @Test
    fun ed25519VerifyInstructionLayout() {
        val signer = pk(8)
        val signature = ByteArray(64) { 1 }
        val message = PaymentChannels.voucherMessageBytes(pk(9), 42, 1234)
        val ix = PaymentChannels.buildEd25519VerifyInstruction(signer, signature, message)
        assertEquals(PaymentChannels.ED25519_PROGRAM_ID, ix.programId)
        // header(16) + pubkey(32) + sig(64) + message(48) = 160.
        assertEquals(16 + 32 + 64 + message.size, ix.data.size)
        assertEquals(1.toByte(), ix.data[0])
        assertEquals(0.toByte(), ix.data[1])
        // public key offset 16, signature offset 48, message offset 112.
        assertContentEquals(u16LE(48), ix.data.copyOfRange(2, 4))
        assertContentEquals(pk(8).bytes, ix.data.copyOfRange(16, 48))
        assertContentEquals(signature, ix.data.copyOfRange(48, 112))
        assertContentEquals(message, ix.data.copyOfRange(112, 160))
    }
}
