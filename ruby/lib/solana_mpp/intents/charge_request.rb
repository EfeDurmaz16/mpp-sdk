# frozen_string_literal: true

module SolanaMpp
  module Intents
    class ChargeRequest
      attr_reader :amount,
                  :currency,
                  :recipient,
                  :description,
                  :external_id,
                  :method_details

      def initialize(amount:, currency:, recipient: nil, description: nil, external_id: nil, method_details: nil)
        self.class.assert_base_units(amount, 'amount')
        raise ArgumentError, 'currency is required' if currency.to_s.empty?
        raise ArgumentError, 'methodDetails must be a Hash' unless method_details.nil? || method_details.is_a?(Hash)

        @amount = amount
        @currency = currency
        @recipient = recipient
        @description = description
        @external_id = external_id
        @method_details = method_details
      end

      def to_h
        value = {
          'amount' => amount,
          'currency' => currency
        }
        value['recipient'] = recipient unless blank?(recipient)
        value['description'] = description unless blank?(description)
        value['externalId'] = external_id unless blank?(external_id)
        value['methodDetails'] = method_details unless method_details.nil?
        value
      end

      def self.from_h(value)
        raise ArgumentError, 'charge request must be a Hash' unless value.is_a?(Hash)

        new(
          amount: value.fetch('amount', '').to_s,
          currency: value.fetch('currency', '').to_s,
          recipient: optional_string(value['recipient']),
          description: optional_string(value['description']),
          external_id: optional_string(value['externalId']),
          method_details: value['methodDetails']
        )
      end

      def self.assert_base_units(value, field)
        text = value.to_s
        return if text.match?(/\A[1-9]\d*\z/)

        raise ArgumentError, "#{field} must be a positive base-unit integer string"
      end

      def self.optional_string(value)
        value.nil? ? nil : value.to_s
      end

      private

      def blank?(value)
        value.nil? || value == ''
      end
    end
  end
end
