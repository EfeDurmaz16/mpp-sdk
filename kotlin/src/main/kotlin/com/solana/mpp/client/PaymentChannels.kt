package com.solana.mpp.client

import com.solana.mpp.crypto.AccountMeta
import com.solana.mpp.crypto.Blake3
import com.solana.mpp.crypto.Instruction
import com.solana.mpp.crypto.Pda
import com.solana.mpp.crypto.Programs
import com.solana.mpp.crypto.PublicKey

/**
 * Typed helpers for the on-chain payment-channels program used by the MPP
 * session intent: channel PDA derivation, associated-token derivation, the
 * blake3 distribution hash, the Borsh voucher signing bytes, the Ed25519
 * precompile verify instruction, and the Open / TopUp instruction builders.
 *
 * Byte layouts mirror `rust/crates/mpp/src/program/payment_channels.rs`
 * exactly so cross-language vouchers and PDAs match. The voucher signing
 * bytes are channelId(32) || cumulativeAmount(u64 LE, 8) ||
 * expiresAt(i64 LE, 8) = 48 bytes, signed with Ed25519.
 */
object PaymentChannels {
    /** Canonical payment-channels program ID deployed to Surfnet. */
    const val PAYMENT_CHANNELS_PROGRAM_ID = "GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc"

    /** Channel PDA seed prefix. */
    const val CHANNEL_SEED = "channel"

    /** Event authority PDA seed prefix. */
    const val EVENT_AUTHORITY_SEED = "event_authority"

    /** Ed25519 signature-verify precompile program ID. */
    const val ED25519_PROGRAM_ID = "Ed25519SigVerify111111111111111111111111111"

    /** Instructions sysvar account ID. */
    const val INSTRUCTIONS_SYSVAR_ID = "Sysvar1nstructions1111111111111111111111111"

    /** Rent sysvar account ID. */
    const val RENT_SYSVAR_ID = "SysvarRent111111111111111111111111111111111"

    /** Length of the Borsh voucher signing message. */
    const val VOUCHER_MESSAGE_LEN = 48

    // Anchor instruction discriminators for the payment-channels program.
    private const val OPEN_DISCRIMINATOR: Byte = 1
    private const val TOP_UP_DISCRIMINATOR: Byte = 3

    /** A single split recipient with a basis-point share. */
    data class Distribution(val recipient: PublicKey, val bps: Int) {
        init {
            require(bps in 0..0xffff) { "bps must fit in u16 (got $bps)" }
        }
    }

    /** Everything needed to derive the channel addresses and build Open. */
    data class OpenChannelParams(
        val payer: PublicKey,
        val payee: PublicKey,
        val mint: PublicKey,
        val authorizedSigner: PublicKey,
        val salt: Long,
        val deposit: Long,
        val gracePeriod: Int,
        val recipients: List<Distribution>,
        val tokenProgram: PublicKey,
        val programId: PublicKey,
    )

    /** Derived accounts for a channel open. */
    data class ChannelAddresses(
        val channel: PublicKey,
        val payerTokenAccount: PublicKey,
        val channelTokenAccount: PublicKey,
        val eventAuthority: PublicKey,
    )

    /** Returns the canonical payment-channels program ID. */
    fun defaultProgramId(): PublicKey = PublicKey.fromBase58(PAYMENT_CHANNELS_PROGRAM_ID)

    /**
     * Derives the channel PDA. Seed order mirrors the Rust spine:
     * "channel" || payer || payee || mint || authorizedSigner || salt(u64 LE).
     */
    fun findChannelPda(
        payer: PublicKey,
        payee: PublicKey,
        mint: PublicKey,
        authorizedSigner: PublicKey,
        salt: Long,
        programId: PublicKey,
    ): Pair<PublicKey, Int> =
        Pda.findProgramAddress(
            listOf(
                CHANNEL_SEED.encodeToByteArray(),
                payer.bytes,
                payee.bytes,
                mint.bytes,
                authorizedSigner.bytes,
                u64LE(salt),
            ),
            programId,
        )

    /** Derives the event authority PDA for the program. */
    fun findEventAuthorityPda(programId: PublicKey): Pair<PublicKey, Int> =
        Pda.findProgramAddress(listOf(EVENT_AUTHORITY_SEED.encodeToByteArray()), programId)

    /**
     * Derives the ATA for the given owner, mint, and token program. Seed
     * order is owner || tokenProgram || mint under the associated-token
     * program, matching the Rust spine.
     */
    fun findAssociatedTokenAddress(owner: PublicKey, mint: PublicKey, tokenProgram: PublicKey): PublicKey =
        Pda.associatedTokenAddress(owner, mint, tokenProgram)

    /** Derives the channel PDA plus the payer/channel ATAs and event authority. */
    fun deriveChannelAddresses(params: OpenChannelParams): ChannelAddresses {
        val (channel, _) = findChannelPda(
            params.payer, params.payee, params.mint, params.authorizedSigner, params.salt, params.programId,
        )
        val payerAta = findAssociatedTokenAddress(params.payer, params.mint, params.tokenProgram)
        val channelAta = findAssociatedTokenAddress(channel, params.mint, params.tokenProgram)
        val (eventAuthority, _) = findEventAuthorityPda(params.programId)
        return ChannelAddresses(
            channel = channel,
            payerTokenAccount = payerAta,
            channelTokenAccount = channelAta,
            eventAuthority = eventAuthority,
        )
    }

    /**
     * Returns the 32 byte blake3 distribution hash committed at channel open.
     * Preimage is count(u32 LE) followed by each recipient(32) || bps(u16 LE),
     * matching `distribution_hash` in the Rust spine.
     */
    fun distributionHash(recipients: List<Distribution>): ByteArray {
        val hasher = Blake3()
        hasher.update(u32LE(recipients.size))
        for (r in recipients) {
            hasher.update(r.recipient.bytes)
            hasher.update(u16LE(r.bps))
        }
        return hasher.finalize()
    }

    /**
     * Returns the Borsh VoucherArgs bytes signed by Ed25519:
     * channelId(32) || cumulativeAmount(u64 LE) || expiresAt(i64 LE).
     */
    fun voucherMessageBytes(channelId: PublicKey, cumulativeAmount: Long, expiresAt: Long): ByteArray {
        val out = ByteArray(VOUCHER_MESSAGE_LEN)
        System.arraycopy(channelId.bytes, 0, out, 0, 32)
        writeU64LE(out, 32, cumulativeAmount)
        writeU64LE(out, 40, expiresAt)
        return out
    }

    /**
     * Builds the Ed25519 precompile verify instruction over the voucher
     * message. Layout mirrors `build_ed25519_verify_instruction` in the
     * Rust spine.
     */
    fun buildEd25519VerifyInstruction(
        authorizedSigner: PublicKey,
        signature: ByteArray,
        message: ByteArray,
    ): Instruction {
        require(signature.size == 64) { "ed25519 signature must be 64 bytes (got ${signature.size})" }
        require(message.size <= 0xffff) { "voucher message too large for ed25519 instruction" }
        val publicKeyOffset = 16
        val signatureOffset = publicKeyOffset + 32
        val messageDataOffset = signatureOffset + 64
        val currentInstruction = 0xffff
        val messageDataSize = message.size

        val data = ArrayList<Byte>(messageDataOffset + message.size)
        data.add(1) // count
        data.add(0) // padding
        appendU16LE(data, signatureOffset)
        appendU16LE(data, currentInstruction)
        appendU16LE(data, publicKeyOffset)
        appendU16LE(data, currentInstruction)
        appendU16LE(data, messageDataOffset)
        appendU16LE(data, messageDataSize)
        appendU16LE(data, currentInstruction)
        for (b in authorizedSigner.bytes) data.add(b)
        for (b in signature) data.add(b)
        for (b in message) data.add(b)

        return Instruction(
            programId = ED25519_PROGRAM_ID,
            accounts = emptyList(),
            data = data.toByteArray(),
        )
    }

    /**
     * Builds the payment-channels Open instruction. The account order and
     * Borsh arg encoding mirror the generated Codama client used by the Rust
     * spine (discriminator 1, 13 accounts).
     */
    fun buildOpenInstruction(params: OpenChannelParams): Instruction {
        val addresses = deriveChannelAddresses(params)
        val data = ByteArray(1) { OPEN_DISCRIMINATOR } + encodeOpenArgs(params)
        val accounts = listOf(
            AccountMeta.writable(params.payer.toBase58(), signer = true),
            AccountMeta.readOnly(params.payee.toBase58()),
            AccountMeta.readOnly(params.mint.toBase58()),
            AccountMeta.readOnly(params.authorizedSigner.toBase58()),
            AccountMeta.writable(addresses.channel.toBase58()),
            AccountMeta.writable(addresses.payerTokenAccount.toBase58()),
            AccountMeta.writable(addresses.channelTokenAccount.toBase58()),
            AccountMeta.readOnly(params.tokenProgram.toBase58()),
            AccountMeta.readOnly(Programs.SYSTEM_PROGRAM),
            AccountMeta.readOnly(RENT_SYSVAR_ID),
            AccountMeta.readOnly(Programs.ASSOCIATED_TOKEN_PROGRAM),
            AccountMeta.readOnly(addresses.eventAuthority.toBase58()),
            AccountMeta.readOnly(params.programId.toBase58()),
        )
        return Instruction(programId = params.programId.toBase58(), accounts = accounts, data = data)
    }

    /**
     * Builds the payment-channels TopUp instruction (discriminator 3, 6
     * accounts) raising a channel's deposit by amount.
     */
    fun buildTopUpInstruction(
        payer: PublicKey,
        channel: PublicKey,
        mint: PublicKey,
        amount: Long,
        tokenProgram: PublicKey,
        programId: PublicKey,
    ): Instruction {
        val payerAta = findAssociatedTokenAddress(payer, mint, tokenProgram)
        val channelAta = findAssociatedTokenAddress(channel, mint, tokenProgram)
        val data = ByteArray(1) { TOP_UP_DISCRIMINATOR } + u64LE(amount)
        val accounts = listOf(
            AccountMeta.writable(payer.toBase58(), signer = true),
            AccountMeta.writable(channel.toBase58()),
            AccountMeta.writable(payerAta.toBase58()),
            AccountMeta.writable(channelAta.toBase58()),
            AccountMeta.readOnly(mint.toBase58()),
            AccountMeta.readOnly(tokenProgram.toBase58()),
        )
        return Instruction(programId = programId.toBase58(), accounts = accounts, data = data)
    }

    /**
     * Borsh-encodes OpenArgs: salt(u64 LE) || deposit(u64 LE) ||
     * gracePeriod(u32 LE) || recipients(vec: u32 LE len, then
     * recipient(32) || bps(u16 LE)).
     */
    private fun encodeOpenArgs(params: OpenChannelParams): ByteArray {
        val out = ArrayList<Byte>(8 + 8 + 4 + 4 + params.recipients.size * 34)
        for (b in u64LE(params.salt)) out.add(b)
        for (b in u64LE(params.deposit)) out.add(b)
        for (b in u32LE(params.gracePeriod)) out.add(b)
        for (b in u32LE(params.recipients.size)) out.add(b)
        for (r in params.recipients) {
            for (b in r.recipient.bytes) out.add(b)
            for (b in u16LE(r.bps)) out.add(b)
        }
        return out.toByteArray()
    }

    private fun u16LE(value: Int): ByteArray =
        byteArrayOf((value and 0xff).toByte(), ((value ushr 8) and 0xff).toByte())

    private fun u32LE(value: Int): ByteArray {
        val out = ByteArray(4)
        for (i in 0 until 4) out[i] = ((value ushr (8 * i)) and 0xff).toByte()
        return out
    }

    private fun u64LE(value: Long): ByteArray {
        val out = ByteArray(8)
        writeU64LE(out, 0, value)
        return out
    }

    private fun writeU64LE(out: ByteArray, offset: Int, value: Long) {
        for (i in 0 until 8) out[offset + i] = ((value ushr (8 * i)) and 0xff).toByte()
    }

    private fun appendU16LE(buf: MutableList<Byte>, value: Int) {
        buf.add((value and 0xff).toByte())
        buf.add(((value ushr 8) and 0xff).toByte())
    }
}
