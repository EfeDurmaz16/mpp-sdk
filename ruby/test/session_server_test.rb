# frozen_string_literal: true

require_relative "test_helper"
require "ed25519"

# Server-side session lifecycle tests. Mirrors
# `rust/crates/mpp/src/server/session.rs::tests`: open, voucher monotonicity,
# cap enforcement, min-delta, idempotent replay, top-up, metered delivery
# commit idempotency, and cooperative close.
class SessionServerTest < Minitest::Test
  include RubyMppTestHelpers

  S = ::Mpp::Protocol::Intents::Session

  # Deterministic Ed25519 session key from a fixed seed.
  def signer_key
    @signer_key ||= ::Ed25519::SigningKey.new("\x2a".b * 32)
  end

  def authorized_signer
    @authorized_signer ||= ::PayCore::Solana::Base58.encode(signer_key.verify_key.to_bytes)
  end

  def channel_id
    pubkey(9)
  end

  def make_server(min_voucher_delta: 0, max_cap: 10_000_000)
    config = ::Mpp::Server::Session::Config.new(
      operator: authorized_signer, recipient: pubkey(7),
      max_cap: max_cap, currency: "USDC", network: "localnet",
      min_voucher_delta: min_voucher_delta
    )
    ::Mpp::Server::Session.new(config: config, store: ::Mpp::MemoryChannelStore.new)
  end

  def open_server(server, deposit: 1_000_000)
    payload = S::OpenPayload.push(channel_id: channel_id, deposit: deposit, authorized_signer: authorized_signer, signature: "open_sig")
    server.process_open(payload)
  end

  # Build a signed voucher for `cumulative` on the test channel.
  def signed_voucher(cumulative, expires_at: S::DEFAULT_SESSION_EXPIRES_AT, channel: channel_id, key: signer_key)
    data = S::VoucherData.new(channel_id: channel, cumulative: cumulative.to_s, expires_at: expires_at)
    signature = ::PayCore::Solana::Base58.encode(key.sign(data.message_bytes))
    S::SignedVoucher.new(data: data, signature: signature)
  end

  # ── Challenge ──

  def test_build_challenge_request_clamps_cap_and_omits_push_only_modes
    server = make_server(max_cap: 5_000)
    request = server.build_challenge_request(1_000_000)

    assert_equal "5000", request.cap
    assert_empty request.modes
    assert_equal "localnet", request.network
    assert_equal "USDC", request.currency
  end

  def test_build_challenge_request_advertises_pull_strategy
    config = ::Mpp::Server::Session::Config.new(
      operator: authorized_signer, recipient: pubkey(7), network: "localnet",
      modes: [S::Mode::PUSH, S::Mode::PULL],
      pull_voucher_strategy: S::PullVoucherStrategy::OPERATED_VOUCHER
    )
    server = ::Mpp::Server::Session.new(config: config)
    request = server.build_challenge_request(1_000)

    assert_equal ["push", "pull"], request.modes
    assert_equal "operatedVoucher", request.pull_voucher_strategy
  end

  # ── Open ──

  def test_process_open_persists_channel_state
    server = make_server
    state = open_server(server, deposit: 500_000)

    assert_equal channel_id, state.channel_id
    assert_equal authorized_signer, state.authorized_signer
    assert_equal 500_000, state.deposit
    assert_equal 0, state.cumulative
    refute state.finalized
  end

  def test_process_open_rejects_zero_deposit
    server = make_server
    payload = S::OpenPayload.push(channel_id: channel_id, deposit: 0, authorized_signer: authorized_signer, signature: "s")

    assert_raises(::Mpp::VerificationError) { server.process_open(payload) }
  end

  def test_process_open_rejects_deposit_above_cap
    server = make_server(max_cap: 100)
    payload = S::OpenPayload.push(channel_id: channel_id, deposit: 1_000, authorized_signer: authorized_signer, signature: "s")

    assert_raises(::Mpp::VerificationError) { server.process_open(payload) }
  end

  def test_process_open_rejects_unsupported_mode
    server = make_server
    payload = S::OpenPayload.pull(token_account: pubkey(7), approved_amount: 1000, owner: pubkey(8), authorized_signer: authorized_signer, signature: "s")

    assert_raises(::Mpp::VerificationError) { server.process_open(payload) }
  end

  # ── Voucher ──

  def test_verify_voucher_advances_watermark
    server = make_server
    open_server(server)

    first = server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(100)))
    second = server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(250)))

    assert_equal 100, first
    assert_equal 250, second
  end

  def test_verify_voucher_rejects_non_increasing_cumulative
    server = make_server
    open_server(server)
    server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(200)))

    assert_raises(::Mpp::VerificationError) do
      server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(150)))
    end
  end

  def test_verify_voucher_idempotent_replay_returns_same_cumulative
    server = make_server
    open_server(server)
    voucher = signed_voucher(300)
    payload = S::VoucherPayload.new(voucher: voucher)

    first = server.verify_voucher(payload)
    replay = server.verify_voucher(payload)

    assert_equal 300, first
    assert_equal 300, replay
  end

  def test_verify_voucher_rejects_cumulative_above_deposit
    server = make_server
    open_server(server, deposit: 1000)

    assert_raises(::Mpp::VerificationError) do
      server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(2000)))
    end
  end

  def test_verify_voucher_enforces_min_delta
    server = make_server(min_voucher_delta: 1000)
    open_server(server)
    server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(1000)))

    error = assert_raises(::Mpp::VerificationError) do
      server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(1500)))
    end
    assert_match(/below minimum/, error.message)

    # A voucher meeting the minimum delta is accepted.
    assert_equal 2000, server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(2000)))
  end

  def test_verify_voucher_rejects_bad_signature
    server = make_server
    open_server(server)
    wrong_key = ::Ed25519::SigningKey.new("\x07".b * 32)
    voucher = signed_voucher(100, key: wrong_key)

    assert_raises(::Mpp::VerificationError) do
      server.verify_voucher(S::VoucherPayload.new(voucher: voucher))
    end
  end

  def test_verify_voucher_rejects_expired_voucher
    server = make_server
    open_server(server)
    voucher = signed_voucher(100, expires_at: 1)

    error = assert_raises(::Mpp::VerificationError) do
      server.verify_voucher(S::VoucherPayload.new(voucher: voucher))
    end
    assert_match(/expired/, error.message)
  end

  def test_verify_voucher_rejects_unknown_channel
    server = make_server

    assert_raises(::Mpp::VerificationError) do
      server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(100)))
    end
  end

  # ── Top-up ──

  def test_process_topup_raises_deposit
    server = make_server
    open_server(server, deposit: 1000)

    state = server.process_topup(S::TopUpPayload.new(channel_id: channel_id, new_deposit: 5000, signature: "tx"))

    assert_equal 5000, state.deposit
  end

  def test_process_topup_rejects_non_increasing_deposit
    server = make_server
    open_server(server, deposit: 5000)

    assert_raises(::Mpp::VerificationError) do
      server.process_topup(S::TopUpPayload.new(channel_id: channel_id, new_deposit: 1000, signature: "tx"))
    end
  end

  def test_process_topup_rejects_above_cap
    server = make_server(max_cap: 2000)
    open_server(server, deposit: 1000)

    assert_raises(::Mpp::VerificationError) do
      server.process_topup(S::TopUpPayload.new(channel_id: channel_id, new_deposit: 3000, signature: "tx"))
    end
  end

  # ── Metered delivery commit ──

  def test_begin_delivery_then_commit_advances_watermark
    server = make_server
    open_server(server)

    directive = server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: channel_id, amount: 100))

    assert_equal "100", directive.amount
    assert_equal 1, directive.sequence
    assert_equal "USDC", directive.currency

    receipt = server.process_commit(S::CommitPayload.new(delivery_id: directive.delivery_id, voucher: signed_voucher(100)))

    assert_equal "committed", receipt.status
    assert_equal "100", receipt.cumulative
    assert_equal "100", receipt.amount
  end

  def test_process_commit_is_idempotent_on_delivery_id
    server = make_server
    open_server(server)
    directive = server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: channel_id, amount: 100))
    voucher = signed_voucher(100)
    payload = S::CommitPayload.new(delivery_id: directive.delivery_id, voucher: voucher)

    first = server.process_commit(payload)
    replay = server.process_commit(payload)

    assert_equal "committed", first.status
    assert_equal "replayed", replay.status
    assert_equal first.cumulative, replay.cumulative

    # The watermark did not double-advance.
    assert_equal 100, server.store.get_channel(channel_id).cumulative
  end

  def test_process_commit_rejects_different_voucher_for_committed_delivery
    server = make_server
    open_server(server)
    directive = server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: channel_id, amount: 200))
    server.process_commit(S::CommitPayload.new(delivery_id: directive.delivery_id, voucher: signed_voucher(100)))

    # Re-commit the same delivery id with a different cumulative.
    assert_raises(::Mpp::VerificationError) do
      server.process_commit(S::CommitPayload.new(delivery_id: directive.delivery_id, voucher: signed_voucher(150)))
    end
  end

  def test_begin_delivery_rejects_amount_over_available_deposit
    server = make_server
    open_server(server, deposit: 100)

    assert_raises(::Mpp::VerificationError) do
      server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: channel_id, amount: 200))
    end
  end

  def test_begin_delivery_rejects_duplicate_delivery_id
    server = make_server
    open_server(server)
    server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: channel_id, amount: 100, delivery_id: "dup"))

    assert_raises(::Mpp::VerificationError) do
      server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: channel_id, amount: 100, delivery_id: "dup"))
    end
  end

  def test_process_commit_unknown_delivery_raises
    server = make_server
    open_server(server)

    assert_raises(::Mpp::VerificationError) do
      server.process_commit(S::CommitPayload.new(delivery_id: "nope", voucher: signed_voucher(100)))
    end
  end

  # ── Close + finalize ──

  def test_process_close_applies_final_voucher_and_returns_finalize_params
    server = make_server
    open_server(server)
    server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(100)))

    params = server.process_close(S::ClosePayload.new(channel_id: channel_id, voucher: signed_voucher(500)))

    assert_equal channel_id, params.channel_id
    assert_equal 500, params.settled
    assert_equal authorized_signer, params.authorized_signer
    assert_equal 32, params.distribution_hash.bytesize
    assert_equal pubkey(7), params.recipient
  end

  def test_process_close_without_voucher_keeps_watermark
    server = make_server
    open_server(server)
    server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(250)))

    params = server.process_close(S::ClosePayload.new(channel_id: channel_id))

    assert_equal 250, params.settled
  end

  def test_voucher_rejected_after_close_requested
    server = make_server
    open_server(server)
    server.process_close(S::ClosePayload.new(channel_id: channel_id))

    assert_raises(::Mpp::VerificationError) do
      server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(100)))
    end
  end

  def test_process_close_rejects_double_close
    server = make_server
    open_server(server)
    server.process_close(S::ClosePayload.new(channel_id: channel_id))

    assert_raises(::Mpp::VerificationError) do
      server.process_close(S::ClosePayload.new(channel_id: channel_id))
    end
  end

  def test_mark_finalized_blocks_further_vouchers
    server = make_server
    open_server(server)
    server.mark_finalized(channel_id)

    assert_raises(::Mpp::VerificationError) do
      server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(100)))
    end
  end

  def test_payment_channel_open_params_validates_derived_channel
    config = ::Mpp::Server::Session::Config.new(
      operator: authorized_signer, recipient: pubkey(7), network: "localnet"
    )
    server = ::Mpp::Server::Session.new(config: config)
    mint = ::PayCore::Solana::Mints.resolve("USDC", "localnet")
    channel = ::Mpp::Program::PaymentChannels.channel_address(
      payer: pubkey(1), payee: pubkey(7), mint: mint, authorized_signer: authorized_signer, salt: 5
    )
    payload = S::OpenPayload.payment_channel(
      channel_id: channel, deposit: 1000, payer: pubkey(1), payee: pubkey(7),
      mint: mint, salt: 5, grace_period: 3600, authorized_signer: authorized_signer, signature: "s"
    )

    params = server.payment_channel_open_params(payload)

    assert_equal channel, params[:channel]
    assert_equal 5, params[:salt]
  end

  def test_payment_channel_open_params_rejects_mismatched_channel
    config = ::Mpp::Server::Session::Config.new(
      operator: authorized_signer, recipient: pubkey(7), network: "localnet"
    )
    server = ::Mpp::Server::Session.new(config: config)
    mint = ::PayCore::Solana::Mints.resolve("USDC", "localnet")
    payload = S::OpenPayload.payment_channel(
      channel_id: pubkey(2), deposit: 1000, payer: pubkey(1), payee: pubkey(7),
      mint: mint, salt: 5, grace_period: 3600, authorized_signer: authorized_signer, signature: "s"
    )

    assert_raises(::Mpp::VerificationError) { server.payment_channel_open_params(payload) }
  end
end
