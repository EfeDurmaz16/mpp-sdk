# frozen_string_literal: true

module SolanaMpp
  module Intents
    class SubscriptionReceipt
      attr_reader :subscription_id,
                  :amount,
                  :currency,
                  :period_start,
                  :period_end,
                  :reference,
                  :external_id

      def initialize(subscription_id:, amount:, currency:, period_start:, period_end:, reference: nil, external_id: nil)
        SessionRequest.assert_required(subscription_id, 'subscriptionId')
        ChargeRequest.assert_base_units(amount, 'amount')
        SessionRequest.assert_required(currency, 'currency')
        raise ArgumentError, 'periodStart must be a positive epoch second' unless period_start.is_a?(Integer) && period_start.positive?
        raise ArgumentError, 'periodEnd must be after periodStart' unless period_end.is_a?(Integer) && period_end > period_start

        @subscription_id = subscription_id
        @amount = amount
        @currency = currency
        @period_start = period_start
        @period_end = period_end
        @reference = reference
        @external_id = external_id
      end

      def to_h
        value = {
          'subscriptionId' => subscription_id,
          'amount' => amount,
          'currency' => currency,
          'periodStart' => period_start,
          'periodEnd' => period_end
        }
        value['reference'] = reference unless blank?(reference)
        value['externalId'] = external_id unless blank?(external_id)
        value
      end

      private

      def blank?(value)
        value.nil? || value == ''
      end
    end
  end
end
