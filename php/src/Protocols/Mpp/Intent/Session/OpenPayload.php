<?php

declare(strict_types=1);

namespace PayKit\Protocols\Mpp\Intent\Session;

use InvalidArgumentException;
use PayKit\Protocols\Mpp\Core\Json;

/**
 * Payload for the `open` action. Shape varies by {@see SessionMode}.
 *
 * Use {@see OpenPayload::push}, {@see OpenPayload::paymentChannel}, or
 * {@see OpenPayload::pull} to construct. Inspect {@see OpenPayload::$mode} to
 * distinguish variants on the server.
 *
 * `salt` is serialized as a decimal string because authorization headers are
 * JSON-canonicalized and arbitrary u64 values are not safe JSON numbers. On
 * decode both a string and a (legacy) JSON number are accepted, matching the
 * Rust `deserialize_optional_u64_from_string_or_number` adapter.
 */
final class OpenPayload
{
    private function __construct(
        public readonly SessionMode $mode,
        public readonly string $authorizedSigner,
        public readonly string $signature,
        public readonly ?string $channelId = null,
        public readonly ?string $deposit = null,
        public readonly ?string $payer = null,
        public readonly ?string $payee = null,
        public readonly ?string $mint = null,
        public readonly ?string $salt = null,
        public readonly ?int $gracePeriod = null,
        public readonly ?string $transaction = null,
        public readonly ?string $tokenAccount = null,
        public readonly ?string $approvedAmount = null,
        public readonly ?string $owner = null,
        public readonly ?string $initMultiDelegateTx = null,
        public readonly ?string $updateDelegationTx = null,
    ) {
    }

    /**
     * Construct a push payment-channel open payload.
     */
    public static function push(string $channelId, string $deposit, string $authorizedSigner, string $signature): self
    {
        return new self(
            mode: SessionMode::Push,
            authorizedSigner: $authorizedSigner,
            signature: $signature,
            channelId: $channelId,
            deposit: $deposit,
        );
    }

    /**
     * Construct a full payment-channel open payload with an explicit mode.
     */
    public static function paymentChannel(
        SessionMode $mode,
        string $channelId,
        string $deposit,
        string $payer,
        string $payee,
        string $mint,
        string $salt,
        int $gracePeriod,
        string $authorizedSigner,
        string $signature,
    ): self {
        return new self(
            mode: $mode,
            authorizedSigner: $authorizedSigner,
            signature: $signature,
            channelId: $channelId,
            deposit: $deposit,
            payer: $payer,
            payee: $payee,
            mint: $mint,
            salt: $salt,
            gracePeriod: $gracePeriod,
        );
    }

    /**
     * Construct a pull (SPL delegation) open payload.
     */
    public static function pull(
        string $tokenAccount,
        string $approvedAmount,
        string $owner,
        string $authorizedSigner,
        string $signature,
    ): self {
        return new self(
            mode: SessionMode::Pull,
            authorizedSigner: $authorizedSigner,
            signature: $signature,
            tokenAccount: $tokenAccount,
            approvedAmount: $approvedAmount,
            owner: $owner,
        );
    }

    public function withTransaction(string $txBase64): self
    {
        return $this->cloneWith(transaction: $txBase64);
    }

    public function withInitTx(string $txBase64): self
    {
        return $this->cloneWith(initMultiDelegateTx: $txBase64);
    }

    public function withUpdateTx(string $txBase64): self
    {
        return $this->cloneWith(updateDelegationTx: $txBase64);
    }

    /**
     * Session identifier used as the channel store key:
     * - payment channel: channelId
     * - operated-voucher pull: tokenAccount
     */
    public function sessionId(): string
    {
        if ($this->channelId !== null && $this->channelId !== '') {
            return $this->channelId;
        }
        if ($this->mode === SessionMode::Pull && $this->tokenAccount !== null && $this->tokenAccount !== '') {
            return $this->tokenAccount;
        }
        throw new InvalidArgumentException(
            $this->mode === SessionMode::Push
                ? 'push open missing channelId'
                : 'pull open missing channelId or tokenAccount'
        );
    }

    /**
     * Deposit / approved amount for this open, as a base-unit integer string.
     */
    public function depositAmount(): string
    {
        $raw = $this->deposit;
        if ($raw === null || $raw === '') {
            $raw = $this->mode === SessionMode::Pull ? $this->approvedAmount : null;
        }
        if ($raw === null || $raw === '' || !ctype_digit($raw)) {
            throw new InvalidArgumentException(
                $this->mode === SessionMode::Push
                    ? 'push open missing or invalid deposit'
                    : 'pull open missing or invalid deposit/approvedAmount'
            );
        }
        return $raw;
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $value = ['mode' => $this->mode->value];
        if ($this->channelId !== null) {
            $value['channelId'] = $this->channelId;
        }
        if ($this->deposit !== null) {
            $value['deposit'] = $this->deposit;
        }
        if ($this->payer !== null) {
            $value['payer'] = $this->payer;
        }
        if ($this->payee !== null) {
            $value['payee'] = $this->payee;
        }
        if ($this->mint !== null) {
            $value['mint'] = $this->mint;
        }
        if ($this->salt !== null) {
            // u64 serialized as a decimal string (JS-safe canonical JSON).
            $value['salt'] = $this->salt;
        }
        if ($this->gracePeriod !== null) {
            $value['gracePeriod'] = $this->gracePeriod;
        }
        if ($this->transaction !== null) {
            $value['transaction'] = $this->transaction;
        }
        if ($this->tokenAccount !== null) {
            $value['tokenAccount'] = $this->tokenAccount;
        }
        if ($this->approvedAmount !== null) {
            $value['approvedAmount'] = $this->approvedAmount;
        }
        if ($this->owner !== null) {
            $value['owner'] = $this->owner;
        }
        if ($this->initMultiDelegateTx !== null) {
            $value['initMultiDelegateTx'] = $this->initMultiDelegateTx;
        }
        if ($this->updateDelegationTx !== null) {
            $value['updateDelegationTx'] = $this->updateDelegationTx;
        }
        $value['authorizedSigner'] = $this->authorizedSigner;
        $value['signature'] = $this->signature;

        return $value;
    }

    /**
     * @param array<string, mixed> $value
     */
    public static function fromArray(array $value): self
    {
        $modeRaw = $value['mode'] ?? null;
        if (!is_string($modeRaw)) {
            // No default: clients must always send "mode".
            throw new InvalidArgumentException('open payload missing mode');
        }
        $mode = SessionMode::from($modeRaw);

        return new self(
            mode: $mode,
            authorizedSigner: Json::optionalString($value['authorizedSigner'] ?? null, 'authorizedSigner'),
            signature: Json::optionalString($value['signature'] ?? null, 'signature'),
            channelId: self::optString($value, 'channelId'),
            deposit: self::optString($value, 'deposit'),
            payer: self::optString($value, 'payer'),
            payee: self::optString($value, 'payee'),
            mint: self::optString($value, 'mint'),
            salt: self::decodeSalt($value['salt'] ?? null),
            gracePeriod: Json::optionalInt($value['gracePeriod'] ?? null, 'gracePeriod'),
            transaction: self::optString($value, 'transaction'),
            tokenAccount: self::optString($value, 'tokenAccount'),
            approvedAmount: self::optString($value, 'approvedAmount'),
            owner: self::optString($value, 'owner'),
            initMultiDelegateTx: self::optString($value, 'initMultiDelegateTx'),
            updateDelegationTx: self::optString($value, 'updateDelegationTx'),
        );
    }

    /**
     * @param array<string, mixed> $value
     */
    private static function optString(array $value, string $field): ?string
    {
        return isset($value[$field]) ? Json::string($value[$field], $field) : null;
    }

    /**
     * Accept salt as a decimal string or a (legacy) JSON number; normalize to
     * a decimal string. Mirrors the Rust string-or-number deserializer.
     */
    private static function decodeSalt(mixed $raw): ?string
    {
        if ($raw === null) {
            return null;
        }
        if (is_int($raw)) {
            if ($raw < 0) {
                throw new InvalidArgumentException('salt must be an unsigned 64-bit integer');
            }
            return (string) $raw;
        }
        if (is_string($raw)) {
            if ($raw === '' || !ctype_digit($raw)) {
                throw new InvalidArgumentException('salt must be a decimal string');
            }
            return $raw;
        }
        throw new InvalidArgumentException('salt must be a decimal string or unsigned 64-bit integer');
    }

    private function cloneWith(
        ?string $transaction = null,
        ?string $initMultiDelegateTx = null,
        ?string $updateDelegationTx = null,
    ): self {
        return new self(
            mode: $this->mode,
            authorizedSigner: $this->authorizedSigner,
            signature: $this->signature,
            channelId: $this->channelId,
            deposit: $this->deposit,
            payer: $this->payer,
            payee: $this->payee,
            mint: $this->mint,
            salt: $this->salt,
            gracePeriod: $this->gracePeriod,
            transaction: $transaction ?? $this->transaction,
            tokenAccount: $this->tokenAccount,
            approvedAmount: $this->approvedAmount,
            owner: $this->owner,
            initMultiDelegateTx: $initMultiDelegateTx ?? $this->initMultiDelegateTx,
            updateDelegationTx: $updateDelegationTx ?? $this->updateDelegationTx,
        );
    }
}
