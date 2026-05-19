# frozen_string_literal: true

require_relative 'test_helper'

module SolanaMpp
  module Intents
    class SessionRequestTest < Minitest::Test
      def test_serializes_shared_wire_fields
        request = SessionRequest.new(
          cap: '1000000',
          currency: 'USDC',
          operator: 'operator',
          recipient: 'recipient',
          decimals: 6,
          network: 'devnet',
          splits: [SessionSplit.new(recipient: 'affiliate', bps: 250)],
          program_id: 'program',
          description: 'Metered API session',
          external_id: 'session-001',
          min_voucher_delta: '1000',
          modes: [SessionRequest::MODE_PUSH, SessionRequest::MODE_PULL],
          pull_voucher_strategy: SessionRequest::PULL_CLIENT_VOUCHER,
          recent_blockhash: 'blockhash'
        )

        assert_equal '1000000', request.to_h['cap']
        assert_equal 'affiliate', request.to_h['splits'][0]['recipient']
        assert_equal ['push', 'pull'], request.to_h['modes']
        assert_equal 'clientVoucher', request.to_h['pullVoucherStrategy']
      end

      def test_requires_pull_voucher_strategy_for_pull_mode
        error = assert_raises(ArgumentError) do
          SessionRequest.new(
            cap: '1000',
            currency: 'USDC',
            operator: 'operator',
            recipient: 'recipient',
            modes: [SessionRequest::MODE_PULL]
          )
        end

        assert_match(/pullVoucherStrategy is required/, error.message)
      end

      def test_signed_voucher_serializes_cumulative_voucher
        voucher = SignedVoucher.new(
          data: {
            channel_id: 'channel',
            cumulative_amount: '25000',
            expires_at: VoucherData::DEFAULT_EXPIRES_AT,
            nonce: 1
          },
          signature: 'signature'
        )

        assert_equal 'channel', voucher.to_h['data']['channelId']
        assert_equal '25000', voucher.to_h['data']['cumulativeAmount']
        assert_equal 'signature', voucher.to_h['signature']
      end

      def test_metering_directive_serializes_commit_fields
        directive = SessionMeteringDirective.new(
          delivery_id: 'delivery-001',
          session_id: 'channel',
          amount: '5000',
          currency: 'USDC',
          sequence: 1,
          expires_at: VoucherData::DEFAULT_EXPIRES_AT,
          commit_url: 'https://merchant.example/session/commit',
          proof: 'proof'
        )

        assert_equal 'delivery-001', directive.to_h['deliveryId']
        assert_equal 'channel', directive.to_h['sessionId']
        assert_equal 'https://merchant.example/session/commit', directive.to_h['commitUrl']
      end

      def test_commit_receipt_rejects_unknown_status
        error = assert_raises(ArgumentError) do
          SessionCommitReceipt.new(
            delivery_id: 'delivery-001',
            session_id: 'channel',
            amount: '5000',
            cumulative: '30000',
            status: 'accepted'
          )
        end

        assert_equal 'status must be committed or replayed', error.message
      end
    end
  end
end
