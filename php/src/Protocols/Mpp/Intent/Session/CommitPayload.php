<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;
use PayKit\Protocols\Mpp\Core\Json;

/**
 * Payload for the `commit` action: commit a metered delivery by attaching a
 * signed voucher. `deliveryId` is the idempotency key.
 */
final class CommitPayload
{
    public function __construct(
        public readonly string $deliveryId,
        public readonly SignedVoucher $voucher,
    ) {
        if ($deliveryId === '') {
            throw new InvalidArgumentException('deliveryId is required');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return [
            'deliveryId' => $this->deliveryId,
            'voucher' => $this->voucher->toArray(),
        ];
    }

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $voucher = $value['voucher'] ?? null;
        if (!is_array($voucher)) {
            throw new InvalidArgumentException('commit voucher must be an object');
        }
        return new self(
            Json::optionalString($value['deliveryId'] ?? null, 'deliveryId'),
            SignedVoucher::fromArray(Json::object($voucher, 'voucher')),
        );
    }
}
