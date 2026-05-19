<?php

declare(strict_types=1);

namespace SolanaMpp\Tests;

use DateTimeImmutable;
use PHPUnit\Framework\TestCase;
use SolanaMpp\Core\Challenge;
use SolanaMpp\Core\Credential;
use SolanaMpp\Core\Headers;
use SolanaMpp\Intent\SubscriptionRequest;
use SolanaMpp\Server\SubscriptionServer;
use SolanaMpp\Server\SubscriptionVerifier;
use SolanaMpp\Server\VerificationResult;

final class SubscriptionServerTest extends TestCase
{
    public function testCreatesChallengeHeaderAndVerifiesCredential(): void
    {
        $server = new SubscriptionServer(secretKey: 'secret', realm: 'api');
        $request = new SubscriptionRequest(
            amount: '1000',
            currency: 'USDC',
            periodUnit: SubscriptionRequest::PERIOD_MONTH,
            periodCount: '1',
            externalId: 'subscription-001',
        );
        $challenge = Headers::parseWwwAuthenticate($server->createChallengeHeader($request));
        $credential = new Credential(
            challenge: $challenge->toEcho(),
            payload: ['type' => 'subscription-activation', 'signature' => 'sig'],
        );

        $result = $server->verifyAuthorizationHeader(
            $credential->toAuthorizationHeader(),
            new class implements SubscriptionVerifier {
                public function verify(Credential $credential, Challenge $challenge): VerificationResult
                {
                    TestCase::assertSame('sig', $credential->payload['signature']);
                    TestCase::assertSame('subscription', $challenge->intent);

                    return VerificationResult::success(reference: 'subscription-id', externalId: 'subscription-001');
                }
            },
        );

        self::assertTrue($result->ok);
        self::assertSame('subscription-id', $result->reference);
        $receipt = Headers::parseReceipt($server->createReceiptHeader($challenge, $result));
        self::assertSame($challenge->id, $receipt->challengeId);
        self::assertSame('subscription-001', $receipt->externalId);
    }

    public function testRejectsWrongIntent(): void
    {
        $server = new SubscriptionServer(secretKey: 'secret', realm: 'api');
        $request = (new SubscriptionRequest(
            amount: '1000',
            currency: 'USDC',
            periodUnit: SubscriptionRequest::PERIOD_MONTH,
            periodCount: '1',
        ))->toArray();
        $encodedRequest = Challenge::withSecret(
            secretKey: 'secret',
            realm: 'api',
            method: 'solana',
            intent: 'subscription',
            request: $request,
        )->request;
        $challenge = new Challenge(
            id: Challenge::computeId(
                secretKey: 'secret',
                realm: 'api',
                method: 'solana',
                intent: 'charge',
                request: $encodedRequest,
            ),
            realm: 'api',
            method: 'solana',
            intent: 'charge',
            request: $encodedRequest,
        );
        $credential = new Credential(challenge: $challenge->toEcho(), payload: ['type' => 'subscription-activation']);

        $result = $server->verifyAuthorizationHeader(
            $credential->toAuthorizationHeader(),
            $this->unusedVerifier(),
        );

        self::assertFalse($result->ok);
        self::assertSame('challenge method or intent mismatch', $result->reason);
    }

    public function testRejectsExpiredChallenge(): void
    {
        $server = new SubscriptionServer(secretKey: 'secret', realm: 'api');
        $challenge = $server->createChallenge(
            new SubscriptionRequest(
                amount: '1000',
                currency: 'USDC',
                periodUnit: SubscriptionRequest::PERIOD_MONTH,
                periodCount: '1',
            ),
            expires: '2026-01-01T00:00:00+00:00',
        );
        $credential = new Credential(challenge: $challenge->toEcho(), payload: ['type' => 'subscription-activation']);

        $result = $server->verifyAuthorizationHeader(
            $credential->toAuthorizationHeader(),
            $this->unusedVerifier(),
            new DateTimeImmutable('2026-05-19T00:00:00+00:00'),
        );

        self::assertFalse($result->ok);
        self::assertSame('challenge expired', $result->reason);
    }

    private function unusedVerifier(): SubscriptionVerifier
    {
        return new class implements SubscriptionVerifier {
            public function verify(Credential $credential, Challenge $challenge): VerificationResult
            {
                TestCase::fail('verifier should not be called');
            }
        };
    }
}
