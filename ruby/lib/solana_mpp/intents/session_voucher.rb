# frozen_string_literal: true

module SolanaMpp
  module Intents
    class VoucherData
      DEFAULT_EXPIRES_AT = 4_102_444_800

      attr_reader :channel_id, :cumulative_amount, :expires_at, :nonce

      def initialize(channel_id:, cumulative_amount:, expires_at: DEFAULT_EXPIRES_AT, nonce: nil)
        SessionRequest.assert_required(channel_id, 'channelId')
        SessionRequest.assert_positive_decimal(cumulative_amount, 'cumulativeAmount')
        raise ArgumentError, 'expiresAt must be positive' unless expires_at.is_a?(Integer) && expires_at.positive?
        raise ArgumentError, 'nonce cannot be negative' unless nonce.nil? || (nonce.is_a?(Integer) && !nonce.negative?)

        @channel_id = channel_id
        @cumulative_amount = cumulative_amount
        @expires_at = expires_at
        @nonce = nonce
      end

      def to_h
        value = {
          'channelId' => channel_id,
          'cumulativeAmount' => cumulative_amount,
          'expiresAt' => expires_at
        }
        value['nonce'] = nonce unless nonce.nil?
        value
      end
    end

    class SignedVoucher
      attr_reader :data, :signature

      def initialize(data:, signature:)
        @data = data.is_a?(VoucherData) ? data : VoucherData.new(**data)
        SessionRequest.assert_required(signature, 'signature')
        @signature = signature
      end

      def to_h
        {
          'data' => data.to_h,
          'signature' => signature
        }
      end
    end
  end
end
