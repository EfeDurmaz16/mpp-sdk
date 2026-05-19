# frozen_string_literal: true

module SolanaMpp
  module Intents
    class SessionMeteringDirective
      attr_reader :delivery_id, :session_id, :amount, :currency, :sequence, :expires_at, :commit_url, :proof

      def initialize(delivery_id:, session_id:, amount:, currency:, sequence:, expires_at:, commit_url: nil, proof: nil)
        SessionRequest.assert_required(delivery_id, 'deliveryId')
        SessionRequest.assert_required(session_id, 'sessionId')
        SessionRequest.assert_positive_decimal(amount, 'amount')
        SessionRequest.assert_required(currency, 'currency')
        raise ArgumentError, 'sequence cannot be negative' unless sequence.is_a?(Integer) && !sequence.negative?
        raise ArgumentError, 'expiresAt must be positive' unless expires_at.is_a?(Integer) && expires_at.positive?

        @delivery_id = delivery_id
        @session_id = session_id
        @amount = amount
        @currency = currency
        @sequence = sequence
        @expires_at = expires_at
        @commit_url = commit_url
        @proof = proof
      end

      def to_h
        value = {
          'deliveryId' => delivery_id,
          'sessionId' => session_id,
          'amount' => amount,
          'currency' => currency,
          'sequence' => sequence,
          'expiresAt' => expires_at
        }
        value['commitUrl'] = commit_url unless blank?(commit_url)
        value['proof'] = proof unless blank?(proof)
        value
      end

      private

      def blank?(value)
        value.nil? || value == ''
      end
    end

    class SessionCommitReceipt
      STATUS_COMMITTED = 'committed'
      STATUS_REPLAYED = 'replayed'

      attr_reader :delivery_id, :session_id, :amount, :cumulative, :status

      def initialize(delivery_id:, session_id:, amount:, cumulative:, status:)
        SessionRequest.assert_required(delivery_id, 'deliveryId')
        SessionRequest.assert_required(session_id, 'sessionId')
        SessionRequest.assert_positive_decimal(amount, 'amount')
        SessionRequest.assert_positive_decimal(cumulative, 'cumulative')
        raise ArgumentError, 'status must be committed or replayed' unless [STATUS_COMMITTED, STATUS_REPLAYED].include?(status)

        @delivery_id = delivery_id
        @session_id = session_id
        @amount = amount
        @cumulative = cumulative
        @status = status
      end

      def to_h
        {
          'deliveryId' => delivery_id,
          'sessionId' => session_id,
          'amount' => amount,
          'cumulative' => cumulative,
          'status' => status
        }
      end
    end
  end
end
