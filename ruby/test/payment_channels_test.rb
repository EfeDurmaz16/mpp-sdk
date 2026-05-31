# frozen_string_literal: true

require_relative "test_helper"

# Golden-vector tests for the payment-channels program helpers. The expected
# values are pinned against the Rust spine
# (`rust/crates/mpp/src/program/payment_channels.rs`) and cross-checked by
# running the same inputs through the Rust crate. Interop byte-parity can only
# be fully proven in CI (surfpool); these vectors prove parity locally.
class PaymentChannelsTest < Minitest::Test
  include RubyMppTestHelpers

  PC = ::Mpp::Program::PaymentChannels

  def test_voucher_message_bytes_is_program_borsh_layout
    bytes = PC.voucher_message_bytes(channel_id: pubkey(9), cumulative_amount: 42, expires_at: 1234)

    assert_equal 48, bytes.bytesize
    assert_equal ::PayCore::Solana::Base58.decode(pubkey(9)), bytes.byteslice(0, 32)
    assert_equal [42].pack("Q<"), bytes.byteslice(32, 8)
    assert_equal [1234].pack("q<"), bytes.byteslice(40, 8)
  end

  # Golden vector: byte-for-byte against the Rust spine for the same inputs.
  def test_voucher_message_bytes_golden_vector
    bytes = PC.voucher_message_bytes(channel_id: pubkey(9), cumulative_amount: 42, expires_at: 1234)

    assert_equal(
      "09090909090909090909090909090909090909090909090909090909090909092a00000000000000d204000000000000",
      bytes.unpack1("H*")
    )
  end

  def test_voucher_message_bytes_negative_expiry
    bytes = PC.voucher_message_bytes(channel_id: pubkey(0), cumulative_amount: 0, expires_at: -1)

    assert_equal "\xFF".b * 8, bytes.byteslice(40, 8)
  end

  def test_distribution_hash_matches_program_preimage_shape
    recipients = [
      {recipient: pubkey(1), bps: 7_500},
      {recipient: pubkey(2), bps: 2_500}
    ]

    hasher = ::PayCore::Solana::Blake3.new
    hasher.update([2].pack("L<"))
    hasher.update(::PayCore::Solana::Base58.decode(pubkey(1)))
    hasher.update([7_500].pack("S<"))
    hasher.update(::PayCore::Solana::Base58.decode(pubkey(2)))
    hasher.update([2_500].pack("S<"))

    assert_equal hasher.digest, PC.distribution_hash(recipients)
  end

  # Golden vector: matches the Rust spine distribution_hash output.
  def test_distribution_hash_golden_vector
    recipients = [
      {recipient: pubkey(1), bps: 7_500},
      {recipient: pubkey(2), bps: 2_500}
    ]

    assert_equal(
      "2c00d870359f0a4861c420eaeffdf7a7d6b2cd281024ee69e1f12f743e04c416",
      PC.distribution_hash(recipients).unpack1("H*")
    )
  end

  def test_distribution_hash_empty_recipients
    # An empty split set still hashes its u32 length prefix (count = 0).
    hasher = ::PayCore::Solana::Blake3.new
    hasher.update([0].pack("L<"))

    assert_equal hasher.digest, PC.distribution_hash([])
  end

  def test_distribution_hash_accepts_string_keys
    symbol_keyed = PC.distribution_hash([{recipient: pubkey(1), bps: 5_000}])
    string_keyed = PC.distribution_hash([{"recipient" => pubkey(1), "bps" => 5_000}])

    assert_equal symbol_keyed, string_keyed
  end

  # Golden vector: matches the Rust spine find_channel_pda for the same inputs.
  def test_channel_pda_golden_vector
    address = PC.channel_address(
      payer: pubkey(1), payee: pubkey(2), mint: pubkey(3),
      authorized_signer: pubkey(4), salt: 99
    )

    assert_equal "H4q6bNCrC8R1ieNqoWuMz5V4VmQPLYFhYqTKzsPCejgf", address
  end

  def test_channel_pda_is_deterministic
    args = {payer: pubkey(1), payee: pubkey(2), mint: pubkey(3), authorized_signer: pubkey(4), salt: 7}

    assert_equal PC.channel_address(**args), PC.channel_address(**args)
  end

  def test_channel_pda_salt_changes_address
    base = {payer: pubkey(1), payee: pubkey(2), mint: pubkey(3), authorized_signer: pubkey(4)}

    refute_equal PC.channel_address(salt: 1, **base), PC.channel_address(salt: 2, **base)
  end

  def test_associated_token_address_matches_pay_core_ata
    owner = pubkey(5)
    mint = pubkey(6)
    derived = PC.find_associated_token_address(owner: owner, mint: mint)
    via_core = ::PayCore::Solana::ATA.derive(owner: owner, mint: mint, token_program: ::PayCore::Solana::Programs::TOKEN_PROGRAM)

    assert_equal via_core, derived
  end

  def test_default_program_id
    assert_equal "GuoKrzaBiZnW5DvJ3yZVE7xHqbcBvaX9SH6P6Cn9gNvc", PC.default_program_id
  end
end
