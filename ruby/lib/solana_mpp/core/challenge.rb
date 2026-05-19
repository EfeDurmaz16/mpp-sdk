# frozen_string_literal: true

require 'openssl'
require 'time'

module SolanaMpp
  module Core
    class Challenge
      attr_reader :id, :realm, :method, :intent, :request, :expires, :digest, :opaque

      def initialize(id:, realm:, method:, intent:, request:, expires: nil, digest: nil, opaque: nil)
        raise ArgumentError, 'Challenge is missing required fields' if [id, realm, method, intent, request].any? { |value| value.to_s.empty? }
        raise ArgumentError, 'Challenge method must be lowercase ASCII' unless method.match?(/\A[a-z]+\z/)

        @id = id
        @realm = realm
        @method = method
        @intent = intent
        @request = request
        @expires = expires.to_s
        @digest = digest.to_s
        @opaque = opaque
      end

      def self.with_secret(secret_key:, realm:, method:, intent:, request:, expires: nil, digest: nil, opaque: nil)
        encoded_request = Base64Url.encode_json(request)
        new(
          id: compute_id(
            secret_key: secret_key,
            realm: realm,
            method: method,
            intent: intent,
            request: encoded_request,
            expires: expires.to_s,
            digest: digest.to_s,
            opaque: opaque
          ),
          realm: realm,
          method: method,
          intent: intent,
          request: encoded_request,
          expires: expires,
          digest: digest,
          opaque: opaque
        )
      end

      def self.compute_id(secret_key:, realm:, method:, intent:, request:, expires: nil, digest: nil, opaque: nil)
        message = [realm, method, intent, request, expires.to_s, digest.to_s, opaque.to_s].join('|')
        Base64Url.encode(OpenSSL::HMAC.digest('sha256', secret_key, message))
      end

      def verify?(secret_key)
        expected = self.class.compute_id(
          secret_key: secret_key,
          realm: realm,
          method: method,
          intent: intent,
          request: request,
          expires: expires,
          digest: digest,
          opaque: opaque
        )
        secure_compare(expected, id)
      end

      def expired?(now = Time.now)
        return false if expires.nil? || expires.empty?

        Time.iso8601(expires) <= now
      rescue ArgumentError
        true
      end

      def decode_request
        Base64Url.decode_json(request)
      end

      def to_echo
        ChallengeEcho.new(
          id: id,
          realm: realm,
          method: method,
          intent: intent,
          request: request,
          expires: expires,
          digest: digest,
          opaque: opaque
        )
      end

      private

      def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        a.bytes.zip(b.bytes).reduce(0) { |memo, pair| memo | (pair[0] ^ pair[1]) }.zero?
      end
    end

    class ChallengeEcho
      attr_reader :id, :realm, :method, :intent, :request, :expires, :digest, :opaque

      def initialize(id:, realm:, method:, intent:, request:, expires: nil, digest: nil, opaque: nil)
        @id = id
        @realm = realm
        @method = method
        @intent = intent
        @request = request
        @expires = expires.to_s
        @digest = digest.to_s
        @opaque = opaque
      end

      def to_h
        value = {
          'id' => id,
          'realm' => realm,
          'method' => method,
          'intent' => intent,
          'request' => request
        }
        value['expires'] = expires unless expires.empty?
        value['digest'] = digest unless digest.empty?
        value['opaque'] = opaque unless opaque.nil?
        value
      end

      def self.from_h(value)
        raise ArgumentError, 'challenge must be a Hash' unless value.is_a?(Hash)

        new(
          id: value.fetch('id', '').to_s,
          realm: value.fetch('realm', '').to_s,
          method: value.fetch('method', '').to_s,
          intent: value.fetch('intent', '').to_s,
          request: value.fetch('request', '').to_s,
          expires: value.fetch('expires', '').to_s,
          digest: value.fetch('digest', '').to_s,
          opaque: value['opaque']
        )
      end
    end
  end
end
