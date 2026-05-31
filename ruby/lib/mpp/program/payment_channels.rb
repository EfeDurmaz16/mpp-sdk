# frozen_string_literal: true

require "pay_core/solana/base58"
require "pay_core/solana/public_key"
require "pay_core/solana/programs"
require "pay_core/solana/blake3"

module Mpp
  module Program
    # Typed helpers for the on-chain payment-channels program: PDA derivation,
    # associated-token derivation, distribution hashing, and the Borsh voucher
    # byte layout signed by Ed25519.
    #
    # Mirrors the Rust spine `rust/crates/mpp/src/program/payment_channels.rs`.
    # Only the pieces the Ruby server needs are ported: channel PDA, ATA,
    # event-authority PDA, distribution hash, and voucher message bytes. The
    # Anchor instruction encoders live on the client side and are out of scope
    # for the server role.
    module PaymentChannels
      module_function

      # Canonical payment-channels program ID deployed to Surfnet.
      PAYMENT_CHANNELS_PROGRAM_ID = "GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc"

      # Channel PDA seed prefix.
      CHANNEL_SEED = "channel"

      # Event authority PDA seed prefix.
      EVENT_AUTHORITY_SEED = "event_authority"

      # Ed25519 precompile program ID.
      ED25519_PROGRAM_ID = "Ed25519SigVerify111111111111111111111111111"

      # Instructions sysvar ID.
      INSTRUCTIONS_SYSVAR_ID = "Sysvar1nstructions1111111111111111111111111"

      # Rent sysvar ID.
      RENT_SYSVAR_ID = "SysvarRent111111111111111111111111111111111"

      # Treasury owner used by the current payment-channels program deployment.
      TREASURY_OWNER = ([0xBE, 0xEF] * 16).freeze

      def default_program_id
        PAYMENT_CHANNELS_PROGRAM_ID
      end

      # Derive the channel PDA. Seed order mirrors the Rust spine exactly:
      # `b"channel" || payer || payee || mint || authorized_signer || salt_le`.
      def find_channel_pda(payer:, payee:, mint:, authorized_signer:, salt:, program_id: default_program_id)
        ::PayCore::Solana::PublicKey.find_program_address(
          [
            CHANNEL_SEED.b,
            ::PayCore::Solana::PublicKey.new(payer).bytes.pack("C*"),
            ::PayCore::Solana::PublicKey.new(payee).bytes.pack("C*"),
            ::PayCore::Solana::PublicKey.new(mint).bytes.pack("C*"),
            ::PayCore::Solana::PublicKey.new(authorized_signer).bytes.pack("C*"),
            [salt].pack("Q<")
          ],
          program_id
        )
      end

      # Base58 channel address for the supplied open parameters.
      def channel_address(payer:, payee:, mint:, authorized_signer:, salt:, program_id: default_program_id)
        find_channel_pda(
          payer: payer, payee: payee, mint: mint,
          authorized_signer: authorized_signer, salt: salt, program_id: program_id
        ).first.to_s
      end

      # Derive the event-authority PDA for the program.
      def find_event_authority_pda(program_id: default_program_id)
        ::PayCore::Solana::PublicKey.find_program_address([EVENT_AUTHORITY_SEED.b], program_id)
      end

      # Derive the associated token account for an owner/mint/token-program.
      def find_associated_token_address(owner:, mint:, token_program: ::PayCore::Solana::Programs::TOKEN_PROGRAM)
        ::PayCore::Solana::PublicKey.find_program_address(
          [
            ::PayCore::Solana::PublicKey.new(owner).bytes.pack("C*"),
            ::PayCore::Solana::PublicKey.new(token_program).bytes.pack("C*"),
            ::PayCore::Solana::PublicKey.new(mint).bytes.pack("C*")
          ],
          ::PayCore::Solana::Programs::ASSOCIATED_TOKEN_PROGRAM
        ).first.to_s
      end

      # Compute the 32-byte distribution hash committed at channel open.
      #
      # Preimage (matches the program + Rust spine):
      #   u32_le(count) || (recipient_pubkey_bytes || u16_le(bps))*
      #
      # `recipients` is an array of {recipient:, bps:} hashes (recipient is a
      # base58 string). Returns the raw 32-byte binary digest.
      def distribution_hash(recipients)
        hasher = ::PayCore::Solana::Blake3.new
        hasher.update([recipients.length].pack("L<"))
        recipients.each do |entry|
          recipient = entry[:recipient] || entry["recipient"]
          bps = entry[:bps] || entry["bps"]
          hasher.update(::PayCore::Solana::PublicKey.new(recipient).bytes.pack("C*"))
          hasher.update([bps].pack("S<"))
        end
        hasher.digest
      end

      # Serialize the payment-channels `VoucherArgs` bytes signed by Ed25519.
      #
      # Layout: `channel_id (32) || cumulative_amount (u64 LE, 8) ||
      # expires_at (i64 LE, 8)` = 48 bytes. `channel_id` is a base58 address;
      # `cumulative_amount` is an unsigned 64-bit; `expires_at` is a signed
      # 64-bit Unix timestamp.
      def voucher_message_bytes(channel_id:, cumulative_amount:, expires_at:)
        channel_bytes = ::PayCore::Solana::PublicKey.new(channel_id).bytes.pack("C*")
        channel_bytes + [cumulative_amount].pack("Q<") + [expires_at].pack("q<")
      end
    end
  end
end
