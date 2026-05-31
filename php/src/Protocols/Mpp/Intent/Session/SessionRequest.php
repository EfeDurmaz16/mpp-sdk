<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;
use PayKit\Protocols\Mpp\Core\Json;

/**
 * Session intent request embedded in a 402 challenge.
 *
 * Describes the channel parameters: cap, currency, splits, network, modes, etc.
 * Serialization mirrors the Rust `SessionRequest` serde rules: empty splits and
 * modes are omitted, `None` optional fields are omitted, `programId`/`externalId`
 * /`minVoucherDelta`/`recentBlockhash` carry their camelCase wire names, and a
 * push-only `modes` list is dropped (clients assume push when modes is absent).
 *
 * @see rust/crates/mpp/src/protocol/intents/session.rs SessionRequest
 */
final class SessionRequest
{
    /**
     * @param list<SessionSplit> $splits
     * @param list<SessionMode> $modes
     */
    public function __construct(
        public readonly string $cap,
        public readonly string $currency,
        public readonly string $operator,
        public readonly string $recipient,
        public readonly ?int $decimals = null,
        public readonly ?string $network = null,
        public readonly array $splits = [],
        public readonly ?string $programId = null,
        public readonly ?string $description = null,
        public readonly ?string $externalId = null,
        public readonly ?string $minVoucherDelta = null,
        public readonly array $modes = [],
        public readonly ?SessionPullVoucherStrategy $pullVoucherStrategy = null,
        public readonly ?string $recentBlockhash = null,
    ) {
        if ($cap === '') {
            throw new InvalidArgumentException('cap is required');
        }
        if ($currency === '') {
            throw new InvalidArgumentException('currency is required');
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
        if ($this->network !== null) {
            $value['network'] = $this->network;
        }
        if ($this->splits !== []) {
            $value['splits'] = array_map(static fn (SessionSplit $s): array => $s->toArray(), $this->splits);
        }
        if ($this->programId !== null) {
            $value['programId'] = $this->programId;
        }
        if ($this->description !== null) {
            $value['description'] = $this->description;
        }
        if ($this->externalId !== null) {
            $value['externalId'] = $this->externalId;
        }
        if ($this->minVoucherDelta !== null) {
            $value['minVoucherDelta'] = $this->minVoucherDelta;
        }
        // A push-only modes list is dropped: clients assume push when absent.
        if ($this->modes !== [] && $this->modes !== [SessionMode::Push]) {
            $value['modes'] = array_map(static fn (SessionMode $m): string => $m->value, $this->modes);
        }
        if ($this->pullVoucherStrategy !== null) {
            $value['pullVoucherStrategy'] = $this->pullVoucherStrategy->value;
        }
        if ($this->recentBlockhash !== null) {
            $value['recentBlockhash'] = $this->recentBlockhash;
        }

        return $value;
    }

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $splitsRaw = $value['splits'] ?? [];
        if (!is_array($splitsRaw)) {
            throw new InvalidArgumentException('splits must be an array');
        }
        $splits = [];
        foreach ($splitsRaw as $split) {
            $splits[] = SessionSplit::fromArray(Json::object($split, 'split'));
        }

        $modesRaw = $value['modes'] ?? [];
        if (!is_array($modesRaw)) {
            throw new InvalidArgumentException('modes must be an array');
        }
        $modes = [];
        foreach ($modesRaw as $mode) {
            if (!is_string($mode)) {
                throw new InvalidArgumentException('mode must be a string');
            }
            $modes[] = SessionMode::from($mode);
        }

        $strategyRaw = $value['pullVoucherStrategy'] ?? null;
        $strategy = null;
        if ($strategyRaw !== null) {
            if (!is_string($strategyRaw)) {
                throw new InvalidArgumentException('pullVoucherStrategy must be a string');
            }
            $strategy = SessionPullVoucherStrategy::from($strategyRaw);
        }

        return new self(
            cap: Json::optionalString($value['cap'] ?? null, 'cap'),
            currency: Json::optionalString($value['currency'] ?? null, 'currency'),
            operator: Json::optionalString($value['operator'] ?? null, 'operator'),
            recipient: Json::optionalString($value['recipient'] ?? null, 'recipient'),
            decimals: Json::optionalInt($value['decimals'] ?? null, 'decimals'),
            network: isset($value['network']) ? Json::string($value['network'], 'network') : null,
            splits: $splits,
            programId: isset($value['programId']) ? Json::string($value['programId'], 'programId') : null,
            description: isset($value['description']) ? Json::string($value['description'], 'description') : null,
            externalId: isset($value['externalId']) ? Json::string($value['externalId'], 'externalId') : null,
            minVoucherDelta: isset($value['minVoucherDelta']) ? Json::string($value['minVoucherDelta'], 'minVoucherDelta') : null,
            modes: $modes,
            pullVoucherStrategy: $strategy,
            recentBlockhash: isset($value['recentBlockhash']) ? Json::string($value['recentBlockhash'], 'recentBlockhash') : null,
        );
    }
}
