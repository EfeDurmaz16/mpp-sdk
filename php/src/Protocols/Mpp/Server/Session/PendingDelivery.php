<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

/**
 * A metered delivery reserved by the server but not yet committed by the client.
 */
final class PendingDelivery
{
    public function __construct(
        public readonly string $deliveryId,
        public readonly int $amount,
        public readonly int $sequence,
        public readonly int $expiresAt,
    ) {
    }
}
