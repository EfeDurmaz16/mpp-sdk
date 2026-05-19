# frozen_string_literal: true

module SolanaMpp
  module Core
    module Headers
      PAYMENT_SCHEME = 'Payment'
      WWW_AUTHENTICATE = 'www-authenticate'
      AUTHORIZATION = 'authorization'
      PAYMENT_RECEIPT = 'payment-receipt'
      MAX_TOKEN_LENGTH = 16 * 1024

      module_function

      def format_www_authenticate(challenge)
        parts = [
          %(id="#{escape_quoted(challenge.id)}"),
          %(realm="#{escape_quoted(challenge.realm)}"),
          %(method="#{escape_quoted(challenge.method)}"),
          %(intent="#{escape_quoted(challenge.intent)}"),
          %(request="#{escape_quoted(challenge.request)}")
        ]
        parts << %(expires="#{escape_quoted(challenge.expires)}") unless challenge.expires.empty?
        parts << %(digest="#{escape_quoted(challenge.digest)}") unless challenge.digest.empty?
        parts << %(opaque="#{escape_quoted(challenge.opaque)}") unless challenge.opaque.nil?
        "#{PAYMENT_SCHEME} #{parts.join(', ')}"
      end

      def parse_www_authenticate(header)
        rest = strip_payment_scheme(header)
        raise ArgumentError, 'Expected Payment scheme' if rest.nil?

        params = parse_auth_params(rest.strip)
        %w[id realm method intent request].each do |field|
          raise ArgumentError, %(Missing "#{field}" field) if params[field].to_s.empty?
        end
        Base64Url.decode_json(params['request'])

        Challenge.new(
          id: params['id'],
          realm: params['realm'],
          method: params['method'],
          intent: params['intent'],
          request: params['request'],
          expires: params.fetch('expires', ''),
          digest: params.fetch('digest', ''),
          opaque: params['opaque']
        )
      end

      def format_receipt(receipt)
        Base64Url.encode_json(receipt.to_h)
      end

      def parse_receipt(header)
        token = header.to_s.strip
        raise ArgumentError, "Receipt exceeds maximum length of #{MAX_TOKEN_LENGTH} bytes" if token.bytesize > MAX_TOKEN_LENGTH

        Receipt.from_h(Base64Url.decode_json(token))
      end

      def strip_payment_scheme(header)
        value = header.to_s.strip
        return nil unless value.downcase.start_with?("#{PAYMENT_SCHEME.downcase} ")

        value[PAYMENT_SCHEME.length..]
      end

      def parse_auth_params(value)
        params = {}
        i = 0
        while i < value.length
          i += 1 while i < value.length && [" ", "\t", ","].include?(value[i])
          break if i >= value.length

          key_start = i
          i += 1 while i < value.length && !['=', ',', ' ', "\t"].include?(value[i])
          key = value[key_start...i]
          i += 1 while i < value.length && [" ", "\t"].include?(value[i])
          raise ArgumentError, 'Invalid auth parameter' if key.empty? || i >= value.length || value[i] != '='

          i += 1
          i += 1 while i < value.length && [" ", "\t"].include?(value[i])
          if value[i] == '"'
            parsed, i = parse_quoted_value(value, i + 1)
            params[key] = parsed
            next
          end

          value_start = i
          i += 1 while i < value.length && value[i] != ','
          params[key] = value[value_start...i].strip
        end
        params
      end

      def parse_quoted_value(value, index)
        buffer = +''
        i = index
        while i < value.length
          char = value[i]
          if char == '\\'
            i += 1
            raise ArgumentError, 'Invalid quoted value' if i >= value.length

            buffer << value[i]
            i += 1
            next
          end
          return [buffer, i + 1] if char == '"'

          buffer << char
          i += 1
        end

        raise ArgumentError, 'Unterminated quoted value'
      end

      def escape_quoted(value)
        value.to_s.gsub('\\', '\\\\\\').gsub('"', '\\"')
      end
    end
  end
end
