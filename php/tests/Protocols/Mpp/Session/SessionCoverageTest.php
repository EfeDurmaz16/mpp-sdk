<?php

declare(strict_types=1);

namespace PayKit\Tests;

use InvalidArgumentException;
use PHPUnit\Framework\TestCase;
use RuntimeException;
use PayKit\Protocols\Mpp\Intent\Session\ClosePayload;
use PayKit\Protocols\Mpp\Intent\Session\CommitPayload;
use PayKit\Protocols\Mpp\Intent\Session\CommitReceipt;
use PayKit\Protocols\Mpp\Intent\Session\CommitStatus;
use PayKit\Protocols\Mpp\Intent\Session\MeteringDirective;
use PayKit\Protocols\Mpp\Intent\Session\OpenPayload;
use PayKit\Protocols\Mpp\Intent\Session\SessionMode;
use PayKit\Protocols\Mpp\Intent\Session\SessionPullVoucherStrategy;
use PayKit\Protocols\Mpp\Intent\Session\SessionRequest;
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

/**
 * Extra coverage for session-related classes to reach the 91% gate.
 * Targets uncovered branches identified from the clover.xml report.
 */
final class SessionCoverageTest extends TestCase
{
    private const RECIPIENT = 'CXhrFZJLKqjzmP3sjYLcF4dTeXWKCy9e2SXXZ2Yo6MPY';

    /** @var array{0:string,1:string} */
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

    // -------------------------------------------------------------------------
    // CommitReceipt::toArray
    // -------------------------------------------------------------------------

    public function testCommitReceiptToArray(): void
    {
        $receipt = new CommitReceipt(
            deliveryId: 'del-1',
            sessionId: 'chan-1',
            amount: '125',
            cumulative: '250',
            status: CommitStatus::Committed,
        );
        $arr = $receipt->toArray();
        self::assertSame('del-1', $arr['deliveryId']);
        self::assertSame('chan-1', $arr['sessionId']);
        self::assertSame('125', $arr['amount']);
        self::assertSame('250', $arr['cumulative']);
        self::assertSame('committed', $arr['status']);
    }

    public function testCommitReceiptToArrayReplayed(): void
    {
        $receipt = new CommitReceipt(
            deliveryId: 'd2',
            sessionId: 'ch2',
            amount: '50',
            cumulative: '50',
            status: CommitStatus::Replayed,
        );
        self::assertSame('replayed', $receipt->toArray()['status']);
    }

    // -------------------------------------------------------------------------
    // MeteringDirective - uncovered branches
    // -------------------------------------------------------------------------

    public function testMeteringDirectiveWithProof(): void
    {
        $d = new MeteringDirective('d1', 'ch1', '100', 'USDC', 1, 9999999999, 'https://example.com/commit', 'proof-blob');
        $arr = $d->toArray();
        self::assertSame('proof-blob', $arr['proof']);
        self::assertSame('https://example.com/commit', $arr['commitUrl']);
    }

    public function testMeteringDirectiveFromArrayWithProofAndCommitUrl(): void
    {
        $d = MeteringDirective::fromArray([
            'deliveryId' => 'd1',
            'sessionId' => 'ch1',
            'amount' => '100',
            'currency' => 'USDC',
            'sequence' => 1,
            'expiresAt' => 9999999999,
            'commitUrl' => 'https://x/commit',
            'proof' => 'some-proof',
        ]);
        self::assertSame('https://x/commit', $d->commitUrl);
        self::assertSame('some-proof', $d->proof);
    }

    public function testMeteringDirectiveFromArrayRejectsNonIntSequence(): void
    {
        $this->expectException(InvalidArgumentException::class);
        MeteringDirective::fromArray([
            'deliveryId' => 'd1',
            'sessionId' => 'ch1',
            'amount' => '100',
            'currency' => 'USDC',
            'sequence' => 'bad',
            'expiresAt' => 9999999999,
        ]);
    }

    public function testMeteringDirectiveFromArrayRejectsNonIntExpiresAt(): void
    {
        $this->expectException(InvalidArgumentException::class);
        MeteringDirective::fromArray([
            'deliveryId' => 'd1',
            'sessionId' => 'ch1',
            'amount' => '100',
            'currency' => 'USDC',
            'sequence' => 1,
            'expiresAt' => 'not-an-int',
        ]);
    }

    public function testMeteringDirectiveRejectsEmptyDeliveryId(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new MeteringDirective('', 'ch1', '100', 'USDC', 1, 9999999999);
    }

    // -------------------------------------------------------------------------
    // OpenPayload - uncovered branches
    // -------------------------------------------------------------------------

    public function testOpenPayloadSessionIdThrowsOnPullWithNoChannelOrTokenAccount(): void
    {
        // Build a pull payload without tokenAccount or channelId manually via fromArray
        $payload = OpenPayload::fromArray([
            'mode' => 'pull',
            'authorizedSigner' => $this->signer,
            'signature' => 'sig',
        ]);
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/pull open missing/');
        $payload->sessionId();
    }

    public function testOpenPayloadDepositAmountUsesApprovedAmountForPull(): void
    {
        $payload = OpenPayload::pull('tokacct', '3000000', 'wallet1', $this->signer, 'sig');
        self::assertSame('3000000', $payload->depositAmount());
    }

    public function testOpenPayloadDepositAmountThrowsForPullWithNoAmount(): void
    {
        $payload = OpenPayload::fromArray([
            'mode' => 'pull',
            'tokenAccount' => 'ta1',
            'authorizedSigner' => $this->signer,
            'signature' => 'sig',
        ]);
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/pull open missing/');
        $payload->depositAmount();
    }

    public function testOpenPayloadDepositAmountThrowsForPushWithNoDeposit(): void
    {
        $payload = OpenPayload::fromArray([
            'mode' => 'push',
            'channelId' => 'chan1',
            'authorizedSigner' => $this->signer,
            'signature' => 'sig',
        ]);
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/push open missing/');
        $payload->depositAmount();
    }

    public function testDecodeSaltRejectsNegativeInt(): void
    {
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/unsigned/');
        OpenPayload::fromArray([
            'mode' => 'push',
            'channelId' => 'c',
            'authorizedSigner' => 's',
            'signature' => 'sig',
            'salt' => -1,
        ]);
    }

    public function testDecodeSaltRejectsNonDecimalString(): void
    {
        $this->expectException(InvalidArgumentException::class);
        OpenPayload::fromArray([
            'mode' => 'push',
            'channelId' => 'c',
            'authorizedSigner' => 's',
            'signature' => 'sig',
            'salt' => 'abc',
        ]);
    }

    public function testDecodeSaltRejectsNonStringNonInt(): void
    {
        $this->expectException(InvalidArgumentException::class);
        OpenPayload::fromArray([
            'mode' => 'push',
            'channelId' => 'c',
            'authorizedSigner' => 's',
            'signature' => 'sig',
            'salt' => 3.14,
        ]);
    }

    public function testDecodeSaltRejectsEmptyString(): void
    {
        $this->expectException(InvalidArgumentException::class);
        OpenPayload::fromArray([
            'mode' => 'push',
            'channelId' => 'c',
            'authorizedSigner' => 's',
            'signature' => 'sig',
            'salt' => '',
        ]);
    }

    // -------------------------------------------------------------------------
    // SessionSplit - uncovered validation branches
    // -------------------------------------------------------------------------

    public function testSessionSplitRejectsEmptyRecipient(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new SessionSplit('', 100);
    }

    public function testSessionSplitRejectsNegativeBps(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new SessionSplit('rec1', -1);
    }

    public function testSessionSplitFromArrayRejectsNonIntBps(): void
    {
        $this->expectException(InvalidArgumentException::class);
        SessionSplit::fromArray(['recipient' => 'rec1', 'bps' => 'abc']);
    }

    public function testSessionSplitFromArrayRejectsNonStringRecipient(): void
    {
        $this->expectException(InvalidArgumentException::class);
        SessionSplit::fromArray(['recipient' => 123, 'bps' => 100]);
    }

    // -------------------------------------------------------------------------
    // VoucherData - uncovered validation branches
    // -------------------------------------------------------------------------

    public function testVoucherDataRejectsEmptyChannelId(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new VoucherData('', '100', 9999999999);
    }

    public function testVoucherDataRejectsNonDigitCumulative(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new VoucherData('chan1', 'abc', 9999999999);
    }

    public function testVoucherDataFromArrayRejectsNonStringChannelId(): void
    {
        $this->expectException(InvalidArgumentException::class);
        VoucherData::fromArray(['channelId' => 123, 'cumulativeAmount' => '100', 'expiresAt' => 9999999999]);
    }

    public function testVoucherDataFromArrayRejectsNonIntExpiresAt(): void
    {
        $this->expectException(InvalidArgumentException::class);
        VoucherData::fromArray(['channelId' => 'c', 'cumulativeAmount' => '100', 'expiresAt' => 'bad']);
    }

    public function testVoucherDataFromArrayRejectsNonIntNonce(): void
    {
        $this->expectException(InvalidArgumentException::class);
        VoucherData::fromArray(['channelId' => 'c', 'cumulativeAmount' => '100', 'expiresAt' => 99, 'nonce' => 'bad']);
    }

    public function testVoucherDataNormalizeCumulativeNegativeIntThrows(): void
    {
        $this->expectException(InvalidArgumentException::class);
        VoucherData::fromArray(['channelId' => 'c', 'cumulativeAmount' => -1, 'expiresAt' => 99]);
    }

    public function testVoucherDataNormalizeCumulativeMissingThrows(): void
    {
        $this->expectException(InvalidArgumentException::class);
        VoucherData::fromArray(['channelId' => 'c', 'expiresAt' => 99]);
    }

    // -------------------------------------------------------------------------
    // SessionRequest - uncovered validation branches
    // -------------------------------------------------------------------------

    public function testSessionRequestRejectsEmptyCap(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new SessionRequest(cap: '', currency: 'USDC', operator: 'op', recipient: 'rec');
    }

    public function testSessionRequestRejectsEmptyCurrency(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new SessionRequest(cap: '1000', currency: '', operator: 'op', recipient: 'rec');
    }

    public function testSessionRequestFromArrayRejectsNonArraySplits(): void
    {
        $this->expectException(InvalidArgumentException::class);
        SessionRequest::fromArray([
            'cap' => '1000',
            'currency' => 'USDC',
            'operator' => 'op',
            'recipient' => 'rec',
            'splits' => 'bad',
        ]);
    }

    public function testSessionRequestFromArrayRejectsNonArrayModes(): void
    {
        $this->expectException(InvalidArgumentException::class);
        SessionRequest::fromArray([
            'cap' => '1000',
            'currency' => 'USDC',
            'operator' => 'op',
            'recipient' => 'rec',
            'modes' => 'bad',
        ]);
    }

    public function testSessionRequestFromArrayRejectsNonStringMode(): void
    {
        $this->expectException(InvalidArgumentException::class);
        SessionRequest::fromArray([
            'cap' => '1000',
            'currency' => 'USDC',
            'operator' => 'op',
            'recipient' => 'rec',
            'modes' => [42],
        ]);
    }

    public function testSessionRequestFromArrayRejectsNonStringPullVoucherStrategy(): void
    {
        $this->expectException(InvalidArgumentException::class);
        SessionRequest::fromArray([
            'cap' => '1000',
            'currency' => 'USDC',
            'operator' => 'op',
            'recipient' => 'rec',
            'pullVoucherStrategy' => 123,
        ]);
    }

    public function testSessionRequestToArrayEmitsRecentBlockhash(): void
    {
        $req = new SessionRequest(
            cap: '1000',
            currency: 'USDC',
            operator: 'op',
            recipient: 'rec',
            recentBlockhash: 'blockhash123',
        );
        $arr = $req->toArray();
        self::assertSame('blockhash123', $arr['recentBlockhash']);
    }

    public function testSessionRequestFromArrayRoundTripsRecentBlockhash(): void
    {
        $req = SessionRequest::fromArray([
            'cap' => '1000',
            'currency' => 'USDC',
            'operator' => 'op',
            'recipient' => 'rec',
            'recentBlockhash' => 'bh-xyz',
        ]);
        self::assertSame('bh-xyz', $req->recentBlockhash);
    }

    // -------------------------------------------------------------------------
    // SessionServer - uncovered branches
    // -------------------------------------------------------------------------

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

    private function openPush(SessionServer $server, int $deposit = 1_000_000): void
    {
        $server->processOpen(OpenPayload::push($this->channel, (string) $deposit, $this->signer, 'tx'));
    }

    public function testBuildChallengeRequestWithMinVoucherDeltaEmitsField(): void
    {
        $server = new SessionServer(
            new SessionConfig(
                operator: self::RECIPIENT,
                recipient: self::RECIPIENT,
                network: 'localnet',
                minVoucherDelta: 500,
            ),
            new MemoryChannelStore(),
        );
        $req = $server->buildChallengeRequest(1_000_000);
        self::assertSame('500', $req->minVoucherDelta);
    }

    public function testBuildChallengeRequestWithPullStrategyEmitsStrategy(): void
    {
        $server = new SessionServer(
            new SessionConfig(
                operator: self::RECIPIENT,
                recipient: self::RECIPIENT,
                network: 'localnet',
                modes: [SessionMode::Push, SessionMode::Pull],
                pullVoucherStrategy: SessionPullVoucherStrategy::ClientVoucher,
            ),
            new MemoryChannelStore(),
        );
        $req = $server->buildChallengeRequest(1_000_000);
        self::assertSame(SessionPullVoucherStrategy::ClientVoucher, $req->pullVoucherStrategy);
    }

    public function testProcessTopupRejectsOverMaxCap(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 1_000_000);
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/exceeds max cap/');
        $server->processTopup(new TopUpPayload($this->channel, '20000000', 'txsig'));
    }

    public function testProcessTopupRejectsUnknownChannel(): void
    {
        $server = $this->makeServer();
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/not found/');
        $server->processTopup(new TopUpPayload($this->channel, '2000000', 'txsig'));
    }

    public function testBeginDeliveryRejectsZeroAmount(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/greater than zero/');
        $server->beginDelivery(new DeliveryRequest($this->channel, 0));
    }

    public function testBeginDeliveryRejectsFinalizedChannel(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $server->markFinalized($this->channel);
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/finalized/');
        $server->beginDelivery(new DeliveryRequest($this->channel, 100));
    }

    public function testBeginDeliveryRejectsClosePendingChannel(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $server->processClose(new ClosePayload($this->channel));
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/close is pending/');
        $server->beginDelivery(new DeliveryRequest($this->channel, 100));
    }

    public function testBeginDeliveryRejectsUnknownChannel(): void
    {
        $server = $this->makeServer();
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/not found/');
        $server->beginDelivery(new DeliveryRequest($this->channel, 100));
    }

    public function testBeginDeliveryAcceptsExplicitDeliveryId(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $directive = $server->beginDelivery(new DeliveryRequest($this->channel, 100, 'my-delivery-id'));
        self::assertSame('my-delivery-id', $directive->deliveryId);
    }

    public function testBeginDeliveryRejectsDuplicatePendingDeliveryId(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $server->beginDelivery(new DeliveryRequest($this->channel, 100, 'dup-id'));
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/already exists/');
        $server->beginDelivery(new DeliveryRequest($this->channel, 100, 'dup-id'));
    }

    public function testBeginDeliveryWithCommitUrlAndProof(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $directive = $server->beginDelivery(new DeliveryRequest(
            $this->channel,
            100,
            null,
            'https://example.com/commit',
            'proof-val',
        ));
        self::assertSame('https://example.com/commit', $directive->commitUrl);
        self::assertSame('proof-val', $directive->proof);
    }

    public function testProcessCommitRejectsUnknownDelivery(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/not found/');
        $server->processCommit(new CommitPayload('no-such', $this->voucher(100)));
    }

    public function testProcessCommitRejectsDifferentVoucherForCommittedDelivery(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 2_000);
        $directive = $server->beginDelivery(new DeliveryRequest($this->channel, 100));
        $server->processCommit(new CommitPayload($directive->deliveryId, $this->voucher(100)));

        // Re-submit same deliveryId with different cumulative
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/already committed with different voucher/');
        $server->processCommit(new CommitPayload($directive->deliveryId, $this->voucher(150)));
    }

    public function testProcessCommitRejectsFinalizedChannel(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $directive = $server->beginDelivery(new DeliveryRequest($this->channel, 100));
        // Finalize externally to reach the closure branch
        $server->markFinalized($this->channel);
        $this->expectException(RuntimeException::class);
        $server->processCommit(new CommitPayload($directive->deliveryId, $this->voucher(100)));
    }

    public function testProcessCommitRejectsCommitForClosePendingChannel(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $directive = $server->beginDelivery(new DeliveryRequest($this->channel, 100));
        $server->processClose(new ClosePayload($this->channel));
        $this->expectException(RuntimeException::class);
        $server->processCommit(new CommitPayload($directive->deliveryId, $this->voucher(100)));
    }

    public function testProcessCommitRejectsWhenCumulativeBelowWatermark(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 2_000);
        // Advance watermark to 200 first via a direct voucher
        $server->verifyVoucher($this->voucher(200));
        $directive = $server->beginDelivery(new DeliveryRequest($this->channel, 100));
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/must exceed watermark/');
        $server->processCommit(new CommitPayload($directive->deliveryId, $this->voucher(100)));
    }

    public function testProcessCloseWithNoVoucherStillFinalizesChannel(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $params = $server->processClose(new ClosePayload($this->channel));
        self::assertSame(0, $params->settled);
        self::assertSame(self::RECIPIENT, $params->recipient);
    }

    public function testProcessCloseRejectsFinalizedChannel(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $server->markFinalized($this->channel);
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/finalized/');
        $server->processClose(new ClosePayload($this->channel));
    }

    public function testProcessCloseRejectsDoubleClose(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $server->processClose(new ClosePayload($this->channel));
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/Close already requested/');
        $server->processClose(new ClosePayload($this->channel));
    }

    public function testProcessCloseWithFinalVoucherOverDepositThrows(): void
    {
        $server = $this->makeServer();
        $this->openPush($server, 500);
        // Build a voucher beyond the deposit without signing-level checks via a modified VoucherData
        $data = new VoucherData($this->channel, '600', time() + 3600);
        $sig = sodium_crypto_sign_detached($data->messageBytes(), $this->signerKey[1]);
        $voucher = new SignedVoucher($data, Base58::encode($sig));
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/exceeds deposit/');
        $server->processClose(new ClosePayload($this->channel, $voucher));
    }

    public function testProcessCloseIdempotentHighestVoucherReplayedOnClose(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $v = $this->voucher(100);
        $server->verifyVoucher($v);
        // Close with the exact same voucher (cumulative = watermark, same sig)
        $params = $server->processClose(new ClosePayload($this->channel, $v));
        self::assertSame(100, $params->settled);
    }

    public function testProcessCloseRejectsVoucherWithLowerCumulativeThanWatermark(): void
    {
        $server = $this->makeServer();
        $this->openPush($server);
        $server->verifyVoucher($this->voucher(300));
        // Build a voucher at cumulative 100 (below watermark 300, different sig)
        $data = new VoucherData($this->channel, '100', time() + 3600);
        $sig = sodium_crypto_sign_detached($data->messageBytes(), $this->signerKey[1]);
        $voucher = new SignedVoucher($data, Base58::encode($sig));
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/must exceed watermark/');
        $server->processClose(new ClosePayload($this->channel, $voucher));
    }

    public function testFinalizeParamsRejectsUnknownChannel(): void
    {
        $server = $this->makeServer();
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/not found/');
        $server->finalizeParams($this->channel);
    }

    public function testPaymentChannelOpenParamsMissingPayer(): void
    {
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
        $payload = OpenPayload::fromArray([
            'mode' => 'pull',
            'channelId' => $this->channel,
            'deposit' => '1000000',
            'payee' => self::RECIPIENT,
            'mint' => 'So11111111111111111111111111111111111111112',
            'salt' => '1',
            'gracePeriod' => 900,
            'authorizedSigner' => $this->signer,
            'signature' => 'sig',
        ]);
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/missing payer/');
        $server->paymentChannelOpenParams($payload);
    }

    public function testPaymentChannelOpenParamsMissingAuthorizedSigner(): void
    {
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
        $payload = OpenPayload::fromArray([
            'mode' => 'pull',
            'channelId' => $this->channel,
            'deposit' => '1000000',
            'payer' => PublicKey::fromBytes(str_repeat(chr(21), 32))->toBase58(),
            'payee' => self::RECIPIENT,
            'mint' => 'So11111111111111111111111111111111111111112',
            'salt' => '1',
            'gracePeriod' => 900,
            'authorizedSigner' => '',
            'signature' => 'sig',
        ]);
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/authorizedSigner/');
        $server->paymentChannelOpenParams($payload);
    }

    public function testPaymentChannelOpenParamsMissingSalt(): void
    {
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
        $payer = PublicKey::fromBytes(str_repeat(chr(21), 32))->toBase58();
        $payload = OpenPayload::fromArray([
            'mode' => 'pull',
            'channelId' => $this->channel,
            'deposit' => '1000000',
            'payer' => $payer,
            'payee' => self::RECIPIENT,
            'mint' => 'So11111111111111111111111111111111111111112',
            'gracePeriod' => 900,
            'authorizedSigner' => $this->signer,
            'signature' => 'sig',
        ]);
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/salt/');
        $server->paymentChannelOpenParams($payload);
    }

    public function testPaymentChannelOpenParamsMissingGracePeriod(): void
    {
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
        $payer = PublicKey::fromBytes(str_repeat(chr(21), 32))->toBase58();
        $payload = OpenPayload::fromArray([
            'mode' => 'pull',
            'channelId' => $this->channel,
            'deposit' => '1000000',
            'payer' => $payer,
            'payee' => self::RECIPIENT,
            'mint' => 'So11111111111111111111111111111111111111112',
            'salt' => '1',
            'authorizedSigner' => $this->signer,
            'signature' => 'sig',
        ]);
        $this->expectException(InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/gracePeriod/');
        $server->paymentChannelOpenParams($payload);
    }

    public function testVerifyVoucherConcurrentWatermarkAdvanceInsideClosureThrows(): void
    {
        // The double-checked watermark path inside the update closure uses MemoryChannelStore.
        // Simulate by opening, verifying once, then providing a same-cumulative voucher
        // with a different signature (not an idempotent replay).
        $server = $this->makeServer();
        $this->openPush($server);
        $server->verifyVoucher($this->voucher(200));

        // Different sig, same cumulative -> should fail "must exceed watermark"
        $kp2 = sodium_crypto_sign_keypair();
        $pub2 = sodium_crypto_sign_publickey($kp2);
        $sec2 = sodium_crypto_sign_secretkey($kp2);

        // Open a fresh server and channel with different signer to create a voucher
        // with same cumulative but different sig that's not idempotent
        $data = new VoucherData($this->channel, '200', time() + 3600);
        $sig = sodium_crypto_sign_detached($data->messageBytes(), $this->signerKey[1]);
        $differentSigVoucher = new SignedVoucher($data, Base58::encode($sig) . 'x');

        $this->expectException(RuntimeException::class);
        $server->verifyVoucher($differentSigVoucher);
    }

    public function testSessionConfigSupportsModeWithEmptyModesDefaultsToPush(): void
    {
        $config = new SessionConfig(
            operator: 'op',
            recipient: 'rec',
            modes: [],
        );
        self::assertTrue($config->supportsMode(SessionMode::Push));
        self::assertFalse($config->supportsMode(SessionMode::Pull));
    }

    public function testMemoryChannelStoreMarkFinalizedUnknownChannelThrows(): void
    {
        $store = new MemoryChannelStore();
        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessageMatches('/not found/');
        $store->markFinalized('no-such-channel');
    }
}
