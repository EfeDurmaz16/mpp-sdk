<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

/**
 * A committed metered delivery, retained for idempotent commit replay.
 */
final class CommittedDelivery
{
    public function __construct(
        public readonly string $deliveryId,
        public readonly int $amount,
        public readonly int $cumulative,
        public readonly string $voucherSignature,
    ) {
    }
}
