<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use InvalidArgumentException;

final class SessionMeteringDirective
{
    public function __construct(
        public readonly string $deliveryId,
        public readonly string $sessionId,
        public readonly string $amount,
        public readonly string $currency,
        public readonly int $sequence,
        public readonly int $expiresAt,
        public readonly string $commitUrl = '',
        public readonly string $proof = '',
    ) {
        self::assertRequired($deliveryId, 'deliveryId');
        self::assertRequired($sessionId, 'sessionId');
        SessionRequest::assertPositiveDecimal($amount, 'amount');
        self::assertRequired($currency, 'currency');
        if ($sequence < 0) {
            throw new InvalidArgumentException('sequence cannot be negative');
        }
        if ($expiresAt <= 0) {
            throw new InvalidArgumentException('expiresAt must be positive');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $value = [
            'deliveryId' => $this->deliveryId,
            'sessionId' => $this->sessionId,
            'amount' => $this->amount,
            'currency' => $this->currency,
            'sequence' => $this->sequence,
            'expiresAt' => $this->expiresAt,
        ];
        if ($this->commitUrl !== '') {
            $value['commitUrl'] = $this->commitUrl;
        }
        if ($this->proof !== '') {
            $value['proof'] = $this->proof;
        }

        return $value;
    }

    private static function assertRequired(string $value, string $field): void
    {
        if ($value === '') {
            throw new InvalidArgumentException(sprintf('%s is required', $field));
        }
    }
}
