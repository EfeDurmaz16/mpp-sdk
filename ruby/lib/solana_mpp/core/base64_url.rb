# frozen_string_literal: true

require 'base64'
require 'json'

module SolanaMpp
  module Core
    module Base64Url
      module_function

      def encode(value)
        Base64.urlsafe_encode64(value, padding: false)
      end

      def decode(value)
        Base64.urlsafe_decode64(value)
      rescue ArgumentError => e
        raise ArgumentError, "invalid base64url: #{e.message}"
      end

      def encode_json(value)
        encode(JSON.generate(value))
      end

      def decode_json(value)
        JSON.parse(decode(value))
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid JSON: #{e.message}"
      end
    end
  end
end
