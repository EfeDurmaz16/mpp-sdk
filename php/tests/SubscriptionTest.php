<?php

declare(strict_types=1);

namespace SolanaMpp\Tests;

use DateTimeImmutable;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;
use SolanaMpp\Intent\SubscriptionAccountState;
use SolanaMpp\Intent\SubscriptionReceipt;
use SolanaMpp\Intent\SubscriptionRequest;

final class SubscriptionTest extends TestCase
{
    public function testSubscriptionRequestRoundTripsWireFields(): void
    {
        $request = new SubscriptionRequest(
            amount: '1000',
            currency: 'USDC',
            periodUnit: SubscriptionRequest::PERIOD_WEEK,
            periodCount: '2',
            recipient: 'recipient',
            subscriptionExpires: '2027-01-01T00:00:00+00:00',
            description: 'Pro plan',
            externalId: 'sub-001',
            methodDetails: ['network' => 'localnet'],
        );

        self::assertSame([
            'amount' => '1000',
            'currency' => 'USDC',
            'periodUnit' => 'week',
            'periodCount' => '2',
            'recipient' => 'recipient',
            'subscriptionExpires' => '2027-01-01T00:00:00+00:00',
            'description' => 'Pro plan',
            'externalId' => 'sub-001',
            'methodDetails' => ['network' => 'localnet'],
        ], $request->toArray());
        self::assertEquals($request, SubscriptionRequest::fromArray($request->toArray()));
    }

    public function testSubscriptionRequestRejectsInvalidPeriod(): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessage('unsupported periodUnit');

        new SubscriptionRequest(amount: '1000', currency: 'USDC', periodUnit: 'hour', periodCount: '1');
    }

    public function testSubscriptionRequestRejectsLeadingZeroAmount(): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessage('invalid amount');

        new SubscriptionRequest(amount: '01000', currency: 'USDC', periodUnit: 'day', periodCount: '1');
    }

    public function testSubscriptionAccountingAllowsOneRenewalPerPeriod(): void
    {
        $state = new SubscriptionAccountState(
            subscriptionId: 'sub-001',
            anchor: new DateTimeImmutable('2026-01-01T00:00:00+00:00'),
            periodUnit: SubscriptionRequest::PERIOD_DAY,
            periodCount: 1,
            lastPaidPeriod: 0,
        );

        [$allowed, $period] = $state->canRenew(new DateTimeImmutable('2026-01-02T00:00:00+00:00'));
        self::assertTrue($allowed);
        self::assertSame(1, $period);
        self::assertSame(1, $state->recordRenewal(new DateTimeImmutable('2026-01-02T00:00:00+00:00')));

        [$allowedAgain, $samePeriod] = $state->canRenew(new DateTimeImmutable('2026-01-02T12:00:00+00:00'));
        self::assertFalse($allowedAgain);
        self::assertSame(1, $samePeriod);
    }

    public function testSubscriptionAccountingDoesNotAccumulateMissedPeriods(): void
    {
        $state = new SubscriptionAccountState(
            subscriptionId: 'sub-001',
            anchor: new DateTimeImmutable('2026-01-01T00:00:00+00:00'),
            periodUnit: SubscriptionRequest::PERIOD_WEEK,
            periodCount: 1,
            lastPaidPeriod: 0,
        );

        self::assertSame(4, $state->recordRenewal(new DateTimeImmutable('2026-01-29T00:00:00+00:00')));
        self::assertSame(4, $state->lastPaidPeriod);
    }

    public function testSubscriptionAccountingStopsAfterCancellation(): void
    {
        $state = new SubscriptionAccountState(
            subscriptionId: 'sub-001',
            anchor: new DateTimeImmutable('2026-01-01T00:00:00+00:00'),
            periodUnit: SubscriptionRequest::PERIOD_DAY,
            periodCount: 1,
            lastPaidPeriod: 0,
            canceledAt: new DateTimeImmutable('2026-01-02T00:00:00+00:00'),
        );

        [$allowed, $period] = $state->canRenew(new DateTimeImmutable('2026-01-02T00:00:00+00:00'));

        self::assertFalse($allowed);
        self::assertSame(0, $period);
    }

    public function testSubscriptionReceiptSerializesSubscriptionId(): void
    {
        $receipt = new SubscriptionReceipt(
            method: 'solana',
            reference: 'tx-signature',
            status: 'success',
            subscriptionId: 'sub-001',
            timestamp: '2026-05-19T00:00:00.000Z',
            externalId: 'order-001',
        );

        self::assertSame('sub-001', $receipt->toArray()['subscriptionId']);
        self::assertSame('order-001', $receipt->toArray()['externalId']);
    }
}
