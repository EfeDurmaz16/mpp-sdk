# frozen_string_literal: true

module Mpp
  # Persisted state of a payment channel, managed by the session server.
  #
  # Unlike the charge replay store (a write-once consumed-signature set), the
  # session server tracks lifecycle: the settled watermark, the authorized
  # signer, pending/committed metered deliveries, and close/finalize flags.
  #
  # Mirrors `rust/crates/mpp/src/store.rs` (ChannelState / ChannelStore).
  class ChannelState
    attr_accessor :channel_id, :authorized_signer, :deposit, :cumulative,
      :finalized, :highest_voucher_signature, :highest_voucher_expires_at,
      :close_requested_at, :operator, :next_delivery_sequence,
      :pending_deliveries, :committed_deliveries

    def initialize(channel_id:, authorized_signer:, deposit:, cumulative: 0,
      finalized: false, highest_voucher_signature: nil,
      highest_voucher_expires_at: nil, close_requested_at: nil, operator: nil,
      next_delivery_sequence: 0, pending_deliveries: [], committed_deliveries: [])
      @channel_id = channel_id
      @authorized_signer = authorized_signer
      @deposit = deposit
      @cumulative = cumulative
      @finalized = finalized
      @highest_voucher_signature = highest_voucher_signature
      @highest_voucher_expires_at = highest_voucher_expires_at
      @close_requested_at = close_requested_at
      @operator = operator
      @next_delivery_sequence = next_delivery_sequence
      @pending_deliveries = pending_deliveries
      @committed_deliveries = committed_deliveries
    end

    # Deep copy so a store updater never mutates the persisted object in place.
    def dup_state
      ChannelState.new(
        channel_id: channel_id,
        authorized_signer: authorized_signer,
        deposit: deposit,
        cumulative: cumulative,
        finalized: finalized,
        highest_voucher_signature: highest_voucher_signature,
        highest_voucher_expires_at: highest_voucher_expires_at,
        close_requested_at: close_requested_at,
        operator: operator,
        next_delivery_sequence: next_delivery_sequence,
        pending_deliveries: pending_deliveries.map(&:dup),
        committed_deliveries: committed_deliveries.map(&:dup)
      )
    end
  end

  # A delivery reserved by the server but not yet committed by the client.
  class PendingDelivery
    attr_accessor :delivery_id, :amount, :sequence, :expires_at

    def initialize(delivery_id:, amount:, sequence:, expires_at:)
      @delivery_id = delivery_id
      @amount = amount
      @sequence = sequence
      @expires_at = expires_at
    end

    def dup
      PendingDelivery.new(delivery_id: delivery_id, amount: amount, sequence: sequence, expires_at: expires_at)
    end
  end

  # A committed delivery, kept for idempotent commit replay.
  class CommittedDelivery
    attr_accessor :delivery_id, :amount, :cumulative, :voucher_signature

    def initialize(delivery_id:, amount:, cumulative:, voucher_signature:)
      @delivery_id = delivery_id
      @amount = amount
      @cumulative = cumulative
      @voucher_signature = voucher_signature
    end

    def dup
      CommittedDelivery.new(delivery_id: delivery_id, amount: amount, cumulative: cumulative, voucher_signature: voucher_signature)
    end
  end

  # Raised when a store update closure rejects a transition.
  class StoreError < StandardError; end

  # Channel store interface with atomic read-modify-write.
  #
  # Implementations MUST guarantee that `update_channel` is atomic so no
  # concurrent voucher/commit/topup/close can interleave and double-spend.
  class ChannelStore
    def get_channel(_channel_id)
      raise NotImplementedError
    end

    def put_channel(_channel_id, _state)
      raise NotImplementedError
    end

    # Atomically read-modify-write. The block receives the current state (or
    # nil if absent) and returns the new state, or raises StoreError to abort.
    def update_channel(_channel_id)
      raise NotImplementedError
    end

    def mark_finalized(channel_id)
      update_channel(channel_id) do |state|
        raise StoreError, "Channel #{channel_id} not found" if state.nil?

        state.finalized = true
        state
      end
    end
  end

  # Thread-safe in-memory channel store for tests and single-process servers.
  #
  # A single mutex guards the whole map; `update_channel` holds it across the
  # entire read-modify-write, giving the atomicity the session server relies on.
  class MemoryChannelStore < ChannelStore
    def initialize
      @mutex = Mutex.new
      @channels = {}
    end

    def get_channel(channel_id)
      @mutex.synchronize do
        state = @channels[channel_id]
        state&.dup_state
      end
    end

    def put_channel(channel_id, state)
      @mutex.synchronize { @channels[channel_id] = state.dup_state }
    end

    def update_channel(channel_id)
      @mutex.synchronize do
        current = @channels[channel_id]
        new_state = yield(current&.dup_state)
        raise StoreError, "channel updater returned nil" if new_state.nil?

        @channels[channel_id] = new_state.dup_state
        new_state
      end
    end
  end
end
