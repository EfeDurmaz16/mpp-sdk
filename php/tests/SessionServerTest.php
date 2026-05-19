<?php

declare(strict_types=1);

namespace SolanaMpp\Tests;

use DateTimeImmutable;
use PHPUnit\Framework\TestCase;
use SolanaMpp\Core\Challenge;
use SolanaMpp\Core\Credential;
use SolanaMpp\Core\Headers;
use SolanaMpp\Intent\SessionRequest;
use SolanaMpp\Server\SessionServer;
use SolanaMpp\Server\SessionVerifier;
use SolanaMpp\Server\VerificationResult;

final class SessionServerTest extends TestCase
{
    public function testCreatesChallengeHeaderAndVerifiesCredential(): void
    {
        $server = new SessionServer(secretKey: 'secret', realm: 'api');
        $request = new SessionRequest(
            cap: '1000000',
            currency: 'USDC',
            operator: 'operator',
            recipient: 'recipient',
            externalId: 'session-001',
        );
        $challenge = Headers::parseWwwAuthenticate($server->createChallengeHeader($request));
        $credential = new Credential(
            challenge: $challenge->toEcho(),
            payload: ['type' => 'session-open', 'signature' => 'sig'],
        );

        $result = $server->verifyAuthorizationHeader(
            $credential->toAuthorizationHeader(),
            new class implements SessionVerifier {
                public function verify(Credential $credential, Challenge $challenge): VerificationResult
                {
                    TestCase::assertSame('sig', $credential->payload['signature']);
                    TestCase::assertSame('session', $challenge->intent);

                    return VerificationResult::success(reference: 'channel-id', externalId: 'session-001');
                }
            },
        );

        self::assertTrue($result->ok);
        self::assertSame('channel-id', $result->reference);
        $receipt = Headers::parseReceipt($server->createReceiptHeader($challenge, $result));
        self::assertSame($challenge->id, $receipt->challengeId);
        self::assertSame('session-001', $receipt->externalId);
    }

    public function testRejectsWrongIntent(): void
    {
        $server = new SessionServer(secretKey: 'secret', realm: 'api');
        $sessionRequest = (new SessionRequest(
            cap: '1',
            currency: 'USDC',
            operator: 'operator',
            recipient: 'recipient',
        ))->toArray();
        $encodedRequest = Challenge::withSecret(
            secretKey: 'secret',
            realm: 'api',
            method: 'solana',
            intent: 'session',
            request: $sessionRequest,
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
        $credential = new Credential(challenge: $challenge->toEcho(), payload: ['type' => 'session-open']);

        $result = $server->verifyAuthorizationHeader(
            $credential->toAuthorizationHeader(),
            $this->unusedVerifier(),
        );

        self::assertFalse($result->ok);
        self::assertSame('challenge method or intent mismatch', $result->reason);
    }

    public function testRejectsExpiredChallenge(): void
    {
        $server = new SessionServer(secretKey: 'secret', realm: 'api');
        $challenge = $server->createChallenge(
            new SessionRequest(cap: '1', currency: 'USDC', operator: 'operator', recipient: 'recipient'),
            expires: '2026-01-01T00:00:00+00:00',
        );
        $credential = new Credential(challenge: $challenge->toEcho(), payload: ['type' => 'session-open']);

        $result = $server->verifyAuthorizationHeader(
            $credential->toAuthorizationHeader(),
            $this->unusedVerifier(),
            new DateTimeImmutable('2026-05-19T00:00:00+00:00'),
        );

        self::assertFalse($result->ok);
        self::assertSame('challenge expired', $result->reason);
    }

    private function unusedVerifier(): SessionVerifier
    {
        return new class implements SessionVerifier {
            public function verify(Credential $credential, Challenge $challenge): VerificationResult
            {
                TestCase::fail('verifier should not be called');
            }
        };
    }
}
