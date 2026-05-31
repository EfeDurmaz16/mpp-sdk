<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;
use PayKit\Protocols\Mpp\Core\Json;

/**
 * Payload for the `topUp` action. Note the capital `U` in the wire tag, which
 * matches the Rust `SessionAction::TopUp` camelCase serde rename.
 */
final class TopUpPayload
{
    public function __construct(
        public readonly string $channelId,
        public readonly string $newDeposit,
        public readonly string $signature,
    ) {
        if ($channelId === '') {
            throw new InvalidArgumentException('channelId is required');
        }
        if ($newDeposit === '' || !ctype_digit($newDeposit)) {
            throw new InvalidArgumentException('newDeposit must be a base-unit integer string');
        }
        if ($signature === '') {
            throw new InvalidArgumentException('signature is required');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return [
            'channelId' => $this->channelId,
            'newDeposit' => $this->newDeposit,
            'signature' => $this->signature,
        ];
    }

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        return new self(
            Json::optionalString($value['channelId'] ?? null, 'channelId'),
            Json::optionalString($value['newDeposit'] ?? null, 'newDeposit'),
            Json::optionalString($value['signature'] ?? null, 'signature'),
        );
    }
}
