<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

/**
 * Request to reserve a metered delivery for client-side commit.
 */
final class DeliveryRequest
{
    public function __construct(
        public readonly string $sessionId,
        public readonly int $amount,
        public readonly ?string $deliveryId = null,
        public readonly ?string $commitUrl = null,
        public readonly ?string $proof = null,
        public readonly ?int $expiresAt = null,
    ) {
    }
}
