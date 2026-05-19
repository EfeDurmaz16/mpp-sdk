<?php

declare(strict_types=1);

namespace SolanaMpp\Intent;

use DateTimeImmutable;
use InvalidArgumentException;

final class SubscriptionRequest
{
    public const PERIOD_DAY = 'day';
    public const PERIOD_WEEK = 'week';
    public const PERIOD_MONTH = 'month';

    /**
     * @param array<string, mixed>|null $methodDetails
     */
    public function __construct(
        public readonly string $amount,
        public readonly string $currency,
        public readonly string $periodUnit,
        public readonly string $periodCount,
        public readonly string $recipient = '',
        public readonly string $subscriptionExpires = '',
        public readonly string $description = '',
        public readonly string $externalId = '',
        public readonly ?array $methodDetails = null,
    ) {
        self::assertPositiveDecimal($amount, 'amount');
        if ($currency === '') {
            throw new InvalidArgumentException('currency is required');
        }
        self::normalizePeriodUnit($periodUnit);
        self::assertPositiveDecimal($periodCount, 'periodCount');
        if ($subscriptionExpires !== '') {
            self::parseSubscriptionExpires($subscriptionExpires);
        }
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $value = [
            'amount' => $this->amount,
            'currency' => $this->currency,
            'periodUnit' => $this->periodUnit,
            'periodCount' => $this->periodCount,
        ];
        if ($this->recipient !== '') {
            $value['recipient'] = $this->recipient;
        }
        if ($this->subscriptionExpires !== '') {
            $value['subscriptionExpires'] = $this->subscriptionExpires;
        }
        if ($this->description !== '') {
            $value['description'] = $this->description;
        }
        if ($this->externalId !== '') {
            $value['externalId'] = $this->externalId;
        }
        if ($this->methodDetails !== null) {
            $value['methodDetails'] = $this->methodDetails;
        }

        return $value;
    }

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $methodDetails = $value['methodDetails'] ?? null;
        if ($methodDetails !== null && !is_array($methodDetails)) {
            throw new InvalidArgumentException('methodDetails must be an object');
        }

        /** @var array<string, mixed>|null $methodDetails */
        return new self(
            amount: (string)($value['amount'] ?? ''),
            currency: (string)($value['currency'] ?? ''),
            periodUnit: (string)($value['periodUnit'] ?? ''),
            periodCount: (string)($value['periodCount'] ?? ''),
            recipient: (string)($value['recipient'] ?? ''),
            subscriptionExpires: (string)($value['subscriptionExpires'] ?? ''),
            description: (string)($value['description'] ?? ''),
            externalId: (string)($value['externalId'] ?? ''),
            methodDetails: $methodDetails,
        );
    }

    public static function normalizePeriodUnit(string $periodUnit): string
    {
        return match ($periodUnit) {
            self::PERIOD_DAY, self::PERIOD_WEEK, self::PERIOD_MONTH => $periodUnit,
            default => throw new InvalidArgumentException(sprintf('unsupported periodUnit: %s', $periodUnit)),
        };
    }

    public static function parseSubscriptionExpires(string $value): DateTimeImmutable
    {
        $parsed = DateTimeImmutable::createFromFormat(DATE_ATOM, $value);
        if ($parsed === false) {
            throw new InvalidArgumentException(sprintf('invalid subscriptionExpires: %s', $value));
        }

        return $parsed;
    }

    private static function assertPositiveDecimal(string $value, string $field): void
    {
        if ($value === '' || !ctype_digit($value)) {
            throw new InvalidArgumentException(sprintf('invalid %s: %s', $field, $value));
        }

        $canonical = ltrim($value, '0');
        if ($canonical === '' || $canonical !== $value) {
            throw new InvalidArgumentException(sprintf('invalid %s: %s', $field, $value));
        }
    }
}
