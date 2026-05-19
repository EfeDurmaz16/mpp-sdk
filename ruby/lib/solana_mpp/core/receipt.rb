# frozen_string_literal: true

module SolanaMpp
  module Core
    class Receipt
      STATUS_SUCCESS = 'success'

      attr_reader :status, :method, :timestamp, :reference, :challenge_id, :external_id

      def initialize(status:, method:, timestamp:, reference:, challenge_id:, external_id: nil)
        @status = status
        @method = method
        @timestamp = timestamp
        @reference = reference
        @challenge_id = challenge_id
        @external_id = external_id
      end

      def self.success(method:, reference:, challenge_id:, external_id: nil, timestamp: Time.now.utc.iso8601)
        new(
          status: STATUS_SUCCESS,
          method: method,
          timestamp: timestamp,
          reference: reference,
          challenge_id: challenge_id,
          external_id: external_id
        )
      end

      def to_h
        value = {
          'status' => status,
          'method' => method,
          'timestamp' => timestamp,
          'reference' => reference,
          'challengeId' => challenge_id
        }
        value['externalId'] = external_id unless external_id.nil? || external_id == ''
        value
      end

      def self.from_h(value)
        raise ArgumentError, 'receipt must be a Hash' unless value.is_a?(Hash)

        new(
          status: value.fetch('status', '').to_s,
          method: value.fetch('method', '').to_s,
          timestamp: value.fetch('timestamp', '').to_s,
          reference: value.fetch('reference', '').to_s,
          challenge_id: value.fetch('challengeId', '').to_s,
          external_id: value['externalId']
        )
      end
    end
  end
end
