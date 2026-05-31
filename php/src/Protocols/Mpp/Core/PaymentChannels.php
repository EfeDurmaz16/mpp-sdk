<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Core;

use InvalidArgumentException;
use SolanaPhpSdk\Keypair\PublicKey;
use SolanaPhpSdk\Programs\AssociatedTokenProgram;

/**
 * Typed helpers for the payment-channels program used by the session intent.
 *
 * Hand-written adapter code mirroring the Rust spine
 * (`rust/crates/mpp/src/program/payment_channels.rs`): channel PDA derivation,
 * associated-token derivation, BLAKE3 distribution hashing, and the Ed25519
 * voucher signing-byte layout. The byte layouts here are load-bearing for
 * cross-language signature parity, so they match the Rust `VoucherArgs` and
 * `distribution_hash` preimages exactly.
 */
final class PaymentChannels
{
    /** Canonical payment-channels program ID deployed to Surfnet. */
    public const PROGRAM_ID = 'GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc';

    /** Channel PDA seed prefix. */
    public const CHANNEL_SEED = 'channel';

    /** Event authority PDA seed prefix. */
    public const EVENT_AUTHORITY_SEED = 'event_authority';

    private function __construct()
    {
    }

    /**
     * Encode a u64 as 8 little-endian bytes. PHP `pack('P', ...)` emits LE
     * 64-bit; this keeps the dependency on platform endianness explicit and
     * works for values up to PHP_INT_MAX. Salt/cumulative come in as decimal
     * strings to preserve the full u64 range, so accept a string here.
     */
    public static function u64LeBytes(string $value): string
    {
        if ($value === '' || !ctype_digit($value)) {
            throw new InvalidArgumentException('u64 value must be a non-negative decimal string');
        }
        // brick/math is a dependency; use it for exact u64 little-endian bytes.
        $n = \Brick\Math\BigInteger::of($value);
        if ($n->isLessThan(0) || $n->isGreaterThan(\Brick\Math\BigInteger::of('18446744073709551615'))) {
            throw new InvalidArgumentException('u64 value out of range');
        }
        $bytes = '';
        for ($i = 0; $i < 8; $i++) {
            $byte = $n->mod(256)->toInt();
            $bytes .= chr($byte);
            $n = $n->dividedBy(256, \Brick\Math\RoundingMode::DOWN);
        }
        return $bytes;
    }

    /**
     * Encode an i64 as 8 little-endian bytes (two's complement).
     */
    public static function i64LeBytes(int $value): string
    {
        // pack('P') is little-endian unsigned 64-bit; PHP ints are 64-bit
        // two's complement on supported platforms, so the bit pattern matches
        // the on-chain i64 little-endian encoding.
        return pack('P', $value);
    }

    /**
     * The 48-byte Ed25519 signing message for a voucher, matching the on-chain
     * `VoucherArgs` Borsh layout: `channelId(32) || cumulativeAmount(u64 LE,8)
     * || expiresAt(i64 LE,8)`.
     *
     * @param string $channelId base58 channel/session address
     * @param string $cumulativeAmount base-unit decimal string
     * @param int $expiresAt unix timestamp
     */
    public static function voucherMessageBytes(string $channelId, string $cumulativeAmount, int $expiresAt): string
    {
        $channel = new PublicKey($channelId);
        $channelBytes = $channel->toBytes();
        if (strlen($channelBytes) !== 32) {
            throw new InvalidArgumentException('channelId must decode to 32 bytes');
        }
        return $channelBytes
            . self::u64LeBytes($cumulativeAmount)
            . self::i64LeBytes($expiresAt);
    }

    /**
     * Derive the channel PDA and its bump for the given open parameters.
     *
     * Seed order mirrors the program:
     * `["channel", payer, payee, mint, authorizedSigner, salt(u64 LE)]`.
     *
     * @return array{0: PublicKey, 1: int}
     */
    public static function findChannelPda(
        string $payer,
        string $payee,
        string $mint,
        string $authorizedSigner,
        string $salt,
        string $programId = self::PROGRAM_ID
    ): array {
        $seeds = [
            self::CHANNEL_SEED,
            (new PublicKey($payer))->toBytes(),
            (new PublicKey($payee))->toBytes(),
            (new PublicKey($mint))->toBytes(),
            (new PublicKey($authorizedSigner))->toBytes(),
            self::u64LeBytes($salt),
        ];
        return PublicKey::findProgramAddress($seeds, new PublicKey($programId));
    }

    /**
     * Derive the event-authority PDA for the program.
     *
     * @return array{0: PublicKey, 1: int}
     */
    public static function findEventAuthorityPda(string $programId = self::PROGRAM_ID): array
    {
        return PublicKey::findProgramAddress([self::EVENT_AUTHORITY_SEED], new PublicKey($programId));
    }

    /**
     * Derive the associated token account address for (owner, mint, tokenProgram).
     *
     * @return array{0: PublicKey, 1: int}
     */
    public static function findAssociatedTokenAddress(string $owner, string $mint, string $tokenProgram): array
    {
        return AssociatedTokenProgram::findAssociatedTokenAddress(
            new PublicKey($owner),
            new PublicKey($mint),
            new PublicKey($tokenProgram),
        );
    }

    /**
     * Compute the 32-byte BLAKE3 distribution hash committed at channel open.
     *
     * Preimage layout mirrors the program and the Rust spine:
     * `len(u32 LE) || (recipient(32) || bps(u16 LE))*`.
     *
     * @param list<array{recipient: string, bps: int}> $recipients
     */
    public static function distributionHash(array $recipients): string
    {
        $preimage = pack('V', count($recipients));
        foreach ($recipients as $entry) {
            $recipient = new PublicKey($entry['recipient']);
            $bps = $entry['bps'];
            if ($bps < 0 || $bps > 0xFFFF) {
                throw new InvalidArgumentException('bps must fit in a u16');
            }
            $preimage .= $recipient->toBytes();
            $preimage .= pack('v', $bps);
        }
        return Blake3::hash($preimage);
    }
}
