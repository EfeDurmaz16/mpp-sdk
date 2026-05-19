<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use InvalidArgumentException;

final class SessionCommitReceipt
{
    public const STATUS_COMMITTED = 'committed';
    public const STATUS_REPLAYED = 'replayed';

    public function __construct(
        public readonly string $deliveryId,
        public readonly string $sessionId,
        public readonly string $amount,
        public readonly string $cumulative,
        public readonly string $status,
    ) {
        self::assertRequired($deliveryId, 'deliveryId');
        self::assertRequired($sessionId, 'sessionId');
        SessionRequest::assertPositiveDecimal($amount, 'amount');
        SessionRequest::assertPositiveDecimal($cumulative, 'cumulative');
        if ($status !== self::STATUS_COMMITTED && $status !== self::STATUS_REPLAYED) {
            throw new InvalidArgumentException('status must be committed or replayed');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return [
            'deliveryId' => $this->deliveryId,
            'sessionId' => $this->sessionId,
            'amount' => $this->amount,
            'cumulative' => $this->cumulative,
            'status' => $this->status,
        ];
    }

    private static function assertRequired(string $value, string $field): void
    {
        if ($value === '') {
            throw new InvalidArgumentException(sprintf('%s is required', $field));
        }
    }
}
