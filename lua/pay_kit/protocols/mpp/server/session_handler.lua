--[[
Server-side session intent: challenge issuance, voucher verification, and
channel lifecycle management.

Mirrors the Rust spine at `rust/crates/mpp/src/server/session.rs`:

  1. build_challenge_request(cap)  -> SessionRequest for the 402 challenge.
  2. process_open(payload)         -> persist ChannelState.
  3. verify_voucher(payload)       -> advance the settled watermark atomically.
  4. begin_delivery(request)       -> reserve a metered delivery + directive.
  5. process_commit(payload)       -> commit a metered delivery (idempotent on
                                      deliveryId; returns replayed on re-send).
  6. process_topup(payload)        -> raise the deposit cap atomically.
  7. process_close(payload)        -> set close-pending, apply final voucher,
                                      return finalize params.
  8. finalize_params(channel_id)   -> on-chain settlement params (blake3
                                      distribution hash, settled watermark).

Amounts are kept as decimal STRINGS end to end (`pay_kit.util.uint`) so u64
values above 2^53 stay exact. Voucher signatures are verified with Ed25519
over the 48-byte payment-channels message (channelId || cumulative LE ||
expiresAt LE).
]]

local uint = require('pay_kit.util.uint')
local base58 = require('pay_kit.solana.base58')
local ed25519 = require('pay_kit.util.ed25519')
local session = require('pay_kit.protocols.mpp.session')
local channel_store = require('pay_kit.protocols.mpp.channel_store')
local payment_channels = require('pay_kit.solana.payment_channels')
local mints = require('pay_kit.solana.mints')

local M = {}

local Server = {}
Server.__index = Server

local function now_seconds()
  return os.time()
end

--- Construct a session server.
-- config:
--   operator (base58)            advertised to clients
--   recipient (base58)           primary payee
--   splits []                    { recipient=<b58>, bps=<number> }
--   max_cap (string/number)      max cap offered per session (u64)
--   currency                     e.g. "USDC" or a mint
--   decimals                     default 6
--   network                      "mainnet" | "devnet" | "localnet"
--   program_id (base58)          optional; defaults to canonical program
--   min_voucher_delta            optional u64 anti-spam minimum
--   modes []                     {'push'} | {'push','pull'} ...
--   pull_voucher_strategy        required when modes includes 'pull'
--   store                        optional channel store (defaults memory)
--   clock                        optional function() -> unix seconds
function M.new(config)
  if type(config) ~= 'table' then
    error('config table is required')
  end
  local instance = {
    operator = config.operator,
    recipient = config.recipient,
    splits = config.splits or {},
    max_cap = uint.normalize(config.max_cap or '10000000'),
    currency = config.currency or 'USDC',
    decimals = config.decimals or 6,
    network = config.network or 'mainnet',
    program_id = config.program_id,
    min_voucher_delta = config.min_voucher_delta and uint.normalize(config.min_voucher_delta) or '0',
    modes = config.modes or { session.MODE_PUSH },
    pull_voucher_strategy = config.pull_voucher_strategy,
    store = config.store or channel_store.memory(),
    clock = config.clock or now_seconds,
  }
  return setmetatable(instance, Server)
end

local function modes_is_push_only(modes)
  return #modes == 1 and modes[1] == session.MODE_PUSH
end

local function modes_contains(modes, mode)
  for i = 1, #modes do
    if modes[i] == mode then return true end
  end
  return false
end

--- Build the SessionRequest to embed in a 402 challenge. `cap` is clamped to
--- `config.max_cap`. A push-only server omits `modes` (clients assume push).
function Server:build_challenge_request(cap)
  local effective_cap = uint.normalize(cap or self.max_cap)
  if uint.compare(effective_cap, self.max_cap) > 0 then
    effective_cap = self.max_cap
  end
  local opts = {
    cap = effective_cap,
    currency = self.currency,
    decimals = self.decimals,
    network = self.network,
    operator = self.operator,
    recipient = self.recipient,
    splits = self.splits,
    program_id = self.program_id,
  }
  if uint.compare(self.min_voucher_delta, '0') > 0 then
    opts.min_voucher_delta = self.min_voucher_delta
  end
  if not modes_is_push_only(self.modes) then
    opts.modes = self.modes
  end
  if modes_contains(self.modes, session.MODE_PULL) then
    opts.pull_voucher_strategy = self.pull_voucher_strategy
  end
  return session.session_request(opts)
end

--- Process an `open` action: validate and persist channel state.
function Server:process_open(payload)
  local supports
  if #self.modes == 0 then
    supports = payload.mode == session.MODE_PUSH
  else
    supports = modes_contains(self.modes, payload.mode)
  end
  if not supports then
    error('Session mode ' .. tostring(payload.mode) .. ' is not supported by this challenge')
  end

  local session_id = session.session_id(payload)
  local deposit = session.deposit_amount(payload)

  if uint.compare(deposit, '0') == 0 then
    error('Deposit must be greater than zero')
  end
  if uint.compare(deposit, self.max_cap) > 0 then
    error('Deposit ' .. deposit .. ' exceeds max cap ' .. self.max_cap)
  end

  local state = channel_store.new_state({
    channel_id = session_id,
    authorized_signer = payload.authorizedSigner,
    deposit = deposit,
    operator = payload.owner or payload.payer,
  })
  self.store:put_channel(session_id, state)
  return state
end

--- Verify an Ed25519 voucher signature against the authorized signer and the
--- voucher expiry. Raises on failure.
function Server:_verify_signature(voucher, authorized_signer)
  local data = voucher.data
  local expires_at = tonumber(data.expiresAt) or 0
  if expires_at <= self.clock() then
    error('Voucher has expired')
  end
  local message = session.voucher_message_bytes(data)
  local pubkey = base58.decode(authorized_signer)
  if #pubkey ~= 32 then
    error('Invalid authorized_signer')
  end
  local sig = base58.decode(voucher.signature)
  if #sig ~= 64 then
    error('Signature is not 64 bytes')
  end
  local ok, err = ed25519.verify(pubkey, message, sig)
  if not ok then
    error('Voucher signature verification failed' .. (err and (': ' .. tostring(err)) or ''))
  end
end

--- Verify a voucher, advance the watermark atomically, return new cumulative.
function Server:verify_voucher(payload)
  local voucher = payload.voucher
  local data = voucher.data
  local channel_id = data.channelId
  local new_cumulative = uint.normalize(session.voucher_cumulative(data))

  local state = self.store:get_channel(channel_id)
  if state == nil then
    error('Channel ' .. tostring(channel_id) .. ' not found')
  end
  if state.finalized then
    error('Channel is already finalized')
  end
  if state.close_requested_at ~= nil then
    error('Channel close is pending - no further vouchers accepted')
  end

  -- Idempotent replay: same cumulative AND same signature.
  if uint.compare(new_cumulative, state.cumulative) == 0
    and state.highest_voucher_signature == voucher.signature then
    self:_verify_signature(voucher, state.authorized_signer)
    return new_cumulative
  end

  if uint.compare(new_cumulative, state.cumulative) <= 0 then
    error('Voucher cumulative ' .. new_cumulative .. ' must exceed watermark ' .. state.cumulative)
  end
  if uint.compare(new_cumulative, state.deposit) > 0 then
    error('Voucher cumulative ' .. new_cumulative .. ' exceeds deposit ' .. state.deposit)
  end
  if uint.compare(self.min_voucher_delta, '0') > 0 then
    local delta = uint.sub(new_cumulative, state.cumulative)
    if uint.compare(delta, self.min_voucher_delta) < 0 then
      error('Voucher delta ' .. delta .. ' is below minimum ' .. self.min_voucher_delta)
    end
  end

  self:_verify_signature(voucher, state.authorized_signer)

  local signature = voucher.signature
  local expires_at = data.expiresAt
  local result = self.store:update_channel(channel_id, function(s)
    if s == nil then error('Channel not found') end
    if s.finalized then error('Channel is already finalized') end
    if s.close_requested_at ~= nil then
      error('Channel close is pending - no further vouchers accepted')
    end
    if uint.compare(new_cumulative, s.cumulative) == 0 and s.highest_voucher_signature == signature then
      return s
    end
    if uint.compare(new_cumulative, s.cumulative) <= 0 then
      error('Concurrent update: watermark advanced')
    end
    s.cumulative = new_cumulative
    s.highest_voucher_signature = signature
    s.highest_voucher_expires_at = expires_at
    return s
  end)
  return result.cumulative
end

--- Process a `topUp` action: atomically raise the deposit cap.
function Server:process_topup(payload)
  local new_deposit = uint.normalize(payload.newDeposit)
  local max_cap = self.max_cap
  return self.store:update_channel(payload.channelId, function(state)
    if state == nil then
      error('Channel ' .. tostring(payload.channelId) .. ' not found')
    end
    if uint.compare(new_deposit, state.deposit) <= 0 then
      error('New deposit ' .. new_deposit .. ' must exceed current deposit ' .. state.deposit)
    end
    if uint.compare(new_deposit, max_cap) > 0 then
      error('New deposit ' .. new_deposit .. ' exceeds max cap ' .. max_cap)
    end
    state.deposit = new_deposit
    return state
  end)
end

--- Reserve capacity for a metered delivery and return the MeteringDirective.
-- request: { session_id, amount, delivery_id?, commit_url?, proof?, expires_at? }
function Server:begin_delivery(request)
  local amount = uint.normalize(request.amount)
  if uint.compare(amount, '0') == 0 then
    error('Delivery amount must be greater than zero')
  end
  local session_id = request.session_id
  local currency = self.currency
  local expires_at = request.expires_at or session.DEFAULT_SESSION_EXPIRES_AT
  local requested_id = request.delivery_id
  local commit_url = request.commit_url
  local proof = request.proof
  local directive

  self.store:update_channel(session_id, function(state)
    if state == nil then
      error('Channel ' .. tostring(session_id) .. ' not found')
    end
    if state.finalized then error('Channel is already finalized') end
    if state.close_requested_at ~= nil then
      error('Channel close is pending - no further deliveries accepted')
    end
    local pending_total = '0'
    for i = 1, #state.pending_deliveries do
      pending_total = uint.add(pending_total, state.pending_deliveries[i].amount)
    end
    local projected = uint.add(uint.add(state.cumulative, pending_total), amount)
    if uint.compare(projected, state.deposit) > 0 then
      error('Delivery amount ' .. amount .. ' exceeds available deposit')
    end

    local sequence = state.next_delivery_sequence + 1
    local delivery_id = requested_id or (session_id .. ':' .. tostring(sequence))
    for i = 1, #state.pending_deliveries do
      if state.pending_deliveries[i].delivery_id == delivery_id then
        error('Delivery ' .. delivery_id .. ' already exists')
      end
    end
    for i = 1, #state.committed_deliveries do
      if state.committed_deliveries[i].delivery_id == delivery_id then
        error('Delivery ' .. delivery_id .. ' already exists')
      end
    end

    state.next_delivery_sequence = sequence
    state.pending_deliveries[#state.pending_deliveries + 1] = {
      delivery_id = delivery_id,
      amount = amount,
      sequence = sequence,
      expires_at = expires_at,
    }

    directive = {
      deliveryId = delivery_id,
      sessionId = session_id,
      amount = amount,
      currency = currency,
      sequence = sequence,
      expiresAt = expires_at,
    }
    if commit_url ~= nil then directive.commitUrl = commit_url end
    if proof ~= nil then directive.proof = proof end
    return state
  end)

  if directive == nil then
    error('Delivery reservation did not produce directive')
  end
  return directive
end

--- Commit a reserved metered delivery. Idempotent on deliveryId: a duplicate
--- commit with the same voucher returns a `replayed` receipt.
function Server:process_commit(payload)
  local voucher = payload.voucher
  local data = voucher.data
  local channel_id = data.channelId
  local new_cumulative = uint.normalize(session.voucher_cumulative(data))

  local state = self.store:get_channel(channel_id)
  if state == nil then
    error('Channel ' .. tostring(channel_id) .. ' not found')
  end

  -- Idempotent replay (read-side fast path).
  for i = 1, #state.committed_deliveries do
    local committed = state.committed_deliveries[i]
    if committed.delivery_id == payload.deliveryId then
      if uint.compare(committed.cumulative, new_cumulative) == 0
        and committed.voucher_signature == voucher.signature then
        self:_verify_signature(voucher, state.authorized_signer)
        return {
          deliveryId = payload.deliveryId,
          sessionId = channel_id,
          amount = committed.amount,
          cumulative = committed.cumulative,
          status = session.COMMIT_STATUS_REPLAYED,
        }
      end
      error('Delivery ' .. payload.deliveryId .. ' was already committed with different voucher')
    end
  end

  local pending
  for i = 1, #state.pending_deliveries do
    if state.pending_deliveries[i].delivery_id == payload.deliveryId then
      pending = state.pending_deliveries[i]
    end
  end
  if pending == nil then
    error('Delivery ' .. payload.deliveryId .. ' not found')
  end
  if (tonumber(pending.expires_at) or 0) <= self.clock() then
    error('Delivery ' .. payload.deliveryId .. ' has expired')
  end
  if uint.compare(new_cumulative, state.cumulative) <= 0 then
    error('Commit cumulative ' .. new_cumulative .. ' must exceed watermark ' .. state.cumulative)
  end
  self:_verify_signature(voucher, state.authorized_signer)

  local delivery_id = payload.deliveryId
  local signature = voucher.signature
  local expires_at = data.expiresAt
  local outcome
  self.store:update_channel(channel_id, function(s)
    if s == nil then error('Channel not found') end
    if s.finalized then error('Channel is already finalized') end
    if s.close_requested_at ~= nil then
      error('Channel close is pending - no further commits accepted')
    end
    for i = 1, #s.committed_deliveries do
      local committed = s.committed_deliveries[i]
      if committed.delivery_id == delivery_id then
        if uint.compare(committed.cumulative, new_cumulative) == 0
          and committed.voucher_signature == signature then
          outcome = { amount = committed.amount, cumulative = committed.cumulative,
            status = session.COMMIT_STATUS_REPLAYED }
          return s
        end
        error('Delivery ' .. delivery_id .. ' was already committed with different voucher')
      end
    end
    local pending_index
    for i = 1, #s.pending_deliveries do
      if s.pending_deliveries[i].delivery_id == delivery_id then
        pending_index = i
      end
    end
    if pending_index == nil then
      error('Delivery ' .. delivery_id .. ' not found')
    end
    local p = s.pending_deliveries[pending_index]
    if (tonumber(p.expires_at) or 0) <= self.clock() then
      error('Delivery ' .. delivery_id .. ' has expired')
    end
    if uint.compare(new_cumulative, s.cumulative) <= 0 then
      error('Commit cumulative ' .. new_cumulative .. ' must exceed watermark ' .. s.cumulative)
    end
    local actual_amount = uint.sub(new_cumulative, s.cumulative)
    if uint.compare(actual_amount, p.amount) > 0 then
      error('Commit amount ' .. actual_amount .. ' exceeds reserved amount ' .. p.amount)
    end

    table.remove(s.pending_deliveries, pending_index)
    s.cumulative = new_cumulative
    s.highest_voucher_signature = signature
    s.highest_voucher_expires_at = expires_at
    s.committed_deliveries[#s.committed_deliveries + 1] = {
      delivery_id = delivery_id,
      amount = actual_amount,
      cumulative = new_cumulative,
      voucher_signature = signature,
    }
    outcome = { amount = actual_amount, cumulative = new_cumulative,
      status = session.COMMIT_STATUS_COMMITTED }
    return s
  end)

  if outcome == nil then
    error('Commit did not produce a receipt')
  end
  return {
    deliveryId = payload.deliveryId,
    sessionId = channel_id,
    amount = outcome.amount,
    cumulative = outcome.cumulative,
    status = outcome.status,
  }
end

--- Process a `close` action: set close-pending, apply a final voucher (if
--- provided), and return finalize params.
function Server:process_close(payload)
  local now = self.clock()
  local voucher = payload.voucher
  local verify_signature = function(v, signer) self:_verify_signature(v, signer) end

  self.store:update_channel(payload.channelId, function(state)
    if state == nil then error('Channel not found') end
    if state.finalized then error('Channel is already finalized') end
    if state.close_requested_at ~= nil then error('Close already requested') end

    local new_cumulative = state.cumulative
    local new_sig = state.highest_voucher_signature
    local new_expires = state.highest_voucher_expires_at
    if voucher ~= nil then
      local cumulative = uint.normalize(session.voucher_cumulative(voucher.data))
      if uint.compare(cumulative, state.cumulative) <= 0 then
        if uint.compare(cumulative, state.cumulative) == 0
          and state.highest_voucher_signature == voucher.signature then
          new_expires = state.highest_voucher_expires_at or voucher.data.expiresAt
        else
          error('Final voucher cumulative ' .. cumulative .. ' must exceed watermark ' .. state.cumulative)
        end
      else
        if uint.compare(cumulative, state.deposit) > 0 then
          error('Final voucher exceeds deposit')
        end
        verify_signature(voucher, state.authorized_signer)
        new_cumulative = cumulative
        new_sig = voucher.signature
        new_expires = voucher.data.expiresAt
      end
    end

    state.cumulative = new_cumulative
    state.highest_voucher_signature = new_sig
    state.highest_voucher_expires_at = new_expires
    state.close_requested_at = now
    return state
  end)

  return self:finalize_params(payload.channelId)
end

--- Return finalize parameters for a channel ready for on-chain settlement.
function Server:finalize_params(channel_id)
  local state = self.store:get_channel(channel_id)
  if state == nil then
    error('Channel ' .. tostring(channel_id) .. ' not found')
  end
  local program_id = self.program_id or payment_channels.default_program_id()
  local mint = mints.resolve_mint(self.currency, self.network)
  local distribution_hash = payment_channels.distribution_hash(self.splits)
  return {
    channel_id = channel_id,
    authorized_signer = state.authorized_signer,
    payer = state.operator,
    mint = mint,
    program_id = program_id,
    settled = state.cumulative,
    voucher_signature = state.highest_voucher_signature,
    voucher_expires_at = state.highest_voucher_expires_at,
    recipient = self.recipient,
    splits = self.splits,
    distribution_hash = distribution_hash,
  }
end

--- Mark a channel finalized (call after the on-chain finalize tx confirms).
function Server:mark_finalized(channel_id)
  return self.store:mark_finalized(channel_id)
end

M.Server = Server
return M
