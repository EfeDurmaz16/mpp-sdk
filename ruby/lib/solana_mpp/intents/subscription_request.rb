# frozen_string_literal: true

module SolanaMpp
  module Intents
    class SubscriptionRequest
      PERIOD_DAY = 'day'
      PERIOD_WEEK = 'week'
      PERIOD_MONTH = 'month'

      attr_reader :amount,
                  :currency,
                  :period_unit,
                  :period_count,
                  :recipient,
                  :subscription_expires,
                  :description,
                  :external_id,
                  :method_details

      def initialize(amount:, currency:, period_unit:, period_count:, recipient: nil, subscription_expires: nil,
                     description: nil, external_id: nil, method_details: nil)
        ChargeRequest.assert_base_units(amount, 'amount')
        raise ArgumentError, 'currency is required' if currency.to_s.empty?
        @period_unit = self.class.normalize_period_unit(period_unit)
        ChargeRequest.assert_base_units(period_count, 'periodCount')
        raise ArgumentError, 'methodDetails must be a Hash' unless method_details.nil? || method_details.is_a?(Hash)

        @amount = amount
        @currency = currency
        @period_count = period_count
        @recipient = recipient
        @subscription_expires = subscription_expires
        @description = description
        @external_id = external_id
        @method_details = method_details
      end

      def to_h
        value = {
          'amount' => amount,
          'currency' => currency,
          'periodUnit' => period_unit,
          'periodCount' => period_count
        }
        value['recipient'] = recipient unless blank?(recipient)
        value['subscriptionExpires'] = subscription_expires unless blank?(subscription_expires)
        value['description'] = description unless blank?(description)
        value['externalId'] = external_id unless blank?(external_id)
        value['methodDetails'] = method_details unless method_details.nil?
        value
      end

      def self.from_h(value)
        raise ArgumentError, 'subscription request must be a Hash' unless value.is_a?(Hash)

        new(
          amount: value.fetch('amount', '').to_s,
          currency: value.fetch('currency', '').to_s,
          period_unit: value.fetch('periodUnit', '').to_s,
          period_count: value.fetch('periodCount', '').to_s,
          recipient: ChargeRequest.optional_string(value['recipient']),
          subscription_expires: ChargeRequest.optional_string(value['subscriptionExpires']),
          description: ChargeRequest.optional_string(value['description']),
          external_id: ChargeRequest.optional_string(value['externalId']),
          method_details: value['methodDetails']
        )
      end

      def self.normalize_period_unit(period_unit)
        return period_unit if [PERIOD_DAY, PERIOD_WEEK, PERIOD_MONTH].include?(period_unit)

        raise ArgumentError, "unsupported periodUnit: #{period_unit}"
      end

      private

      def blank?(value)
        value.nil? || value == ''
      end
    end
  end
end
