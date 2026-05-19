<?php

declare(strict_types=1);

namespace SolanaMpp\Tests;

use InvalidArgumentException;
use PHPUnit\Framework\TestCase;
use SolanaMpp\Intent\SessionCommitReceipt;
use SolanaMpp\Intent\SessionMeteringDirective;
use SolanaMpp\Intent\SessionRequest;
use SolanaMpp\Intent\SessionSplit;
use SolanaMpp\Intent\SignedVoucher;
use SolanaMpp\Intent\VoucherData;

final class SessionTest extends TestCase
{
    public function testSessionRequestSerializesSharedWireFields(): void
    {
        $request = new SessionRequest(
            cap: '1000000',
            currency: 'USDC',
            operator: 'operator',
            recipient: 'recipient',
            decimals: 6,
            network: 'devnet',
            splits: [new SessionSplit(recipient: 'affiliate', bps: 250)],
            programId: 'program',
            description: 'Metered API session',
            externalId: 'session-001',
            minVoucherDelta: '1000',
            modes: [SessionRequest::MODE_PUSH, SessionRequest::MODE_PULL],
            pullVoucherStrategy: SessionRequest::PULL_CLIENT_VOUCHER,
            recentBlockhash: 'blockhash',
        );

        self::assertSame([
            'cap' => '1000000',
            'currency' => 'USDC',
            'operator' => 'operator',
            'recipient' => 'recipient',
            'decimals' => 6,
            'network' => 'devnet',
            'splits' => [['recipient' => 'affiliate', 'bps' => 250]],
            'programId' => 'program',
            'description' => 'Metered API session',
            'externalId' => 'session-001',
            'minVoucherDelta' => '1000',
            'modes' => ['push', 'pull'],
            'pullVoucherStrategy' => 'clientVoucher',
            'recentBlockhash' => 'blockhash',
        ], $request->toArray());
    }

    public function testSessionRequestRequiresPullVoucherStrategyForPullMode(): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessage('pullVoucherStrategy is required');

        new SessionRequest(
            cap: '1000',
            currency: 'USDC',
            operator: 'operator',
            recipient: 'recipient',
            modes: [SessionRequest::MODE_PULL],
        );
    }

    public function testSignedVoucherSerializesCumulativeVoucher(): void
    {
        $voucher = new SignedVoucher(
            data: new VoucherData(
                channelId: 'channel',
                cumulativeAmount: '25000',
                expiresAt: VoucherData::DEFAULT_EXPIRES_AT,
                nonce: 1,
            ),
            signature: 'signature',
        );

        self::assertSame([
            'data' => [
                'channelId' => 'channel',
                'cumulativeAmount' => '25000',
                'expiresAt' => 4_102_444_800,
                'nonce' => 1,
            ],
            'signature' => 'signature',
        ], $voucher->toArray());
    }

    public function testMeteringDirectiveSerializesCommitFields(): void
    {
        $directive = new SessionMeteringDirective(
            deliveryId: 'delivery-001',
            sessionId: 'channel',
            amount: '5000',
            currency: 'USDC',
            sequence: 1,
            expiresAt: VoucherData::DEFAULT_EXPIRES_AT,
            commitUrl: 'https://merchant.example/session/commit',
            proof: 'proof',
        );

        self::assertSame('delivery-001', $directive->toArray()['deliveryId']);
        self::assertSame('channel', $directive->toArray()['sessionId']);
        self::assertSame('https://merchant.example/session/commit', $directive->toArray()['commitUrl']);
    }

    public function testCommitReceiptRejectsUnknownStatus(): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessage('status must be committed or replayed');

        new SessionCommitReceipt(
            deliveryId: 'delivery-001',
            sessionId: 'channel',
            amount: '5000',
            cumulative: '30000',
            status: 'accepted',
        );
    }
}
