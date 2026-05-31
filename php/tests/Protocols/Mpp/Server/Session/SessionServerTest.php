<?php

declare(strict_types=1);

namespace PayKit\Tests;

use PHPUnit\Framework\TestCase;
use RuntimeException;
use PayKit\PayCore\Solana\Mints;
use PayKit\Protocols\Mpp\Core\PaymentChannels;
use PayKit\Protocols\Mpp\Intent\Session\ClosePayload;
use PayKit\Protocols\Mpp\Intent\Session\CommitPayload;
use PayKit\Protocols\Mpp\Intent\Session\CommitStatus;
use PayKit\Protocols\Mpp\Intent\Session\OpenPayload;
use PayKit\Protocols\Mpp\Intent\Session\SessionMode;
use PayKit\Protocols\Mpp\Intent\Session\SessionPullVoucherStrategy;
use PayKit\Protocols\Mpp\Intent\Session\SessionSplit;
use PayKit\Protocols\Mpp\Intent\Session\SignedVoucher;
use PayKit\Protocols\Mpp\Intent\Session\TopUpPayload;
use PayKit\Protocols\Mpp\Intent\Session\VoucherData;
use PayKit\Protocols\Mpp\Server\Session\DeliveryRequest;
use PayKit\Protocols\Mpp\Server\Session\MemoryChannelStore;
use PayKit\Protocols\Mpp\Server\Session\SessionConfig;
use PayKit\Protocols\Mpp\Server\Session\SessionServer;
use SolanaPhpSdk\Keypair\PublicKey;
use SolanaPhpSdk\Util\Base58;

final class SessionServerTest extends TestCase
{
    private const RECIPIENT = 'CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY';

    /** @var array{0:string,1:string} [base58 pubkey, raw 64-byte secret] */
    private array $signerKey;

    private string $signer;

    private string $channel;

    protected function setUp(): void
    {
        $kp = sodium_crypto_sign_keypair();
        $pub = sodium_crypto_sign_publickey($kp);
        $this->signerKey = [Base58::encode($pub), sodium_crypto_sign_secretkey($kp)];
        $this->signer = $this->signerKey[0];
        $this->channel = PublicKey::fromBytes(str_repeat(chr(7), 32))->toBase58();
    }

    private function makeServer(int $minDelta = 0): SessionServer
    {
        return new SessionServer(
            new SessionConfig(
                operator: self::RECIPIENT,
                recipient: self::RECIPIENT,
                network: 'localnet',
                minVoucherDelta: $minDelta,
            ),
            new MemoryChannelStore(),
        );
    }

    private function voucher(int $cumulative, ?int $expiresAt = null): SignedVoucher
    {
        $expiresAt ??= time() + 3600;
        $data = new VoucherData($this->channel, (string) $cumulative, $expiresAt);
        $sig = sodium_crypto_sign_detached($data->messageBytes(), $this->signerKey[1]);
        return new SignedVoucher($data, Base58::encode($sig));
    }

    private function openPush(SessionServer $server, int $deposit): void
    {
        $server->processOpen(OpenPayload::push($this->channel, (string) $deposit, $this->signer, 'tx'));
    }

    public function testBuildChallengeRequestClampsCap(): void
    {
        $server = $this->makeServer();
        self::assertSame('10000000', $server->buildChallengeRequest(50_000_000)->cap);
        self::assertSame('5000000', $server->buildChallengeRequest(5_000_000)->cap);
    }

    public function testBuildChallengeRequestIncludesConfigFields(): void
    {
        $req = $this->makeServer()->buildChallengeRequest(1_000_000);
        self::assertSame(self::RECIPIENT, $req->operator);
        self::assertSame(self::RECIPIENT, $req->recipient);
        self::assertSame('USDC', $req->currency);
        self::assertSame(6, $req->decimals);
        self::assertSame('localnet', $req->network);
        self::assertSame([], $req->splits);
    }

    public function testProcessOpenStoresState(): void
    {
        $server = $this->makeServer();
        $state = $server->processOpen(OpenPayload::push($this->channel, '1000000', $this->signer, 'tx'));
        self::assertSame(1_000_000, $state->deposit);
        self::assertSame(0, $state->cumulative);
        self::assertFalse($state->finalized);
        self::assertSame($this->signer, $state->authorizedSigner);
    }

    public function testProcessOpenRejectsZeroDeposit(): void
    {
        $this->expectException(RuntimeException::class);
        $this->makeServer()->processOpen(OpenPayload::push($this->channel, '0', $this->signer, 'tx'));
    }

    public function testProcessOpenRejectsDepositOverCap(): void
    {
        $this->expectException(RuntimeException::class);
        $this->makeServer()->processOpen(OpenPayload::push($this->channel, '20000000', $this->signer, 'tx'));
    }

    public function testProcessOpenAtExactlyCapAccepted(): void
    {
        $server = $this->makeServer();
        $state = $server->processOpen(OpenPayload::push($this->channel, '10000000', $this->signer, 'tx'));
        self::assertSame(10_000_000, $state->deposit);
    }

    public function testProcessOpenRejectsUnadvertisedPullMode(): void
    {
        $server = $this->makeServer();
        $payload = OpenPayload::paymentChannel(
            SessionMode::Pull,
            $this->channel,
            '1000000',
            'payer',
            self::RECIPIENT,
            'mint',
            '1',
            900,
            $this->signer,
            'pending',
        );
        $this->expectExceptionMessage('not supported');
        $server->processOpen($payload);
    }

    public function testVerifyVoucherAdvancesWatermarkMonotonically(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        self::assertSame(100, $server->verifyVoucher($this->voucher(100)));
        self::assertSame(250, $server->verifyVoucher($this->voucher(250)));
    }

    public function testVerifyVoucherRejectsNonIncreasingCumulative(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $server->verifyVoucher($this->voucher(250));
        $this->expectExceptionMessage('must exceed watermark');
        $server->verifyVoucher($this->voucher(100));
    }

    public function testVerifyVoucherIdempotentReplayReturnsSameWatermark(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $v = $this->voucher(250);
        self::assertSame(250, $server->verifyVoucher($v));
        self::assertSame(250, $server->verifyVoucher($v));
    }

    public function testVerifyVoucherRejectsOverDeposit(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 500);
        $this->expectExceptionMessage('exceeds deposit');
        $server->verifyVoucher($this->voucher(600));
    }

    public function testVerifyVoucherEnforcesMinDelta(): void
    {
        $server = $this->makeServer(minDelta: 100);
        $this->openPush($server, 1_000_000);
        $server->verifyVoucher($this->voucher(100));
        $this->expectExceptionMessage('below minimum');
        $server->verifyVoucher($this->voucher(150));
    }

    public function testVerifyVoucherRejectsExpired(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $this->expectExceptionMessage('expired');
        $server->verifyVoucher($this->voucher(100, time() - 1));
    }

    public function testVerifyVoucherRejectsBadSignature(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $bad = new SignedVoucher(
            new VoucherData($this->channel, '100', time() + 3600),
            Base58::encode(str_repeat(chr(0), 64)),
        );
        $this->expectExceptionMessage('signature verification failed');
        $server->verifyVoucher($bad);
    }

    public function testVerifyVoucherUnknownChannel(): void
    {
        $this->expectExceptionMessage('not found');
        $this->makeServer()->verifyVoucher($this->voucher(100));
    }

    public function testMeteredDeliveryCommitAndIdempotentReplay(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000);
        $directive = $server->beginDelivery(new DeliveryRequest($this->channel, 125));
        self::assertSame($this->channel, $directive->sessionId);
        self::assertSame('125', $directive->amount);
        self::assertSame(1, $directive->sequence);

        $voucher = $this->voucher(125);
        $payload = new CommitPayload($directive->deliveryId, $voucher);
        $receipt = $server->processCommit($payload);
        self::assertSame('125', $receipt->amount);
        self::assertSame('125', $receipt->cumulative);
        self::assertSame(CommitStatus::Committed, $receipt->status);

        $replay = $server->processCommit($payload);
        self::assertSame(CommitStatus::Replayed, $replay->status);
    }

    public function testBeginDeliveryRejectsOverDeposit(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000);
        $server->beginDelivery(new DeliveryRequest($this->channel, 100));
        $this->expectExceptionMessage('exceeds available deposit');
        $server->beginDelivery(new DeliveryRequest($this->channel, 901));
    }

    public function testProcessCommitAcceptsPartialStreamUsage(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000);
        $directive = $server->beginDelivery(new DeliveryRequest($this->channel, 125));
        $receipt = $server->processCommit(new CommitPayload($directive->deliveryId, $this->voucher(75)));
        self::assertSame('75', $receipt->amount);
        self::assertSame('75', $receipt->cumulative);
    }

    public function testProcessCommitRejectsOverReservedCumulative(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000);
        $directive = $server->beginDelivery(new DeliveryRequest($this->channel, 125));
        $this->expectExceptionMessage('exceeds reserved amount');
        $server->processCommit(new CommitPayload($directive->deliveryId, $this->voucher(200)));
    }

    public function testProcessTopupRaisesDeposit(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $state = $server->processTopup(new TopUpPayload($this->channel, '5000000', 'txsig'));
        self::assertSame(5_000_000, $state->deposit);
    }

    public function testProcessTopupRejectsNonIncreasingDeposit(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $this->expectExceptionMessage('must exceed current deposit');
        $server->processTopup(new TopUpPayload($this->channel, '500000', 'txsig'));
    }

    public function testProcessCloseAppliesFinalVoucherAndBlocksFurtherVouchers(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $server->verifyVoucher($this->voucher(100));
        $params = $server->processClose(new ClosePayload($this->channel, $this->voucher(500)));
        self::assertSame(500, $params->settled);
        self::assertSame(self::RECIPIENT, $params->recipient);
        self::assertSame(PaymentChannels::PROGRAM_ID, $params->programId);

        $this->expectExceptionMessage('close is pending');
        $server->verifyVoucher($this->voucher(600));
    }

    public function testFinalizeParamsCarriesDistributionHash(): void
    {
        $splitRecipient = PublicKey::fromBytes(str_repeat(chr(11), 32))->toBase58();
        $server = new SessionServer(
            new SessionConfig(
                operator: self::RECIPIENT,
                recipient: self::RECIPIENT,
                network: 'localnet',
                splits: [new SessionSplit($splitRecipient, 1000)],
            ),
            new MemoryChannelStore(),
        );
        $this->openPush($server, 1_000_000);
        $params = $server->finalizeParams($this->channel);
        self::assertSame(
            PaymentChannels::distributionHash([['recipient' => $splitRecipient, 'bps' => 1000]]),
            $params->distributionHash,
        );
        self::assertCount(1, $params->splits);
    }

    public function testMarkFinalizedBlocksVouchers(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $server->markFinalized($this->channel);
        $this->expectExceptionMessage('finalized');
        $server->verifyVoucher($this->voucher(100));
    }

    public function testPaymentChannelOpenParamsValidatesChallengeFields(): void
    {
        $payer = PublicKey::fromBytes(str_repeat(chr(21), 32))->toBase58();
        $mint = Mints::resolve('USDC', 'localnet');
        self::assertIsString($mint);
        [$channel] = PaymentChannels::findChannelPda($payer, self::RECIPIENT, $mint, $this->signer, '77');

        $server = new SessionServer(
            new SessionConfig(
                operator: self::RECIPIENT,
                recipient: self::RECIPIENT,
                network: 'localnet',
                modes: [SessionMode::Pull],
                pullVoucherStrategy: SessionPullVoucherStrategy::ClientVoucher,
            ),
            new MemoryChannelStore(),
        );
        $payload = OpenPayload::paymentChannel(
            SessionMode::Pull,
            $channel->toBase58(),
            '1000000',
            $payer,
            self::RECIPIENT,
            $mint,
            '77',
            900,
            $this->signer,
            'pending',
        );
        $params = $server->paymentChannelOpenParams($payload);
        self::assertSame($payer, $params['payer']);
        self::assertSame($mint, $params['mint']);
        self::assertSame($channel->toBase58(), $params['channel']);

        // Wrong payee is rejected.
        $wrongPayee = OpenPayload::paymentChannel(
            SessionMode::Pull,
            $channel->toBase58(),
            '1000000',
            $payer,
            PublicKey::fromBytes(str_repeat(chr(22), 32))->toBase58(),
            $mint,
            '77',
            900,
            $this->signer,
            'pending',
        );
        $this->expectExceptionMessage('payee does not match');
        $server->paymentChannelOpenParams($wrongPayee);
    }

    public function testPaymentChannelOpenParamsRejectsMismatchedChannelPda(): void
    {
        $payer = PublicKey::fromBytes(str_repeat(chr(21), 32))->toBase58();
        $mint = Mints::resolve('USDC', 'localnet');
        self::assertIsString($mint);
        $server = new SessionServer(
            new SessionConfig(
                operator: self::RECIPIENT,
                recipient: self::RECIPIENT,
                network: 'localnet',
                modes: [SessionMode::Pull],
                pullVoucherStrategy: SessionPullVoucherStrategy::ClientVoucher,
            ),
            new MemoryChannelStore(),
        );
        $payload = OpenPayload::paymentChannel(
            SessionMode::Pull,
            PublicKey::fromBytes(str_repeat(chr(0xAB), 32))->toBase58(),
            '1000000',
            $payer,
            self::RECIPIENT,
            $mint,
            '77',
            900,
            $this->signer,
            'pending',
        );
        $this->expectExceptionMessage('channelId does not match');
        $server->paymentChannelOpenParams($payload);
    }
}
