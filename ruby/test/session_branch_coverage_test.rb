# frozen_string_literal: true

require_relative "test_helper"
require "ed25519"

# Branch-coverage tests for the session surface: validation error paths,
# wire-shape fallbacks, and store edge cases that the happy-path lifecycle
# tests do not reach.
class SessionBranchCoverageTest < Minitest::Test
  include RubyMppTestHelpers

  S = ::Mpp::Protocol::Intents::Session

  # ── parse_optional_u64 ──

  def test_parse_optional_u64_nil_returns_nil
    assert_nil S.parse_optional_u64(nil)
  end

  def test_parse_optional_u64_passes_integer_through
    assert_equal 7, S.parse_optional_u64(7)
  end

  def test_parse_optional_u64_rejects_non_numeric_string
    assert_raises(ArgumentError) { S.parse_optional_u64("not-a-number") }
  end

  # ── SessionRequest / SessionSplit ──

  def test_session_request_from_h_rejects_non_hash
    assert_raises(ArgumentError) { S::SessionRequest.from_h("nope") }
  end

  def test_session_request_from_h_parses_splits
    request = S::SessionRequest.from_h(
      "cap" => "1", "currency" => "USDC", "operator" => pubkey(1), "recipient" => pubkey(2),
      "splits" => [{"recipient" => pubkey(3), "bps" => 1000}], "decimals" => 6,
      "minVoucherDelta" => "5", "modes" => ["push"], "pullVoucherStrategy" => "clientVoucher"
    )

    assert_equal 1, request.splits.length
    assert_equal pubkey(3), request.splits.first.recipient
    assert_equal "5", request.min_voucher_delta
  end

  def test_session_split_from_h
    split = S::SessionSplit.from_h("recipient" => pubkey(3), "bps" => 2500)

    assert_equal pubkey(3), split.recipient
    assert_equal 2500, split.bps
  end

  # ── VoucherData ──

  def test_voucher_data_from_h_rejects_non_hash
    assert_raises(ArgumentError) { S::VoucherData.from_h([]) }
  end

  def test_voucher_data_from_h_missing_cumulative_raises
    assert_raises(ArgumentError) do
      S::VoucherData.from_h("channelId" => pubkey(9), "expiresAt" => 10)
    end
  end

  def test_voucher_data_cumulative_i_rejects_garbage
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "100", expires_at: 10)
    data.instance_variable_set(:@cumulative, "xx")

    assert_raises(ArgumentError) { data.cumulative_i }
  end

  # ── SignedVoucher ──

  def test_signed_voucher_from_h_rejects_non_hash
    assert_raises(ArgumentError) { S::SignedVoucher.from_h(nil) }
  end

  # ── OpenPayload ──

  def test_open_payload_to_h_includes_pull_fields
    payload = S::OpenPayload.pull(token_account: pubkey(7), approved_amount: 5000, owner: pubkey(8), authorized_signer: pubkey(6), signature: "s")
      .tap { |p| p.instance_variable_set(:@init_multi_delegate_tx, "init") }
    wire = payload.to_h

    assert_equal pubkey(7), wire["tokenAccount"]
    assert_equal "init", wire["initMultiDelegateTx"]
  end

  def test_open_payload_pull_missing_token_account_session_id_raises
    payload = S::OpenPayload.new(mode: S::Mode::PULL, authorized_signer: pubkey(6), signature: "s", approved_amount: "1")

    assert_raises(ArgumentError) { payload.session_id }
  end

  def test_open_payload_push_missing_deposit_raises
    payload = S::OpenPayload.new(mode: S::Mode::PUSH, authorized_signer: pubkey(6), signature: "s", channel_id: pubkey(5))

    assert_raises(ArgumentError) { payload.deposit_amount }
  end

  def test_open_payload_pull_missing_amount_raises
    payload = S::OpenPayload.new(mode: S::Mode::PULL, authorized_signer: pubkey(6), signature: "s", token_account: pubkey(7))

    assert_raises(ArgumentError) { payload.deposit_amount }
  end

  def test_open_payload_invalid_deposit_string_raises
    payload = S::OpenPayload.new(mode: S::Mode::PUSH, authorized_signer: pubkey(6), signature: "s", channel_id: pubkey(5), deposit: "12x")

    assert_raises(ArgumentError) { payload.deposit_amount }
  end

  # ── MeteringDirective / TopUp ──

  def test_metering_directive_roundtrip_with_optional_fields
    directive = S::MeteringDirective.new(
      delivery_id: "d-1", session_id: pubkey(9), amount: "100", currency: "USDC",
      sequence: 1, expires_at: 10, commit_url: "https://x/commit", proof: "p"
    )
    back = S::MeteringDirective.from_h(directive.to_h)

    assert_equal "https://x/commit", back.commit_url
    assert_equal "p", back.proof
    assert_equal 100, back.amount_base_units
  end

  def test_metering_directive_from_h_without_optional_fields
    directive = S::MeteringDirective.from_h(
      "deliveryId" => "d", "sessionId" => pubkey(9), "amount" => "5",
      "currency" => "USDC", "sequence" => 2, "expiresAt" => 10
    )
    wire = directive.to_h

    assert_nil directive.commit_url
    refute wire.key?("commitUrl")
    refute wire.key?("proof")
  end

  def test_metering_directive_amount_base_units_rejects_garbage
    directive = S::MeteringDirective.new(delivery_id: "d", session_id: pubkey(9), amount: "x", currency: "USDC", sequence: 1, expires_at: 10)

    assert_raises(ArgumentError) { directive.amount_base_units }
  end

  def test_topup_new_deposit_amount_rejects_garbage
    payload = S::TopUpPayload.new(channel_id: pubkey(5), new_deposit: "x", signature: "s")

    assert_raises(ArgumentError) { payload.new_deposit_amount }
  end

  # ── ClosePayload ──

  def test_session_action_dispatch_voucher_commit_close
    data = {"channelId" => pubkey(9), "cumulativeAmount" => "10", "expiresAt" => 5}
    voucher = {"data" => data, "signature" => "sig"}

    voucher_action, voucher_payload = S::SessionAction.from_h("action" => "voucher", "voucher" => voucher)
    commit_action, commit_payload = S::SessionAction.from_h("action" => "commit", "deliveryId" => "d", "voucher" => voucher)
    close_action, close_payload = S::SessionAction.from_h("action" => "close", "channelId" => pubkey(5))

    assert_equal "voucher", voucher_action
    assert_instance_of S::VoucherPayload, voucher_payload
    assert_equal "commit", commit_action
    assert_instance_of S::CommitPayload, commit_payload
    assert_equal "close", close_action
    assert_instance_of S::ClosePayload, close_payload
  end

  def test_session_action_from_h_rejects_non_hash
    assert_raises(ArgumentError) { S::SessionAction.from_h("nope") }
  end

  def test_close_payload_from_h_without_voucher
    payload = S::ClosePayload.from_h("action" => "close", "channelId" => pubkey(5))

    assert_nil payload.voucher
  end

  def test_close_payload_from_h_with_voucher
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "10", expires_at: 5)
    payload = S::ClosePayload.new(channel_id: pubkey(5), voucher: S::SignedVoucher.new(data: data, signature: "s"))
    back = S::ClosePayload.from_h(payload.to_h)

    refute_nil back.voucher
    assert_equal "10", back.voucher.data.cumulative
  end

  # ── ChannelStore edges ──

  def test_channel_store_get_missing_returns_nil
    store = ::Mpp::MemoryChannelStore.new

    assert_nil store.get_channel("missing")
  end

  def test_channel_store_update_returns_state
    store = ::Mpp::MemoryChannelStore.new
    store.put_channel("c", ::Mpp::ChannelState.new(channel_id: "c", authorized_signer: pubkey(1), deposit: 100))

    result = store.update_channel("c") do |state|
      state.deposit = 200
      state
    end

    assert_equal 200, result.deposit
    assert_equal 200, store.get_channel("c").deposit
  end

  def test_channel_store_update_nil_return_raises
    store = ::Mpp::MemoryChannelStore.new

    assert_raises(::Mpp::StoreError) { store.update_channel("c") { nil } }
  end

  def test_mark_finalized_missing_channel_raises
    store = ::Mpp::MemoryChannelStore.new

    assert_raises(::Mpp::StoreError) { store.mark_finalized("missing") }
  end

  def test_channel_store_base_class_raises_not_implemented
    store = ::Mpp::ChannelStore.new

    assert_raises(NotImplementedError) { store.get_channel("c") }
    assert_raises(NotImplementedError) { store.put_channel("c", nil) }
    assert_raises(NotImplementedError) { store.update_channel("c") }
  end
end
