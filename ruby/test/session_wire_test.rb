# frozen_string_literal: true

require_relative "test_helper"

# Wire-shape tests for the session intent types. Mirrors the serde tests in
# `rust/crates/mpp/src/protocol/intents/session.rs::tests`.
class SessionWireTest < Minitest::Test
  include RubyMppTestHelpers

  S = ::Mpp::Protocol::Intents::Session

  # ── Mode / strategy serde ──

  def test_mode_constants
    assert_equal "push", S::Mode::PUSH
    assert_equal "pull", S::Mode::PULL
  end

  def test_pull_voucher_strategy_constants
    assert_equal "clientVoucher", S::PullVoucherStrategy::CLIENT_VOUCHER
    assert_equal "operatedVoucher", S::PullVoucherStrategy::OPERATED_VOUCHER
  end

  def test_commit_status_constants
    assert_equal "committed", S::CommitStatus::COMMITTED
    assert_equal "replayed", S::CommitStatus::REPLAYED
  end

  def test_default_session_expires_at_is_below_max_safe_integer
    assert_equal 4_102_444_800, S::DEFAULT_SESSION_EXPIRES_AT
    assert_operator S::DEFAULT_SESSION_EXPIRES_AT, :<, (2**53) - 1
  end

  # ── SessionRequest ──

  def test_session_request_omits_empty_splits_and_modes
    request = S::SessionRequest.new(
      cap: "10000000", currency: "USDC", operator: pubkey(1), recipient: pubkey(2),
      decimals: 6, network: "localnet"
    )
    wire = request.to_h

    refute wire.key?("splits")
    refute wire.key?("modes")
    refute wire.key?("pullVoucherStrategy")
    refute wire.key?("minVoucherDelta")
    assert_equal "10000000", wire["cap"]
    assert_equal 6, wire["decimals"]
  end

  def test_session_request_serializes_splits_and_modes_when_present
    request = S::SessionRequest.new(
      cap: "5000", currency: "USDC", operator: pubkey(1), recipient: pubkey(2),
      splits: [S::SessionSplit.new(recipient: pubkey(3), bps: 1000)],
      modes: [S::Mode::PUSH, S::Mode::PULL],
      pull_voucher_strategy: S::PullVoucherStrategy::OPERATED_VOUCHER,
      min_voucher_delta: "1000", program_id: pubkey(4), external_id: "ref-1"
    )
    wire = request.to_h

    assert_equal [{"recipient" => pubkey(3), "bps" => 1000}], wire["splits"]
    assert_equal ["push", "pull"], wire["modes"]
    assert_equal "operatedVoucher", wire["pullVoucherStrategy"]
    assert_equal "1000", wire["minVoucherDelta"]
    assert_equal pubkey(4), wire["programId"]
    assert_equal "ref-1", wire["externalId"]
  end

  def test_session_request_roundtrip
    request = S::SessionRequest.new(
      cap: "5000", currency: "USDC", operator: pubkey(1), recipient: pubkey(2),
      modes: [S::Mode::PULL], pull_voucher_strategy: S::PullVoucherStrategy::CLIENT_VOUCHER
    )
    back = S::SessionRequest.from_h(request.to_h)

    assert_equal request.to_h, back.to_h
  end

  def test_session_request_carries_recent_blockhash_and_description
    request = S::SessionRequest.new(
      cap: "5000", currency: "USDC", operator: pubkey(1), recipient: pubkey(2),
      description: "metered API", recent_blockhash: pubkey(8)
    )
    wire = request.to_h

    assert_equal "metered API", wire["description"]
    assert_equal pubkey(8), wire["recentBlockhash"]
    assert_equal "metered API", S::SessionRequest.from_h(wire).description
  end

  # ── OpenPayload ──

  def test_open_push_builder
    payload = S::OpenPayload.push(channel_id: pubkey(5), deposit: 1_000_000, authorized_signer: pubkey(6), signature: "sig")

    assert_equal "push", payload.mode
    assert_equal pubkey(5), payload.session_id
    assert_equal 1_000_000, payload.deposit_amount
    wire = payload.to_h
    assert_equal "open", wire["action"]
    assert_equal "1000000", wire["deposit"]
    refute wire.key?("salt")
  end

  def test_open_payment_channel_salt_serializes_as_string
    payload = S::OpenPayload.payment_channel(
      channel_id: pubkey(5), deposit: 1000, payer: pubkey(1), payee: pubkey(2),
      mint: pubkey(3), salt: 18_446_744_073_709_551_615, grace_period: 3600,
      authorized_signer: pubkey(6), signature: "sig"
    )
    wire = payload.to_h

    assert_equal "18446744073709551615", wire["salt"]
    assert_kind_of String, wire["salt"]
    assert_equal 3600, wire["gracePeriod"]
  end

  def test_open_salt_deserializes_from_string_or_number
    from_string = S::OpenPayload.from_h(
      "action" => "open", "mode" => "push", "salt" => "42",
      "authorizedSigner" => pubkey(6), "signature" => "sig", "channelId" => pubkey(5), "deposit" => "1"
    )
    from_number = S::OpenPayload.from_h(
      "action" => "open", "mode" => "push", "salt" => 42,
      "authorizedSigner" => pubkey(6), "signature" => "sig", "channelId" => pubkey(5), "deposit" => "1"
    )

    assert_equal 42, from_string.salt
    assert_equal 42, from_number.salt
    assert_equal "42", from_string.to_h["salt"]
  end

  def test_open_pull_builder_session_id_is_token_account
    payload = S::OpenPayload.pull(
      token_account: pubkey(7), approved_amount: 5000, owner: pubkey(8),
      authorized_signer: pubkey(6), signature: "sig"
    )

    assert_equal "pull", payload.mode
    assert_equal pubkey(7), payload.session_id
    assert_equal 5000, payload.deposit_amount
    assert_equal "5000", payload.to_h["approvedAmount"]
  end

  def test_open_push_missing_channel_id_raises
    payload = S::OpenPayload.new(mode: S::Mode::PUSH, authorized_signer: pubkey(6), signature: "sig", deposit: "1")

    assert_raises(ArgumentError) { payload.session_id }
  end

  # ── Vouchers ──

  def test_voucher_data_serializes_cumulative_amount_only
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "100", expires_at: 1234)
    wire = data.to_h

    assert_equal "100", wire["cumulativeAmount"]
    refute wire.key?("cumulative")
    assert_equal 1234, wire["expiresAt"]
  end

  def test_voucher_data_reads_cumulative_alias
    via_alias = S::VoucherData.from_h("channelId" => pubkey(9), "cumulative" => "55", "expiresAt" => 10)
    via_canonical = S::VoucherData.from_h("channelId" => pubkey(9), "cumulativeAmount" => "55", "expiresAt" => 10)

    assert_equal "55", via_alias.cumulative
    assert_equal "55", via_canonical.cumulative
  end

  def test_voucher_data_canonical_name_wins_over_alias
    data = S::VoucherData.from_h(
      "channelId" => pubkey(9), "cumulativeAmount" => "100", "cumulative" => "1", "expiresAt" => 10
    )

    assert_equal "100", data.cumulative
  end

  def test_voucher_data_message_bytes_roundtrips_against_program
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "42", expires_at: 1234)
    expected = ::Mpp::Program::PaymentChannels.voucher_message_bytes(channel_id: pubkey(9), cumulative_amount: 42, expires_at: 1234)

    assert_equal expected, data.message_bytes
  end

  def test_signed_voucher_roundtrip
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "100", expires_at: 1234, nonce: 3)
    voucher = S::SignedVoucher.new(data: data, signature: "abc")
    back = S::SignedVoucher.from_h(voucher.to_h)

    assert_equal "100", back.data.cumulative
    assert_equal 3, back.data.nonce
    assert_equal "abc", back.signature
  end

  # ── Action tags ──

  def test_topup_action_tag_uses_capital_u
    payload = S::TopUpPayload.new(channel_id: pubkey(5), new_deposit: 2000, signature: "sig")

    assert_equal "topUp", payload.to_h["action"]
    assert_equal "2000", payload.to_h["newDeposit"]
  end

  def test_session_action_dispatch_by_tag
    open_action, open_payload = S::SessionAction.from_h(
      "action" => "open", "mode" => "push", "authorizedSigner" => pubkey(6),
      "signature" => "sig", "channelId" => pubkey(5), "deposit" => "1"
    )
    topup_action, = S::SessionAction.from_h(
      "action" => "topUp", "channelId" => pubkey(5), "newDeposit" => "2", "signature" => "sig"
    )

    assert_equal "open", open_action
    assert_instance_of S::OpenPayload, open_payload
    assert_equal "topUp", topup_action
  end

  def test_session_action_unknown_tag_raises
    assert_raises(ArgumentError) { S::SessionAction.from_h("action" => "bogus") }
  end

  def test_commit_payload_roundtrip
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "100", expires_at: 10)
    payload = S::CommitPayload.new(delivery_id: "d-1", voucher: S::SignedVoucher.new(data: data, signature: "s"))
    back = S::CommitPayload.from_h(payload.to_h)

    assert_equal "commit", payload.to_h["action"]
    assert_equal "d-1", back.delivery_id
    assert_equal "100", back.voucher.data.cumulative
  end

  def test_close_payload_omits_voucher_when_absent
    payload = S::ClosePayload.new(channel_id: pubkey(5))

    refute payload.to_h.key?("voucher")
    assert_equal "close", payload.to_h["action"]
  end
end
