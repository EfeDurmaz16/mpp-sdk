<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

use PayKit\Protocols\Mpp\Intent\Session\SessionSplit;

/**
 * Parameters needed to submit on-chain finalize + distribute transactions.
 *
 * Mirrors the Rust `FinalizeParams`. The `distributionHash` is the 32-byte
 * BLAKE3 commitment over `splits` computed at channel open time; it is returned
 * as raw bytes so callers can compare it against on-chain channel state.
 */
final class FinalizeParams
{
    /**
     * @param list<SessionSplit> $splits
     */
    public function __construct(
        public readonly string $channelId,
        public readonly string $recipient,
        public readonly string $programId,
        public readonly int $settled,
        public readonly string $distributionHash,
        public readonly ?string $authorizedSigner = null,
        public readonly ?string $payer = null,
        public readonly ?string $mint = null,
        public readonly ?string $voucherSignature = null,
        public readonly ?int $voucherExpiresAt = null,
        public readonly array $splits = [],
    ) {
    }
}
