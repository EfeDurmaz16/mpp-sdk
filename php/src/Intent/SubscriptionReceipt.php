<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use InvalidArgumentException;

final class SubscriptionReceipt
{
    public function __construct(
        public readonly string $method,
        public readonly string $reference,
        public readonly string $status,
        public readonly string $subscriptionId,
        public readonly string $timestamp,
        public readonly string $externalId = '',
    ) {
        if ($this->method === '' || $this->reference === '' || $this->status === '' || $this->subscriptionId === '' || $this->timestamp === '') {
            throw new InvalidArgumentException('Subscription receipt is missing required fields');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $value = [
            'method' => $this->method,
            'reference' => $this->reference,
            'status' => $this->status,
            'subscriptionId' => $this->subscriptionId,
            'timestamp' => $this->timestamp,
        ];
        if ($this->externalId !== '') {
            $value['externalId'] = $this->externalId;
        }

        return $value;
    }
}
