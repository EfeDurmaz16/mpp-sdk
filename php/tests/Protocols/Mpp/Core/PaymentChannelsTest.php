<?php

declare(strict_types=1);

namespace PayKit\Tests;

use PHPUnit\Framework\TestCase;
use PayKit\Protocols\Mpp\Core\PaymentChannels;
use SolanaPhpSdk\Keypair\PublicKey;

final class PaymentChannelsTest extends TestCase
{
    private static function pk(int $byte): string
    {
        return PublicKey::fromBytes(str_repeat(chr($byte), 32))->toBase58();
    }

    public function testVoucherMessageIsProgramBorshLayout(): void
    {
        // Mirrors rust voucher_message_is_program_borsh_layout: channelId(32)
        // || cumulative(u64 LE) || expiresAt(i64 LE) = 48 bytes.
        $bytes = PaymentChannels::voucherMessageBytes(self::pk(9), '42', 1234);
        self::assertSame(48, strlen($bytes));
        self::assertSame(str_repeat(chr(9), 32), substr($bytes, 0, 32));
        self::assertSame(pack('P', 42), substr($bytes, 32, 8));
        self::assertSame(pack('P', 1234), substr($bytes, 40, 8));
    }

    public function testVoucherMessageHandlesFullU64Cumulative(): void
    {
        $bytes = PaymentChannels::voucherMessageBytes(self::pk(3), '18446744073709551615', 0);
        self::assertSame(48, strlen($bytes));
        self::assertSame(str_repeat("\xff", 8), substr($bytes, 32, 8));
    }

    public function testVoucherMessageHandlesNegativeExpiry(): void
    {
        $bytes = PaymentChannels::voucherMessageBytes(self::pk(4), '0', -1);
        self::assertSame(str_repeat("\xff", 8), substr($bytes, 40, 8));
    }

    public function testVoucherMessageDiffersByCumulative(): void
    {
        $a = PaymentChannels::voucherMessageBytes(self::pk(6), '100', 42);
        $b = PaymentChannels::voucherMessageBytes(self::pk(6), '200', 42);
        self::assertNotSame($a, $b);
    }

    public function testDistributionHashMatchesProgramPreimageShape(): void
    {
        // Mirrors rust distribution_hash_matches_program_preimage_shape.
        $hash = PaymentChannels::distributionHash([
            ['recipient' => self::pk(1), 'bps' => 7500],
            ['recipient' => self::pk(2), 'bps' => 2500],
        ]);
        self::assertSame(
            '2c00d870359f0a4861c420eaeffdf7a7d6b2cd281024ee69e1f12f743e04c416',
            bin2hex($hash),
        );
    }

    public function testEmptyDistributionHashIsLenPrefixOnly(): void
    {
        // BLAKE3 of just the u32 LE length prefix (0 recipients).
        $hash = PaymentChannels::distributionHash([]);
        self::assertSame(
            'ec2bd03bf86b935fa34d71ad7ebb049f1f10f87d343e521511d8f9e6625620cd',
            bin2hex($hash),
        );
    }

    public function testChannelPdaIsStableAndDerivesValidBump(): void
    {
        [$channel, $bump] = PaymentChannels::findChannelPda(
            self::pk(1),
            self::pk(2),
            self::pk(3),
            self::pk(4),
            '99',
        );
        self::assertInstanceOf(PublicKey::class, $channel);
        self::assertGreaterThanOrEqual(0, $bump);
        self::assertLessThanOrEqual(255, $bump);

        // Re-derivation is deterministic.
        [$again] = PaymentChannels::findChannelPda(
            self::pk(1),
            self::pk(2),
            self::pk(3),
            self::pk(4),
            '99',
        );
        self::assertSame($channel->toBase58(), $again->toBase58());

        // A different salt yields a different channel PDA.
        [$other] = PaymentChannels::findChannelPda(
            self::pk(1),
            self::pk(2),
            self::pk(3),
            self::pk(4),
            '100',
        );
        self::assertNotSame($channel->toBase58(), $other->toBase58());
    }

    public function testU64LeBytesRejectsOutOfRange(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        PaymentChannels::u64LeBytes('18446744073709551616');
    }
}
