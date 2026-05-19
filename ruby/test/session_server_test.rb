# frozen_string_literal: true

require_relative 'test_helper'

module SolanaMpp
  module Server
    class SessionServerTest < Minitest::Test
      def test_creates_challenge_header_and_verifies_credential
        server = SessionServer.new(secret_key: 'secret', realm: 'api')
        request = Intents::SessionRequest.new(
          cap: '1000000',
          currency: 'USDC',
          operator: 'operator',
          recipient: 'recipient',
          external_id: 'session-001'
        )
        challenge = Core::Headers.parse_www_authenticate(server.create_challenge_header(request))
        credential = Core::Credential.new(
          challenge: challenge.to_echo,
          payload: { 'type' => 'session-open', 'signature' => 'sig' }
        )

        result = server.verify_authorization_header(
          credential.to_authorization_header,
          verifier: lambda do |parsed_credential, parsed_challenge|
            assert_equal 'sig', parsed_credential.payload['signature']
            assert_equal 'session', parsed_challenge.intent
            VerificationResult.success(reference: 'channel-id', external_id: 'session-001')
          end
        )

        assert result.ok?
        assert_equal 'channel-id', result.reference
        receipt = Core::Headers.parse_receipt(server.create_receipt_header(challenge, result))
        assert_equal challenge.id, receipt.challenge_id
        assert_equal 'session-001', receipt.external_id
      end

      def test_rejects_wrong_intent
        server = SessionServer.new(secret_key: 'secret', realm: 'api')
        request = Intents::SessionRequest.new(cap: '1', currency: 'USDC', operator: 'operator', recipient: 'recipient')
        charge_challenge = Core::Challenge.with_secret(
          secret_key: 'secret',
          realm: 'api',
          method: 'solana',
          intent: 'charge',
          request: request.to_h
        )
        credential = Core::Credential.new(challenge: charge_challenge.to_echo, payload: { 'type' => 'session-open' })

        result = server.verify_authorization_header(
          credential.to_authorization_header,
          verifier: unused_verifier
        )

        refute result.ok?
        assert_equal 'challenge method or intent mismatch', result.reason
      end

      def test_rejects_expired_challenge
        server = SessionServer.new(secret_key: 'secret', realm: 'api')
        challenge = server.create_challenge(
          Intents::SessionRequest.new(cap: '1', currency: 'USDC', operator: 'operator', recipient: 'recipient'),
          expires: '2026-01-01T00:00:00Z'
        )
        credential = Core::Credential.new(challenge: challenge.to_echo, payload: { 'type' => 'session-open' })

        result = server.verify_authorization_header(
          credential.to_authorization_header,
          verifier: unused_verifier,
          now: Time.iso8601('2026-05-19T00:00:00Z')
        )

        refute result.ok?
        assert_equal 'challenge expired', result.reason
      end

      private

      def unused_verifier
        lambda do |_credential, _challenge|
          flunk 'verifier should not be called'
        end
      end
    end
  end
end
