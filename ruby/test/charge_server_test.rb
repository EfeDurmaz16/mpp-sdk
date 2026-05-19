# frozen_string_literal: true

require_relative 'test_helper'

module SolanaMpp
  module Server
    class ChargeServerTest < Minitest::Test
      def test_creates_challenge_header_and_verifies_credential
        server = ChargeServer.new(secret_key: 'secret', realm: 'api')
        request = Intents::ChargeRequest.new(amount: '1000', currency: 'USDC', external_id: 'order-001')
        challenge = Core::Headers.parse_www_authenticate(server.create_challenge_header(request))
        credential = Core::Credential.new(
          challenge: challenge.to_echo,
          payload: { 'type' => 'signature', 'signature' => 'sig' }
        )

        result = server.verify_authorization_header(
          credential.to_authorization_header,
          verifier: lambda do |parsed_credential, parsed_challenge|
            assert_equal 'sig', parsed_credential.payload['signature']
            assert_equal 'charge', parsed_challenge.intent
            VerificationResult.success(reference: 'tx-signature', external_id: 'order-001')
          end
        )

        assert result.ok?
        assert_equal 'tx-signature', result.reference
        receipt = Core::Headers.parse_receipt(server.create_receipt_header(challenge, result))
        assert_equal challenge.id, receipt.challenge_id
        assert_equal 'order-001', receipt.external_id
      end

      def test_rejects_credentials_for_wrong_secret
        issuer = ChargeServer.new(secret_key: 'issuer-secret', realm: 'api')
        server = ChargeServer.new(secret_key: 'server-secret', realm: 'api')
        challenge = issuer.create_challenge(Intents::ChargeRequest.new(amount: '1', currency: 'USDC'))
        credential = Core::Credential.new(challenge: challenge.to_echo, payload: { 'type' => 'signature' })

        result = server.verify_authorization_header(
          credential.to_authorization_header,
          verifier: unused_verifier
        )

        refute result.ok?
        assert_equal 'challenge verification failed', result.reason
      end

      def test_rejects_expired_challenge
        server = ChargeServer.new(secret_key: 'secret', realm: 'api')
        challenge = server.create_challenge(
          Intents::ChargeRequest.new(amount: '1', currency: 'USDC'),
          expires: '2026-01-01T00:00:00Z'
        )
        credential = Core::Credential.new(challenge: challenge.to_echo, payload: { 'type' => 'signature' })

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
