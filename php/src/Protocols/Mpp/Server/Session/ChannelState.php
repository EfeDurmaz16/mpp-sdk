<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

/**
 * Persisted state of a payment channel, managed by the session server.
 *
 * Mirrors the Rust `ChannelState` (`rust/crates/mpp/src/store.rs`). Amounts are
 * held as PHP ints; base-unit session caps are well within PHP_INT_MAX on the
 * 64-bit builds the SDK targets.
 */
final class ChannelState
{
    /**
     * @param list<PendingDelivery> $pendingDeliveries
     * @param list<CommittedDelivery> $committedDeliveries
     */
    public function __construct(
        public string $channelId,
        public string $authorizedSigner,
        public int $deposit,
        public int $cumulative = 0,
        public bool $finalized = false,
        public ?string $highestVoucherSignature = null,
        public ?int $highestVoucherExpiresAt = null,
        public ?int $closeRequestedAt = null,
        public ?string $operator = null,
        public int $nextDeliverySequence = 0,
        public array $pendingDeliveries = [],
        public array $committedDeliveries = [],
    ) {
    }

    /**
     * Return a deep copy so atomic update closures cannot mutate the stored
     * snapshot in place before the store commits the new value.
     */
    public function copy(): self
    {
        return new self(
            channelId: $this->channelId,
            authorizedSigner: $this->authorizedSigner,
            deposit: $this->deposit,
            cumulative: $this->cumulative,
            finalized: $this->finalized,
            highestVoucherSignature: $this->highestVoucherSignature,
            highestVoucherExpiresAt: $this->highestVoucherExpiresAt,
            closeRequestedAt: $this->closeRequestedAt,
            operator: $this->operator,
            nextDeliverySequence: $this->nextDeliverySequence,
            pendingDeliveries: $this->pendingDeliveries,
            committedDeliveries: $this->committedDeliveries,
        );
    }
}
