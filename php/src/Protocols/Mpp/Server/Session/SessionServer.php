<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Server\Session;

use InvalidArgumentException;
use RuntimeException;
use PayKit\PayCore\Solana\Mints;
use PayKit\Protocols\Mpp\Core\PaymentChannels;
use PayKit\Protocols\Mpp\Intent\Session\ClosePayload;
use PayKit\Protocols\Mpp\Intent\Session\CommitPayload;
use PayKit\Protocols\Mpp\Intent\Session\CommitReceipt;
use PayKit\Protocols\Mpp\Intent\Session\CommitStatus;
use PayKit\Protocols\Mpp\Intent\Session\MeteringDirective;
use PayKit\Protocols\Mpp\Intent\Session\OpenPayload;
use PayKit\Protocols\Mpp\Intent\Session\SessionMode;
use PayKit\Protocols\Mpp\Intent\Session\SessionRequest;
use PayKit\Protocols\Mpp\Intent\Session\SignedVoucher;
use PayKit\Protocols\Mpp\Intent\Session\TopUpPayload;
use SolanaPhpSdk\Keypair\PublicKey;
use SolanaPhpSdk\Util\Base58;

/**
 * Server-side session intent: challenge issuance, voucher verification, and
 * channel lifecycle management.
 *
 * Mirrors the Rust `SessionServer` (`rust/crates/mpp/src/server/session.rs`).
 * The session server is stateful (unlike the stateless charge handler): it
 * stores per-channel state in a {@see ChannelStore} and advances a settled
 * watermark atomically via {@see ChannelStore::update()}.
 *
 * Flow:
 *   1. {@see buildChallengeRequest()} produces the SessionRequest for a 402.
 *   2. {@see processOpen()} records a new channel from an `open` action.
 *   3. {@see verifyVoucher()} validates per-request vouchers and advances the
 *      watermark.
 *   4. {@see beginDelivery()} / {@see processCommit()} drive the metered
 *      delivery flow with idempotent commits keyed on `deliveryId`.
 *   5. {@see processTopup()} raises the deposit cap.
 *   6. {@see processClose()} / {@see finalizeParams()} produce on-chain
 *      settlement parameters.
 *
 * On-chain transaction verification (confirming the open/top-up signature) is
 * left to the host integration, matching the Rust default where `rpc_url` is
 * unset in unit tests.
 */
final class SessionServer
{
    /** Default session voucher/directive expiry: 2100-01-01T00:00:00Z. */
    public const DEFAULT_SESSION_EXPIRES_AT = 4_102_444_800;

    public function __construct(
        private readonly SessionConfig $config,
        private readonly ChannelStore $store,
    ) {
    }

    /**
     * Build the SessionRequest to embed in a 402 challenge. `cap` is clamped
     * to the configured max cap.
     */
    public function buildChallengeRequest(int $cap): SessionRequest
    {
        $effectiveCap = min($cap, $this->config->maxCap);
        return new SessionRequest(
            cap: (string) $effectiveCap,
            currency: $this->config->currency,
            operator: $this->config->operator,
            recipient: $this->config->recipient,
            decimals: $this->config->decimals,
            network: $this->config->network,
            splits: $this->config->splits,
            programId: $this->config->programId,
            minVoucherDelta: $this->config->minVoucherDelta > 0
                ? (string) $this->config->minVoucherDelta
                : null,
            // Omit a push-only list; SessionRequest::toArray drops it anyway.
            modes: $this->config->modes,
            pullVoucherStrategy: $this->config->offersPull()
                ? $this->config->pullVoucherStrategy
                : null,
        );
    }

    /**
     * Validate a payment-channel `open` payload against the challenge and
     * return the resolved on-chain open parameters (channel PDA, payer/payee/
     * mint, token program, distribution hash).
     *
     * @return array{
     *   payer: string, payee: string, mint: string, authorizedSigner: string,
     *   salt: string, deposit: string, gracePeriod: int, tokenProgram: string,
     *   programId: string, channel: string, distributionHash: string
     * }
     */
    public function paymentChannelOpenParams(OpenPayload $payload): array
    {
        $payer = $this->requireField($payload->payer, 'payer');
        $payee = $this->requireField($payload->payee, 'payee');
        $mint = $this->requireField($payload->mint, 'mint');
        $authorizedSigner = $payload->authorizedSigner;
        if ($authorizedSigner === '') {
            throw new InvalidArgumentException('payment-channel open missing authorizedSigner');
        }
        $salt = $payload->salt;
        if ($salt === null) {
            throw new InvalidArgumentException('payment-channel open missing salt');
        }
        $gracePeriod = $payload->gracePeriod;
        if ($gracePeriod === null) {
            throw new InvalidArgumentException('payment-channel open missing gracePeriod');
        }
        $deposit = $payload->depositAmount();

        $tokenProgram = Mints::tokenProgramFor($this->config->currency, $this->config->network);
        $programId = $this->config->programId ?? PaymentChannels::PROGRAM_ID;
        $expectedMint = $this->expectedMint();

        // Validate pubkey shapes early for clear errors.
        $this->assertPubkey($authorizedSigner, 'authorizedSigner');
        $this->assertPubkey($payer, 'payer');

        if ($payee !== $this->config->recipient) {
            throw new RuntimeException('payment-channel open payee does not match challenge recipient');
        }
        if ($mint !== $expectedMint) {
            throw new RuntimeException('payment-channel open mint does not match challenge currency');
        }

        [$channel] = PaymentChannels::findChannelPda(
            $payer,
            $payee,
            $mint,
            $authorizedSigner,
            $salt,
            $programId,
        );
        $channelB58 = $channel->toBase58();
        if ($payload->channelId !== $channelB58) {
            throw new RuntimeException('payment-channel open channelId does not match derived channel PDA');
        }

        return [
            'payer' => $payer,
            'payee' => $payee,
            'mint' => $mint,
            'authorizedSigner' => $authorizedSigner,
            'salt' => $salt,
            'deposit' => $deposit,
            'gracePeriod' => $gracePeriod,
            'tokenProgram' => $tokenProgram,
            'programId' => $programId,
            'channel' => $channelB58,
            'distributionHash' => $this->distributionHash(),
        ];
    }

    /**
     * Process an `open` action: persist the channel state. Accepts
     * payment-channel and operated-voucher delegated-token opens.
     */
    public function processOpen(OpenPayload $payload): ChannelState
    {
        if (!$this->config->supportsMode($payload->mode)) {
            throw new RuntimeException(
                sprintf('Session mode %s is not supported by this challenge', $payload->mode->value)
            );
        }

        $sessionId = $payload->sessionId();
        $deposit = (int) $payload->depositAmount();

        if ($deposit === 0) {
            throw new RuntimeException('Deposit must be greater than zero');
        }
        if ($deposit > $this->config->maxCap) {
            throw new RuntimeException(sprintf('Deposit %d exceeds max cap %d', $deposit, $this->config->maxCap));
        }

        $state = new ChannelState(
            channelId: $sessionId,
            authorizedSigner: $payload->authorizedSigner,
            deposit: $deposit,
            operator: $payload->owner ?? $payload->payer,
        );
        $this->store->put($sessionId, $state);
        return $state;
    }

    /**
     * Verify a per-request voucher, advance the watermark, and return the new
     * cumulative. Rejects unknown channels, non-increasing cumulatives (unless
     * an exact idempotent replay), over-deposit cumulatives, sub-min-delta
     * increments, expired/invalid signatures, and post-close vouchers.
     */
    public function verifyVoucher(SignedVoucher $voucher): int
    {
        $channelId = $voucher->data->channelId;
        $newCumulative = $this->parseAmount($voucher->data->cumulative, 'voucher cumulative');

        $state = $this->store->get($channelId);
        if ($state === null) {
            throw new RuntimeException("Channel {$channelId} not found");
        }
        if ($state->finalized) {
            throw new RuntimeException('Channel is already finalized');
        }
        if ($state->closeRequestedAt !== null) {
            throw new RuntimeException('Channel close is pending; no further vouchers accepted');
        }

        // Idempotent replay: same cumulative AND same signature.
        if ($newCumulative === $state->cumulative
            && $state->highestVoucherSignature === $voucher->signature
        ) {
            $this->verifySignature($voucher, $state->authorizedSigner);
            return $newCumulative;
        }

        if ($newCumulative <= $state->cumulative) {
            throw new RuntimeException(
                sprintf('Voucher cumulative %d must exceed watermark %d', $newCumulative, $state->cumulative)
            );
        }
        if ($newCumulative > $state->deposit) {
            throw new RuntimeException(
                sprintf('Voucher cumulative %d exceeds deposit %d', $newCumulative, $state->deposit)
            );
        }
        $delta = $newCumulative - $state->cumulative;
        $min = $this->config->minVoucherDelta;
        if ($min > 0 && $delta < $min) {
            throw new RuntimeException(sprintf('Voucher delta %d is below minimum %d', $delta, $min));
        }

        $this->verifySignature($voucher, $state->authorizedSigner);

        $sig = $voucher->signature;
        $expiresAt = $voucher->data->expiresAt;
        $updated = $this->store->update($channelId, static function (?ChannelState $current) use (
            $channelId,
            $newCumulative,
            $sig,
            $expiresAt
        ): ChannelState {
            if ($current === null) {
                throw new RuntimeException("Channel {$channelId} not found");
            }
            if ($current->finalized) {
                throw new RuntimeException('Channel is already finalized');
            }
            if ($current->closeRequestedAt !== null) {
                throw new RuntimeException('Channel close is pending; no further vouchers accepted');
            }
            if ($newCumulative === $current->cumulative && $current->highestVoucherSignature === $sig) {
                return $current;
            }
            if ($newCumulative <= $current->cumulative) {
                throw new RuntimeException('Concurrent update: watermark advanced');
            }
            $current->cumulative = $newCumulative;
            $current->highestVoucherSignature = $sig;
            $current->highestVoucherExpiresAt = $expiresAt;
            return $current;
        });

        return $updated->cumulative;
    }

    /**
     * Process a `topUp` action: atomically raise the channel deposit cap. The
     * new deposit must exceed the current deposit and stay within the max cap.
     */
    public function processTopup(TopUpPayload $payload): ChannelState
    {
        $newDeposit = $this->parseAmount($payload->newDeposit, 'newDeposit');
        $maxCap = $this->config->maxCap;
        $channelId = $payload->channelId;

        return $this->store->update($channelId, static function (?ChannelState $state) use (
            $channelId,
            $newDeposit,
            $maxCap
        ): ChannelState {
            if ($state === null) {
                throw new RuntimeException("Channel {$channelId} not found");
            }
            if ($newDeposit <= $state->deposit) {
                throw new RuntimeException(
                    sprintf('New deposit %d must exceed current deposit %d', $newDeposit, $state->deposit)
                );
            }
            if ($newDeposit > $maxCap) {
                throw new RuntimeException(sprintf('New deposit %d exceeds max cap %d', $newDeposit, $maxCap));
            }
            $state->deposit = $newDeposit;
            return $state;
        });
    }

    /**
     * Reserve capacity for a delivered message/response and return the metering
     * directive the client must commit after processing it.
     */
    public function beginDelivery(DeliveryRequest $request): MeteringDirective
    {
        if ($request->amount <= 0) {
            throw new RuntimeException('Delivery amount must be greater than zero');
        }

        $sessionId = $request->sessionId;
        $amount = $request->amount;
        $expiresAt = $request->expiresAt ?? self::DEFAULT_SESSION_EXPIRES_AT;
        $requestedId = $request->deliveryId;
        $directive = null;

        $this->store->update($sessionId, static function (?ChannelState $state) use (
            $sessionId,
            $amount,
            $expiresAt,
            $requestedId,
            &$directive
        ): ChannelState {
            if ($state === null) {
                throw new RuntimeException("Channel {$sessionId} not found");
            }
            if ($state->finalized) {
                throw new RuntimeException('Channel is already finalized');
            }
            if ($state->closeRequestedAt !== null) {
                throw new RuntimeException('Channel close is pending; no further deliveries accepted');
            }
            $pendingTotal = 0;
            foreach ($state->pendingDeliveries as $pending) {
                $pendingTotal += $pending->amount;
            }
            if ($state->cumulative + $pendingTotal + $amount > $state->deposit) {
                throw new RuntimeException(sprintf('Delivery amount %d exceeds available deposit', $amount));
            }

            $sequence = $state->nextDeliverySequence + 1;
            $deliveryId = $requestedId ?? sprintf('%s:%d', $sessionId, $sequence);
            foreach ($state->pendingDeliveries as $pending) {
                if ($pending->deliveryId === $deliveryId) {
                    throw new RuntimeException("Delivery {$deliveryId} already exists");
                }
            }
            foreach ($state->committedDeliveries as $committed) {
                if ($committed->deliveryId === $deliveryId) {
                    throw new RuntimeException("Delivery {$deliveryId} already exists");
                }
            }

            $state->nextDeliverySequence = $sequence;
            $state->pendingDeliveries[] = new PendingDelivery($deliveryId, $amount, $sequence, $expiresAt);
            $directive = ['deliveryId' => $deliveryId, 'sequence' => $sequence];
            return $state;
        });

        if (!is_array($directive)) {
            throw new RuntimeException('Delivery reservation did not produce a directive');
        }

        return new MeteringDirective(
            deliveryId: $directive['deliveryId'],
            sessionId: $sessionId,
            amount: (string) $amount,
            currency: $this->config->currency,
            sequence: $directive['sequence'],
            expiresAt: $expiresAt,
            commitUrl: $request->commitUrl,
            proof: $request->proof,
        );
    }

    /**
     * Commit a reserved delivery: verify the attached voucher, advance the
     * settled watermark, and return a receipt. A duplicate commit for the same
     * `deliveryId` with the same voucher returns {@see CommitStatus::Replayed}.
     */
    public function processCommit(CommitPayload $payload): CommitReceipt
    {
        $channelId = $payload->voucher->data->channelId;
        $newCumulative = $this->parseAmount($payload->voucher->data->cumulative, 'commit voucher cumulative');

        $state = $this->store->get($channelId);
        if ($state === null) {
            throw new RuntimeException("Channel {$channelId} not found");
        }

        // Idempotent replay check before mutating.
        foreach ($state->committedDeliveries as $committed) {
            if ($committed->deliveryId === $payload->deliveryId) {
                if ($committed->cumulative === $newCumulative
                    && $committed->voucherSignature === $payload->voucher->signature
                ) {
                    $this->verifySignature($payload->voucher, $state->authorizedSigner);
                    return new CommitReceipt(
                        deliveryId: $payload->deliveryId,
                        sessionId: $channelId,
                        amount: (string) $committed->amount,
                        cumulative: (string) $committed->cumulative,
                        status: CommitStatus::Replayed,
                    );
                }
                throw new RuntimeException(
                    "Delivery {$payload->deliveryId} was already committed with different voucher"
                );
            }
        }

        $pending = null;
        foreach ($state->pendingDeliveries as $candidate) {
            if ($candidate->deliveryId === $payload->deliveryId) {
                $pending = $candidate;
                break;
            }
        }
        if ($pending === null) {
            throw new RuntimeException("Delivery {$payload->deliveryId} not found");
        }
        $now = time();
        if ($pending->expiresAt <= $now) {
            throw new RuntimeException("Delivery {$payload->deliveryId} has expired");
        }
        if ($newCumulative <= $state->cumulative) {
            throw new RuntimeException(
                sprintf('Commit cumulative %d must exceed watermark %d', $newCumulative, $state->cumulative)
            );
        }
        $this->verifySignature($payload->voucher, $state->authorizedSigner);

        $deliveryId = $payload->deliveryId;
        $signature = $payload->voucher->signature;
        $expiresAt = $payload->voucher->data->expiresAt;
        $outcome = null;

        $this->store->update($channelId, static function (?ChannelState $current) use (
            $channelId,
            $deliveryId,
            $newCumulative,
            $signature,
            $expiresAt,
            $now,
            &$outcome
        ): ChannelState {
            if ($current === null) {
                throw new RuntimeException("Channel {$channelId} not found");
            }
            if ($current->finalized) {
                throw new RuntimeException('Channel is already finalized');
            }
            if ($current->closeRequestedAt !== null) {
                throw new RuntimeException('Channel close is pending; no further commits accepted');
            }
            foreach ($current->committedDeliveries as $committed) {
                if ($committed->deliveryId === $deliveryId) {
                    if ($committed->cumulative === $newCumulative
                        && $committed->voucherSignature === $signature
                    ) {
                        $outcome = [$committed->amount, $committed->cumulative, CommitStatus::Replayed];
                        return $current;
                    }
                    throw new RuntimeException(
                        "Delivery {$deliveryId} was already committed with different voucher"
                    );
                }
            }
            $pendingIndex = null;
            foreach ($current->pendingDeliveries as $index => $candidate) {
                if ($candidate->deliveryId === $deliveryId) {
                    $pendingIndex = $index;
                    break;
                }
            }
            if ($pendingIndex === null) {
                throw new RuntimeException("Delivery {$deliveryId} not found");
            }
            $reserved = $current->pendingDeliveries[$pendingIndex];
            if ($reserved->expiresAt <= $now) {
                throw new RuntimeException("Delivery {$deliveryId} has expired");
            }
            if ($newCumulative <= $current->cumulative) {
                throw new RuntimeException(
                    sprintf('Commit cumulative %d must exceed watermark %d', $newCumulative, $current->cumulative)
                );
            }
            $actualAmount = $newCumulative - $current->cumulative;
            if ($actualAmount > $reserved->amount) {
                throw new RuntimeException(
                    sprintf('Commit amount %d exceeds reserved amount %d', $actualAmount, $reserved->amount)
                );
            }

            $remaining = $current->pendingDeliveries;
            array_splice($remaining, $pendingIndex, 1);
            $current->pendingDeliveries = array_values($remaining);
            $current->cumulative = $newCumulative;
            $current->highestVoucherSignature = $signature;
            $current->highestVoucherExpiresAt = $expiresAt;
            $current->committedDeliveries[] = new CommittedDelivery(
                $deliveryId,
                $actualAmount,
                $newCumulative,
                $signature,
            );
            $outcome = [$actualAmount, $newCumulative, CommitStatus::Committed];
            return $current;
        });

        if (!is_array($outcome)) {
            throw new RuntimeException('Commit did not produce a receipt');
        }
        [$amount, $cumulative, $status] = $outcome;
        return new CommitReceipt(
            deliveryId: $payload->deliveryId,
            sessionId: $channelId,
            amount: (string) $amount,
            cumulative: (string) $cumulative,
            status: $status,
        );
    }

    /**
     * Process a `close` action: atomically set close-pending, accept a final
     * voucher if provided, and return on-chain settlement parameters.
     */
    public function processClose(ClosePayload $payload): FinalizeParams
    {
        $now = time();
        $voucher = $payload->voucher;
        $authorizedSigner = $this->store->get($payload->channelId)?->authorizedSigner;
        if ($authorizedSigner !== null && $voucher !== null) {
            // Verify signature outside the closure so the failure surfaces
            // before any state mutation (the watermark advance still re-checks
            // bounds inside the atomic update).
            $cumulative = $this->parseAmount($voucher->data->cumulative, 'final voucher cumulative');
            $existing = $this->store->get($payload->channelId);
            if ($existing !== null && $cumulative > $existing->cumulative) {
                $this->verifySignature($voucher, $authorizedSigner);
            }
        }

        $channelId = $payload->channelId;
        $this->store->update($channelId, static function (?ChannelState $state) use (
            $voucher,
            $now
        ): ChannelState {
            if ($state === null) {
                throw new RuntimeException('Channel not found');
            }
            if ($state->finalized) {
                throw new RuntimeException('Channel is already finalized');
            }
            if ($state->closeRequestedAt !== null) {
                throw new RuntimeException('Close already requested');
            }

            if ($voucher !== null) {
                $cumulative = (int) $voucher->data->cumulative;
                if ($cumulative <= $state->cumulative) {
                    // Idempotent replay of the highest voucher is tolerated.
                    if ($cumulative === $state->cumulative
                        && $state->highestVoucherSignature === $voucher->signature
                    ) {
                        if ($state->highestVoucherExpiresAt === null) {
                            $state->highestVoucherExpiresAt = $voucher->data->expiresAt;
                        }
                    } else {
                        throw new RuntimeException(
                            sprintf(
                                'Final voucher cumulative %d must exceed watermark %d',
                                $cumulative,
                                $state->cumulative
                            )
                        );
                    }
                } else {
                    if ($cumulative > $state->deposit) {
                        throw new RuntimeException('Final voucher exceeds deposit');
                    }
                    $state->cumulative = $cumulative;
                    $state->highestVoucherSignature = $voucher->signature;
                    $state->highestVoucherExpiresAt = $voucher->data->expiresAt;
                }
            }

            $state->closeRequestedAt = $now;
            return $state;
        });

        return $this->finalizeParams($channelId);
    }

    /**
     * Return finalize parameters for a channel ready for on-chain settlement.
     */
    public function finalizeParams(string $channelId): FinalizeParams
    {
        $state = $this->store->get($channelId);
        if ($state === null) {
            throw new RuntimeException("Channel {$channelId} not found");
        }
        $programId = $this->config->programId ?? PaymentChannels::PROGRAM_ID;

        return new FinalizeParams(
            channelId: $channelId,
            recipient: $this->config->recipient,
            programId: $programId,
            settled: $state->cumulative,
            distributionHash: $this->distributionHash(),
            authorizedSigner: $state->authorizedSigner !== '' ? $state->authorizedSigner : null,
            payer: $state->operator,
            mint: $this->maybeExpectedMint(),
            voucherSignature: $state->highestVoucherSignature,
            voucherExpiresAt: $state->highestVoucherExpiresAt,
            splits: $this->config->splits,
        );
    }

    public function markFinalized(string $channelId): void
    {
        $this->store->markFinalized($channelId);
    }

    /**
     * Verify an Ed25519 voucher signature against the authorized signer and
     * reject expired vouchers. Uses libsodium for the actual verification.
     */
    private function verifySignature(SignedVoucher $voucher, string $authorizedSigner): void
    {
        if ($voucher->data->expiresAt <= time()) {
            throw new RuntimeException('Voucher has expired');
        }

        $message = $voucher->data->messageBytes();
        $sigBytes = Base58::decode($voucher->signature);
        $keyBytes = (new PublicKey($authorizedSigner))->toBytes();

        if (strlen($sigBytes) !== SODIUM_CRYPTO_SIGN_BYTES) {
            throw new RuntimeException('Signature is not 64 bytes');
        }
        if (strlen($keyBytes) !== SODIUM_CRYPTO_SIGN_PUBLICKEYBYTES) {
            throw new RuntimeException('authorizedSigner is not 32 bytes');
        }

        if (!sodium_crypto_sign_verify_detached($sigBytes, $message, $keyBytes)) {
            throw new RuntimeException('Voucher signature verification failed');
        }
    }

    private function distributionHash(): string
    {
        $recipients = array_map(
            static fn ($split): array => ['recipient' => $split->recipient, 'bps' => $split->bps],
            $this->config->splits,
        );
        return PaymentChannels::distributionHash($recipients);
    }

    private function expectedMint(): string
    {
        $mint = Mints::resolve($this->config->currency, $this->config->network);
        if ($mint === null) {
            throw new RuntimeException('payment-channel sessions require an SPL token');
        }
        return $mint;
    }

    private function maybeExpectedMint(): ?string
    {
        try {
            return $this->expectedMint();
        } catch (RuntimeException) {
            return null;
        }
    }

    private function requireField(?string $value, string $field): string
    {
        if ($value === null || $value === '') {
            throw new InvalidArgumentException("payment-channel open missing {$field}");
        }
        return $value;
    }

    private function assertPubkey(string $value, string $field): void
    {
        try {
            $bytes = (new PublicKey($value))->toBytes();
        } catch (\Throwable $e) {
            throw new InvalidArgumentException("invalid payment-channel {$field}: {$e->getMessage()}");
        }
        if (strlen($bytes) !== 32) {
            throw new InvalidArgumentException("invalid payment-channel {$field}");
        }
    }

    private function parseAmount(string $value, string $field): int
    {
        if ($value === '' || !ctype_digit($value)) {
            throw new RuntimeException("Invalid {$field}");
        }
        return (int) $value;
    }
}
