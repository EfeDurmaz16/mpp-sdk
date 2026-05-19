<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use InvalidArgumentException;

final class SessionRequest
{
    public const MODE_PUSH = 'push';
    public const MODE_PULL = 'pull';
    public const PULL_CLIENT_VOUCHER = 'clientVoucher';
    public const PULL_OPERATED_VOUCHER = 'operatedVoucher';

    /**
     * @param list<SessionSplit> $splits
     * @param list<string> $modes
     */
    public function __construct(
        public readonly string $cap,
        public readonly string $currency,
        public readonly string $operator,
        public readonly string $recipient,
        public readonly ?int $decimals = null,
        public readonly string $network = '',
        public readonly array $splits = [],
        public readonly string $programId = '',
        public readonly string $description = '',
        public readonly string $externalId = '',
        public readonly string $minVoucherDelta = '',
        public readonly array $modes = [],
        public readonly ?string $pullVoucherStrategy = null,
        public readonly string $recentBlockhash = '',
    ) {
        self::assertPositiveDecimal($cap, 'cap');
        self::assertRequired($currency, 'currency');
        self::assertRequired($operator, 'operator');
        self::assertRequired($recipient, 'recipient');
        if ($decimals !== null && ($decimals < 0 || $decimals > 255)) {
            throw new InvalidArgumentException('decimals must be between 0 and 255');
        }
        foreach ($splits as $split) {
            if (!$split instanceof SessionSplit) {
                throw new InvalidArgumentException('splits must contain SessionSplit values');
            }
        }
        if ($minVoucherDelta !== '') {
            self::assertPositiveDecimal($minVoucherDelta, 'minVoucherDelta');
        }
        foreach ($modes as $mode) {
            self::normalizeMode($mode);
        }
        if (in_array(self::MODE_PULL, $modes, true) && $pullVoucherStrategy === null) {
            throw new InvalidArgumentException('pullVoucherStrategy is required when pull mode is advertised');
        }
        if ($pullVoucherStrategy !== null) {
            self::normalizePullVoucherStrategy($pullVoucherStrategy);
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $value = [
            'cap' => $this->cap,
            'currency' => $this->currency,
            'operator' => $this->operator,
            'recipient' => $this->recipient,
        ];
        if ($this->decimals !== null) {
            $value['decimals'] = $this->decimals;
        }
        if ($this->network !== '') {
            $value['network'] = $this->network;
        }
        if ($this->splits !== []) {
            $value['splits'] = array_map(static fn (SessionSplit $split): array => $split->toArray(), $this->splits);
        }
        if ($this->programId !== '') {
            $value['programId'] = $this->programId;
        }
        if ($this->description !== '') {
            $value['description'] = $this->description;
        }
        if ($this->externalId !== '') {
            $value['externalId'] = $this->externalId;
        }
        if ($this->minVoucherDelta !== '') {
            $value['minVoucherDelta'] = $this->minVoucherDelta;
        }
        if ($this->modes !== []) {
            $value['modes'] = $this->modes;
        }
        if ($this->pullVoucherStrategy !== null) {
            $value['pullVoucherStrategy'] = $this->pullVoucherStrategy;
        }
        if ($this->recentBlockhash !== '') {
            $value['recentBlockhash'] = $this->recentBlockhash;
        }

        return $value;
    }

    public static function normalizeMode(string $mode): string
    {
        return match ($mode) {
            self::MODE_PUSH, self::MODE_PULL => $mode,
            default => throw new InvalidArgumentException(sprintf('unsupported session mode: %s', $mode)),
        };
    }

    public static function normalizePullVoucherStrategy(string $strategy): string
    {
        return match ($strategy) {
            self::PULL_CLIENT_VOUCHER, self::PULL_OPERATED_VOUCHER => $strategy,
            default => throw new InvalidArgumentException(sprintf('unsupported pullVoucherStrategy: %s', $strategy)),
        };
    }

    public static function assertPositiveDecimal(string $value, string $field): void
    {
        if ($value === '' || !ctype_digit($value)) {
            throw new InvalidArgumentException(sprintf('invalid %s: %s', $field, $value));
        }

        $canonical = ltrim($value, '0');
        if ($canonical === '' || $canonical !== $value) {
            throw new InvalidArgumentException(sprintf('invalid %s: %s', $field, $value));
        }
    }

    private static function assertRequired(string $value, string $field): void
    {
        if ($value === '') {
            throw new InvalidArgumentException(sprintf('%s is required', $field));
        }
    }
}
