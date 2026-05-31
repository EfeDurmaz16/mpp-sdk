<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;
use PayKit\Protocols\Mpp\Core\Json;

/**
 * A signed voucher authorizing cumulative payment up to its `cumulative`.
 *
 * Vouchers are cumulative: the server always uses the latest valid voucher it
 * has received. The signature is Ed25519 over the payment-channel Borsh voucher
 * bytes, base58-encoded.
 */
final class SignedVoucher
{
    public function __construct(
        public readonly VoucherData $data,
        public readonly string $signature,
    ) {
        if ($signature === '') {
            throw new InvalidArgumentException('voucher signature is required');
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

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $data = $value['data'] ?? null;
        if (!is_array($data)) {
            throw new InvalidArgumentException('voucher data must be an object');
        }
        return new self(
            VoucherData::fromArray(Json::object($data, 'data')),
            Json::optionalString($value['signature'] ?? null, 'signature'),
        );
    }
}
