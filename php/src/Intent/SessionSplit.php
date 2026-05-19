<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use InvalidArgumentException;

final class SessionSplit
{
    public function __construct(
        public readonly string $recipient,
        public readonly int $bps,
    ) {
        if ($recipient === '') {
            throw new InvalidArgumentException('split recipient is required');
        }
        if ($bps <= 0 || $bps > 10_000) {
            throw new InvalidArgumentException('split bps must be between 1 and 10000');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return [
            'recipient' => $this->recipient,
            'bps' => $this->bps,
        ];
    }
}
