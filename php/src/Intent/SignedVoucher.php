<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use InvalidArgumentException;

final class SignedVoucher
{
    public function __construct(
        public readonly VoucherData $data,
        public readonly string $signature,
    ) {
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
            'data' => $this->data->toArray(),
            'signature' => $this->signature,
        ];
    }
}
