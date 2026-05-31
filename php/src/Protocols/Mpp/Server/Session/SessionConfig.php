<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

use PayKit\Protocols\Mpp\Intent\Session\SessionMode;
use PayKit\Protocols\Mpp\Intent\Session\SessionPullVoucherStrategy;
use PayKit\Protocols\Mpp\Intent\Session\SessionSplit;

/**
 * Server configuration for the session intent. Mirrors the Rust `SessionConfig`.
 */
final class SessionConfig
{
    /**
     * @param list<SessionSplit> $splits
     * @param list<SessionMode> $modes
     */
    public function __construct(
        public readonly string $operator,
        public readonly string $recipient,
        public readonly int $maxCap = 10_000_000,
        public readonly string $currency = 'USDC',
        public readonly int $decimals = 6,
        public readonly string $network = 'mainnet-beta',
        public readonly array $splits = [],
        public readonly ?string $programId = null,
        public readonly int $minVoucherDelta = 0,
        public readonly array $modes = [SessionMode::Push],
        public readonly ?SessionPullVoucherStrategy $pullVoucherStrategy = null,
    ) {
    }

    public function supportsMode(SessionMode $mode): bool
    {
        if ($this->modes === []) {
            return $mode === SessionMode::Push;
        }
        foreach ($this->modes as $supported) {
            if ($supported === $mode) {
                return true;
            }
        }
        return false;
    }

    public function offersPull(): bool
    {
        foreach ($this->modes as $mode) {
            if ($mode === SessionMode::Pull) {
                return true;
            }
        }
        return false;
    }
}
