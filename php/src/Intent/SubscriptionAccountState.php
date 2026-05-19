<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use DateTimeImmutable;
use InvalidArgumentException;

final class SubscriptionAccountState
{
    public function __construct(
        public readonly string $subscriptionId,
        public readonly DateTimeImmutable $anchor,
        public readonly string $periodUnit,
        public readonly int $periodCount,
        public int $lastPaidPeriod,
        public readonly ?DateTimeImmutable $canceledAt = null,
        public readonly bool $revoked = false,
    ) {
        if ($this->subscriptionId === '') {
            throw new InvalidArgumentException('subscriptionId is required');
        }
        SubscriptionRequest::normalizePeriodUnit($this->periodUnit);
        if ($this->periodCount <= 0) {
            throw new InvalidArgumentException('periodCount must be positive');
        }
    }

    public function currentPeriod(DateTimeImmutable $now): int
    {
        if ($now < $this->anchor) {
            return 0;
        }

        return match ($this->periodUnit) {
            SubscriptionRequest::PERIOD_DAY => intdiv($now->getTimestamp() - $this->anchor->getTimestamp(), 86_400 * $this->periodCount),
            SubscriptionRequest::PERIOD_WEEK => intdiv($now->getTimestamp() - $this->anchor->getTimestamp(), 604_800 * $this->periodCount),
            SubscriptionRequest::PERIOD_MONTH => throw new InvalidArgumentException('calendar-month subscription accounting requires method-specific handling'),
            default => throw new InvalidArgumentException(sprintf('unsupported periodUnit: %s', $this->periodUnit)),
        };
    }

    /**
     * @return array{0: bool, 1: int}
     */
    public function canRenew(DateTimeImmutable $now): array
    {
        if ($this->revoked) {
            return [false, 0];
        }
        if ($this->canceledAt !== null && $now >= $this->canceledAt) {
            return [false, 0];
        }

        $period = $this->currentPeriod($now);
        return [$period > $this->lastPaidPeriod, $period];
    }

    public function recordRenewal(DateTimeImmutable $now): int
    {
        [$allowed, $period] = $this->canRenew($now);
        if (!$allowed) {
            throw new InvalidArgumentException(sprintf('subscription period %d cannot renew', $period));
        }

        $this->lastPaidPeriod = $period;
        return $period;
    }
}
