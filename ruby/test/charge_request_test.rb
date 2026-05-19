# frozen_string_literal: true

require_relative 'test_helper'

module SolanaMpp
  module Intents
    class ChargeRequestTest < Minitest::Test
      def test_serializes_wire_fields
        request = ChargeRequest.new(
          amount: '1000',
          currency: 'USDC',
          recipient: 'recipient',
          description: 'API call',
          external_id: 'order-001',
          method_details: { 'network' => 'devnet' }
        )

        assert_equal(
          {
            'amount' => '1000',
            'currency' => 'USDC',
            'recipient' => 'recipient',
            'description' => 'API call',
            'externalId' => 'order-001',
            'methodDetails' => { 'network' => 'devnet' }
          },
          request.to_h
        )
      end

      def test_parses_from_hash
        request = ChargeRequest.from_h(
          'amount' => '1000',
          'currency' => 'USDC',
          'externalId' => 'order-001'
        )

        assert_equal '1000', request.amount
        assert_equal 'USDC', request.currency
        assert_equal 'order-001', request.external_id
      end

      def test_rejects_invalid_amount
        error = assert_raises(ArgumentError) do
          ChargeRequest.new(amount: '0', currency: 'USDC')
        end

        assert_match(/positive base-unit integer string/, error.message)
      end

      def test_rejects_invalid_method_details
        error = assert_raises(ArgumentError) do
          ChargeRequest.new(amount: '1', currency: 'USDC', method_details: 'network')
        end

        assert_equal 'methodDetails must be a Hash', error.message
      end
    end
  end
end
