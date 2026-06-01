<?php

declare(strict_types=1);

/**
 * PHP cross-SDK conformance-vector runner.
 *
 * Honors the same stdin/stdout contract as the TypeScript reference runner
 * (harness/src/conformance/ts-runner.ts) and the Go runner
 * (go/cmd/conformance/main.go): read one conformance vector as JSON on
 * stdin, drive the real PayKit PHP SDK for the requested mode, and emit one
 * RunnerResult line as JSON on stdout.
 *
 * ROLE: PHP is a SERVER-only SDK. It ships the MPP charge pre-broadcast
 * verifier (SolanaChargeTransactionVerifier) and the canonical-JSON /
 * base64url wire encoders, but it has NO client-side transaction build path.
 * Consequently:
 *
 *   - canonical-bytes        -> supported (JCS + base64url + fixed-width bytes)
 *   - verify-transaction     -> supported ONLY when input.transaction is
 *                               present (a server verifies a wire tx it is
 *                               given). A verify vector that omits the
 *                               transaction expects the runner to BUILD one
 *                               first, which a server-only SDK cannot do.
 *   - build-transaction      -> unsupported (no client build path)
 *
 * For any mode this SDK cannot exercise, the runner emits a RunnerResult with
 * outcome "unsupported-mode" so the driver SKIPs that vector for PHP rather
 * than failing it.
 *
 * The run is deterministic and RPC-free: verify operates purely on the wire
 * transaction the vector pins, with no live validator, no RPC, and no HMAC
 * challenge round-trip.
 */

error_reporting(error_reporting() & ~E_DEPRECATED & ~E_USER_DEPRECATED);
ini_set('display_errors', 'stderr');

require __DIR__ . '/../vendor/autoload.php';

use PayKit\PayCore\Solana\Mints;
use PayKit\Protocols\Mpp\Core\Base64Url;
use PayKit\Protocols\Mpp\Core\Challenge;
use PayKit\Protocols\Mpp\Core\ChallengeEcho;
use PayKit\Protocols\Mpp\Core\Credential;
use PayKit\Protocols\Mpp\Core\Json;
use PayKit\Protocols\Mpp\Intent\ChargeRequest;
use PayKit\Protocols\Mpp\Server\SolanaChargeTransactionVerifier;
use SolanaPhpSdk\Keypair\PublicKey;
use SolanaPhpSdk\Programs\MemoProgram;
use SolanaPhpSdk\Programs\SystemProgram;
use SolanaPhpSdk\Programs\TokenProgram;
use SolanaPhpSdk\Transaction\Transaction;
use SolanaPhpSdk\Transaction\VersionedTransaction;

const COMPUTE_BUDGET_PROGRAM = 'ComputeBudget111111111111111111111111111111';
const DEFAULT_NETWORK = 'mainnet';

/**
 * Read the entire vector JSON from stdin.
 */
function read_stdin(): string
{
    $raw = stream_get_contents(STDIN);
    if (!is_string($raw)) {
        throw new RuntimeException('php conformance runner failed to read stdin');
    }
    $trimmed = trim($raw);
    if ($trimmed === '') {
        throw new RuntimeException('php conformance runner received empty stdin');
    }
    return $trimmed;
}

/**
 * @param array<string, mixed> $result
 */
function emit(array $result): void
{
    fwrite(STDOUT, json_encode($result, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES) . "\n");
}

/**
 * Apply the precedence rules the vectors probe: top-level asset / payTo win
 * over currency / recipient. Returns a ChargeRequest the PHP verifier
 * consumes. tokenProgram / decimals resolution is left to the verifier
 * itself (Mints::tokenProgramFor by currency, decimals read from
 * methodDetails) so the runner injects no defaults the SDK would not.
 *
 * @param array<string, mixed> $request
 */
function flatten_request(array $request): ChargeRequest
{
    $currency = Json::optionalString($request['asset'] ?? null, 'asset')
        ?: Json::optionalString($request['currency'] ?? null, 'currency');
    $recipient = Json::optionalString($request['payTo'] ?? null, 'payTo')
        ?: Json::optionalString($request['recipient'] ?? null, 'recipient');
    if ($recipient === '') {
        throw new InvalidArgumentException('vector request is missing recipient/payTo');
    }

    $md = $request['methodDetails'] ?? null;
    $methodDetails = is_array($md) ? Json::object($md, 'methodDetails') : [];
    if (!isset($methodDetails['network']) || !is_string($methodDetails['network']) || $methodDetails['network'] === '') {
        $methodDetails['network'] = DEFAULT_NETWORK;
    }

    return new ChargeRequest(
        amount: Json::optionalString($request['amount'] ?? null, 'amount'),
        currency: $currency,
        recipient: $recipient,
        externalId: Json::optionalString($request['externalId'] ?? null, 'externalId'),
        methodDetails: $methodDetails,
    );
}

/**
 * Drive the PHP server's RPC-free pre-broadcast verify on a wire transaction.
 *
 * The pre-broadcast path lives behind SolanaChargeTransactionVerifier::verify
 * (Credential + Challenge), which runs runVerification(..., onChain: false) and
 * therefore enforces the compute-budget caps a pre-broadcast verifier must.
 * We synthesize a self-issued Challenge embedding the flattened request and a
 * pull-mode Credential carrying the transaction, with no HMAC round-trip: the
 * verifier never checks the challenge signature, only the transaction shape.
 */
function verify_transaction(ChargeRequest $request, string $transactionBase64): void
{
    $challenge = Challenge::withSecret(
        secretKey: 'conformance-runner',
        realm: 'conformance',
        method: 'solana',
        intent: 'charge',
        request: $request->toArray(),
    );
    $credential = new Credential(
        challenge: $challenge->toEcho(),
        payload: ['transaction' => $transactionBase64],
    );

    $verifier = new SolanaChargeTransactionVerifier();
    $result = $verifier->verify($credential, $challenge);
    if (!$result->ok) {
        throw new InvalidArgumentException($result->reason !== '' ? $result->reason : 'verification failed');
    }
}

/**
 * Decode a base64 wire transaction into the semantic shape the conformance
 * driver asserts against. Mirrors the TS reference decoder
 * (harness/src/conformance/decode.ts) and the Go shapeFromTransaction: fee
 * payer is account[0], SPL transfers come from transferChecked (discriminator
 * 12), SOL transfers from the System Program transfer (discriminator 2), memos
 * from the Memo Program, and compute caps from the ComputeBudget program.
 *
 * @return array<string, mixed>
 */
function shape_from_transaction(string $transactionBase64): array
{
    $wire = base64_decode($transactionBase64, true);
    if ($wire === false || $wire === '') {
        throw new InvalidArgumentException('invalid transaction payload');
    }

    $version = VersionedTransaction::peekVersion($wire);
    if ($version === 'legacy') {
        $tx = Transaction::deserialize($wire);
        // Legacy Message->instructions are already
        // {programIdIndex, accounts, data} arrays (see Message::deserialize).
        $accountKeys = $tx->message->accountKeys;
        $instructions = $tx->message->instructions;
    } elseif ($version === 0) {
        $tx = VersionedTransaction::deserialize($wire);
        if ($tx->message->addressTableLookups !== []) {
            throw new InvalidArgumentException('v0 address lookup tables are not supported');
        }
        $accountKeys = $tx->message->staticAccountKeys;
        $instructions = array_map(
            static fn (object $ix): array => [
                'programIdIndex' => $ix->programIdIndex,
                'accounts' => $ix->accountKeyIndexes,
                'data' => $ix->data,
            ],
            $tx->message->compiledInstructions,
        );
    } else {
        throw new InvalidArgumentException('unsupported transaction version');
    }

    if ($accountKeys === []) {
        throw new InvalidArgumentException('transaction has no account keys');
    }

    $accountAt = static function (int $index) use ($accountKeys): string {
        if (!isset($accountKeys[$index])) {
            throw new InvalidArgumentException('account index out of range');
        }
        return $accountKeys[$index]->toBase58();
    };

    $shape = [
        'feePayer' => $accountKeys[0]->toBase58(),
        'forbiddenPrograms' => [],
        'memo' => [],
        'transfers' => [],
    ];

    foreach ($instructions as $ix) {
        $program = $accountAt((int) $ix['programIdIndex']);
        $data = (string) $ix['data'];
        $accounts = $ix['accounts'];

        if ($program === COMPUTE_BUDGET_PROGRAM) {
            if (strlen($data) === 5 && ord($data[0]) === 2) {
                $shape['maxComputeUnitLimit'] = read_u32_le(substr($data, 1, 4));
            } elseif (strlen($data) === 9 && ord($data[0]) === 3) {
                $shape['maxComputeUnitPrice'] = (string) read_u64_le(substr($data, 1, 8));
            }
            continue;
        }

        if ($program === MemoProgram::PROGRAM_ID_V2) {
            $shape['memo'][] = $data;
            continue;
        }

        if ($program === SystemProgram::PROGRAM_ID) {
            if (strlen($data) >= 12 && read_u32_le(substr($data, 0, 4)) === 2 && isset($accounts[1])) {
                $shape['transfers'][] = [
                    'amount' => (string) read_u64_le(substr($data, 4, 8)),
                    'destination' => $accountAt((int) $accounts[1]),
                    'kind' => 'sol',
                ];
            }
            continue;
        }

        if ($program === TokenProgram::PROGRAM_ID || $program === TokenProgram::TOKEN_2022_PROGRAM_ID) {
            if (strlen($data) >= 10 && ord($data[0]) === 12 && count($accounts) >= 4) {
                $shape['transfers'][] = [
                    'amount' => (string) read_u64_le(substr($data, 1, 8)),
                    'decimals' => ord($data[9]),
                    'destination' => $accountAt((int) $accounts[2]),
                    'kind' => 'spl',
                    'mint' => $accountAt((int) $accounts[1]),
                    'tokenProgram' => $program,
                ];
            }
            continue;
        }
    }

    return $shape;
}

/**
 * Normalize a PHP SDK reject message onto the shared cross-SDK RejectCode
 * vocabulary. Mirrors harness/src/conformance/reject.ts and the Go runner's
 * classifyReject: the patterns are tuned against the real strings the PHP
 * verifier emits.
 *
 * PHP is a server-only SDK, so in practice the only reject vector it actually
 * processes is the transferChecked decimals mismatch, which surfaces as
 * "No matching SPL transferChecked of ..." and so honestly classifies as the
 * generic no-matching-transfer category (the decimals field is enforced
 * through the transfer match key, exactly as in the reference). The remaining
 * patterns are kept in lockstep with the shared vocabulary so any future
 * server-verifiable reject reason classifies without further tuning.
 *
 * Returns null when no pattern matches so the harness can surface an
 * unclassified rejection instead of silently passing it.
 */
function classify_reject(string $message): ?string
{
    if ($message === '') {
        return null;
    }

    $patterns = [
        '/compute unit price .* exceeds (maximum|cap)/i' => 'compute-price-over-cap',
        '/compute unit limit .* exceeds (maximum|cap)/i' => 'compute-limit-over-cap',
        '/fee payer cannot authorize/i' => 'fee-payer-not-authority',
        '/fee payer .* (funding source|funds source)/i' => 'fee-payer-is-funds-source',
        '/splits consume the entire amount/i' => 'splits-exceed-amount',
        '/too many splits/i' => 'too-many-splits',
        '/no matching (spl )?(token )?(transfer|transferchecked|sol transfer)/i' => 'no-matching-transfer',
        '/unexpected .* (instruction|transfer)/i' => 'unexpected-instruction',
        '/amount .* (mismatch|does not match)/i' => 'amount-mismatch',
    ];

    foreach ($patterns as $pattern => $code) {
        if (preg_match($pattern, $message) === 1) {
            return $code;
        }
    }

    if (preg_match('/invalid|malformed|decode|payload/i', $message) === 1) {
        return 'invalid-payload';
    }

    return null;
}

function read_u32_le(string $bytes): int
{
    $unpacked = unpack('Vvalue', $bytes);
    if ($unpacked === false || !is_int($unpacked['value'])) {
        throw new InvalidArgumentException('expected 4 bytes');
    }
    return $unpacked['value'];
}

function read_u64_le(string $bytes): int
{
    if (strlen($bytes) !== 8) {
        throw new InvalidArgumentException('expected 8 bytes');
    }
    $value = 0;
    for ($i = 7; $i >= 0; $i -= 1) {
        $value = ($value << 8) + ord($bytes[$i]);
    }
    return $value;
}

/**
 * @param array<string, mixed> $input
 * @return array<string, mixed>
 */
function run_canonical_bytes(array $input): array
{
    $exactBytes = [];

    if (array_key_exists('value', $input)) {
        $canonicalJson = Json::canonicalize($input['value']);
        $exactBytes['canonicalJson'] = $canonicalJson;
        $exactBytes['base64Url'] = Base64Url::encode($canonicalJson);
    }

    $enc = $input['encodeBase64Url'] ?? null;
    if (is_array($enc)) {
        $hex = $enc['hexBytes'] ?? null;
        $utf8 = $enc['utf8'] ?? null;
        if (is_string($hex) && $hex !== '') {
            $bytes = hex2bin($hex);
            if ($bytes === false) {
                throw new InvalidArgumentException('invalid hexBytes');
            }
            $ints = [];
            for ($i = 0, $n = strlen($bytes); $i < $n; $i += 1) {
                $ints[] = ord($bytes[$i]);
            }
            $exactBytes['bytes'] = $ints;
            $exactBytes['base64Url'] = Base64Url::encode($bytes);
        } elseif (is_string($utf8)) {
            $exactBytes['base64Url'] = Base64Url::encode($utf8);
        }
    }

    return $exactBytes;
}

/**
 * @param array<string, mixed> $vector
 * @return array<string, mixed>
 */
function run_vector(array $vector): array
{
    $id = Json::optionalString($vector['id'] ?? null, 'id');
    $mode = Json::optionalString($vector['mode'] ?? null, 'mode');
    $input = is_array($vector['input'] ?? null) ? Json::object($vector['input'], 'input') : [];

    switch ($mode) {
        case 'canonical-bytes':
            return [
                'id' => $id,
                'outcome' => 'accept',
                'exactBytes' => run_canonical_bytes($input),
            ];

        case 'verify-transaction':
            $transaction = $input['transaction'] ?? null;
            if (!is_string($transaction) || $transaction === '') {
                // No wire transaction pinned: the vector expects the runner
                // to BUILD a transaction first, then verify it. PHP is a
                // server-only SDK with no client build path, so this vector
                // is out of scope for PHP.
                return [
                    'id' => $id,
                    'outcome' => 'unsupported-mode',
                    'error' => 'php is server-only: verify-transaction without a pinned input.transaction requires a client build path php does not ship',
                ];
            }
            $request = flatten_request(is_array($input['request'] ?? null) ? Json::object($input['request'], 'request') : []);
            verify_transaction($request, $transaction);
            return [
                'id' => $id,
                'outcome' => 'accept',
                'transactionShape' => shape_from_transaction($transaction),
            ];

        case 'build-transaction':
            // PHP ships no client-side transaction build path; build vectors
            // are out of scope for a server-only SDK.
            return [
                'id' => $id,
                'outcome' => 'unsupported-mode',
                'error' => 'php is server-only: build-transaction is not supported (no client build path)',
            ];

        default:
            return [
                'id' => $id,
                'outcome' => 'unsupported-mode',
                'error' => 'unsupported mode: ' . $mode,
            ];
    }
}

try {
    $vector = json_decode(read_stdin(), true, flags: JSON_THROW_ON_ERROR);
    if (!is_array($vector)) {
        throw new InvalidArgumentException('vector must be a JSON object');
    }
    $vector = Json::object($vector, 'vector');
    $id = Json::optionalString($vector['id'] ?? null, 'id');
    try {
        emit(run_vector($vector));
    } catch (Throwable $error) {
        $message = $error->getMessage();
        $result = [
            'id' => $id,
            'outcome' => 'reject',
            'error' => $message,
        ];
        $rejectCode = classify_reject($message);
        if ($rejectCode !== null) {
            $result['rejectCode'] = $rejectCode;
        }
        emit($result);
    }
} catch (Throwable $fatal) {
    fwrite(STDERR, 'php conformance runner fatal: ' . $fatal->getMessage() . "\n");
    exit(1);
}
