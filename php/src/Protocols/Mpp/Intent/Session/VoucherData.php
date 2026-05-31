<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;
use PayKit\Protocols\Mpp\Core\PaymentChannels;

/**
 * The canonical content of a voucher, signed by the client's session key.
 *
 * Serialized to the on-chain `VoucherArgs` byte layout before signing:
 * `channelId(32) || cumulativeAmount(u64 LE) || expiresAt(i64 LE)`.
 *
 * Wire field-naming parity with the Rust spine:
 * - `cumulativeAmount` is the canonical wire name; `cumulative` is accepted as
 *   a read-alias on decode for backwards compatibility, but encode always emits
 *   `cumulativeAmount`.
 * - `expiresAt` is a Unix timestamp i64.
 * - `nonce` is an optional client-side counter and is NOT part of the signed
 *   bytes.
 */
final class VoucherData
{
    public function __construct(
        public readonly string $channelId,
        public readonly string $cumulative,
        public readonly int $expiresAt,
        public readonly ?int $nonce = null,
    ) {
        if ($channelId === '') {
            throw new InvalidArgumentException('channelId is required');
        }
        if ($cumulative === '' || !ctype_digit($cumulative)) {
            throw new InvalidArgumentException('cumulativeAmount must be a base-unit integer string');
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $value = [
            'channelId' => $this->channelId,
            'cumulativeAmount' => $this->cumulative,
            'expiresAt' => $this->expiresAt,
        ];
        if ($this->nonce !== null) {
            $value['nonce'] = $this->nonce;
        }
        return $value;
    }

    /**
     * Decode voucher data. Accepts `cumulativeAmount` or the legacy
     * `cumulative` field name, and tolerates a JSON number for cumulative
     * (it is normalized to a decimal string).
     *
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $channelId = $value['channelId'] ?? null;
        if (!is_string($channelId)) {
            throw new InvalidArgumentException('channelId must be a string');
        }

        $cumulativeRaw = $value['cumulativeAmount'] ?? ($value['cumulative'] ?? null);
        $cumulative = self::normalizeCumulative($cumulativeRaw);

        $expiresAt = $value['expiresAt'] ?? null;
        if (!is_int($expiresAt)) {
            throw new InvalidArgumentException('expiresAt must be an integer');
        }

        $nonce = $value['nonce'] ?? null;
        if ($nonce !== null && !is_int($nonce)) {
            throw new InvalidArgumentException('nonce must be an integer');
        }

        return new self($channelId, $cumulative, $expiresAt, $nonce);
    }

    /**
     * Serialize to the payment-channels Ed25519 signing bytes (48 bytes).
     */
    public function messageBytes(): string
    {
        return PaymentChannels::voucherMessageBytes($this->channelId, $this->cumulative, $this->expiresAt);
    }

    private static function normalizeCumulative(mixed $raw): string
    {
        if (is_string($raw)) {
            return $raw;
        }
        if (is_int($raw)) {
            if ($raw < 0) {
                throw new InvalidArgumentException('cumulativeAmount must be non-negative');
            }
            return (string) $raw;
        }
        throw new InvalidArgumentException('cumulativeAmount is required');
    }
}
