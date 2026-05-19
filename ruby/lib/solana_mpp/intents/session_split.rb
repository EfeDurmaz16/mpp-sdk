# frozen_string_literal: true

module SolanaMpp
  module Intents
    class SessionSplit
      attr_reader :recipient, :bps

      def initialize(recipient:, bps:)
        SessionRequest.assert_required(recipient, 'split recipient')
        raise ArgumentError, 'split bps must be between 1 and 10000' unless bps.is_a?(Integer) && bps.positive? && bps <= 10_000

        @recipient = recipient
        @bps = bps
      end

      def to_h
        {
          'recipient' => recipient,
          'bps' => bps
        }
      end

      def self.from_h(value)
        raise ArgumentError, 'session split must be a Hash' unless value.is_a?(Hash)

        new(recipient: value.fetch('recipient', '').to_s, bps: value.fetch('bps', 0).to_i)
      end
    end
  end
end
