<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;

/**
 * A payment split committed at channel open and distributed to a specific
 * recipient when the channel closes.
 */
final class SessionSplit
{
    public function __construct(
        public readonly string $recipient,
        public readonly int $bps,
    ) {
        if ($recipient === '') {
            throw new InvalidArgumentException('split recipient is required');
        }
        if ($bps < 0 || $bps > 0xFFFF) {
            throw new InvalidArgumentException('split bps must fit in a u16');
        }
    }

    /**
     * @return array{recipient: string, bps: int}
     */
    public function toArray(): array
    {
        return ['recipient' => $this->recipient, 'bps' => $this->bps];
    }

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $bps = $value['bps'] ?? null;
        if (!is_int($bps)) {
            throw new InvalidArgumentException('split bps must be an integer');
        }
        $recipient = $value['recipient'] ?? null;
        if (!is_string($recipient)) {
            throw new InvalidArgumentException('split recipient must be a string');
        }
        return new self($recipient, $bps);
    }
}
