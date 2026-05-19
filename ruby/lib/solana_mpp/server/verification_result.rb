# frozen_string_literal: true

module SolanaMpp
  module Server
    class VerificationResult
      attr_reader :reason, :reference, :external_id

      def initialize(ok:, reason: nil, reference: nil, external_id: nil)
        @ok = ok
        @reason = reason.to_s
        @reference = reference.to_s
        @external_id = external_id.to_s
      end

      def ok?
        @ok
      end

      def self.success(reference:, external_id: nil)
        new(ok: true, reference: reference, external_id: external_id)
      end

      def self.failure(reason)
        new(ok: false, reason: reason)
      end
    end
  end
end
