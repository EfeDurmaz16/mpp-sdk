<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

/**
 * Result returned after a delivery commit is accepted.
 */
final class CommitReceipt
{
    public function __construct(
        public readonly string $deliveryId,
        public readonly string $sessionId,
        public readonly string $amount,
        public readonly string $cumulative,
        public readonly CommitStatus $status,
    ) {
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
            'status' => $this->status->value,
        ];
    }
}
