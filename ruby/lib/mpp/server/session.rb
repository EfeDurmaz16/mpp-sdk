# frozen_string_literal: true

require "ed25519"

require "pay_core/solana/base58"
require "pay_core/solana/mints"

require "mpp/program/payment_channels"
require "mpp/channel_store"
require "mpp/protocol/intents/session"

module Mpp
  module Server
    # Server-side session intent: challenge issuance, voucher verification, and
    # channel lifecycle management. Unlike charge (stateless), the session
    # server tracks per-channel state through a ChannelStore.
    #
    # Mirrors `rust/crates/mpp/src/server/session.rs`. Lifecycle:
    #   1. build_challenge_request -> SessionRequest for the 402 challenge.
    #   2. process_open -> record channel state.
    #   3. verify_voucher / begin_delivery + process_commit -> advance watermark.
    #   4. process_topup -> raise deposit cap.
    #   5. process_close -> accept final voucher, return FinalizeParams.
    class Session
      Intents = ::Mpp::Protocol::Intents::Session

      # Server configuration for the session intent.
      class Config
        attr_reader :operator, :recipient, :splits, :max_cap, :currency,
          :decimals, :network, :program_id, :min_voucher_delta, :modes,
          :pull_voucher_strategy

        def initialize(operator:, recipient:, splits: [], max_cap: 10_000_000,
          currency: "USDC", decimals: 6, network: "mainnet-beta",
          program_id: nil, min_voucher_delta: 0, modes: [Intents::Mode::PUSH],
          pull_voucher_strategy: nil)
          @operator = operator.to_s
          @recipient = recipient.to_s
          @splits = splits || []
          @max_cap = Integer(max_cap)
          @currency = currency.to_s
          @decimals = Integer(decimals)
          @network = network.to_s
          @program_id = program_id
          @min_voucher_delta = Integer(min_voucher_delta)
          @modes = (modes && !modes.empty?) ? modes : [Intents::Mode::PUSH]
          @pull_voucher_strategy = pull_voucher_strategy
        end
      end

      # Parameters needed to submit a finalize + distribute transaction pair.
      class FinalizeParams
        attr_reader :channel_id, :authorized_signer, :payer, :mint, :program_id,
          :settled, :voucher_signature, :voucher_expires_at, :recipient,
          :splits, :distribution_hash

        def initialize(channel_id:, authorized_signer:, payer:, mint:, program_id:,
          settled:, voucher_signature:, voucher_expires_at:, recipient:, splits:,
          distribution_hash:)
          @channel_id = channel_id
          @authorized_signer = authorized_signer
          @payer = payer
          @mint = mint
          @program_id = program_id
          @settled = settled
          @voucher_signature = voucher_signature
          @voucher_expires_at = voucher_expires_at
          @recipient = recipient
          @splits = splits
          @distribution_hash = distribution_hash
        end
      end

      # Request to reserve a metered delivery for client-side commit.
      class DeliveryRequest
        attr_reader :session_id, :amount, :delivery_id, :commit_url, :proof, :expires_at

        def initialize(session_id:, amount:, delivery_id: nil, commit_url: nil, proof: nil, expires_at: nil)
          @session_id = session_id.to_s
          @amount = Integer(amount)
          @delivery_id = delivery_id
          @commit_url = commit_url
          @proof = proof
          @expires_at = expires_at
        end
      end

      def initialize(config:, store: ::Mpp::MemoryChannelStore.new)
        @config = config
        @store = store
      end

      attr_reader :config, :store

      # Build the SessionRequest to embed in a 402 challenge. `cap` is clamped
      # to `config.max_cap`. Modes are omitted when only push is supported
      # (clients assume push when `modes` is absent).
      def build_challenge_request(cap)
        effective_cap = [Integer(cap), config.max_cap].min
        modes = (config.modes == [Intents::Mode::PUSH]) ? [] : config.modes
        pull_strategy = config.modes.include?(Intents::Mode::PULL) ? config.pull_voucher_strategy : nil

        Intents::SessionRequest.new(
          cap: effective_cap.to_s,
          currency: config.currency,
          decimals: config.decimals,
          network: config.network,
          operator: config.operator,
          recipient: config.recipient,
          splits: config.splits.map { |s| Intents::SessionSplit.new(recipient: s[:recipient] || s["recipient"], bps: s[:bps] || s["bps"]) },
          program_id: config.program_id,
          min_voucher_delta: config.min_voucher_delta.positive? ? config.min_voucher_delta.to_s : nil,
          modes: modes,
          pull_voucher_strategy: pull_strategy
        )
      end

      # Validate the open payload's channel parameters against the challenge and
      # confirm the client-provided channelId matches the derived channel PDA.
      # Returns the resolved open params hash (push/payment-channel mode only).
      def payment_channel_open_params(payload)
        payer = require_pubkey(payload.payer, "payer")
        payee = require_pubkey(payload.payee, "payee")
        mint = require_pubkey(payload.mint, "mint")
        authorized_signer = require_pubkey(payload.authorized_signer, "authorizedSigner")
        salt = payload.salt
        raise ::Mpp::VerificationError, "payment-channel open missing salt" if salt.nil?

        grace_period = payload.grace_period
        raise ::Mpp::VerificationError, "payment-channel open missing gracePeriod" if grace_period.nil?

        deposit = payload.deposit_amount
        program_id = config.program_id || ::Mpp::Program::PaymentChannels.default_program_id

        expected_payee = require_pubkey(config.recipient, "recipient")
        expected_mint = expected_payment_channel_mint

        if payee != expected_payee
          raise ::Mpp::VerificationError, "payment-channel open payee does not match challenge recipient"
        end
        if mint != expected_mint
          raise ::Mpp::VerificationError, "payment-channel open mint does not match challenge currency"
        end

        expected_channel = ::Mpp::Program::PaymentChannels.channel_address(
          payer: payer, payee: payee, mint: mint,
          authorized_signer: authorized_signer, salt: salt, program_id: program_id
        )
        channel = require_pubkey(payload.channel_id, "channelId")
        if channel != expected_channel
          raise ::Mpp::VerificationError, "payment-channel open channelId does not match derived channel PDA"
        end

        {
          payer: payer, payee: payee, mint: mint, authorized_signer: authorized_signer,
          salt: salt, deposit: deposit, grace_period: grace_period,
          recipients: config.splits, program_id: program_id, channel: channel
        }
      end

      # Process an `open` action: persist channel state. Accepts push
      # payment-channel opens and operated-voucher pull opens.
      def process_open(payload)
        supports_mode = config.modes.empty? ? payload.mode == Intents::Mode::PUSH : config.modes.include?(payload.mode)
        unless supports_mode
          raise ::Mpp::VerificationError, "Session mode #{payload.mode.inspect} is not supported by this challenge"
        end

        session_id = payload.session_id
        deposit = payload.deposit_amount
        raise ::Mpp::VerificationError, "Deposit must be greater than zero" if deposit.zero?
        raise ::Mpp::VerificationError, "Deposit #{deposit} exceeds max cap #{config.max_cap}" if deposit > config.max_cap

        state = ::Mpp::ChannelState.new(
          channel_id: session_id,
          authorized_signer: payload.authorized_signer,
          deposit: deposit,
          operator: payload.owner || payload.payer
        )
        store.put_channel(session_id, state)
        state
      end

      # Verify a voucher, advance the watermark atomically, and return the new
      # cumulative. Rejects vouchers for unknown/finalized/close-pending
      # channels, non-increasing cumulative (unless an exact idempotent replay),
      # cumulative above the deposit, and below the minimum delta.
      def verify_voucher(payload)
        voucher = payload.voucher
        channel_id = voucher.data.channel_id
        new_cumulative = voucher.data.cumulative_i

        state = store.get_channel(channel_id)
        raise ::Mpp::VerificationError, "Channel #{channel_id} not found" if state.nil?
        raise ::Mpp::VerificationError, "Channel is already finalized" if state.finalized
        if state.close_requested_at
          raise ::Mpp::VerificationError, "Channel close is pending; no further vouchers accepted"
        end

        # Idempotent replay: same cumulative AND same signature.
        if new_cumulative == state.cumulative && state.highest_voucher_signature == voucher.signature
          verify_signature(voucher, state.authorized_signer)
          return new_cumulative
        end

        if new_cumulative <= state.cumulative
          raise ::Mpp::VerificationError, "Voucher cumulative #{new_cumulative} must exceed watermark #{state.cumulative}"
        end
        if new_cumulative > state.deposit
          raise ::Mpp::VerificationError, "Voucher cumulative #{new_cumulative} exceeds deposit #{state.deposit}"
        end
        delta = new_cumulative - state.cumulative
        if config.min_voucher_delta.positive? && delta < config.min_voucher_delta
          raise ::Mpp::VerificationError, "Voucher delta #{delta} is below minimum #{config.min_voucher_delta}"
        end

        verify_signature(voucher, state.authorized_signer)

        sig = voucher.signature
        expires_at = voucher.data.expires_at
        new_state = store_update(channel_id) do |st|
          raise ::Mpp::StoreError, "Channel not found" if st.nil?
          raise ::Mpp::StoreError, "Channel is already finalized" if st.finalized
          raise ::Mpp::StoreError, "Channel close is pending; no further vouchers accepted" if st.close_requested_at
          if new_cumulative == st.cumulative && st.highest_voucher_signature == sig
            next st
          end
          raise ::Mpp::StoreError, "Concurrent update: watermark advanced" if new_cumulative <= st.cumulative

          st.cumulative = new_cumulative
          st.highest_voucher_signature = sig
          st.highest_voucher_expires_at = expires_at
          st
        end
        new_state.cumulative
      end

      # Process a `topUp` action: atomically raise the channel's deposit cap.
      def process_topup(payload)
        new_deposit = payload.new_deposit_amount
        max_cap = config.max_cap
        cid = payload.channel_id
        store_update(cid) do |state|
          raise ::Mpp::StoreError, "Channel #{cid} not found" if state.nil?
          if new_deposit <= state.deposit
            raise ::Mpp::StoreError, "New deposit #{new_deposit} must exceed current deposit #{state.deposit}"
          end
          raise ::Mpp::StoreError, "New deposit #{new_deposit} exceeds max cap #{max_cap}" if new_deposit > max_cap

          state.deposit = new_deposit
          state
        end
      end

      # Reserve capacity for a delivered response and return the metering
      # directive the client must commit after processing it.
      def begin_delivery(request)
        raise ::Mpp::VerificationError, "Delivery amount must be greater than zero" if request.amount.zero?

        session_id = request.session_id
        amount = request.amount
        currency = config.currency
        expires_at = request.expires_at || Intents::DEFAULT_SESSION_EXPIRES_AT
        directive = nil

        store_update(session_id) do |state|
          raise ::Mpp::StoreError, "Channel #{session_id} not found" if state.nil?
          raise ::Mpp::StoreError, "Channel is already finalized" if state.finalized
          raise ::Mpp::StoreError, "Channel close is pending; no further deliveries accepted" if state.close_requested_at

          pending_total = state.pending_deliveries.sum(&:amount)
          if state.cumulative + pending_total + amount > state.deposit
            raise ::Mpp::StoreError, "Delivery amount #{amount} exceeds available deposit"
          end

          sequence = state.next_delivery_sequence + 1
          delivery_id = request.delivery_id || "#{session_id}:#{sequence}"
          exists = state.pending_deliveries.any? { |d| d.delivery_id == delivery_id } ||
            state.committed_deliveries.any? { |d| d.delivery_id == delivery_id }
          raise ::Mpp::StoreError, "Delivery #{delivery_id} already exists" if exists

          state.next_delivery_sequence = sequence
          state.pending_deliveries.push(::Mpp::PendingDelivery.new(
            delivery_id: delivery_id, amount: amount, sequence: sequence, expires_at: expires_at
          ))

          directive = Intents::MeteringDirective.new(
            delivery_id: delivery_id, session_id: session_id, amount: amount.to_s,
            currency: currency, sequence: sequence, expires_at: expires_at,
            commit_url: request.commit_url, proof: request.proof
          )
          state
        end

        raise ::Mpp::VerificationError, "Delivery reservation did not produce directive" if directive.nil?

        directive
      end

      # Commit a reserved delivery: verify the attached voucher and advance the
      # settled watermark. Idempotent on `deliveryId` (returns Replayed for a
      # duplicate commit with the same voucher).
      def process_commit(payload)
        channel_id = payload.voucher.data.channel_id
        new_cumulative = payload.voucher.data.cumulative_i

        state = store.get_channel(channel_id)
        raise ::Mpp::VerificationError, "Channel #{channel_id} not found" if state.nil?

        committed = state.committed_deliveries.find { |d| d.delivery_id == payload.delivery_id }
        if committed
          if committed.cumulative == new_cumulative && committed.voucher_signature == payload.voucher.signature
            verify_signature(payload.voucher, state.authorized_signer)
            return Intents::CommitReceipt.new(
              delivery_id: payload.delivery_id, session_id: channel_id,
              amount: committed.amount.to_s, cumulative: committed.cumulative.to_s,
              status: Intents::CommitStatus::REPLAYED
            )
          end
          raise ::Mpp::VerificationError, "Delivery #{payload.delivery_id} was already committed with different voucher"
        end

        pending = state.pending_deliveries.find { |d| d.delivery_id == payload.delivery_id }
        raise ::Mpp::VerificationError, "Delivery #{payload.delivery_id} not found" if pending.nil?

        now = unix_now
        raise ::Mpp::VerificationError, "Delivery #{payload.delivery_id} has expired" if pending.expires_at <= now
        if new_cumulative <= state.cumulative
          raise ::Mpp::VerificationError, "Commit cumulative #{new_cumulative} must exceed watermark #{state.cumulative}"
        end
        verify_signature(payload.voucher, state.authorized_signer)

        delivery_id = payload.delivery_id
        signature = payload.voucher.signature
        expires_at = payload.voucher.data.expires_at
        outcome = nil

        store_update(channel_id) do |st|
          raise ::Mpp::StoreError, "Channel #{channel_id} not found" if st.nil?
          raise ::Mpp::StoreError, "Channel is already finalized" if st.finalized
          raise ::Mpp::StoreError, "Channel close is pending; no further commits accepted" if st.close_requested_at

          already = st.committed_deliveries.find { |d| d.delivery_id == delivery_id }
          if already
            if already.cumulative == new_cumulative && already.voucher_signature == signature
              outcome = [already.amount, already.cumulative, Intents::CommitStatus::REPLAYED]
              next st
            end
            raise ::Mpp::StoreError, "Delivery #{delivery_id} was already committed with different voucher"
          end

          index = st.pending_deliveries.index { |d| d.delivery_id == delivery_id }
          raise ::Mpp::StoreError, "Delivery #{delivery_id} not found" if index.nil?

          pending_delivery = st.pending_deliveries[index]
          raise ::Mpp::StoreError, "Delivery #{delivery_id} has expired" if pending_delivery.expires_at <= now
          if new_cumulative <= st.cumulative
            raise ::Mpp::StoreError, "Commit cumulative #{new_cumulative} must exceed watermark #{st.cumulative}"
          end
          actual_amount = new_cumulative - st.cumulative
          if actual_amount > pending_delivery.amount
            raise ::Mpp::StoreError, "Commit amount #{actual_amount} exceeds reserved amount #{pending_delivery.amount}"
          end

          st.pending_deliveries.delete_at(index)
          st.cumulative = new_cumulative
          st.highest_voucher_signature = signature
          st.highest_voucher_expires_at = expires_at
          st.committed_deliveries.push(::Mpp::CommittedDelivery.new(
            delivery_id: delivery_id, amount: actual_amount,
            cumulative: new_cumulative, voucher_signature: signature
          ))
          outcome = [actual_amount, new_cumulative, Intents::CommitStatus::COMMITTED]
          st
        end

        raise ::Mpp::VerificationError, "Commit did not produce a receipt" if outcome.nil?

        amount, cumulative, status = outcome
        Intents::CommitReceipt.new(
          delivery_id: payload.delivery_id, session_id: channel_id,
          amount: amount.to_s, cumulative: cumulative.to_s, status: status
        )
      end

      # Process a `close` action: atomically set close-pending, accept a final
      # voucher if provided, and return the FinalizeParams for on-chain settlement.
      def process_close(payload)
        now = unix_now
        voucher = payload.voucher

        store_update(payload.channel_id) do |state|
          raise ::Mpp::StoreError, "Channel not found" if state.nil?
          raise ::Mpp::StoreError, "Channel is already finalized" if state.finalized
          raise ::Mpp::StoreError, "Close already requested" if state.close_requested_at

          if voucher
            cumulative = voucher.data.cumulative_i
            if cumulative <= state.cumulative
              # Idempotent replay of the highest voucher is tolerated.
              unless cumulative == state.cumulative && state.highest_voucher_signature == voucher.signature
                raise ::Mpp::StoreError, "Final voucher cumulative #{cumulative} must exceed watermark #{state.cumulative}"
              end
              state.highest_voucher_expires_at ||= voucher.data.expires_at
            else
              raise ::Mpp::StoreError, "Final voucher exceeds deposit" if cumulative > state.deposit

              begin
                verify_signature(voucher, state.authorized_signer)
              rescue ::Mpp::Error => e
                raise ::Mpp::StoreError, e.message
              end
              state.cumulative = cumulative
              state.highest_voucher_signature = voucher.signature
              state.highest_voucher_expires_at = voucher.data.expires_at
            end
          end

          state.close_requested_at = now
          state
        end

        finalize_params(payload.channel_id)
      end

      # Return finalize parameters for a channel ready for on-chain settlement.
      def finalize_params(channel_id)
        state = store.get_channel(channel_id)
        raise ::Mpp::VerificationError, "Channel #{channel_id} not found" if state.nil?

        recipients = config.splits.map { |s| {recipient: s[:recipient] || s["recipient"], bps: s[:bps] || s["bps"]} }
        FinalizeParams.new(
          channel_id: channel_id,
          authorized_signer: state.authorized_signer,
          payer: state.operator,
          mint: expected_payment_channel_mint_or_nil,
          program_id: config.program_id || ::Mpp::Program::PaymentChannels.default_program_id,
          settled: state.cumulative,
          voucher_signature: state.highest_voucher_signature,
          voucher_expires_at: state.highest_voucher_expires_at,
          recipient: config.recipient,
          splits: config.splits,
          distribution_hash: ::Mpp::Program::PaymentChannels.distribution_hash(recipients)
        )
      end

      # Mark a channel finalized (call after the on-chain finalize tx confirms).
      def mark_finalized(channel_id)
        store.mark_finalized(channel_id)
        nil
      end

      private

      def store_update(channel_id, &block)
        store.update_channel(channel_id, &block)
      rescue ::Mpp::StoreError => e
        raise ::Mpp::VerificationError, e.message
      end

      def unix_now
        Process.clock_gettime(Process::CLOCK_REALTIME, :second)
      end

      def require_pubkey(value, field)
        raise ::Mpp::VerificationError, "payment-channel open missing #{field}" if value.nil? || value.to_s.empty?

        begin
          ::PayCore::Solana::PublicKey.new(value).to_s
        rescue ArgumentError => e
          raise ::Mpp::VerificationError, "invalid payment-channel #{field}: #{e.message}"
        end
      end

      def expected_payment_channel_mint
        mint = ::PayCore::Solana::Mints.resolve(config.currency, config.network)
        if mint.nil? || mint.to_s.casecmp("SOL").zero?
          raise ::Mpp::VerificationError, "payment-channel sessions require an SPL token"
        end

        ::PayCore::Solana::PublicKey.new(mint).to_s
      end

      def expected_payment_channel_mint_or_nil
        expected_payment_channel_mint
      rescue ::Mpp::Error
        nil
      end

      # Verify an Ed25519 voucher signature against the authorized signer and
      # reject expired vouchers.
      def verify_signature(voucher, authorized_signer)
        raise ::Mpp::VerificationError, "Voucher has expired" if voucher.data.expires_at <= unix_now

        message = voucher.data.message_bytes
        sig_bytes = ::PayCore::Solana::Base58.decode(voucher.signature)
        raise ::Mpp::VerificationError, "Signature is not 64 bytes" unless sig_bytes.bytesize == 64

        key_bytes = ::PayCore::Solana::PublicKey.new(authorized_signer).bytes.pack("C*")
        verify_key = ::Ed25519::VerifyKey.new(key_bytes)
        unless verify_key.verify(sig_bytes, message)
          raise ::Mpp::VerificationError, "Voucher signature verification failed"
        end
      rescue ::Ed25519::VerifyError
        raise ::Mpp::VerificationError, "Voucher signature verification failed"
      rescue ArgumentError => e
        raise ::Mpp::VerificationError, "Invalid voucher signature material: #{e.message}"
      end
    end
  end
end
