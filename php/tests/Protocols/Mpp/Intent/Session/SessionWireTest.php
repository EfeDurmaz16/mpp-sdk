<?php

declare(strict_types=1);

namespace PayKit\Tests;

use InvalidArgumentException;
use PHPUnit\Framework\TestCase;
use PayKit\Protocols\Mpp\Intent\Session\ClosePayload;
use PayKit\Protocols\Mpp\Intent\Session\CommitPayload;
use PayKit\Protocols\Mpp\Intent\Session\MeteringDirective;
use PayKit\Protocols\Mpp\Intent\Session\OpenPayload;
use PayKit\Protocols\Mpp\Intent\Session\SessionAction;
use PayKit\Protocols\Mpp\Intent\Session\SessionMode;
use PayKit\Protocols\Mpp\Intent\Session\SessionPullVoucherStrategy;
use PayKit\Protocols\Mpp\Intent\Session\SessionRequest;
use PayKit\Protocols\Mpp\Intent\Session\SessionSplit;
use PayKit\Protocols\Mpp\Intent\Session\SignedVoucher;
use PayKit\Protocols\Mpp\Intent\Session\TopUpPayload;
use PayKit\Protocols\Mpp\Intent\Session\VoucherData;

final class SessionWireTest extends TestCase
{
    public function testSessionModeWireValues(): void
    {
        self::assertSame('push', SessionMode::Push->value);
        self::assertSame('pull', SessionMode::Pull->value);
        self::assertSame(SessionMode::Push, SessionMode::from('push'));
    }

    public function testPullVoucherStrategyWireValues(): void
    {
        self::assertSame('clientVoucher', SessionPullVoucherStrategy::ClientVoucher->value);
        self::assertSame('operatedVoucher', SessionPullVoucherStrategy::OperatedVoucher->value);
    }

    public function testSessionRequestOmitsEmptySplitsModesAndNoneFields(): void
    {
        $req = new SessionRequest(cap: '1000', currency: 'USDC', operator: 'op', recipient: 'rec');
        $arr = $req->toArray();
        self::assertArrayNotHasKey('splits', $arr);
        self::assertArrayNotHasKey('modes', $arr);
        self::assertArrayNotHasKey('decimals', $arr);
        self::assertArrayNotHasKey('network', $arr);
        self::assertArrayNotHasKey('description', $arr);
        self::assertArrayNotHasKey('externalId', $arr);
        self::assertArrayNotHasKey('minVoucherDelta', $arr);
    }

    public function testSessionRequestDropsPushOnlyModesList(): void
    {
        $req = new SessionRequest(
            cap: '1000',
            currency: 'USDC',
            operator: 'op',
            recipient: 'rec',
            modes: [SessionMode::Push],
        );
        self::assertArrayNotHasKey('modes', $req->toArray());
    }

    public function testSessionRequestEmitsPushAndPullModesAndStrategy(): void
    {
        $req = new SessionRequest(
            cap: '1000',
            currency: 'USDC',
            operator: 'op',
            recipient: 'rec',
            modes: [SessionMode::Push, SessionMode::Pull],
            pullVoucherStrategy: SessionPullVoucherStrategy::ClientVoucher,
        );
        $arr = $req->toArray();
        self::assertSame(['push', 'pull'], $arr['modes']);
        self::assertSame('clientVoucher', $arr['pullVoucherStrategy']);

        $back = SessionRequest::fromArray($arr);
        self::assertSame([SessionMode::Push, SessionMode::Pull], $back->modes);
        self::assertSame(SessionPullVoucherStrategy::ClientVoucher, $back->pullVoucherStrategy);
    }

    public function testSessionRequestRoundTripsSplitsAndMetadata(): void
    {
        $req = new SessionRequest(
            cap: '10000000',
            currency: 'USDC',
            operator: 'op',
            recipient: 'rec',
            decimals: 6,
            network: 'mainnet-beta',
            splits: [new SessionSplit('s1', 100), new SessionSplit('s2', 200)],
            programId: 'prog123',
            description: 'API session',
            externalId: 'ref-1',
            minVoucherDelta: '500',
        );
        $back = SessionRequest::fromArray($req->toArray());
        self::assertCount(2, $back->splits);
        self::assertSame(100, $back->splits[0]->bps);
        self::assertSame('prog123', $back->programId);
        self::assertSame('ref-1', $back->externalId);
        self::assertSame('500', $back->minVoucherDelta);
        self::assertSame('API session', $back->description);
    }

    public function testOpenPayloadPushFields(): void
    {
        $p = OpenPayload::push('chan1', '1000000', 'signer1', 'txsig');
        self::assertSame(SessionMode::Push, $p->mode);
        self::assertSame('chan1', $p->sessionId());
        self::assertSame('1000000', $p->depositAmount());
        self::assertNull($p->tokenAccount);
    }

    public function testOpenPayloadPullFields(): void
    {
        $p = OpenPayload::pull('tokacct', '5000000', 'wallet1', 'signer1', 'approvesig');
        self::assertSame(SessionMode::Pull, $p->mode);
        self::assertSame('tokacct', $p->sessionId());
        self::assertSame('5000000', $p->depositAmount());
        self::assertSame('wallet1', $p->owner);
        self::assertNull($p->channelId);
    }

    public function testOpenPayloadPushRoundTripsAndOmitsPullFields(): void
    {
        $p = OpenPayload::push('chan1', '1000000', 'signer1', 'txsig');
        $arr = $p->toArray();
        self::assertSame('push', $arr['mode']);
        self::assertSame('chan1', $arr['channelId']);
        self::assertArrayNotHasKey('tokenAccount', $arr);
        $back = OpenPayload::fromArray($arr);
        self::assertSame('chan1', $back->channelId);
    }

    public function testOpenPayloadPullRoundTripsAndOmitsChannelId(): void
    {
        $p = OpenPayload::pull('tokacct', '5000000', 'wallet1', 'signer1', 'approvesig');
        $arr = $p->toArray();
        self::assertSame('pull', $arr['mode']);
        self::assertSame('tokacct', $arr['tokenAccount']);
        self::assertArrayNotHasKey('channelId', $arr);
        $back = OpenPayload::fromArray($arr);
        self::assertSame('tokacct', $back->tokenAccount);
        self::assertSame('wallet1', $back->owner);
    }

    public function testSaltSerializesAsStringAndAcceptsLegacyNumber(): void
    {
        $salt = '18446744073709551608'; // u64::MAX - 7
        $p = OpenPayload::paymentChannel(
            SessionMode::Push,
            'chan1',
            '1000000',
            'payer1',
            'payee1',
            'mint1',
            $salt,
            900,
            'signer1',
            'txsig',
        )->withTransaction('open-tx')->withInitTx('init-tx')->withUpdateTx('update-tx');

        $arr = $p->toArray();
        self::assertSame($salt, $arr['salt']);
        self::assertIsString($arr['salt']);
        self::assertSame('open-tx', $arr['transaction']);
        self::assertSame('init-tx', $arr['initMultiDelegateTx']);
        self::assertSame('update-tx', $arr['updateDelegationTx']);

        // Legacy JSON number salt is accepted on decode and normalized.
        $legacy = OpenPayload::fromArray([
            'mode' => 'push',
            'channelId' => 'chan1',
            'deposit' => '1000000',
            'salt' => 42,
            'gracePeriod' => 900,
            'authorizedSigner' => 'signer1',
            'signature' => 'txsig',
        ]);
        self::assertSame('42', $legacy->salt);
    }

    public function testOpenPayloadMissingModeFailsDecode(): void
    {
        $this->expectException(InvalidArgumentException::class);
        OpenPayload::fromArray([
            'channelId' => 'chan1',
            'deposit' => '1000',
            'authorizedSigner' => 's',
            'signature' => 'sig',
        ]);
    }

    public function testSessionActionOpenPushTag(): void
    {
        $action = SessionAction::open(OpenPayload::push('chan123', '5000000', 'signer123', 'sig456'));
        $arr = $action->toArray();
        self::assertSame('open', $arr['action']);
        self::assertSame('push', $arr['mode']);
        $back = SessionAction::fromArray($arr);
        self::assertSame(SessionAction::OPEN, $back->action);
        self::assertNotNull($back->open);
        self::assertSame('chan123', $back->open->channelId);
    }

    public function testSessionActionVoucherTag(): void
    {
        $voucher = new SignedVoucher(new VoucherData('chan1', '500000', 9999999999, 3), 'sig_here');
        $action = SessionAction::voucher($voucher);
        $arr = $action->toArray();
        self::assertSame('voucher', $arr['action']);
        $back = SessionAction::fromArray($arr);
        self::assertNotNull($back->voucher);
        self::assertSame('500000', $back->voucher->data->cumulative);
        self::assertSame(3, $back->voucher->data->nonce);
    }

    public function testSessionActionCommitTag(): void
    {
        $voucher = new SignedVoucher(new VoucherData('chan1', '500000', 9999999999), 'sig_here');
        $action = SessionAction::commit(new CommitPayload('delivery-1', $voucher));
        $arr = $action->toArray();
        self::assertSame('commit', $arr['action']);
        self::assertSame('delivery-1', $arr['deliveryId']);
        $back = SessionAction::fromArray($arr);
        self::assertNotNull($back->commit);
        self::assertSame('delivery-1', $back->commit->deliveryId);
    }

    public function testSessionActionTopUpTagUsesCapitalU(): void
    {
        $action = SessionAction::topUp(new TopUpPayload('chan1', '9000000', 'txsig'));
        $arr = $action->toArray();
        self::assertSame('topUp', $arr['action']);
        $back = SessionAction::fromArray($arr);
        self::assertNotNull($back->topUp);
        self::assertSame('9000000', $back->topUp->newDeposit);
    }

    public function testSessionActionCloseTagWithAndWithoutVoucher(): void
    {
        $noVoucher = SessionAction::close(new ClosePayload('chan1'));
        $arr = $noVoucher->toArray();
        self::assertSame('close', $arr['action']);
        self::assertArrayNotHasKey('voucher', $arr);

        $withVoucher = SessionAction::close(new ClosePayload(
            'chan1',
            new SignedVoucher(new VoucherData('chan1', '700000', 9999999999, 7), 'final_sig'),
        ));
        $back = SessionAction::fromArray($withVoucher->toArray());
        self::assertNotNull($back->close);
        self::assertNotNull($back->close->voucher);
        self::assertSame('700000', $back->close->voucher->data->cumulative);
    }

    public function testVoucherDataEmitsCumulativeAmountAndReadsCumulativeAlias(): void
    {
        $data = new VoucherData('chan1', '500000', 42);
        self::assertSame('500000', $data->toArray()['cumulativeAmount']);
        self::assertArrayNotHasKey('cumulative', $data->toArray());

        // Decode accepts the legacy `cumulative` field name.
        $alias = VoucherData::fromArray(['channelId' => 'chan1', 'cumulative' => '777', 'expiresAt' => 42]);
        self::assertSame('777', $alias->cumulative);

        // Decode tolerates a JSON number for cumulative.
        $numeric = VoucherData::fromArray(['channelId' => 'chan1', 'cumulativeAmount' => 888, 'expiresAt' => 42]);
        self::assertSame('888', $numeric->cumulative);
    }

    public function testMeteringDirectiveRoundTrips(): void
    {
        $directive = new MeteringDirective('d1', 'chan1', '125', 'USDC', 7, 4_102_444_800, 'https://x/commit');
        $arr = $directive->toArray();
        self::assertSame('d1', $arr['deliveryId']);
        self::assertSame('https://x/commit', $arr['commitUrl']);
        $back = MeteringDirective::fromArray($arr);
        self::assertSame(7, $back->sequence);
        self::assertSame('125', $back->amount);
    }

    public function testDefaultSessionExpiryConstant(): void
    {
        self::assertSame(
            4_102_444_800,
            \PayKit\Protocols\Mpp\Server\Session\SessionServer::DEFAULT_SESSION_EXPIRES_AT,
        );
    }
}
