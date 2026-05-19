# frozen_string_literal: true

module SolanaMpp
  module Server
    class SubscriptionServer
      attr_reader :secret_key, :realm, :method

      def initialize(secret_key:, realm:, method: 'solana')
        @secret_key = secret_key
        @realm = realm
        @method = method
      end

      def create_challenge(request, expires: nil, digest: nil, opaque: nil)
        Core::Challenge.with_secret(
          secret_key: secret_key,
          realm: realm,
          method: method,
          intent: 'subscription',
          request: request.to_h,
          expires: expires,
          digest: digest,
          opaque: opaque
        )
      end

      def create_challenge_header(request, expires: nil, digest: nil, opaque: nil)
        Core::Headers.format_www_authenticate(create_challenge(
          request,
          expires: expires,
          digest: digest,
          opaque: opaque
        ))
      end

      def verify_authorization_header(authorization_header, verifier:, now: Time.now)
        credential = Core::Credential.from_authorization_header(authorization_header)
        challenge = challenge_from_echo(credential.challenge)

        return VerificationResult.failure('challenge method or intent mismatch') if challenge.method != method || challenge.intent != 'subscription'
        return VerificationResult.failure('challenge verification failed') unless challenge.verify?(secret_key)
        return VerificationResult.failure('challenge expired') if challenge.expired?(now)

        Intents::SubscriptionRequest.from_h(challenge.decode_request)
        call_verifier(verifier, credential, challenge)
      rescue ArgumentError => e
        VerificationResult.failure(e.message)
      end

      def create_receipt_header(challenge, result)
        raise ArgumentError, 'Cannot create a receipt for a failed verification' unless result.ok?

        Core::Headers.format_receipt(Core::Receipt.success(
          method: challenge.method,
          reference: result.reference,
          challenge_id: challenge.id,
          external_id: result.external_id
        ))
      end

      private

      def challenge_from_echo(echo)
        Core::Challenge.new(
          id: echo.id,
          realm: echo.realm,
          method: echo.method,
          intent: echo.intent,
          request: echo.request,
          expires: echo.expires,
          digest: echo.digest,
          opaque: echo.opaque
        )
      end

      def call_verifier(verifier, credential, challenge)
        return verifier.verify(credential, challenge) if verifier.respond_to?(:verify)
        return verifier.call(credential, challenge) if verifier.respond_to?(:call)

        raise ArgumentError, 'verifier must respond to verify or call'
      end
    end
  end
end
