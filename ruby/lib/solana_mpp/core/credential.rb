# frozen_string_literal: true

module SolanaMpp
  module Core
    class Credential
      MAX_TOKEN_LENGTH = 16 * 1024

      attr_reader :challenge, :payload, :source

      def initialize(challenge:, payload: {}, source: nil)
        @challenge = challenge
        @payload = payload
        @source = source
      end

      def to_h
        value = {
          'challenge' => challenge.to_h,
          'payload' => payload
        }
        value['source'] = source unless source.nil?
        value
      end

      def to_authorization_header
        "Payment #{Base64Url.encode_json(to_h)}"
      end

      def self.from_authorization_header(header)
        token = extract_payment_token(header)
        raise ArgumentError, "Token exceeds maximum length of #{MAX_TOKEN_LENGTH} bytes" if token.bytesize > MAX_TOKEN_LENGTH

        decoded = Base64Url.decode_json(token)
        challenge = decoded['challenge']
        raise ArgumentError, 'Invalid credential JSON structure' unless challenge.is_a?(Hash)

        payload = decoded.fetch('payload', {})
        raise ArgumentError, 'Credential payload must be an object' unless payload.is_a?(Hash)

        new(
          challenge: ChallengeEcho.from_h(challenge),
          payload: payload,
          source: decoded['source']
        )
      end

      def self.extract_payment_token(header)
        header.to_s.split(',').each do |part|
          trimmed = part.strip
          return trimmed[8..].strip if trimmed.downcase.start_with?('payment ')
        end

        raise ArgumentError, 'Expected Payment scheme'
      end
    end
  end
end
