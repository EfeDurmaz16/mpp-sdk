# frozen_string_literal: true

require_relative 'test_helper'

module SolanaMpp
  module Intents
    class SubscriptionRequestTest < Minitest::Test
      def test_serializes_recurring_fields
        request = SubscriptionRequest.new(
          amount: '1000',
          currency: 'USDC',
          period_unit: SubscriptionRequest::PERIOD_MONTH,
          period_count: '1',
          recipient: 'recipient',
          subscription_expires: '2027-01-01T00:00:00+00:00',
          description: 'Monthly API access',
          external_id: 'sub-001',
          method_details: { 'network' => 'devnet' }
        )

        assert_equal '1000', request.to_h['amount']
        assert_equal 'USDC', request.to_h['currency']
        assert_equal 'month', request.to_h['periodUnit']
        assert_equal '1', request.to_h['periodCount']
        assert_equal 'devnet', request.to_h['methodDetails']['network']
      end

      def test_rejects_unsupported_period_unit
        error = assert_raises(ArgumentError) do
          SubscriptionRequest.new(
            amount: '1000',
            currency: 'USDC',
            period_unit: 'year',
            period_count: '1'
          )
        end

        assert_match(/unsupported periodUnit/, error.message)
      end

      def test_receipt_serializes_charged_period
        receipt = SubscriptionReceipt.new(
          subscription_id: 'subscription',
          amount: '1000',
          currency: 'USDC',
          period_start: 1_770_000_000,
          period_end: 1_772_678_400,
          reference: 'tx-signature',
          external_id: 'sub-001'
        )

        assert_equal 'subscription', receipt.to_h['subscriptionId']
        assert_equal 'tx-signature', receipt.to_h['reference']
        assert_equal 1_772_678_400, receipt.to_h['periodEnd']
      end

      def test_account_state_rejects_duplicate_period_charges
        state = SubscriptionAccountState.new(
          subscription_id: 'subscription',
          status: SubscriptionAccountState::STATUS_ACTIVE,
          current_period: 2,
          charged_periods: [1]
        )

        assert state.can_charge_period?(2)
        state.record_period_charge!(2)
        refute state.can_charge_period?(2)
        error = assert_raises(ArgumentError) { state.record_period_charge!(2) }
        assert_equal 'subscription period cannot be charged', error.message
      end

      def test_account_state_does_not_accumulate_missed_periods
        state = SubscriptionAccountState.new(
          subscription_id: 'subscription',
          status: SubscriptionAccountState::STATUS_ACTIVE,
          current_period: 3
        )

        assert state.can_charge_period?(3)
        refute state.can_charge_period?(4)
      end
    end
  end
end
