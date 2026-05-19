# frozen_string_literal: true

require_relative 'test_helper'

module SolanaMpp
  module Core
    class CoreTest < Minitest::Test
      def test_challenge_header_round_trip
        challenge = Challenge.with_secret(
          secret_key: 'secret',
          realm: 'api',
          method: 'solana',
          intent: 'charge',
          request: { 'amount' => '1000', 'currency' => 'USDC' },
          expires: '2027-01-01T00:00:00Z'
        )

        parsed = Headers.parse_www_authenticate(Headers.format_www_authenticate(challenge))

        assert_equal challenge.id, parsed.id
        assert_equal 'charge', parsed.intent
        assert parsed.verify?('secret')
        assert_equal({ 'amount' => '1000', 'currency' => 'USDC' }, parsed.decode_request)
      end

      def test_credential_authorization_round_trip
        challenge = Challenge.with_secret(
          secret_key: 'secret',
          realm: 'api',
          method: 'solana',
          intent: 'charge',
          request: { 'amount' => '1000', 'currency' => 'USDC' }
        )
        credential = Credential.new(
          challenge: challenge.to_echo,
          payload: { 'type' => 'signature', 'signature' => 'sig' }
        )

        parsed = Credential.from_authorization_header(credential.to_authorization_header)

        assert_equal challenge.id, parsed.challenge.id
        assert_equal 'sig', parsed.payload['signature']
      end

      def test_receipt_header_round_trip
        receipt = Receipt.success(
          method: 'solana',
          reference: 'tx-signature',
          challenge_id: 'challenge-id',
          external_id: 'order-001',
          timestamp: '2026-05-19T00:00:00Z'
        )

        parsed = Headers.parse_receipt(Headers.format_receipt(receipt))

        assert_equal 'success', parsed.status
        assert_equal 'tx-signature', parsed.reference
        assert_equal 'order-001', parsed.external_id
      end

      def test_expired_challenge
        challenge = Challenge.with_secret(
          secret_key: 'secret',
          realm: 'api',
          method: 'solana',
          intent: 'charge',
          request: { 'amount' => '1000', 'currency' => 'USDC' },
          expires: '2026-01-01T00:00:00Z'
        )

        assert challenge.expired?(Time.iso8601('2026-05-19T00:00:00Z'))
      end
    end
  end
end
