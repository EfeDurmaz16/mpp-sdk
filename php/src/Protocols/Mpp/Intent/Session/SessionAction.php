<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;

/**
 * The action submitted by the client, a tagged union keyed by `action`:
 * `open | voucher | commit | topUp | close`.
 *
 * Note the capital `U` in `topUp`: this matches the Rust `SessionAction::TopUp`
 * camelCase serde rename and is load-bearing for cross-language parity.
 *
 * Exactly one of the payload accessors is non-null for a decoded action.
 */
final class SessionAction
{
    public const OPEN = 'open';
    public const VOUCHER = 'voucher';
    public const COMMIT = 'commit';
    public const TOP_UP = 'topUp';
    public const CLOSE = 'close';

    private function __construct(
        public readonly string $action,
        public readonly ?OpenPayload $open = null,
        public readonly ?SignedVoucher $voucher = null,
        public readonly ?CommitPayload $commit = null,
        public readonly ?TopUpPayload $topUp = null,
        public readonly ?ClosePayload $close = null,
    ) {
    }

    public static function open(OpenPayload $payload): self
    {
        return new self(self::OPEN, open: $payload);
    }

    public static function voucher(SignedVoucher $voucher): self
    {
        return new self(self::VOUCHER, voucher: $voucher);
    }

    public static function commit(CommitPayload $payload): self
    {
        return new self(self::COMMIT, commit: $payload);
    }

    public static function topUp(TopUpPayload $payload): self
    {
        return new self(self::TOP_UP, topUp: $payload);
    }

    public static function close(ClosePayload $payload): self
    {
        return new self(self::CLOSE, close: $payload);
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        return match ($this->action) {
            self::OPEN => array_merge(['action' => self::OPEN], $this->open?->toArray() ?? []),
            self::VOUCHER => ['action' => self::VOUCHER, 'voucher' => $this->voucher?->toArray()],
            self::COMMIT => array_merge(['action' => self::COMMIT], $this->commit?->toArray() ?? []),
            self::TOP_UP => array_merge(['action' => self::TOP_UP], $this->topUp?->toArray() ?? []),
            self::CLOSE => array_merge(['action' => self::CLOSE], $this->close?->toArray() ?? []),
            default => throw new InvalidArgumentException('unknown session action'),
        };
    }

    /**
     * Decode a tagged session action object.
     *
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $action = $value['action'] ?? null;
        if (!is_string($action)) {
            throw new InvalidArgumentException('session action missing action tag');
        }
        return match ($action) {
            self::OPEN => self::open(OpenPayload::fromArray($value)),
            self::VOUCHER => self::voucher(self::decodeNestedVoucher($value)),
            self::COMMIT => self::commit(CommitPayload::fromArray($value)),
            self::TOP_UP => self::topUp(TopUpPayload::fromArray($value)),
            self::CLOSE => self::close(ClosePayload::fromArray($value)),
            default => throw new InvalidArgumentException("unknown session action: {$action}"),
        };
    }

    /**
     * @param array<string, mixed> $value
     */
    private static function decodeNestedVoucher(array $value): SignedVoucher
    {
        $voucher = $value['voucher'] ?? null;
        if (!is_array($voucher)) {
            throw new InvalidArgumentException('voucher action missing voucher object');
        }
        /** @var array<string, mixed> $voucher */
        return SignedVoucher::fromArray($voucher);
    }
}
