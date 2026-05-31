<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;
use PayKit\Protocols\Mpp\Core\Json;

/**
 * Payload for the `close` action: request cooperative close, optionally
 * attaching a final signed voucher for any remaining balance owed.
 */
final class ClosePayload
{
    public function __construct(
        public readonly string $channelId,
        public readonly ?SignedVoucher $voucher = null,
    ) {
        if ($channelId === '') {
            throw new InvalidArgumentException('channelId is required');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $value = ['channelId' => $this->channelId];
        if ($this->voucher !== null) {
            $value['voucher'] = $this->voucher->toArray();
        }
        return $value;
    }

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $voucherRaw = $value['voucher'] ?? null;
        $voucher = null;
        if ($voucherRaw !== null) {
            if (!is_array($voucherRaw)) {
                throw new InvalidArgumentException('close voucher must be an object');
            }
            $voucher = SignedVoucher::fromArray(Json::object($voucherRaw, 'voucher'));
        }
        return new self(
            Json::optionalString($value['channelId'] ?? null, 'channelId'),
            $voucher,
        );
    }
}
