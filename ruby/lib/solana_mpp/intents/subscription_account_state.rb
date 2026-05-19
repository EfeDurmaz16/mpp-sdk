# frozen_string_literal: true

module SolanaMpp
  module Intents
    class SubscriptionAccountState
      STATUS_ACTIVE = 'active'
      STATUS_EXPIRED = 'expired'
      STATUS_CANCELED = 'canceled'

      attr_reader :subscription_id, :status, :current_period, :charged_periods

      def initialize(subscription_id:, status:, current_period:, charged_periods: [])
        SessionRequest.assert_required(subscription_id, 'subscriptionId')
        raise ArgumentError, "unsupported subscription status: #{status}" unless [STATUS_ACTIVE, STATUS_EXPIRED, STATUS_CANCELED].include?(status)
        raise ArgumentError, 'currentPeriod cannot be negative' unless current_period.is_a?(Integer) && !current_period.negative?

        @subscription_id = subscription_id
        @status = status
        @current_period = current_period
        @charged_periods = {}
        charged_periods.each do |period|
          raise ArgumentError, 'chargedPeriods must contain non-negative integers' unless period.is_a?(Integer) && !period.negative?

          @charged_periods[period] = true
        end
      end

      def can_charge_period?(period)
        raise ArgumentError, 'period must be a non-negative integer' unless period.is_a?(Integer) && !period.negative?
        return false unless status == STATUS_ACTIVE
        return false if period > current_period

        charged_periods[period] != true
      end

      def record_period_charge!(period)
        raise ArgumentError, 'subscription period cannot be charged' unless can_charge_period?(period)

        charged_periods[period] = true
        self
      end
    end
  end
end
