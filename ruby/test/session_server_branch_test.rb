# frozen_string_literal: true

require_relative "test_helper"
require "ed25519"

# Server-side branch-coverage tests: validation error paths and lifecycle
# edges in Mpp::Server::Session not reached by the happy-path tests.
class SessionServerBranchTest < Minitest::Test
  include RubyMppTestHelpers

  S = ::Mpp::Protocol::Intents::Session

  def signer_key
    @signer_key ||= ::Ed25519::SigningKey.new("\x2a".b * 32)
  end

  def authorized_signer
    @authorized_signer ||= ::PayCore::Solana::Base58.encode(signer_key.verify_key.to_bytes)
  end

  def usdc_mint(network = "localnet")
    ::PayCore::Solana::Mints.resolve("USDC", network)
  end

  def make_server(currency: "USDC", network: "localnet", program_id: nil)
    config = ::Mpp::Server::Session::Config.new(
      operator: authorized_signer, recipient: pubkey(7),
      currency: currency, network: network, program_id: program_id
    )
    ::Mpp::Server::Session.new(config: config)
  end

  def signed_voucher(cumulative, channel:, expires_at: S::DEFAULT_SESSION_EXPIRES_AT)
    data = S::VoucherData.new(channel_id: channel, cumulative: cumulative.to_s, expires_at: expires_at)
    signature = ::PayCore::Solana::Base58.encode(signer_key.sign(data.message_bytes))
    S::SignedVoucher.new(data: data, signature: signature)
  end

  # ── Config defaults ──

  def test_config_defaults_modes_to_push_when_empty
    config = ::Mpp::Server::Session::Config.new(operator: authorized_signer, recipient: pubkey(7), modes: [])

    assert_equal [S::Mode::PUSH], config.modes
  end

  def test_build_challenge_request_includes_min_voucher_delta
    config = ::Mpp::Server::Session::Config.new(
      operator: authorized_signer, recipient: pubkey(7), network: "localnet", min_voucher_delta: 250
    )
    request = ::Mpp::Server::Session.new(config: config).build_challenge_request(1000)

    assert_equal "250", request.min_voucher_delta
  end

  def test_process_open_with_empty_modes_accepts_push
    config = ::Mpp::Server::Session::Config.new(operator: authorized_signer, recipient: pubkey(7), network: "localnet")
    # Force an empty modes list to hit the "modes empty -> push only" branch.
    config.instance_variable_set(:@modes, [])
    server = ::Mpp::Server::Session.new(config: config)

    state = server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))

    assert_equal 1000, state.deposit
  end

  def test_process_open_with_empty_modes_rejects_pull
    config = ::Mpp::Server::Session::Config.new(operator: authorized_signer, recipient: pubkey(7), network: "localnet")
    config.instance_variable_set(:@modes, [])
    server = ::Mpp::Server::Session.new(config: config)
    payload = S::OpenPayload.pull(token_account: pubkey(7), approved_amount: 1000, owner: pubkey(8), authorized_signer: authorized_signer, signature: "s")

    assert_raises(::Mpp::VerificationError) { server.process_open(payload) }
  end

  # ── payment_channel_open_params validation ──

  def channel_for(server, salt:, payer: pubkey(1))
    ::Mpp::Program::PaymentChannels.channel_address(
      payer: payer, payee: pubkey(7), mint: usdc_mint, authorized_signer: authorized_signer, salt: salt,
      program_id: server.config.program_id || ::Mpp::Program::PaymentChannels.default_program_id
    )
  end

  def base_payment_channel_payload(server, channel:, salt:, payee: pubkey(7), mint: usdc_mint, grace_period: 3600)
    S::OpenPayload.payment_channel(
      channel_id: channel, deposit: 1000, payer: pubkey(1), payee: payee,
      mint: mint, salt: salt, grace_period: grace_period,
      authorized_signer: authorized_signer, signature: "s"
    )
  end

  def test_open_params_rejects_missing_salt
    server = make_server
    payload = S::OpenPayload.new(
      mode: S::Mode::PUSH, channel_id: pubkey(5), deposit: "1000",
      payer: pubkey(1), payee: pubkey(7), mint: usdc_mint, grace_period: 3600,
      authorized_signer: authorized_signer, signature: "s"
    )

    error = assert_raises(::Mpp::VerificationError) { server.payment_channel_open_params(payload) }
    assert_match(/missing salt/, error.message)
  end

  def test_open_params_rejects_missing_grace_period
    server = make_server
    channel = channel_for(server, salt: 5)
    payload = S::OpenPayload.new(
      mode: S::Mode::PUSH, channel_id: channel, deposit: "1000",
      payer: pubkey(1), payee: pubkey(7), mint: usdc_mint, salt: 5,
      authorized_signer: authorized_signer, signature: "s"
    )

    error = assert_raises(::Mpp::VerificationError) { server.payment_channel_open_params(payload) }
    assert_match(/missing gracePeriod/, error.message)
  end

  def test_open_params_rejects_mismatched_payee
    server = make_server
    channel = channel_for(server, salt: 5)
    payload = base_payment_channel_payload(server, channel: channel, salt: 5, payee: pubkey(2))

    error = assert_raises(::Mpp::VerificationError) { server.payment_channel_open_params(payload) }
    assert_match(/payee does not match/, error.message)
  end

  def test_open_params_rejects_mismatched_mint
    server = make_server
    channel = channel_for(server, salt: 5)
    payload = base_payment_channel_payload(server, channel: channel, salt: 5, mint: pubkey(3))

    error = assert_raises(::Mpp::VerificationError) { server.payment_channel_open_params(payload) }
    assert_match(/mint does not match/, error.message)
  end

  def test_open_params_rejects_empty_pubkey_field
    server = make_server
    payload = S::OpenPayload.new(
      mode: S::Mode::PUSH, channel_id: pubkey(5), deposit: "1000",
      payer: "", payee: pubkey(7), mint: usdc_mint, salt: 5,
      grace_period: 3600, authorized_signer: authorized_signer, signature: "s"
    )

    error = assert_raises(::Mpp::VerificationError) { server.payment_channel_open_params(payload) }
    assert_match(/missing payer/, error.message)
  end

  def test_open_params_rejects_invalid_pubkey_field
    server = make_server
    payload = S::OpenPayload.new(
      mode: S::Mode::PUSH, channel_id: pubkey(5), deposit: "1000",
      payer: "not-base58!!!", payee: pubkey(7), mint: usdc_mint, salt: 5,
      grace_period: 3600, authorized_signer: authorized_signer, signature: "s"
    )

    assert_raises(::Mpp::VerificationError) { server.payment_channel_open_params(payload) }
  end

  def test_open_params_with_explicit_program_id
    program_id = ::Mpp::Program::PaymentChannels.default_program_id
    server = make_server(program_id: program_id)
    channel = channel_for(server, salt: 9)
    payload = base_payment_channel_payload(server, channel: channel, salt: 9)

    params = server.payment_channel_open_params(payload)

    assert_equal program_id, params[:program_id]
  end

  # ── SOL currency / mint resolution ──

  def test_open_params_rejects_sol_currency
    server = make_server(currency: "SOL")
    payload = base_payment_channel_payload(server, channel: pubkey(5), salt: 5)

    error = assert_raises(::Mpp::VerificationError) { server.payment_channel_open_params(payload) }
    assert_match(/require an SPL token/, error.message)
  end

  def test_finalize_params_mint_nil_for_sol_currency
    config = ::Mpp::Server::Session::Config.new(operator: authorized_signer, recipient: pubkey(7), currency: "SOL", network: "localnet")
    server = ::Mpp::Server::Session.new(config: config)
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))

    params = server.finalize_params(pubkey(9))

    assert_nil params.mint
  end

  def test_finalize_params_unknown_channel_raises
    server = make_server

    assert_raises(::Mpp::VerificationError) { server.finalize_params("missing") }
  end

  # ── Voucher / signature edges ──

  def test_verify_voucher_rejects_short_signature
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "100", expires_at: S::DEFAULT_SESSION_EXPIRES_AT)
    voucher = S::SignedVoucher.new(data: data, signature: ::PayCore::Solana::Base58.encode("short"))

    error = assert_raises(::Mpp::VerificationError) { server.verify_voucher(S::VoucherPayload.new(voucher: voucher)) }
    assert_match(/64 bytes/, error.message)
  end

  def test_verify_voucher_rejects_invalid_signer_key
    config = ::Mpp::Server::Session::Config.new(operator: authorized_signer, recipient: pubkey(7), network: "localnet")
    server = ::Mpp::Server::Session.new(config: config)
    state = ::Mpp::ChannelState.new(channel_id: pubkey(9), authorized_signer: "not-base58!!!", deposit: 1000)
    server.store.put_channel(pubkey(9), state)
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "100", expires_at: S::DEFAULT_SESSION_EXPIRES_AT)
    voucher = S::SignedVoucher.new(data: data, signature: ::PayCore::Solana::Base58.encode("a" * 64))

    assert_raises(::Mpp::VerificationError) { server.verify_voucher(S::VoucherPayload.new(voucher: voucher)) }
  end

  # ── Delivery / commit edges ──

  def test_begin_delivery_rejects_zero_amount
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))

    assert_raises(::Mpp::VerificationError) do
      server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: pubkey(9), amount: 0))
    end
  end

  def test_begin_delivery_unknown_channel_raises
    server = make_server

    assert_raises(::Mpp::VerificationError) do
      server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: "missing", amount: 10))
    end
  end

  def test_begin_delivery_rejects_finalized_channel
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    server.mark_finalized(pubkey(9))

    error = assert_raises(::Mpp::VerificationError) do
      server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: pubkey(9), amount: 10))
    end
    assert_match(/finalized/, error.message)
  end

  def test_begin_delivery_rejects_closed_channel
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    server.process_close(S::ClosePayload.new(channel_id: pubkey(9)))

    error = assert_raises(::Mpp::VerificationError) do
      server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: pubkey(9), amount: 10))
    end
    assert_match(/close is pending/, error.message)
  end

  def test_begin_delivery_honors_explicit_delivery_id_and_proof
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))

    directive = server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(
      session_id: pubkey(9), amount: 50, delivery_id: "custom", commit_url: "https://x", proof: "pf", expires_at: S::DEFAULT_SESSION_EXPIRES_AT
    ))

    assert_equal "custom", directive.delivery_id
    assert_equal "https://x", directive.commit_url
    assert_equal "pf", directive.proof
  end

  def test_process_commit_unknown_channel_raises
    server = make_server

    assert_raises(::Mpp::VerificationError) do
      server.process_commit(S::CommitPayload.new(delivery_id: "d", voucher: signed_voucher(100, channel: pubkey(9))))
    end
  end

  def test_process_commit_rejects_expired_delivery
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: pubkey(9), amount: 100, delivery_id: "exp", expires_at: 1))

    error = assert_raises(::Mpp::VerificationError) do
      server.process_commit(S::CommitPayload.new(delivery_id: "exp", voucher: signed_voucher(100, channel: pubkey(9))))
    end
    assert_match(/expired/, error.message)
  end

  def test_process_commit_rejects_non_increasing_cumulative
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(200, channel: pubkey(9))))
    server.begin_delivery(::Mpp::Server::Session::DeliveryRequest.new(session_id: pubkey(9), amount: 100, delivery_id: "d"))

    assert_raises(::Mpp::VerificationError) do
      server.process_commit(S::CommitPayload.new(delivery_id: "d", voucher: signed_voucher(150, channel: pubkey(9))))
    end
  end

  # ── Close edges ──

  def test_process_close_idempotent_final_voucher_replay
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    final = signed_voucher(300, channel: pubkey(9))
    server.verify_voucher(S::VoucherPayload.new(voucher: final))

    # Closing with the same highest voucher (equal cumulative + same sig) is tolerated.
    params = server.process_close(S::ClosePayload.new(channel_id: pubkey(9), voucher: final))

    assert_equal 300, params.settled
  end

  def test_process_close_rejects_voucher_below_watermark
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    server.verify_voucher(S::VoucherPayload.new(voucher: signed_voucher(300, channel: pubkey(9))))

    assert_raises(::Mpp::VerificationError) do
      server.process_close(S::ClosePayload.new(channel_id: pubkey(9), voucher: signed_voucher(100, channel: pubkey(9))))
    end
  end

  def test_process_close_rejects_final_voucher_above_deposit
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 100, authorized_signer: authorized_signer, signature: "s"))

    assert_raises(::Mpp::VerificationError) do
      server.process_close(S::ClosePayload.new(channel_id: pubkey(9), voucher: signed_voucher(500, channel: pubkey(9))))
    end
  end

  def test_process_close_rejects_bad_final_voucher_signature
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    wrong_key = ::Ed25519::SigningKey.new("\x09".b * 32)
    data = S::VoucherData.new(channel_id: pubkey(9), cumulative: "300", expires_at: S::DEFAULT_SESSION_EXPIRES_AT)
    voucher = S::SignedVoucher.new(data: data, signature: ::PayCore::Solana::Base58.encode(wrong_key.sign(data.message_bytes)))

    assert_raises(::Mpp::VerificationError) do
      server.process_close(S::ClosePayload.new(channel_id: pubkey(9), voucher: voucher))
    end
  end

  def test_process_close_unknown_channel_raises
    server = make_server

    assert_raises(::Mpp::VerificationError) do
      server.process_close(S::ClosePayload.new(channel_id: "missing"))
    end
  end

  def test_process_topup_unknown_channel_raises
    server = make_server

    assert_raises(::Mpp::VerificationError) do
      server.process_topup(S::TopUpPayload.new(channel_id: "missing", new_deposit: 100, signature: "s"))
    end
  end

  def test_process_close_rejects_finalized_channel
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    server.mark_finalized(pubkey(9))

    error = assert_raises(::Mpp::VerificationError) do
      server.process_close(S::ClosePayload.new(channel_id: pubkey(9)))
    end
    assert_match(/finalized/, error.message)
  end

  def test_mark_finalized_then_finalize_params
    server = make_server
    server.process_open(S::OpenPayload.push(channel_id: pubkey(9), deposit: 1000, authorized_signer: authorized_signer, signature: "s"))
    server.mark_finalized(pubkey(9))

    assert server.store.get_channel(pubkey(9)).finalized
  end
end
