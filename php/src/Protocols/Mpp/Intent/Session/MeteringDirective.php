<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;
use PayKit\Protocols\Mpp\Core\Json;

/**
 * Server-issued metering directive attached to a delivered message/response.
 *
 * Once a delivery is processed, the client signs a voucher covering `amount`
 * and replies with a {@see CommitPayload} keyed by `deliveryId`. `deliveryId`
 * is the idempotency key the server uses to detect duplicate commits.
 */
final class MeteringDirective
{
    public function __construct(
        public readonly string $deliveryId,
        public readonly string $sessionId,
        public readonly string $amount,
        public readonly string $currency,
        public readonly int $sequence,
        public readonly int $expiresAt,
        public readonly ?string $commitUrl = null,
        public readonly ?string $proof = null,
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
        $value = [
            'deliveryId' => $this->deliveryId,
            'sessionId' => $this->sessionId,
            'amount' => $this->amount,
            'currency' => $this->currency,
            'sequence' => $this->sequence,
            'expiresAt' => $this->expiresAt,
        ];
        if ($this->commitUrl !== null) {
            $value['commitUrl'] = $this->commitUrl;
        }
        if ($this->proof !== null) {
            $value['proof'] = $this->proof;
        }
        return $value;
    }

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $sequence = $value['sequence'] ?? null;
        if (!is_int($sequence)) {
            throw new InvalidArgumentException('sequence must be an integer');
        }
        $expiresAt = $value['expiresAt'] ?? null;
        if (!is_int($expiresAt)) {
            throw new InvalidArgumentException('expiresAt must be an integer');
        }
        return new self(
            Json::optionalString($value['deliveryId'] ?? null, 'deliveryId'),
            Json::optionalString($value['sessionId'] ?? null, 'sessionId'),
            Json::optionalString($value['amount'] ?? null, 'amount'),
            Json::optionalString($value['currency'] ?? null, 'currency'),
            $sequence,
            $expiresAt,
            isset($value['commitUrl']) ? Json::string($value['commitUrl'], 'commitUrl') : null,
            isset($value['proof']) ? Json::string($value['proof'], 'proof') : null,
        );
    }
}
