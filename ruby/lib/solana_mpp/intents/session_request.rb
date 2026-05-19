# frozen_string_literal: true

module SolanaMpp
  module Intents
    class SessionRequest
      MODE_PUSH = 'push'
      MODE_PULL = 'pull'
      PULL_CLIENT_VOUCHER = 'clientVoucher'
      PULL_OPERATED_VOUCHER = 'operatedVoucher'

      attr_reader :cap,
                  :currency,
                  :operator,
                  :recipient,
                  :decimals,
                  :network,
                  :splits,
                  :program_id,
                  :description,
                  :external_id,
                  :min_voucher_delta,
                  :modes,
                  :pull_voucher_strategy,
                  :recent_blockhash

      def initialize(cap:, currency:, operator:, recipient:, decimals: nil, network: nil, splits: [],
                     program_id: nil, description: nil, external_id: nil, min_voucher_delta: nil,
                     modes: [], pull_voucher_strategy: nil, recent_blockhash: nil)
        self.class.assert_positive_decimal(cap, 'cap')
        self.class.assert_required(currency, 'currency')
        self.class.assert_required(operator, 'operator')
        self.class.assert_required(recipient, 'recipient')
        if !decimals.nil? && (!decimals.is_a?(Integer) || decimals.negative? || decimals > 255)
          raise ArgumentError, 'decimals must be between 0 and 255'
        end
        self.class.assert_positive_decimal(min_voucher_delta, 'minVoucherDelta') unless blank?(min_voucher_delta)

        @splits = splits.map { |split| split.is_a?(SessionSplit) ? split : SessionSplit.from_h(split) }
        @modes = modes.map { |mode| self.class.normalize_mode(mode) }
        if @modes.include?(MODE_PULL) && pull_voucher_strategy.nil?
          raise ArgumentError, 'pullVoucherStrategy is required when pull mode is advertised'
        end
        @pull_voucher_strategy = pull_voucher_strategy.nil? ? nil : self.class.normalize_pull_voucher_strategy(pull_voucher_strategy)

        @cap = cap
        @currency = currency
        @operator = operator
        @recipient = recipient
        @decimals = decimals
        @network = network
        @program_id = program_id
        @description = description
        @external_id = external_id
        @min_voucher_delta = min_voucher_delta
        @recent_blockhash = recent_blockhash
      end

      def to_h
        value = {
          'cap' => cap,
          'currency' => currency,
          'operator' => operator,
          'recipient' => recipient
        }
        value['decimals'] = decimals unless decimals.nil?
        value['network'] = network unless blank?(network)
        value['splits'] = splits.map(&:to_h) unless splits.empty?
        value['programId'] = program_id unless blank?(program_id)
        value['description'] = description unless blank?(description)
        value['externalId'] = external_id unless blank?(external_id)
        value['minVoucherDelta'] = min_voucher_delta unless blank?(min_voucher_delta)
        value['modes'] = modes unless modes.empty?
        value['pullVoucherStrategy'] = pull_voucher_strategy unless pull_voucher_strategy.nil?
        value['recentBlockhash'] = recent_blockhash unless blank?(recent_blockhash)
        value
      end

      def self.from_h(value)
        raise ArgumentError, 'session request must be a Hash' unless value.is_a?(Hash)

        new(
          cap: value.fetch('cap', '').to_s,
          currency: value.fetch('currency', '').to_s,
          operator: value.fetch('operator', '').to_s,
          recipient: value.fetch('recipient', '').to_s,
          decimals: value.key?('decimals') ? value['decimals'].to_i : nil,
          network: optional_string(value['network']),
          splits: value.fetch('splits', []),
          program_id: optional_string(value['programId']),
          description: optional_string(value['description']),
          external_id: optional_string(value['externalId']),
          min_voucher_delta: optional_string(value['minVoucherDelta']),
          modes: value.fetch('modes', []),
          pull_voucher_strategy: optional_string(value['pullVoucherStrategy']),
          recent_blockhash: optional_string(value['recentBlockhash'])
        )
      end

      def self.normalize_mode(mode)
        return mode if [MODE_PUSH, MODE_PULL].include?(mode)

        raise ArgumentError, "unsupported session mode: #{mode}"
      end

      def self.normalize_pull_voucher_strategy(strategy)
        return strategy if [PULL_CLIENT_VOUCHER, PULL_OPERATED_VOUCHER].include?(strategy)

        raise ArgumentError, "unsupported pullVoucherStrategy: #{strategy}"
      end

      def self.assert_required(value, field)
        raise ArgumentError, "#{field} is required" if value.to_s.empty?
      end

      def self.assert_positive_decimal(value, field)
        return if value.to_s.match?(/\A[1-9]\d*\z/)

        raise ArgumentError, "invalid #{field}: #{value}"
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
