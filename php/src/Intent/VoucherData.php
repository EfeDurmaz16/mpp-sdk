<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use InvalidArgumentException;

final class VoucherData
{
    public const DEFAULT_EXPIRES_AT = 4_102_444_800;

    public function __construct(
        public readonly string $channelId,
        public readonly string $cumulativeAmount,
        public readonly int $expiresAt = self::DEFAULT_EXPIRES_AT,
        public readonly ?int $nonce = null,
    ) {
        if ($channelId === '') {
            throw new InvalidArgumentException('channelId is required');
        }
        SessionRequest::assertPositiveDecimal($cumulativeAmount, 'cumulativeAmount');
        if ($expiresAt <= 0) {
            throw new InvalidArgumentException('expiresAt must be positive');
        }
        if ($nonce !== null && $nonce < 0) {
            throw new InvalidArgumentException('nonce cannot be negative');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $value = [
            'channelId' => $this->channelId,
            'cumulativeAmount' => $this->cumulativeAmount,
            'expiresAt' => $this->expiresAt,
        ];
        if ($this->nonce !== null) {
            $value['nonce'] = $this->nonce;
        }

        return $value;
    }
}
