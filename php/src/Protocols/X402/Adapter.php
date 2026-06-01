<?php

declare(strict_types=1);

namespace PayKit\Protocols\X402;

use PayKit\Config;
use PayKit\Exception\InvalidProofException;
use PayKit\Gate;
use PayKit\Payment;
use PayKit\Protocol;
use PayKit\Protocols\Mpp\Server\RpcGateway;
use PayKit\Protocols\Mpp\Server\SolanaRpcGateway;
use PayKit\Protocols\X402\Exact\Verifier;
use PayKit\Store\MemoryStore;
use PayKit\Store\Store;
use Psr\Http\Message\ServerRequestInterface;
use RuntimeException;
use SolanaPhpSdk\Keypair\Keypair;
use SolanaPhpSdk\Rpc\RpcClient;
use SolanaPhpSdk\Transaction\VersionedTransaction;
use Throwable;

/**
 * x402 (exact scheme, Solana) adapter. Issues challenges, runs the
 * 11-rule structural verifier on submitted credentials, cosigns as
 * the facilitator, and broadcasts via the configured RPC.
 *
 * Delegated mode (`X402Config::$facilitatorUrl` set) is reserved in
 * the config schema but not yet wired; the adapter raises
 * "delegated mode not implemented" when a facilitator URL is set.
 * Self-hosted is the only x402 path that ships in v1.
 */
final class Adapter
{
    private const PAYMENT_SIGNATURE_HEADER = 'payment-signature';
    // Mirrors rust constants.rs:10/:13. v2 is the default everywhere; v1
    // is accepted inbound for backward compatibility (legacy facilitators).
    private const X402_VERSION_V1          = 1;
    private const X402_VERSION_V2          = 2;
    private const X402_VERSION             = self::X402_VERSION_V2;
    // Legacy v1 client payment header (rust constants.rs:16). The default
    // v2 client payment header is PAYMENT-SIGNATURE (rust constants.rs:25).
    private const X402_V1_PAYMENT_HEADER   = 'X-PAYMENT';
    private const EXACT_SCHEME             = 'exact';
    private const TOKEN_PROGRAM            = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
    private const REPLAY_KEY_PREFIX        = 'x402-svm-exact:consumed:';

    /** @var \Closure():?string|null */
    private $recentBlockhashProvider = null;

    private ?RpcGateway $rpc = null;

    private readonly Store $replayStore;

    /**
     * @param ?Store $replayStore Replay-protection store. When null (the
     *        default) an in-process {@see MemoryStore} is used and a loud
     *        dev-only warning is emitted: a single-process memory store
     *        loses replay protection across workers/restarts, so production
     *        deployments MUST inject a shared atomic store (Redis, Postgres).
     * @param ?RpcGateway $rpc Confirmation/broadcast gateway. Defaults to a
     *        {@see SolanaRpcGateway} over the configured `rpcUrl`, created
     *        lazily on first settlement. Inject a fake for unit tests.
     * @param int $confirmationAttempts How many times to poll
     *        `getSignatureStatuses` before giving up. 40 attempts at the
     *        default delay = 10 seconds. Mirrors the MPP charge handler.
     * @param int $confirmationDelayMicros Sleep between polls in microseconds.
     */
    public function __construct(
        private readonly Config $config,
        ?Store $replayStore = null,
        ?\Closure $recentBlockhashProvider = null,
        ?RpcGateway $rpc = null,
        private readonly int $confirmationAttempts = 40,
        private readonly int $confirmationDelayMicros = 250_000,
    ) {
        if ($config->x402->isDelegated()) {
            throw new InvalidProofException(
                'pay_kit: x402 delegated mode is not yet implemented; '
                . 'leave X402Config::$facilitatorUrl null for self-hosted',
            );
        }
        if ($replayStore === null) {
            self::warnDefaultReplayStore();
            $replayStore = new MemoryStore();
        }
        $this->replayStore = $replayStore;
        $this->recentBlockhashProvider = $recentBlockhashProvider;
        $this->rpc = $rpc;
    }

    private static function warnDefaultReplayStore(): void
    {
        if (function_exists('error_log')) {
            error_log(
                'pay_kit: WARN: x402 adapter using in-memory replay store; '
                . 'dev-only. Inject a shared atomic Store (Redis/Postgres) in production.',
            );
        }
    }

    private function rpc(): RpcGateway
    {
        return $this->rpc ??= new SolanaRpcGateway(new RpcClient($this->config->rpcUrl));
    }

    /**
     * Build a single entry for the 402 accepts[] array.
     *
     * @return array<string,mixed>
     */
    public function acceptsEntry(Gate $gate, ServerRequestInterface $request): array
    {
        $coin = $gate->amount->primaryCoin()?->value ?? $this->config->stablecoins[0]->value;
        // x402 spec puts the on-chain mint pubkey on `asset`, not the
        // ticker. Resolve the ticker to a mint via the legacy Mints
        // registry; Mints::resolve already falls back to the mainnet
        // row when the network row is absent (Ruby PR #142 caveat #1).
        $asset = \PayKit\PayCore\Solana\Mints::resolve($coin, $this->config->network->mintsLabel()) ?? $coin;
        $tokenProgram = \PayKit\PayCore\Solana\Mints::tokenProgramFor($coin, $this->config->network->mintsLabel());
        $payTo = $gate->payTo ?? $this->config->effectiveRecipient();
        $amount = (string) $gate->total()->amount->multipliedBy(1_000_000)->toInt();
        $signer = $this->config->effectiveX402Signer();
        $extra = [
            'feePayer'     => $signer?->pubkey() ?? '',
            'decimals'     => 6,
            'tokenProgram' => $tokenProgram,
            'memo'         => $request->getUri()->getPath(),
        ];
        // Ruby PR #142 caveat #5: stamp the server's recent_blockhash
        // into accepted.extra so pay-kit clients sign against the
        // same chain state the server will broadcast to. Closes the
        // surfpool / forked-mainnet drift the Sinatra example hit.
        // Scope: pay-kit Rust client honours this field; canonical
        // TS / Go x402 clients ignore it and call getLatestBlockhash
        // against their own RPC. Harmless on real networks.
        $blockhash = $this->fetchRecentBlockhash();
        if ($blockhash !== null) {
            $extra['recentBlockhash'] = $blockhash;
        }
        return [
            'protocol'          => 'x402',
            'scheme'            => 'exact',
            'network'           => $this->caip2(),
            'asset'             => $asset,
            'amount'            => $amount,
            'maxAmountRequired' => $amount,
            'payTo'             => $payTo,
            'maxTimeoutSeconds' => 60,
            'extra'             => $extra,
        ];
    }

    private function fetchRecentBlockhash(): ?string
    {
        if ($this->recentBlockhashProvider !== null) {
            try {
                $value = ($this->recentBlockhashProvider)();
                return is_string($value) && $value !== '' ? $value : null;
            } catch (Throwable) {
                return null;
            }
        }
        if ($this->config->rpcUrl === '') {
            return null;
        }
        try {
            $rpc = new \SolanaPhpSdk\Rpc\RpcClient($this->config->rpcUrl);
            $result = $rpc->getLatestBlockhash();
            $value = is_array($result) && isset($result['blockhash']) ? (string) $result['blockhash'] : null;
            return $value !== '' ? $value : null;
        } catch (Throwable) {
            return null;
        }
    }

    /**
     * @return array<string,string>
     */
    public function challengeHeaders(Gate $gate, ServerRequestInterface $request): array
    {
        $challenge = [
            'x402Version' => self::X402_VERSION,
            'resource'    => ['type' => 'http', 'url' => $request->getUri()->getPath()],
            'accepts'     => [$this->acceptsEntry($gate, $request)],
        ];
        return [
            'payment-required' => base64_encode(json_encode($challenge, JSON_THROW_ON_ERROR)),
        ];
    }

    public function verifyAndSettle(Gate $gate, ServerRequestInterface $request): Payment
    {
        $signer = $this->config->effectiveX402Signer();
        if ($signer === null) {
            throw new InvalidProofException('pay_kit: x402 requires operator.signer');
        }
        // Read the v2 default payment header (PAYMENT-SIGNATURE), then fall
        // back to the legacy v1 header (X-PAYMENT). Header matching is
        // case-insensitive; getHeaderLine already lower-cases internally,
        // so the literal casing passed here is for readability only
        // (rust payment.rs:229/:238 use eq_ignore_ascii_case).
        $header = $request->getHeaderLine('Payment-Signature');
        if ($header === '') {
            $header = $request->getHeaderLine(self::X402_V1_PAYMENT_HEADER);
        }
        if ($header === '') {
            throw new InvalidProofException('pay_kit: payment required');
        }

        // Decode credential.
        $decoded = base64_decode($header, true);
        if ($decoded === false) {
            throw new InvalidProofException('invalid_exact_svm_payload_signature_base64');
        }
        try {
            $envelope = json_decode($decoded, true, flags: JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            throw new InvalidProofException('invalid_exact_svm_payload_signature_json');
        }
        if (!is_array($envelope)) {
            throw new InvalidProofException('invalid_exact_svm_payload_envelope');
        }
        $version = $envelope['x402Version'] ?? null;

        // The route's expected requirements always come from the server
        // offer, never from the credential. x402 has no HMAC-bound
        // challenge id, so a credential's self-described `accepted` is
        // attacker-controlled and is only ever compared against, never
        // trusted (rust exact.rs:453-462).
        $offer = $this->acceptsEntry($gate, $request);

        if ($version === self::X402_VERSION_V1) {
            // Legacy v1 envelope: top-level scheme + network, no `accepted`,
            // no `resource`. Validate scheme + CAIP-2-normalized network at
            // parse time, then settle against the server offer alone
            // (rust exact.rs:316-327). The v1 arm intentionally skips the
            // credential-binding identity-key match: there is no `accepted`
            // object to compare, and the offer is the sole source of truth.
            $scheme = is_string($envelope['scheme'] ?? null) ? $envelope['scheme'] : '';
            if ($scheme !== self::EXACT_SCHEME) {
                throw new InvalidProofException('invalid_exact_svm_payload_type');
            }
            $network = is_string($envelope['network'] ?? null) ? $envelope['network'] : '';
            $expectedNetwork = $this->caip2();
            if (self::caip2NetworkForCluster($network) !== $expectedNetwork) {
                throw new InvalidProofException(
                    'pay_kit: charge_request_mismatch: '
                    . "Network mismatch: expected $expectedNetwork, got $network",
                );
            }
            $accepted = null;
        } elseif ($version === self::X402_VERSION_V2) {
            // v2 envelope: `accepted` is required and is structurally
            // matched against the server offer (rust exact.rs:328-340 at
            // parse, exact.rs:412-437 at option-match).
            $accepted = $envelope['accepted'] ?? null;
            if (!is_array($accepted)) {
                throw new InvalidProofException('invalid_exact_svm_payload_envelope');
            }
            // Identity-key match (cross-SDK PR #138 alignment).
            foreach (['scheme', 'network', 'asset', 'payTo'] as $key) {
                if (($accepted[$key] ?? null) !== ($offer[$key] ?? null)) {
                    throw new InvalidProofException(
                        'pay_kit: charge_request_mismatch: '
                        . 'accepted payment requirement does not match server challenge',
                    );
                }
            }
            $offerExtra    = $offer['extra']    ?? [];
            $acceptedExtra = $accepted['extra'] ?? [];
            foreach (['feePayer', 'tokenProgram', 'memo'] as $key) {
                if (array_key_exists($key, $offerExtra)
                    && ($acceptedExtra[$key] ?? null) !== $offerExtra[$key]) {
                    throw new InvalidProofException(
                        'pay_kit: charge_request_mismatch (extra.' . $key . ')',
                    );
                }
            }
        } else {
            // Genuinely-unknown versions are still rejected
            // (rust exact.rs:342-346).
            throw new InvalidProofException('unsupported_x402_version');
        }

        $payload = $envelope['payload'] ?? null;
        if (!is_array($payload)) {
            throw new InvalidProofException('invalid_exact_svm_payload_envelope');
        }

        $txBase64 = is_string($payload['transaction'] ?? null) ? $payload['transaction'] : '';
        if ($txBase64 === '') {
            throw new InvalidProofException('invalid_exact_svm_payload_missing_transaction');
        }

        // Verify structural shape (11 rules).
        Verifier::verify($txBase64, $offer, [$signer->pubkey()]);

        // Cosign as facilitator.
        $rawTx = base64_decode($txBase64, true);
        if ($rawTx === false) {
            throw new InvalidProofException('invalid_exact_svm_payload_base64');
        }
        try {
            $tx = VersionedTransaction::deserialize($rawTx);
        } catch (Throwable) {
            throw new InvalidProofException('invalid_exact_svm_payload_transaction_parse');
        }
        $kp = Keypair::fromSecretKey($signer->secretKey());
        $tx->partialSign($kp);
        $cosignedWire = $tx->serialize(verifySignatures: false);

        // Broadcast via the raw-wire path so PHP doesn't have to
        // reconstruct a SignedTransaction wrapper just to send.
        $rpc = $this->rpc();
        try {
            $sig = $rpc->sendRawTransaction($cosignedWire, [
                'encoding' => 'base64',
                'skipPreflight' => false,
                'preflightCommitment' => 'confirmed',
            ]);
        } catch (Throwable $e) {
            throw new InvalidProofException(
                'pay_kit: invalid proof: broadcast failed: ' . $e->getMessage(),
            );
        }
        if (!is_string($sig) || $sig === '') {
            throw new InvalidProofException('pay_kit: empty broadcast result');
        }

        // Reserve in the replay store BETWEEN broadcast and confirmation.
        // RPC has accepted the transaction, so it may land even if the
        // await below times out or the process crashes. Reserving first
        // means a retry of the same credential trips the consumed guard
        // rather than re-settling. Mirrors the MPP SolanaChargeHandler
        // (settle() reserves between sendRawTransaction and
        // awaitConfirmation; PR #85 Greptile P1 / audit gap G05).
        if (!$this->replayStore->putIfAbsent(self::REPLAY_KEY_PREFIX . $sig, true)) {
            throw new InvalidProofException('pay_kit: signature_consumed');
        }

        // Confirm BEFORE returning the payment-response success. RPC
        // acceptance is not settlement: the transaction can still fail or
        // never finalize. Poll getSignatureStatuses until confirmed or
        // finalized, throwing on on-chain failure or timeout so callers
        // never receive a success header for an unsettled transaction.
        // Closes main-audit finding 3 (PHP x402 confirm-before-success).
        try {
            $this->awaitConfirmation($sig);
        } catch (Throwable $e) {
            throw new InvalidProofException(
                'pay_kit: invalid proof: settlement not confirmed: ' . $e->getMessage(),
            );
        }

        $responseEnvelope = base64_encode(json_encode([
            'success'     => true,
            'transaction' => $sig,
            'network'     => (is_array($accepted) ? ($accepted['network'] ?? null) : null) ?? $this->caip2(),
            'payer'       => $payload['transactionHash'] ?? '',
        ], JSON_THROW_ON_ERROR));

        return new Payment(
            protocol: Protocol::X402,
            transaction: $sig,
            gateName: null,
            settlementHeaders: [
                'payment-response'                => $responseEnvelope,
                'x-payment-settlement-signature'  => $sig,
            ],
            raw: $header,
        );
    }

    /**
     * Poll `getSignatureStatuses` until the broadcast transaction is
     * confirmed or finalized. Throws on on-chain failure (`err`) or when
     * the confirmation budget is exhausted. Mirrors
     * {@see \PayKit\Protocols\Mpp\Server\SolanaChargeHandler::awaitConfirmation()}.
     */
    private function awaitConfirmation(string $signature): void
    {
        $rpc = $this->rpc();
        for ($attempt = 0; $attempt < $this->confirmationAttempts; $attempt += 1) {
            $statuses = $rpc->getSignatureStatuses([$signature]);
            $status = $statuses[0] ?? null;
            if (is_array($status)) {
                if (($status['err'] ?? null) !== null) {
                    throw new RuntimeException(
                        "Transaction $signature failed: " . json_encode($status['err'], JSON_THROW_ON_ERROR),
                    );
                }
                $confirmationStatus = $status['confirmationStatus'] ?? null;
                if ($confirmationStatus === 'confirmed' || $confirmationStatus === 'finalized') {
                    return;
                }
            }
            usleep($this->confirmationDelayMicros);
        }
        throw new RuntimeException("Timed out waiting for transaction $signature");
    }

    private function caip2(): string
    {
        return $this->config->network->caip2();
    }

    /**
     * Normalize a legacy v1 network string (or any cluster slug / CAIP-2
     * id) to its canonical CAIP-2 chain identifier. Mirrors the rust spine
     * `caip2_network_for_cluster` (types.rs:31-38) so a v1 envelope's
     * legacy `network` (`"solana"` / `"solana-devnet"`) normalizes back to
     * the same CAIP-2 value the server advertises before the mismatch
     * check (rust exact.rs:322).
     *
     * Note: localnet collapses to the devnet CAIP-2 id here, matching
     * {@see \PayKit\PayCore\Network::caip2()} (Surfpool clones mainnet
     * state but advertises the devnet genesis hash by convention).
     */
    private static function caip2NetworkForCluster(string $cluster): string
    {
        $mainnet = 'solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp';
        $devnet  = 'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1';
        $testnet = 'solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z';
        return match ($cluster) {
            $mainnet, 'solana', 'mainnet', 'mainnet-beta' => $mainnet,
            $testnet, 'testnet', 'solana-testnet'         => $testnet,
            'devnet', 'localnet'                          => $devnet,
            $devnet, 'solana-devnet'                      => $devnet,
            default                                       => $mainnet,
        };
    }
}
